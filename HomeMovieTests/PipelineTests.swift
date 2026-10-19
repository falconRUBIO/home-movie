import XCTest
import AVFoundation
import CoreImage
import MetalKit
@testable import HomeMovie

final class PipelineTests: XCTestCase {
    @MainActor func testQuickMoviesStartStandardWithoutNamingAndRecordingSettingsLockAfterFirstScene() async throws {
        let store = try await makeStore()
        let first = try await store.createQuickMovie()
        let second = try await store.createQuickMovie()
        XCTAssertFalse(first.name.isEmpty)
        XCTAssertNotEqual(first.name, second.name)
        XCTAssertEqual(first.captureProfile, .standard)
        XCTAssertNil(first.look)
        XCTAssertNil(first.recordingFormat)
        try await store.setMovieRecordingSettings(movieID: first.id, profile: .appleLog, look: .filmica)
        let logSnapshots = await store.snapshot()
        XCTAssertEqual(logSnapshots.first { $0.id == first.id }?.captureProfile, .appleLog)
        try await store.setMovieRecordingSettings(movieID: first.id, profile: .standard, look: nil)
        try await store.rename(first.id, name: "Optional custom title")
        let renamed = await store.snapshot()
        XCTAssertEqual(renamed.first { $0.id == first.id }?.name, "Optional custom title")
        _ = try await record(first, into: store)
        do {
            try await store.setMovieRecordingSettings(movieID: first.id, profile: .appleLog, look: .filmica)
            XCTFail("Existing recordings must not be relabeled as Log")
        } catch {}
        let saved = await store.snapshot()
        XCTAssertEqual(saved.first { $0.id == first.id }?.captureProfile, .standard)
        XCTAssertEqual(saved.first { $0.id == first.id }?.activeScenes.count, 1)
    }

    @MainActor func testRecordingUILockUsesVisibleInterfaceRatherThanSensorAngle() {
        // Portrait selfie can report a landscape capture angle (and vice versa).
        for angle: CGFloat in [0, 90, 180, 270] {
            XCTAssertEqual(OrientationPolicy.interfaceFormat(.portrait, observed: angle), .portrait)
            XCTAssertEqual(OrientationPolicy.interfaceFormat(.portraitUpsideDown, observed: angle), .portrait)
            XCTAssertEqual(OrientationPolicy.interfaceFormat(.landscapeLeft, observed: angle), .landscape)
            XCTAssertEqual(OrientationPolicy.interfaceFormat(.landscapeRight, observed: angle), .landscape)
        }
        XCTAssertEqual(OrientationPolicy.interfaceFormat(.unknown, observed: 90), .portrait)
        XCTAssertEqual(OrientationPolicy.interfaceFormat(.unknown, observed: 0), .landscape)
    }

    func testLogMovieFileRotationPreservesCameraCompensationForEveryCanvas() {
        for format in MovieFormat.allCases {
            for observed: CGFloat in [0, 90, 180, 270, 359.5, -90, 450] {
                let expected = (observed.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
                XCTAssertEqual(format.recordingAngle(observed: observed, profile: .appleLog), expected)
                XCTAssertEqual(format.recordingAngle(observed: observed, profile: .standard),
                    format.recordingAngle(observed: observed))
            }
        }
        // Native portrait selfie pixels must stay portrait when the coordinator
        // reports zero. The old canvas-based 90° correction made them landscape.
        for (format, native, observed) in [
            (MovieFormat.portrait, CGSize(width: 1080, height: 1920), CGFloat(0)),
            (.portrait, CGSize(width: 1080, height: 1920), CGFloat(180)),
            (.portrait, CGSize(width: 1920, height: 1080), CGFloat(90)),
            (.portrait, CGSize(width: 1920, height: 1080), CGFloat(270)),
            (.landscape, CGSize(width: 1080, height: 1920), CGFloat(90)),
            (.landscape, CGSize(width: 1920, height: 1080), CGFloat(0))
        ] {
            let angle = format.recordingAngle(observed: observed, profile: .appleLog)
            let rect = CGRect(origin: .zero, size: native).applying(CGAffineTransform(rotationAngle: angle * .pi / 180))
            XCTAssertEqual(rect.width, format.canvas.width, accuracy: 0.001)
            XCTAssertEqual(rect.height, format.canvas.height, accuracy: 0.001)
        }
        XCTAssertEqual(MovieFormat.portrait.recordingAngle(observed: .nan, profile: .appleLog), 90)
        XCTAssertEqual(MovieFormat.landscape.recordingAngle(observed: .infinity, profile: .appleLog), 0)
    }

    @MainActor func testDuplicateSceneOwnsMediaPreservesEditsAndInsertsAfterOriginal() async throws {
        let store = try await makeStore()
        let project = try await store.create(name: "Duplicate", format: .landscape)
        for _ in 0..<2 { _ = try await record(project, into: store) }
        let snapshots = await store.snapshot()
        let movie = try XCTUnwrap(snapshots.first)
        let original = movie.activeScenes[0]
        let latest = movie.latestTake?.id
        let light = SceneAdjustments(exposure: 0.1, shadows: 0.2, highlights: -0.2)
        var effects = FilmEffectsSettings.off; effects.grainEnabled = true
        try await store.duplicateScene(movieID: project.id, sceneID: original.id,
            start: CMTime(seconds: 0.25, preferredTimescale: 600),
            end: CMTime(seconds: 1.5, preferredTimescale: 600), adjustments: light, filmEffects: effects)
        let reopened = ProjectStore(root: store.root)
        _ = try await reopened.load()
        let saved = await reopened.snapshot()
        let result = try XCTUnwrap(saved.first)
        XCTAssertEqual(result.activeScenes.count, 3)
        XCTAssertEqual(result.exportEffects, effects)
        XCTAssertEqual(result.activeScenes[0].id, original.id)
        XCTAssertEqual(result.activeScenes[2].id, movie.activeScenes[1].id)
        let duplicate = result.activeScenes[1]
        XCTAssertNotEqual(duplicate.id, original.id)
        XCTAssertNotEqual(duplicate.source, original.source)
        XCTAssertEqual(duplicate.duplicateOf, original.id)
        XCTAssertEqual(duplicate.lightAdjustments, light)
        XCTAssertEqual(duplicate.playableDuration.seconds, 1.25, accuracy: 0.001)
        XCTAssertEqual(result.latestTake?.id, latest)
        XCTAssertNil(duplicate.photosAssetID)
        let originalBytes = try Data(contentsOf: store.root.appendingPathComponent(original.source))
        XCTAssertEqual(try Data(contentsOf: store.root.appendingPathComponent(duplicate.source)), originalBytes)
        try await reopened.setSceneDeleted(movieID: project.id, sceneID: original.id, deleted: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.root.appendingPathComponent(duplicate.source).path))
    }

    @MainActor func testUndoLastTakeUsesCaptureOrderAfterReordering() async throws {
        let store = try await makeStore()
        let project = try await store.create(name: "Latest take", format: .landscape)
        for _ in 0..<2 { _ = try await record(project, into: store) }
        let snapshots = await store.snapshot()
        let movie = try XCTUnwrap(snapshots.first)
        let latest = try XCTUnwrap(movie.latestTake)
        let before = movie.activeScenes.map(\.id)
        try await store.reorderScenes(movieID: project.id, order: Array(before.reversed()), expected: before)
        let reordered = await store.snapshot()
        XCTAssertEqual(reordered.first?.latestTake?.id, latest.id)
        try await store.undoLastTake(movieID: project.id, expectedSceneID: latest.id)
        let undone = await store.snapshot()
        XCTAssertFalse(undone.first?.activeScenes.contains { $0.id == latest.id } ?? true)
        XCTAssertEqual(undone.first?.activeScenes.count, 1)
    }

    @MainActor func testCompleteSceneOrderSupportsUndoAndRejectsStaleChanges() async throws {
        let store = try await makeStore()
        let project = try await store.create(name: "Reorder Undo", format: .landscape)
        for _ in 0..<3 { _ = try await record(project, into: store) }
        let snapshots = await store.snapshot()
        let original = try XCTUnwrap(snapshots.first)
        let before = original.activeScenes.map(\.id)
        let after = [before[2], before[0], before[1]]
        try await store.reorderScenes(movieID: project.id, order: after, expected: before)
        let reopened = ProjectStore(root: store.root)
        _ = try await reopened.load()
        let saved = await reopened.snapshot()
        XCTAssertEqual(saved.first?.activeScenes.map(\.id), after)
        do {
            try await reopened.reorderScenes(movieID: project.id, order: before, expected: before)
            XCTFail("An obsolete order must be rejected")
        } catch {}
        do {
            try await reopened.reorderScenes(movieID: project.id, order: [before[0], before[0], before[1]], expected: after)
            XCTFail("Duplicate IDs must be rejected")
        } catch {}
        try await reopened.reorderScenes(movieID: project.id, order: before, expected: after)
        let undone = await reopened.snapshot()
        XCTAssertEqual(undone.first?.activeScenes.map(\.id), before)
        for scene in original.scenes {
            XCTAssertEqual(undone.first?.scenes.first { $0.id == scene.id }, scene)
        }
    }

    @MainActor func testSceneReorderingPersistsAndPreservesDeletedScenes() async throws {
        let store = try await makeStore()
        let project = try await store.create(name: "Reordering", format: .landscape)
        for _ in 0..<3 { _ = try await record(project, into: store) }
        let snapshots = await store.snapshot()
        let original = try XCTUnwrap(snapshots.first)
        let scenes = original.activeScenes
        try await store.setSceneDeleted(movieID: project.id, sceneID: scenes[1].id, deleted: true)
        try await store.moveScene(movieID: project.id, sceneID: scenes[2].id, to: scenes[0].id)
        let reopened = ProjectStore(root: store.root)
        _ = try await reopened.load()
        let saved = await reopened.snapshot()
        let moved = try XCTUnwrap(saved.first)
        XCTAssertEqual(moved.activeScenes.map(\.id), [scenes[2].id, scenes[0].id])
        XCTAssertGreaterThan(moved.revision, original.revision)
        XCTAssertEqual(Set(moved.scenes.map(\.sequence)).count, 3)
        for scene in scenes {
            var expected = scene
            let actual = try XCTUnwrap(moved.scenes.first { $0.id == scene.id })
            expected.sequence = actual.sequence
            expected.deletedAt = actual.deletedAt
            XCTAssertEqual(actual, expected, "Reordering must preserve media, trims and looks")
        }
        try await reopened.moveScene(movieID: project.id, sceneID: scenes[2].id, to: scenes[0].id)
        try await reopened.setSceneDeleted(movieID: project.id, sceneID: scenes[1].id, deleted: false)
        let restored = await reopened.snapshot()
        XCTAssertEqual(restored.first?.activeScenes.map(\.id), scenes.map(\.id))
    }

    @MainActor func testExportValidationRejectsLostAudioAndWrongGeometry() async throws {
        let store = try await makeStore()
        let created = try await store.create(name: "Export validation", format: .landscape)
        _ = try await record(created, into: store)
        let movies = await store.snapshot()
        var movie = try XCTUnwrap(movies.first)
        var info = MediaInfo(duration: movie.duration, size: movie.format.canvas, hasAudio: false, bytes: 100)
        XCTAssertTrue(ExportModel.matchesExport(info, movie: movie), "Silent source scenes should remain valid")
        movie.scenes[0].hasAudio = true
        XCTAssertFalse(ExportModel.matchesExport(info, movie: movie), "Matching dimensions must not conceal missing sound")
        info.hasAudio = true
        XCTAssertTrue(ExportModel.matchesExport(info, movie: movie))
        info.size = CGSize(width: 1080, height: 1920)
        XCTAssertFalse(ExportModel.matchesExport(info, movie: movie))
        info.size = movie.format.canvas; info.duration = CMTimeAdd(movie.duration, CMTime(seconds: 1, preferredTimescale: 600))
        XCTAssertFalse(ExportModel.matchesExport(info, movie: movie))
    }

    @MainActor func testSceneLightEditsPersistIndependentlyAndClipExportKeepsOnlySelectedTrim() async throws {
        let store = try await makeStore()
        let project = try await store.create(name: "Clip light", format: .landscape)
        _ = try await record(project, into: store); _ = try await record(project, into: store)
        let beforeSnapshots = await store.snapshot()
        let before = try XCTUnwrap(beforeSnapshots.first)
        let first = try XCTUnwrap(before.activeScenes.first), last = try XCTUnwrap(before.activeScenes.last)
        let originalURL = store.root.appendingPathComponent(first.source)
        let bytes = try Data(contentsOf: originalURL)
        let lutURL = store.root.appendingPathComponent(LUTReference.filmica.path)
        let lutBytes = try Data(contentsOf: lutURL)
        let recipe = SceneAdjustments(exposure: 0.1, shadows: 0.2, highlights: -0.3,
            warmth: 0.15, tint: -0.1, contrast: 0.35, blackPoint: -0.2, whitePoint: -0.15, saturation: -0.4, vibrance: 0.5)
        try await store.editScene(movieID: project.id, sceneID: first.id,
            start: CMTime(seconds: 0.25, preferredTimescale: 600), end: CMTime(seconds: 1.75, preferredTimescale: 600), adjustments: recipe)
        let reopened = ProjectStore(root: store.root); _ = try await reopened.load()
        let snapshots = await reopened.snapshot()
        let movie = try XCTUnwrap(snapshots.first)
        let edited = try XCTUnwrap(movie.activeScenes.first)
        XCTAssertEqual(edited.lightAdjustments, recipe)
        XCTAssertEqual(movie.activeScenes.last?.id, last.id)
        XCTAssertEqual(movie.activeScenes.last?.lightAdjustments, .neutral)
        XCTAssertEqual(try Data(contentsOf: originalURL), bytes)
        XCTAssertEqual(try Data(contentsOf: lutURL), lutBytes)
        let watch = try await MediaAssembler().build(movie: movie, root: store.root)
        let firstInstruction = try XCTUnwrap(watch.videoComposition.instructions.first as? ColorInstruction)
        XCTAssertEqual(firstInstruction.adjustments, recipe)
        let clip = try ExportModel.singleSceneMovie(movie: movie, scene: edited)
        XCTAssertEqual(clip.activeScenes.map(\.id), [first.id])
        XCTAssertEqual(clip.duration.seconds, 1.5, accuracy: 0.0001)
        XCTAssertNotEqual(ExportModel.cachePrefix(movie: clip), ExportModel.cachePrefix(movie: movie))
        let export = try await MediaAssembler().build(movie: clip, root: store.root, filmEffects: clip.exportEffects)
        XCTAssertEqual(export.duration.seconds, 1.5, accuracy: 0.0001)
        XCTAssertEqual((export.videoComposition.instructions.first as? ColorInstruction)?.adjustments, recipe)
        XCTAssertEqual(export.videoComposition.renderSize, movie.format.canvas)
        let preview = try await MediaAssembler().build(movie: clip, root: store.root, forFilmEffectsPreview: true)
        var frames: [Data] = []
        for bundle in [watch, preview, export] {
            let generator = AVAssetImageGenerator(asset: bundle.asset)
            generator.videoComposition = bundle.videoComposition
            generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
            let image = try await generator.image(at: CMTime(value: 15, timescale: 30)).image
            frames.append(try XCTUnwrap(image.dataProvider?.data) as Data)
        }
        XCTAssertEqual(frames[0], frames[1]); XCTAssertEqual(frames[1], frames[2])
        let original = try await MediaAssembler().build(movie: movie, root: store.root, showOriginalLog: true)
        XCTAssertEqual((original.videoComposition.instructions.first as? ColorInstruction)?.adjustments, .neutral)
    }
    @MainActor func testSceneAndMovieFXSaveAtomicallyAndReachClipExport() async throws {
        let store = try await makeStore()
        let project = try await store.create(name: "Combined recipe", format: .landscape)
        _ = try await record(project, into: store)
        let snapshots = await store.snapshot()
        let before = try XCTUnwrap(snapshots.first)
        let scene = try XCTUnwrap(before.activeScenes.first)
        var fx = FilmEffectsSettings.off
        fx.halationEnabled = true; fx.bloomEnabled = true; fx.grainEnabled = true
        let light = SceneAdjustments(exposure: 0.2, warmth: 0.1, tint: -0.1)
        try await store.editScene(movieID: project.id, sceneID: scene.id,
            start: scene.trimStart.cmTime, end: scene.trimEnd.cmTime, adjustments: light, filmEffects: fx)
        let reopened = ProjectStore(root: store.root); _ = try await reopened.load()
        let saved = await reopened.snapshot()
        let movie = try XCTUnwrap(saved.first)
        XCTAssertEqual(movie.revision, before.revision + 1)
        XCTAssertEqual(movie.exportEffects, fx)
        XCTAssertEqual(movie.activeScenes.first?.lightAdjustments, light)
        let clip = try ExportModel.singleSceneMovie(movie: movie, scene: movie.activeScenes[0])
        let bundle = try await MediaAssembler().build(movie: clip, root: store.root, filmEffects: clip.exportEffects)
        let instruction = try XCTUnwrap(bundle.videoComposition.instructions.first as? ColorInstruction)
        XCTAssertEqual(instruction.filmEffects, fx)
        XCTAssertEqual(instruction.adjustments, light)
        // A later Light-only save must preserve the movie's FX.
        try await reopened.editScene(movieID: movie.id, sceneID: scene.id,
            start: scene.trimStart.cmTime, end: scene.trimEnd.cmTime, adjustments: .neutral)
        let afterLight = await reopened.snapshot()
        XCTAssertEqual(afterLight.first?.exportEffects, fx)
        // FX-only edits still invalidate the export revision.
        try await reopened.editScene(movieID: movie.id, sceneID: scene.id,
            start: scene.trimStart.cmTime, end: scene.trimEnd.cmTime, adjustments: .neutral, filmEffects: .off)
        let afterReset = await reopened.snapshot()
        XCTAssertEqual(afterReset.first?.exportEffects, .off)
        XCTAssertEqual(afterReset.first?.revision, movie.revision + 2)
    }

    @MainActor func testInvalidCombinedSceneEditDoesNotPartiallySaveFX() async throws {
        let store = try await makeStore()
        let project = try await store.create(name: "Atomic recipe", format: .landscape)
        _ = try await record(project, into: store)
        let snapshots = await store.snapshot()
        let before = try XCTUnwrap(snapshots.first)
        let scene = try XCTUnwrap(before.activeScenes.first)
        var fx = FilmEffectsSettings.off; fx.grainEnabled = true
        do {
            try await store.editScene(movieID: project.id, sceneID: scene.id,
                start: .zero, end: CMTime(seconds: 100, preferredTimescale: 600), adjustments: .neutral, filmEffects: fx)
            XCTFail("Invalid trim should reject the complete recipe")
        } catch {}
        let after = await store.snapshot()
        XCTAssertEqual(after.first, before)
        fx.grainAmount = .nan
        do {
            try await store.editScene(movieID: project.id, sceneID: scene.id,
                start: scene.trimStart.cmTime, end: scene.trimEnd.cmTime,
                adjustments: SceneAdjustments(exposure: 0.2), filmEffects: fx)
            XCTFail("Invalid FX should reject the scene edit too")
        } catch {}
        let afterInvalidFX = await store.snapshot()
        XCTAssertEqual(afterInvalidFX.first, before)
    }

    func testOnlyCinemaIsInstalledAndRetiredSelectionFallsBack() async throws {
        let store = try await makeStore()
        let looks = await store.availableLooks()
        XCTAssertEqual(looks.map(\.id), [LUTReference.filmica.id])
        let movie = try await store.create(name: "Original look", format: .landscape, profile: .appleLog)
        try await store.setLook(movieID: movie.id, look: .cinemaTwo)
        let saved = await store.snapshot()
        XCTAssertEqual(saved.first?.look?.id, LUTReference.filmica.id)
        let original = try ColorCube.load(.filmica, root: store.root)
        let retired = try ColorCube.load(.cinemaThree, root: store.root)
        XCTAssertEqual(original.rgba, retired.rgba)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.root.appendingPathComponent(LUTReference.cinemaTwo.path).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.root.appendingPathComponent(LUTReference.cinemaThree.path).path))
    }

    func testFilmEffectsWatchPreviewAndExportShareSavedRecipeAndOriginalBypassesFX() async throws {
        let store = try await makeStore()
        let original = try await store.create(name: "Effects integration", format: .landscape)
        _ = try await record(original, into: store)
        let sourceMovies = await store.snapshot()
        let originalSources = sourceMovies.first?.scenes.map(\.source) ?? []
        var settings = FilmEffectsSettings.off
        settings.grainEnabled = true; settings.grainAmount = 0.7
        settings.halationEnabled = true; settings.bloomEnabled = true
        try await store.setFilmEffects(movieID: original.id, settings: settings)
        let movies = await store.snapshot()
        let movie = try XCTUnwrap(movies.first)
        let assembler = MediaAssembler()
        let watch = try await assembler.build(movie: movie, root: store.root)
        let watchInstruction = try XCTUnwrap(watch.videoComposition.instructions.first as? ColorInstruction)
        XCTAssertEqual(watchInstruction.filmEffects, settings)
        let originalPlayback = try await assembler.build(movie: movie, root: store.root, showOriginalLog: true)
        XCTAssertNil(originalPlayback.videoComposition.customVideoCompositorClass)
        let explicitBypass = try await assembler.build(movie: movie, root: store.root, filmEffects: .off)
        XCTAssertNil(explicitBypass.videoComposition.customVideoCompositorClass)
        let preview = try await assembler.build(movie: movie, root: store.root, filmEffects: settings, forFilmEffectsPreview: true)
        let export = try await assembler.build(movie: movie, root: store.root, filmEffects: movie.exportEffects)
        let a = try XCTUnwrap(preview.videoComposition.instructions.first as? ColorInstruction)
        let b = try XCTUnwrap(export.videoComposition.instructions.first as? ColorInstruction)
        XCTAssertEqual(a.filmEffects, b.filmEffects)
        XCTAssertEqual(a.transform, b.transform)
        XCTAssertNil(a.cube); XCTAssertNil(b.cube)
        let time = CMTime(value: 10, timescale: 30)
        let previewGenerator = AVAssetImageGenerator(asset: preview.asset)
        previewGenerator.videoComposition = preview.videoComposition
        previewGenerator.requestedTimeToleranceBefore = .zero; previewGenerator.requestedTimeToleranceAfter = .zero
        let exportGenerator = AVAssetImageGenerator(asset: export.asset)
        exportGenerator.videoComposition = export.videoComposition
        exportGenerator.requestedTimeToleranceBefore = .zero; exportGenerator.requestedTimeToleranceAfter = .zero
        let watchGenerator = AVAssetImageGenerator(asset: watch.asset)
        watchGenerator.videoComposition = watch.videoComposition
        watchGenerator.requestedTimeToleranceBefore = .zero; watchGenerator.requestedTimeToleranceAfter = .zero
        let watchImage = try await watchGenerator.image(at: time).image
        let previewImage = try await previewGenerator.image(at: time).image
        let exportImage = try await exportGenerator.image(at: time).image
        XCTAssertEqual(previewImage.width, 1920); XCTAssertEqual(previewImage.height, 1080)
        let previewBytes = try XCTUnwrap(previewImage.dataProvider?.data)
        let exportBytes = try XCTUnwrap(exportImage.dataProvider?.data)
        XCTAssertEqual(previewBytes as Data, exportBytes as Data)
        XCTAssertEqual(try XCTUnwrap(watchImage.dataProvider?.data) as Data, exportBytes as Data)
        let destination = store.root.appendingPathComponent("effects-export.mp4")
        let session = try XCTUnwrap(AVAssetExportSession(asset: export.asset, presetName: AVAssetExportPresetHighestQuality))
        session.videoComposition = export.videoComposition; session.audioMix = export.audioMix
        try await session.export(to: destination, as: .mp4)
        let info = try await MediaInspector.inspect(destination)
        XCTAssertEqual(info.duration.seconds, movie.duration.seconds, accuracy: 0.05)
        XCTAssertEqual(info.size.width, 1920); XCTAssertEqual(info.size.height, 1080)
        XCTAssertEqual(movie.scenes.map(\.source), originalSources)
    }
    @MainActor func testShortLogRecipeExportsAllEffectsFrom4KInBothOrientations() async throws {
        let store = try await makeStore()
        let source = store.root.appendingPathComponent("large-effects-fixture.mov")
        // SDR synthetic pixels exercise the Log recipe and 4K decode; real Apple Log
        // sensor/10-bit validation still requires an iPhone recording.
        try await footage(source, width: 3840, height: 2160, frames: 12)
        let sourceBytes = try Data(contentsOf: source)
        for format in [MovieFormat.landscape, .portrait] {
            var movie = Movie(name: "Short Log effects", format: format, profile: .appleLog)
            movie.look = .filmica
            movie.scenes = [Scene(id: UUID(), sequence: 0, source: source.lastPathComponent,
                capturedAt: Date(), timeZone: "UTC", sourceDuration: MediaTime(seconds: 0.4),
                trimStart: MediaTime(seconds: 0), trimEnd: MediaTime(seconds: 0.4),
                width: 3840, height: 2160, hasAudio: false, bytes: Int64(sourceBytes.count),
                profile: .appleLog)]
            movie.scenes[0].adjustments = SceneAdjustments(exposure: 0.2, shadows: 0.3, highlights: -0.3,
                warmth: 0.15, tint: -0.1, contrast: 0.35, blackPoint: -0.2, whitePoint: -0.15, saturation: -0.3, vibrance: 0.5)
            var effects = FilmEffectsSettings.off
            effects.grainEnabled = true; effects.grainAmount = 1; effects.grainTexture = .coarse16
            effects.halationEnabled = true; effects.halationAmount = 1; effects.halationSpread = 1
            effects.bloomEnabled = true; effects.bloomAmount = 1; effects.bloomSpread = 1
            movie.filmEffects = effects
            let bundle = try await MediaAssembler().build(movie: movie, root: store.root, filmEffects: effects)
            let instruction = try XCTUnwrap(bundle.videoComposition.instructions.first as? ColorInstruction)
            XCTAssertEqual(instruction.cube?.dimension, try ColorCube.filmica.get().dimension)
            XCTAssertTrue(instruction.adjustments.isActive)
            let destination = store.root.appendingPathComponent("short-log-\(format.rawValue).mp4")
            let session = try XCTUnwrap(AVAssetExportSession(asset: bundle.asset, presetName: AVAssetExportPresetHighestQuality))
            session.videoComposition = bundle.videoComposition
            try await session.export(to: destination, as: .mp4)
            XCTAssertEqual(session.status, .completed)
            let info = try await MediaInspector.inspect(destination)
            XCTAssertTrue(ExportModel.matchesExport(info, movie: movie))
            let decoded = try await AVAssetImageGenerator(asset: AVURLAsset(url: destination))
                .image(at: CMTime(value: 6, timescale: 30)).image
            XCTAssertEqual(decoded.width, Int(format.canvas.width))
            XCTAssertEqual(decoded.height, Int(format.canvas.height))
        }
        XCTAssertEqual(try Data(contentsOf: source), sourceBytes)
    }
    func testDollyClosePreservesMotionAndSettlesPromptlyInBothDirections() throws {
        for speed in SmoothZoomSpeed.allCases {
            for timed in [false, true] {
                for (start, end) in [(1.0, 8.0), (8.0, 1.0)] {
                    var filter = try XCTUnwrap(SmoothZoomFilter(current: start, minimum: 0.5, maximum: 16))
                    filter.setTarget(end, duration: timed ? 3 : nil)
                    for _ in 0..<30 { _ = filter.advance(seconds: 1.0 / 60, rate: speed.rate, response: speed.responseTime) }
                    let current = filter.value, incomingVelocity = filter.velocity
                    filter.finishMotion()
                    XCTAssertEqual(filter.value, current)
                    XCTAssertEqual(filter.velocity, incomingVelocity, accuracy: 0.000001)
                    for _ in 0..<12 {
                        _ = filter.advance(seconds: 1.0 / 60, rate: speed.rate, response: speed.responseTime)
                        XCTAssertTrue((0.5...16).contains(filter.value))
                    }
                    XCTAssertTrue(filter.isSettled)
                    XCTAssertEqual(filter.velocity, 0, accuracy: 0.000001)
                    XCTAssertGreaterThanOrEqual((log2(filter.value) - log2(current)) * incomingVelocity, -0.000001)
                }
            }
        }
    }
    func testIdenticalDollyRoutesHaveDistinctCompletionIdentities() throws {
        let first = try XCTUnwrap(DollyZoomRoute(start: 1, destination: 8, seconds: 3))
        let second = try XCTUnwrap(DollyZoomRoute(start: 1, destination: 8, seconds: 3))
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(first.progress(at: 2), second.progress(at: 2))
    }
    func testManualResponseSettingsChangeFollowLagWithoutOverridingHandSpeed() throws {
        var values: [Double] = []
        for speed in SmoothZoomSpeed.allCases {
            var input = SmoothZoomInput(), filter = try XCTUnwrap(SmoothZoomFilter(current: 1, minimum: 0.5, maximum: 32))
            input.observe(factor: 1, at: 0)
            for frame in 1...120 {
                let time = Double(frame) / 60, target = exp2(time)
                input.observe(factor: target, at: time); filter.setTarget(target)
                _ = filter.advance(seconds: 1.0 / 60, rate: input.rate(baseline: speed.rate), response: speed.responseTime)
            }
            values.append(filter.value)
        }
        XCTAssertLessThan(values[0], values[1]); XCTAssertLessThan(values[1], values[2])
        XCTAssertGreaterThan(values[0], 2, "Gentle response must still follow the moving hand")
        XCTAssertLessThan(values[2], 4, "Fast response retains smoothing rather than jumping straight to the target")
    }
    func testDollyGuidanceFollowsActualZoomInBothDirections() throws {
        for (start, end) in [(1.0, 8.0), (8.0, 1.0)] {
            let route = try XCTUnwrap(DollyZoomRoute(start: start, destination: end, seconds: 3))
            var filter = try XCTUnwrap(SmoothZoomFilter(current: start, minimum: 1, maximum: 8))
            filter.setTarget(end, duration: 3)
            XCTAssertEqual(route.progress(at: start), 0)
            XCTAssertFalse(route.hasArrived(at: start))
            for _ in 0..<60 { _ = filter.advance(seconds: 1.0 / 60, rate: 0.75) }
            XCTAssertGreaterThan(route.progress(at: filter.value), 0)
            XCTAssertLessThan(route.progress(at: filter.value), 1)
            XCTAssertFalse(route.hasArrived(at: filter.value))
            for _ in 0..<120 { _ = filter.advance(seconds: 1.0 / 60, rate: 0.75) }
            XCTAssertEqual(route.progress(at: filter.value), 1, accuracy: 0.00001)
            XCTAssertTrue(route.hasArrived(at: filter.value))
        }
    }
    func testDollyGuidanceCannotReportAnUnreachedOrInvalidDestination() throws {
        XCTAssertNil(DollyZoomRoute(start: 1, destination: 1, seconds: 3))
        XCTAssertNil(DollyZoomRoute(start: 0, destination: 8, seconds: 3))
        XCTAssertNil(DollyZoomRoute(start: 1, destination: .infinity, seconds: 3))
        let route = try XCTUnwrap(DollyZoomRoute(start: 1, destination: 8, seconds: 99))
        XCTAssertEqual(route.seconds, 3)
        XCTAssertEqual(route.progress(at: 0.5), 0)
        XCTAssertEqual(route.progress(at: 16), 1)
        XCTAssertEqual(route.progress(at: .nan), 0)
        XCTAssertFalse(route.hasArrived(at: 4)) // Temporary hardware limit, not the requested 8x.
        XCTAssertFalse(route.hasArrived(at: .nan))
        let retargeted = try XCTUnwrap(DollyZoomRoute(start: 4, destination: 1, seconds: 5))
        XCTAssertEqual(retargeted.progress(at: 4), 0)
        XCTAssertEqual(retargeted.progress(at: 2), 0.5)
        XCTAssertFalse(retargeted.hasArrived(at: 2))
    }
    func testDollyRetainsRequestedLensWhenTemporaryHardwareRangeWidens() throws {
        var filter = try XCTUnwrap(SmoothZoomFilter(current: 2, minimum: 1, maximum: 4))
        filter.setTarget(16, duration: 3)
        XCTAssertEqual(filter.target, 4); XCTAssertEqual(filter.requestedTarget, 16)
        _ = filter.advance(seconds: 0.25, rate: 0.75)
        let current = filter.value, velocity = filter.velocity
        XCTAssertTrue(filter.reconfigure(current: current, minimum: 1, maximum: 32))
        XCTAssertEqual(filter.target, 16); XCTAssertEqual(filter.value, current); XCTAssertEqual(filter.velocity, velocity)
        XCTAssertEqual(try XCTUnwrap(filter.remainingDuration), 2.75, accuracy: 0.000001)
        _ = filter.advance(seconds: 2.75, rate: 0.75)
        XCTAssertEqual(filter.value, 16, accuracy: 0.000001)
    }
    func testManualDragVelocityControlsZoomAtEveryBaseSpeed() throws {
        for speed in SmoothZoomSpeed.allCases {
            var values: [Double] = [], rates: [Float] = []
            for handSpeed in [0.05, 3.0] {
                var input = SmoothZoomInput(), filter = try XCTUnwrap(SmoothZoomFilter(current: 1, minimum: 0.5, maximum: 128))
                input.observe(factor: 1, at: 0)
                for frame in 1...120 {
                    let time = Double(frame) / 60, target = exp2(handSpeed * time)
                    input.observe(factor: target, at: time); filter.setTarget(target)
                    _ = filter.advance(seconds: 1.0 / 60, rate: input.rate(baseline: speed.rate), response: speed.responseTime)
                }
                values.append(filter.value); rates.append(input.rate(baseline: speed.rate))
            }
            XCTAssertLessThan(values[0], 1.1, "A slow hand must stay slow even with the Fast setting")
            XCTAssertGreaterThan(values[1], values[0] * 8, "A fast hand must not remain stuck at the base Slow/Normal limit")
            XCTAssertGreaterThan(rates[1], rates[0])
        }
    }
    func testDragVelocityFilteringReleaseAndInvalidSamples() {
        var input = SmoothZoomInput()
        input.observe(factor: 1, at: 0); input.observe(factor: 2, at: 1.0 / 60)
        let fast = input.rate(baseline: 0.35)
        XCTAssertGreaterThan(fast, 0.35); XCTAssertLessThan(fast, 8)
        input.observe(factor: 2, at: 2.0 / 60)
        let slowing = input.rate(baseline: 0.35)
        XCTAssertLessThan(slowing, fast); XCTAssertGreaterThan(slowing, 0.35)
        input.observe(factor: .nan, at: 1); input.observe(factor: 4, at: .nan); input.observe(factor: 4, at: 0)
        XCTAssertEqual(input.rate(baseline: 0.35), slowing)
        input.end(); XCTAssertEqual(input.rate(baseline: 0.35), slowing, "Release keeps the final catch-up smooth")
        input.observe(factor: 4, at: 100)
        XCTAssertEqual(input.rate(baseline: 0.35), 0.35, "The next gesture starts a fresh speed measurement")
        input.observe(factor: 8, at: 101)
        XCTAssertEqual(input.rate(baseline: 0.35), 0.35, "A stale timestamp gap must not produce a speed burst")
    }
    func testSameManualHandSpeedRemainsConsistentAcrossGestureCadences() throws {
        var results: [Double] = []
        for cadence in [30, 60, 120] {
            var input = SmoothZoomInput(), filter = try XCTUnwrap(SmoothZoomFilter(current: 1, minimum: 0.5, maximum: 16))
            input.observe(factor: 1, at: 0)
            for frame in 1...(cadence * 2) {
                let time = Double(frame) / Double(cadence), target = exp2(time)
                input.observe(factor: target, at: time); filter.setTarget(target)
                _ = filter.advance(seconds: 1 / Double(cadence), rate: input.rate(baseline: 0.75))
            }
            results.append(filter.value)
        }
        XCTAssertLessThan(abs(log2(results[0] / results[1])), 0.04)
        XCTAssertLessThan(abs(log2(results[1] / results[2])), 0.04)
    }
    func testLongDurationRetargetToNearbyLensDoesNotAmplifyMomentum() throws {
        var filter = try XCTUnwrap(SmoothZoomFilter(current: 1, minimum: 0.5, maximum: 32))
        filter.setTarget(8, duration: 3); _ = filter.advance(seconds: 1.5, rate: 0.75)
        let current = filter.value, velocity = filter.velocity
        let target = current * exp2(0.1)
        filter.setTarget(target, duration: 10)
        XCTAssertEqual(filter.velocity, velocity)
        for _ in 0..<600 {
            let next = filter.advance(seconds: 1.0 / 60, rate: 0.75)
            XCTAssertGreaterThanOrEqual(next, current - 0.000001)
            XCTAssertLessThanOrEqual(next, target + 0.000001, "A long duration must not stretch incoming momentum into a large overshoot")
        }
        XCTAssertEqual(filter.value, target, accuracy: 0.000001); XCTAssertEqual(filter.velocity, 0, accuracy: 0.000001)
    }
    func testManualDollyReversalsKeepMomentumAndSettleAtEverySpeed() throws {
        for speed in SmoothZoomSpeed.allCases {
            var filter = try XCTUnwrap(SmoothZoomFilter(current: 2, minimum: 0.5, maximum: 32))
            filter.setTarget(8)
            for _ in 0..<60 { _ = filter.advance(seconds: 1.0 / 60, rate: speed.rate) }
            let value = filter.value, velocity = filter.velocity
            filter.setTarget(1)
            XCTAssertEqual(filter.value, value); XCTAssertEqual(filter.velocity, velocity)
            XCTAssertGreaterThan(filter.advance(seconds: 1.0 / 120, rate: speed.rate), value, "Reversal first decelerates the existing motion")
            for _ in 0..<1800 {
                let previous = filter.value
                let next = filter.advance(seconds: 1.0 / 60, rate: speed.rate)
                XCTAssertTrue(next.isFinite); XCTAssertGreaterThanOrEqual(next, 0.5); XCTAssertLessThanOrEqual(next, 32)
                XCTAssertLessThanOrEqual(abs(log2(next / previous)), Double(speed.rate) / 60 + 0.00001)
            }
            XCTAssertEqual(filter.value, 1, accuracy: 0.00001); XCTAssertTrue(filter.isSettled)
        }
    }
    func testTimedDollyRetargetAndManualTakeoverPreserveIncomingSpeed() throws {
        var filter = try XCTUnwrap(SmoothZoomFilter(current: 1, minimum: 0.5, maximum: 32))
        filter.setTarget(8, duration: 3); _ = filter.advance(seconds: 1, rate: 0.75)
        let position = filter.value, velocity = filter.velocity
        filter.setTarget(16, duration: 5)
        XCTAssertEqual(filter.value, position); XCTAssertEqual(filter.velocity, velocity)
        let next = filter.advance(seconds: 1.0 / 120, rate: 0.75)
        XCTAssertEqual(log2(next / position) * 120, velocity, accuracy: 0.05)
        let reversingVelocity = filter.velocity, reversingPosition = filter.value
        filter.setTarget(1, duration: 2)
        XCTAssertEqual(filter.velocity, reversingVelocity)
        XCTAssertGreaterThan(filter.advance(seconds: 1.0 / 120, rate: 0.75), reversingPosition)
        _ = filter.advance(seconds: 2, rate: 0.75)
        XCTAssertEqual(filter.value, 1, accuracy: 0.000001); XCTAssertEqual(filter.velocity, 0)
        filter.setTarget(8, duration: 3); _ = filter.advance(seconds: 1, rate: 0.75)
        let takeoverVelocity = filter.velocity, takeoverPosition = filter.value
        filter.setTarget(16)
        XCTAssertFalse(filter.isTimed); XCTAssertEqual(filter.velocity, takeoverVelocity); XCTAssertEqual(filter.value, takeoverPosition)
        let step = filter.advance(seconds: 0.00001, rate: 0.35)
        XCTAssertEqual(log2(step / takeoverPosition) / 0.00001, takeoverVelocity, accuracy: 0.001)
    }
    func testManualDollySpeedChangesDecelerateWithoutClampingVelocity() throws {
        for speed in [SmoothZoomSpeed.slow, .normal] {
            var filter = try XCTUnwrap(SmoothZoomFilter(current: 1, minimum: 0.5, maximum: 32))
            filter.setTarget(8)
            for _ in 0..<30 { _ = filter.advance(seconds: 1.0 / 60, rate: SmoothZoomSpeed.fast.rate) }
            let previous = filter.value, velocity = filter.velocity
            _ = filter.advance(seconds: 0.00001, rate: speed.rate)
            XCTAssertEqual(filter.velocity, velocity, accuracy: 0.001)
            XCTAssertGreaterThan(filter.velocity, Double(speed.rate), "A slower setting eases down rather than snapping speed")
            XCTAssertEqual(log2(filter.value / previous) / 0.00001, velocity, accuracy: 0.001)
            for _ in 0..<1800 { _ = filter.advance(seconds: 1.0 / 60, rate: speed.rate) }
            XCTAssertEqual(filter.value, 8, accuracy: 0.00001); XCTAssertTrue(filter.isSettled)
        }
    }
    func testDollyRangeChangesKeepVelocityDurationAndSafeBounds() throws {
        var filter = try XCTUnwrap(SmoothZoomFilter(current: 1, minimum: 0.5, maximum: 16))
        filter.setTarget(8, duration: 3); _ = filter.advance(seconds: 1, rate: 0.75)
        let position = filter.value, velocity = filter.velocity
        XCTAssertTrue(filter.reconfigure(current: position, minimum: 1, maximum: 12))
        XCTAssertEqual(filter.velocity, velocity); XCTAssertEqual(try XCTUnwrap(filter.remainingDuration), 2, accuracy: 0.000001)
        _ = filter.advance(seconds: 2, rate: 0.75)
        XCTAssertEqual(filter.value, 8, accuracy: 0.000001)
        filter.setTarget(12)
        for _ in 0..<30 { _ = filter.advance(seconds: 1.0 / 60, rate: 0.75) }
        let manualVelocity = filter.velocity
        XCTAssertTrue(filter.reconfigure(current: filter.value, minimum: 1, maximum: 16))
        XCTAssertEqual(filter.velocity, manualVelocity)
        XCTAssertTrue(filter.reconfigure(current: 4, minimum: 1, maximum: 4))
        XCTAssertEqual(filter.value, 4); XCTAssertEqual(filter.target, 4); XCTAssertEqual(filter.velocity, 0)
        XCTAssertFalse(filter.reconfigure(current: .nan, minimum: 1, maximum: 4))
    }
    func testDollyClockPausesRatherThanJumpingAfterQueueStalls() throws {
        var clock = SmoothZoomClock(), filter = try XCTUnwrap(SmoothZoomFilter(current: 1, minimum: 0.5, maximum: 16))
        clock.reset(at: 10); filter.setTarget(8, duration: 1)
        var time = 10.0
        for _ in 0..<30 { time += 1.0 / 60; _ = filter.advance(seconds: clock.step(at: time), rate: 0.75) }
        let previous = filter.value; time += 1
        let step = clock.step(at: time)
        XCTAssertEqual(step, 1.0 / 30, accuracy: 0.000001)
        _ = filter.advance(seconds: step, rate: 0.75)
        XCTAssertLessThan(log2(filter.value / previous), 3 * 1.875 / 30 + 0.00001)
        XCTAssertFalse(filter.isSettled); XCTAssertGreaterThan(try XCTUnwrap(filter.remainingDuration), 0.4)
        XCTAssertEqual(clock.step(at: time), 0); XCTAssertEqual(clock.step(at: time - 1), 0); XCTAssertEqual(clock.step(at: .nan), 0)
        clock.reset(); XCTAssertEqual(clock.step(at: 100), 0)
    }
    func testManualDollyMotionIsConsistentAtThirtySixtyAndOneTwentyHz() throws {
        for speed in SmoothZoomSpeed.allCases {
            for (start, end) in [(0.5, 8.0), (8.0, 0.5), (1.0, 16.0), (16.0, 1.0)] {
                var results: [Double] = []
                for cadence in [30, 60, 120] {
                    var filter = try XCTUnwrap(SmoothZoomFilter(current: start, minimum: 0.5, maximum: 32))
                    filter.setTarget(end)
                    for _ in 0..<(cadence * 2) { _ = filter.advance(seconds: 1 / Double(cadence), rate: speed.rate) }
                    results.append(filter.value)
                }
                XCTAssertEqual(results[0], results[1], accuracy: 0.000001); XCTAssertEqual(results[1], results[2], accuracy: 0.000001)
            }
        }
    }
    private func livePreviewFrame(format: OSType = kCVPixelFormatType_32BGRA) throws -> CVPixelBuffer {
        var pixel: CVPixelBuffer?
        let attributes: [String: Any] = [kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 32, 32, format, attributes as CFDictionary, &pixel), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixel)
        CVPixelBufferLockBaseAddress(buffer, []); defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        if CVPixelBufferIsPlanar(buffer) {
            for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
                let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, plane)).assumingMemoryBound(to: UInt16.self)
                let count = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) / 2 * CVPixelBufferGetHeightOfPlane(buffer, plane)
                for index in 0..<count { base[index] = UInt16(512 << 6) }
            }
        } else {
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
            for row in 0..<32 { for column in 0..<32 {
                let offset = row * CVPixelBufferGetBytesPerRow(buffer) + column * 4
                base[offset] = 80; base[offset + 1] = 80; base[offset + 2] = 80; base[offset + 3] = 255
            }}
        }
        return buffer
    }
    @MainActor func testLiveCinemaGPUOutputMatchesSelectedCubeForEightAndTenBitFrames() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice()), renderer = try XCTUnwrap(LiveLookRenderer(device: device))
        let queue = try XCTUnwrap(device.makeCommandQueue()), cube = try ColorCube.filmica.get()
        renderer.configure(frames: LiveFrames(), cube: cube, active: true); renderer.angle = 0
        for format in [kCVPixelFormatType_32BGRA, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange] {
            let source = try livePreviewFrame(format: format)
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 32, height: 32, mipmapped: false)
            descriptor.storageMode = .shared; descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
            let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor)), command = try XCTUnwrap(queue.makeCommandBuffer())
            try renderer.encode(source, to: texture, command: command)
            let completed = expectation(description: "Cinema GPU render completes")
            command.addCompletedHandler { _ in completed.fulfill() }; command.commit()
            await fulfillment(of: [completed], timeout: 15)
            XCTAssertEqual(command.status, .completed)
            var actual = [UInt8](repeating: 0, count: 32 * 32 * 4)
            texture.getBytes(&actual, bytesPerRow: 32 * 4, from: MTLRegionMake2D(0, 0, 32, 32), mipmapLevel: 0)
            let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
            let expected = try cube.apply(to: CIImage(cvPixelBuffer: source, options: [.colorSpace: NSNull()]))
            var reference = [UInt8](repeating: 0, count: 4), original = [UInt8](repeating: 0, count: 4)
            context.render(expected, toBitmap: &reference, rowBytes: 4, bounds: CGRect(x: 16, y: 16, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
            context.render(CIImage(cvPixelBuffer: source, options: [.colorSpace: NSNull()]), toBitmap: &original, rowBytes: 4, bounds: CGRect(x: 16, y: 16, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
            let offset = (16 * 32 + 16) * 4
            XCTAssertEqual(Double(actual[offset + 2]), Double(reference[0]), accuracy: 3)
            XCTAssertEqual(Double(actual[offset + 1]), Double(reference[1]), accuracy: 3)
            XCTAssertEqual(Double(actual[offset]), Double(reference[2]), accuracy: 3)
            XCTAssertNotEqual(reference, original, "The live output must contain Cinema rather than untouched Log samples")
        }
    }
    @MainActor func testLiveLookBecomesVisibleWithoutTransparentFirstFrameHandshake() async throws {
        let controller = UIViewController(), preview = PreviewUIView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: preview.bounds)
        window.frame = preview.bounds; controller.view = preview; window.rootViewController = controller; window.isHidden = false
        defer { preview.configureLiveLook(frames: nil, cube: nil, active: false); window.isHidden = true }
        preview.layoutIfNeeded()
        let shown = expectation(description: "Graded drawable presented in the visible preview")
        var statuses: [LiveLookStatus] = []
        preview.onLiveLookStatus = { status in statuses.append(status); if status == .ready { shown.fulfill() } }
        let frames = LiveFrames(); frames.push(try livePreviewFrame())
        preview.configureLiveLook(frames: frames, cube: try ColorCube.filmica.get(), active: true)
        let metal = try XCTUnwrap(preview.subviews.compactMap { $0 as? MTKView }.first)
        XCTAssertEqual(metal.alpha, 1); XCTAssertFalse(metal.isHidden); XCTAssertFalse(metal.isPaused)
        await fulfillment(of: [shown], timeout: 15)
        XCTAssertTrue(statuses.contains(.preparing)); XCTAssertEqual(statuses.last, .ready)
        preview.configureLiveLook(frames: frames, cube: nil, active: true)
        XCTAssertTrue(metal.isHidden); XCTAssertTrue(metal.isPaused); XCTAssertEqual(statuses.last, .inactive)
        preview.configureLiveLook(frames: frames, cube: try ColorCube.filmica.get(), active: true)
        preview.configureLiveLook(frames: frames, cube: try ColorCube.filmica.get(), active: false)
        XCTAssertTrue(metal.isHidden); XCTAssertTrue(metal.isPaused); XCTAssertEqual(statuses.last, .inactive)
    }
    @MainActor func testCinemaPreviewResizesWithoutReplacingItsSessionOrMetalSurface() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal preview is unavailable") }
        let preview = PreviewUIView(frame: CGRect(x: 0, y: 0, width: 393, height: 698))
        let session = AVCaptureSession(); preview.previewLayer.session = session
        let frames = LiveFrames(); frames.push(try livePreviewFrame())
        preview.configureLiveLook(frames: frames, cube: try ColorCube.filmica.get(), active: true)
        let metal = try XCTUnwrap(preview.subviews.compactMap { $0 as? MTKView }.first)
        let delegate = metal.delegate
        for size in [CGSize(width: 698, height: 393), CGSize(width: 393, height: 698), CGSize(width: 698, height: 393)] {
            preview.bounds = CGRect(origin: .zero, size: size)
            preview.setNeedsLayout(); preview.layoutIfNeeded()
            XCTAssertTrue(preview.previewLayer.session === session)
            XCTAssertTrue(preview.subviews.compactMap { $0 as? MTKView }.first === metal)
            XCTAssertTrue(metal.delegate === delegate)
            XCTAssertEqual(metal.frame, preview.bounds)
            XCTAssertGreaterThan(metal.drawableSize.width, 0); XCTAssertGreaterThan(metal.drawableSize.height, 0)
            XCTAssertEqual(metal.drawableSize.width / metal.drawableSize.height, size.width / size.height, accuracy: 0.001)
            XCTAssertFalse(metal.isHidden); XCTAssertFalse(metal.isPaused)
            XCTAssertNotNil(frames.latest())
        }
        preview.detachPreview()
        XCTAssertNil(preview.previewLayer.session)
        XCTAssertTrue(metal.isPaused); XCTAssertTrue(metal.isHidden)
    }
    func testSceneAudioEdgesFadeAtActualOffsetsAndKeepFullVolumeBetweenCuts() {
        let parameters = AVMutableAudioMixInputParameters()
        MediaAssembler.smoothAudioEdges(parameters, range: CMTimeRange(start: CMTime(seconds: 2.25, preferredTimescale: 48000), duration: CMTime(seconds: 1, preferredTimescale: 48000)))
        var start: Float = -1, end: Float = -1, range = CMTimeRange.invalid
        XCTAssertTrue(parameters.getVolumeRamp(for: CMTime(seconds: 2.252, preferredTimescale: 48000), startVolume: &start, endVolume: &end, timeRange: &range))
        XCTAssertEqual(start, 0); XCTAssertEqual(end, 1)
        XCTAssertEqual(range.start.seconds, 2.25, accuracy: 0.00001)
        XCTAssertEqual(range.duration.seconds, 0.005, accuracy: 0.00001)
        XCTAssertTrue(parameters.getVolumeRamp(for: CMTime(seconds: 2.75, preferredTimescale: 48000), startVolume: &start, endVolume: &end, timeRange: &range))
        XCTAssertEqual(start, 1); XCTAssertEqual(end, 1)
        XCTAssertTrue(parameters.getVolumeRamp(for: CMTime(seconds: 3.248, preferredTimescale: 48000), startVolume: &start, endVolume: &end, timeRange: &range))
        XCTAssertEqual(start, 1); XCTAssertEqual(end, 0)
        XCTAssertEqual(CMTimeRangeGetEnd(range).seconds, 3.25, accuracy: 0.00001)
    }
    func testVeryShortSceneAudioFadesDoNotOverlap() {
        let parameters = AVMutableAudioMixInputParameters()
        MediaAssembler.smoothAudioEdges(parameters, range: CMTimeRange(start: .zero, duration: CMTime(value: 192, timescale: 48000)))
        var start: Float = -1, end: Float = -1, range = CMTimeRange.invalid
        XCTAssertTrue(parameters.getVolumeRamp(for: CMTime(value: 48, timescale: 48000), startVolume: &start, endVolume: &end, timeRange: &range))
        XCTAssertEqual(start, 0); XCTAssertEqual(end, 1)
        XCTAssertEqual(range.duration.seconds, 0.002, accuracy: 0.00001)
        XCTAssertTrue(parameters.getVolumeRamp(for: CMTime(value: 144, timescale: 48000), startVolume: &start, endVolume: &end, timeRange: &range))
        XCTAssertEqual(start, 1); XCTAssertEqual(end, 0)
        XCTAssertEqual(range.start.seconds, 0.002, accuracy: 0.00001)
    }
    func testAudioMixSurvivesSilentSceneGapsTrimsAndExport() async throws {
        let store = try await makeStore(), movie = try await store.create(name: "Audio cuts", format: .landscape)
        _ = try await record(movie, into: store)
        let ticket = try await store.begin(movieID: movie.id), target = try await store.url(ticket.staging)
        let video = store.root.appendingPathComponent("tone-video.mov"), wave = store.root.appendingPathComponent("tone.m4a")
        try await footage(video)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96000))
        buffer.frameLength = 96000
        let samples = try XCTUnwrap(buffer.floatChannelData)[0]
        for frame in 0..<96000 { samples[frame] = Float(sin(Double(frame) * 2 * .pi * 440 / 48000) * 0.5) }
        do {
            let audioFile = try AVAudioFile(forWriting: wave, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 128000],
                commonFormat: .pcmFormatFloat32, interleaved: false)
            try audioFile.write(from: buffer)
        }
        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: video), audioAsset = AVURLAsset(url: wave)
        defer { withExtendedLifetime((videoAsset, audioAsset)) {} }
        let videoTracks = try await videoAsset.loadTracks(withMediaType: .video)
        let audioTracks: [AVAssetTrack]
        do { audioTracks = try await audioAsset.loadTracks(withMediaType: .audio) }
        catch { XCTFail("AAC fixture load failed: \(error)"); throw error }
        let sourceVideo = try XCTUnwrap(videoTracks.first), sourceAudio = try XCTUnwrap(audioTracks.first)
        let videoTrack = try XCTUnwrap(composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
        let audioTrack = try XCTUnwrap(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
        let full = CMTimeRange(start: .zero, duration: CMTime(seconds: 2, preferredTimescale: 48000))
        let videoRange = try await sourceVideo.load(.timeRange), audioRange = try await sourceAudio.load(.timeRange)
        do {
            try videoTrack.insertTimeRange(CMTimeRangeGetIntersection(full, otherRange: videoRange), of: sourceVideo, at: .zero)
            try audioTrack.insertTimeRange(CMTimeRangeGetIntersection(full, otherRange: audioRange), of: sourceAudio, at: .zero)
        } catch { XCTFail("Audio fixture track assembly failed: \(error)"); throw error }
        let fixture = try XCTUnwrap(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality))
        do { try await fixture.export(to: target, as: .mov) }
        catch { XCTFail("Audio fixture mux failed: \(error)"); throw error }
        try await store.commit(ticket)
        try await store.trim(movieID: movie.id, sceneID: ticket.sceneID, start: CMTime(seconds: 0.25, preferredTimescale: 48000), end: CMTime(seconds: 1.25, preferredTimescale: 48000))
        _ = try await record(movie, into: store)
        let movies = await store.snapshot(); let snapshot = try XCTUnwrap(movies.first)
        let bundle = try await MediaAssembler().build(movie: snapshot, root: store.root)
        XCTAssertEqual(bundle.duration.seconds, 5, accuracy: 0.0001)
        let mix = try XCTUnwrap(bundle.audioMix), parameters = try XCTUnwrap(mix.inputParameters.first)
        var start: Float = -1, end: Float = -1, range = CMTimeRange.invalid
        XCTAssertTrue(parameters.getVolumeRamp(for: CMTime(seconds: 2.002, preferredTimescale: 48000), startVolume: &start, endVolume: &end, timeRange: &range))
        XCTAssertEqual(start, 0); XCTAssertEqual(end, 1); XCTAssertEqual(range.start.seconds, 2, accuracy: 0.0001)
        XCTAssertTrue(parameters.getVolumeRamp(for: CMTime(seconds: 2.998, preferredTimescale: 48000), startVolume: &start, endVolume: &end, timeRange: &range))
        XCTAssertEqual(start, 1); XCTAssertEqual(end, 0)
        let output = store.root.appendingPathComponent("smoothed.mp4")
        try await GradedMovieExporter.export(bundle, to: output) { _ in }
        let info = try await MediaInspector.inspect(output)
        XCTAssertTrue(info.hasAudio); XCTAssertEqual(info.duration.seconds, 5, accuracy: 0.15)
    }
    @MainActor func testLateCameraReadyUpdatesDoNotHideFailureOrInterruption() async throws {
        let app = AppModel(store: try await makeStore())
        // Keep the model's weak application owner alive for the complete test.
        let ownedCamera = CameraModel(app: app)
        let options = CameraOptions(lenses: [], zoom: 1, minimum: 1, maximum: 8, multiplier: 1,
            isFront: false, angle: 90, profile: .standard, canMeter: false, canLock: false,
            focusLocked: false, exposureBias: 0, minimumExposureBias: 0, maximumExposureBias: 0,
            canFlip: false, hasTorch: false, torchOn: false, canStayOnLens: false,
            smoothMoving: false, recordingFormat: "Standard · H.264")
        for state in [CameraState.failed, .interrupted, .denied, .starting, .recording, .finalizing] {
            ownedCamera.state = state; ownedCamera.message = "Preserved recording error"
            await ownedCamera.receive(.ready(options))
            XCTAssertEqual(ownedCamera.state, state)
            XCTAssertEqual(ownedCamera.message, "Preserved recording error")
        }
        ownedCamera.state = .preparing
        await ownedCamera.receive(.ready(options))
        XCTAssertEqual(ownedCamera.state, .ready, "An explicit retry can become ready")
    }
    func testLiveLogLookRemainsEnabledWhileSaving() {
        for state in [CameraState.ready, .starting, .recording, .finalizing] { XCTAssertTrue(state.showsLiveLook) }
        for state in [CameraState.preparing, .failed, .denied, .interrupted] { XCTAssertFalse(state.showsLiveLook) }
    }
    @MainActor func testHandsFreeCountdownCancellationRestartAndDuplicateStart() async {
        let countdown = RecordingCountdown(tick: .milliseconds(1))
        var cancelledStarts = 0, completedStarts = 0
        countdown.start(canStart: { true }, onStart: { cancelledStarts += 1 })
        XCTAssertEqual(countdown.remaining, 3)
        countdown.cancel(); XCTAssertNil(countdown.remaining)
        let started = expectation(description: "Only the new countdown starts recording")
        countdown.start(canStart: { true }, onStart: { completedStarts += 1; started.fulfill() })
        countdown.start(canStart: { true }, onStart: { XCTFail("A second Record tap must not create another start") })
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(cancelledStarts, 0)
        XCTAssertEqual(completedStarts, 1)
        XCTAssertNil(countdown.remaining)
    }
    func testDollyStartDelayDoesNotDelayOrdinaryRecording() {
        for seconds in [0, 3, 5, 7, -1, 999] {
            XCTAssertEqual(DollyStartDelay.effective(seconds, dollyOpen: false), 0)
        }
        XCTAssertEqual(DollyStartDelay.effective(0, dollyOpen: true), 0)
        XCTAssertEqual(DollyStartDelay.effective(5, dollyOpen: true), 5)
        XCTAssertEqual(DollyStartDelay.effective(7, dollyOpen: true), 7)
        XCTAssertEqual(DollyStartDelay.effective(-1, dollyOpen: true), 3)
    }
    @MainActor func testSelectedDollyCountdownStartsOnceAndOffStartsImmediately() async {
        for seconds in [3, 5, 7] {
            let countdown = RecordingCountdown(tick: .milliseconds(1))
            var starts = 0
            let started = expectation(description: "Selected delay \(seconds) completes")
            countdown.start(seconds: seconds, canStart: { true }, onStart: { starts += 1; started.fulfill() })
            XCTAssertEqual(countdown.remaining, seconds)
            countdown.start(seconds: 3, canStart: { true }, onStart: { XCTFail("Duplicate start") })
            await fulfillment(of: [started], timeout: 2)
            XCTAssertEqual(starts, 1); XCTAssertNil(countdown.remaining)
        }
        let countdown = RecordingCountdown(tick: .milliseconds(1))
        var starts = 0
        countdown.start(seconds: 0, canStart: { true }, onStart: { starts += 1 })
        XCTAssertEqual(starts, 1); XCTAssertNil(countdown.remaining)
    }
    @MainActor func testLongDollyCountdownCanBeCancelledAndReplaced() async {
        let countdown = RecordingCountdown(tick: .milliseconds(1))
        countdown.start(seconds: 7, canStart: { true }, onStart: { XCTFail("Cancelled countdown fired") })
        XCTAssertEqual(countdown.remaining, 7); countdown.cancel()
        let started = expectation(description: "Replacement delay completes")
        countdown.start(seconds: 5, canStart: { true }, onStart: { started.fulfill() })
        XCTAssertEqual(countdown.remaining, 5)
        await fulfillment(of: [started], timeout: 2)
        XCTAssertNil(countdown.remaining)
    }
    @MainActor func testHandsFreeCountdownRechecksCameraAvailability() async {
        let countdown = RecordingCountdown(tick: .milliseconds(1))
        var available = true
        let unexpected = expectation(description: "Unavailable camera must not start")
        unexpected.isInverted = true
        countdown.start(canStart: { available }, onStart: { unexpected.fulfill() })
        available = false
        await fulfillment(of: [unexpected], timeout: 0.2)
        XCTAssertNil(countdown.remaining)
        countdown.start(canStart: { false }, onStart: { XCTFail("Do not schedule an unavailable camera") })
        XCTAssertNil(countdown.remaining)
    }
    func testTimedDollyWaitsForFullDurationEvenNearTarget() throws {
        var filter = try XCTUnwrap(SmoothZoomFilter(current: 1, minimum: 1, maximum: 16))
        filter.setTarget(8, duration: 10)
        _ = filter.advance(seconds: 9.99, rate: 0.75)
        XCTAssertLessThan(abs(log2(filter.value / filter.target)), 0.0002)
        XCTAssertFalse(filter.isSettled, "A small zoom error must not cut short the requested duration")
        XCTAssertEqual(try XCTUnwrap(filter.remainingDuration), 0.01, accuracy: 0.000001)
        _ = filter.advance(seconds: 0.01, rate: 0.75)
        XCTAssertTrue(filter.isSettled); XCTAssertEqual(filter.value, 8, accuracy: 0.00001)
    }
    func testTimedDollyUsesElapsedTimeAndPreservesRemainingTimeOnRangeChange() throws {
        var filter = try XCTUnwrap(SmoothZoomFilter(current: 1, minimum: 1, maximum: 16))
        filter.setTarget(8, duration: 3)
        _ = filter.advance(seconds: 1.5, rate: 0.75)
        XCTAssertEqual(filter.value, sqrt(8), accuracy: 0.0001)
        var changed = try XCTUnwrap(SmoothZoomFilter(current: filter.value, minimum: 1, maximum: 8))
        changed.setTarget(filter.target, duration: filter.remainingDuration)
        _ = changed.advance(seconds: 1.5, rate: 0.75)
        XCTAssertTrue(changed.isSettled); XCTAssertEqual(changed.value, 8, accuracy: 0.0001)
    }
    func testOrphanRecoveryKeepsStandardOutOfAnExistingLogRecoveryMovie() async throws {
        let store = try await makeStore()
        let logMovie = try await store.create(name: "Recovered Recordings", format: .portrait, profile: .appleLog)
        let orphan = store.root.appendingPathComponent("Staging/\(UUID().uuidString).mov")
        try await footage(orphan)
        let bytes = try Data(contentsOf: orphan)
        let reopened = ProjectStore(root: store.root); _ = try await reopened.load()
        let movies = await reopened.snapshot()
        let existing = try XCTUnwrap(movies.first { $0.id == logMovie.id })
        XCTAssertTrue(existing.scenes.isEmpty); XCTAssertEqual(existing.captureProfile, .appleLog)
        let recovered = try XCTUnwrap(movies.first { $0.id != logMovie.id && $0.name == "Recovered Recordings" })
        XCTAssertEqual(recovered.captureProfile, .standard)
        let scene = try XCTUnwrap(recovered.activeScenes.first)
        XCTAssertEqual(scene.profile, .standard)
        XCTAssertEqual(try Data(contentsOf: store.root.appendingPathComponent(scene.source)), bytes)
    }

    @MainActor func testPhotosExportRetryClearsEarlierError() async {
        actor Writer {
            var calls = 0
            func write(_ url: URL) throws -> String {
                calls += 1
                if calls == 1 { throw HomeMovieError.message("Temporary Photos failure") }
                return "saved-asset"
            }
        }
        let writer = Writer()
        let model = ExportModel(authorizePhotos: { true }, writePhotosVideo: { try await writer.write($0) })
        model.exportedURL = URL(fileURLWithPath: "/tmp/fixture-export.mp4")
        await model.saveToPhotos(); XCTAssertNotNil(model.error); XCTAssertNil(model.notice)
        XCTAssertEqual(model.saveFeedback?.kind, .failure)
        await model.saveToPhotos(); XCTAssertNil(model.error); XCTAssertNotNil(model.notice)
        XCTAssertEqual(model.saveFeedback?.kind, .success)
        XCTAssertEqual(model.saveFeedback?.message, "Saved to Photos")
    }
    @MainActor func testPhotosExportDoesNotClaimSuccessWithoutAReceipt() async {
        let model = ExportModel(authorizePhotos: { true }, writePhotosVideo: { _ in "" })
        model.exportedURL = URL(fileURLWithPath: "/tmp/fixture-export.mp4")
        model.notice = "Old successful save"
        await model.saveToPhotos()
        XCTAssertNotNil(model.error); XCTAssertNil(model.notice)
    }
    @MainActor func testDeniedPhotosExportNeverRequestsAWrite() async {
        let model = ExportModel(authorizePhotos: { false }, writePhotosVideo: { _ in
            XCTFail("Denied permission must not write to Photos"); return "unexpected"
        })
        model.exportedURL = URL(fileURLWithPath: "/tmp/fixture-export.mp4")
        await model.saveToPhotos(); XCTAssertNotNil(model.error); XCTAssertNil(model.notice)
    }
    @MainActor func testConcurrentPhotosExportsDoNotCreateDuplicateWrites() async {
        actor Writer {
            var calls = 0
            private var pending: CheckedContinuation<Void, Never>?
            func write(_ url: URL) async -> String {
                calls += 1
                await withCheckedContinuation { pending = $0 }
                return "saved-asset"
            }
            func finish() { pending?.resume(); pending = nil }
        }
        let writer = Writer()
        let model = ExportModel(authorizePhotos: { true }, writePhotosVideo: { await writer.write($0) })
        model.exportedURL = URL(fileURLWithPath: "/tmp/fixture-export.mp4")
        let first = Task { await model.saveToPhotos() }
        for _ in 0..<1000 {
            let calls = await writer.calls
            if calls > 0 { break }
            await Task.yield()
        }
        let startedCalls = await writer.calls
        XCTAssertEqual(model.saveFeedback?.kind, .saving)
        guard startedCalls == 1 else { first.cancel(); XCTFail("First save did not start"); return }
        await model.saveToPhotos() // The first write is deliberately still in flight.
        let calls = await writer.calls
        await writer.finish(); await first.value
        XCTAssertEqual(calls, 1); XCTAssertNil(model.error); XCTAssertNotNil(model.notice)
    }

    func testLogCodecPrefersHEVCAndSupportsNativeProResWithoutSDRFallback() {
        XCTAssertEqual(LogRecordingCodec.preferred(in: [LogRecordingCodec.proRes422, .hevc, LogRecordingCodec.proResLT]), .hevc)
        XCTAssertEqual(LogRecordingCodec.preferred(in: [LogRecordingCodec.proRes422, LogRecordingCodec.proResLT]), LogRecordingCodec.proResLT)
        XCTAssertEqual(LogRecordingCodec.preferred(in: [LogRecordingCodec.proRes422]), LogRecordingCodec.proRes422)
        XCTAssertNil(LogRecordingCodec.preferred(in: [.h264]))
        XCTAssertNil(LogRecordingCodec.preferred(in: []))
    }

    @MainActor func testLiveLookCompletionCannotRevealOriginalOrInactivePreview() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let renderer = LiveLookRenderer(device: device) else {
            throw XCTSkip("Metal preview is unavailable on this simulator")
        }
        let frames = LiveFrames(), cube = try ColorCube.appleStandard.get()
        renderer.configure(frames: frames, cube: cube, active: true)
        let graded = renderer.presentationID
        XCTAssertTrue(renderer.canPresent(graded))
        renderer.configure(frames: frames, cube: nil, active: true)
        XCTAssertFalse(renderer.canPresent(graded), "A finishing GPU frame must not reveal a look after Show Original")
        renderer.configure(frames: frames, cube: cube, active: true)
        let resumed = renderer.presentationID
        XCTAssertFalse(renderer.canPresent(graded))
        XCTAssertTrue(renderer.canPresent(resumed))
        renderer.configure(frames: frames, cube: cube, active: false)
        XCTAssertFalse(renderer.canPresent(resumed), "Leaving capture must invalidate in-flight presentation")
    }
    @MainActor func testLiveLookSwitchRejectsPreviousFrameWithoutInvalidatingSameLook() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let renderer = LiveLookRenderer(device: device) else {
            throw XCTSkip("Metal preview is unavailable on this simulator")
        }
        let frames = LiveFrames(), cube = try ColorCube.appleStandard.get()
        renderer.configure(frames: frames, cube: cube, active: true)
        let initial = renderer.presentationID
        renderer.configure(frames: frames, cube: cube, active: true)
        XCTAssertTrue(renderer.canPresent(initial), "Timer and metering updates must not invalidate an unchanged look")
        var changed = cube; changed.minimum = [-1, -1, -1]
        renderer.configure(frames: frames, cube: changed, active: true)
        XCTAssertFalse(renderer.canPresent(initial), "Switching looks must reject an old frame even with identical samples")
        XCTAssertTrue(renderer.canPresent(renderer.presentationID))
        let current = renderer.presentationID
        renderer.configure(frames: LiveFrames(), cube: changed, active: true)
        XCTAssertFalse(renderer.canPresent(current), "A different capture source must invalidate the previous frame")
    }
    func testSmoothZoomOpeningDoesNotMoveAndInvalidTargetsAreIgnored() throws {
        var filter = try XCTUnwrap(SmoothZoomFilter(current: 3.2, minimum: 1, maximum: 16))
        XCTAssertEqual(filter.value, 3.2); XCTAssertEqual(filter.target, 3.2)
        XCTAssertEqual(filter.advance(seconds: 0.05, rate: 0.75), 3.2, accuracy: 0.0001)
        filter.setTarget(.nan); filter.setTarget(.infinity); filter.setTarget(-2)
        XCTAssertEqual(filter.target, 3.2)
        XCTAssertNil(SmoothZoomFilter(current: .infinity, minimum: 1, maximum: 8))
        XCTAssertNil(SmoothZoomFilter(current: 1, minimum: 0, maximum: 8))
        XCTAssertNil(SmoothZoomFilter(current: 1, minimum: 8, maximum: 8))
    }
    func testSmoothZoomTargetFollowsRateLimitWithoutOvershootAndSettlesAfterRelease() throws {
        var filter = try XCTUnwrap(SmoothZoomFilter(current: 1, minimum: 1, maximum: 16))
        filter.setTarget(8)
        var previous = filter.value
        for _ in 0..<240 {
            let value = filter.advance(seconds: 0.05, rate: 0.75)
            XCTAssertGreaterThanOrEqual(value, previous)
            XCTAssertLessThanOrEqual(value, 8)
            XCTAssertLessThanOrEqual(log2(value / previous), 0.75 * 0.05 + 0.0002)
            previous = value
        }
        XCTAssertEqual(filter.value, 8, accuracy: 0.001)
        XCTAssertEqual(filter.target, 8, "Releasing input must retain the target while the controller settles")
    }
    func testSmoothZoomReversalAndSpeedAreDirectionIndependent() throws {
        var slow = try XCTUnwrap(SmoothZoomFilter(current: 4, minimum: 1, maximum: 16))
        var fast = slow; slow.setTarget(16); fast.setTarget(16)
        for _ in 0..<20 { _ = slow.advance(seconds: 0.05, rate: SmoothZoomSpeed.slow.rate); _ = fast.advance(seconds: 0.05, rate: SmoothZoomSpeed.fast.rate) }
        XCTAssertGreaterThan(fast.value, slow.value)
        let incomingVelocity = fast.velocity
        fast.setTarget(1); XCTAssertEqual(fast.velocity, incomingVelocity)
        var previous = fast.value
        for index in 0..<200 {
            let value = fast.advance(seconds: 0.05, rate: SmoothZoomSpeed.fast.rate)
            if index >= 3 { XCTAssertLessThanOrEqual(value, previous) }
            XCTAssertGreaterThanOrEqual(value, 1)
            XCTAssertLessThanOrEqual(abs(log2(previous / value)), Double(SmoothZoomSpeed.fast.rate) * 0.05 + 0.0002)
            previous = value
        }
        XCTAssertEqual(fast.value, 1, accuracy: 0.001)
    }
    func testDollyFineAdjustmentKeepsStartAndCompletionIdentity() throws {
        let route = try XCTUnwrap(DollyZoomRoute(start: 1.3, destination: 8, seconds: 30))
        let adjusted = route.adjustingDestination(to: 7.6)
        XCTAssertEqual(adjusted.id, route.id)
        XCTAssertEqual(adjusted.start, 1.3)
        XCTAssertEqual(adjusted.destination, 7.6)
        XCTAssertEqual(adjusted.seconds, 30)
        XCTAssertTrue(adjusted.hasArrived(at: 7.6))
        XCTAssertFalse(adjusted.hasArrived(at: 8))
        XCTAssertEqual(adjusted.adjustingDestination(to: .nan), adjusted)
        XCTAssertEqual(route.adjustingDestination(to: 1.3).progress(at: 1.3), 1)
    }
    func testDollyEndpointRefinementPreservesRemainingTimeAndMomentum() throws {
        for duration in [15, 20, 25, 30] {
            XCTAssertEqual(DollyZoomDuration.validated(duration), duration)
            for (start, end, refined) in [(1.3, 8.0, 7.6), (8.0, 1.0, 1.3)] {
                var filter = try XCTUnwrap(SmoothZoomFilter(current: start, minimum: 0.5, maximum: 16))
                filter.setTarget(end, duration: Double(duration))
                _ = filter.advance(seconds: Double(duration) / 3, rate: 0.75)
                let position = filter.value, velocity = filter.velocity
                let remaining = try XCTUnwrap(filter.remainingDuration)
                filter.adjustTimedDestination(to: refined)
                XCTAssertEqual(filter.value, position)
                XCTAssertEqual(filter.velocity, velocity)
                XCTAssertEqual(try XCTUnwrap(filter.remainingDuration), remaining, accuracy: 0.000001)
                for _ in 0..<600 { _ = filter.advance(seconds: remaining / 600, rate: 0.75) }
                XCTAssertEqual(filter.value, refined, accuracy: 0.0001)
                XCTAssertTrue(filter.isSettled)
            }
        }
    }
    func testDollyDurationControlsFullMoveInBothDirections() throws {
        XCTAssertEqual(DollyZoomDuration.validated(99), 3)
        for duration in DollyZoomDuration.choices {
            for (start, end) in [(1.0, 8.0), (8.0, 1.0), (1.0, 4.0), (4.0, 1.0)] {
                var filter = try XCTUnwrap(SmoothZoomFilter(current: start, minimum: 1, maximum: 16))
                filter.setTarget(end, duration: Double(duration))
                XCTAssertTrue(filter.isTimed)
                let tick = Double(duration) / 200
                var steps: [Double] = []
                for frame in 0..<200 {
                    let previous = filter.value
                    let next = filter.advance(seconds: tick, rate: 0.35)
                    steps.append(abs(log2(next / previous)))
                    XCTAssertGreaterThanOrEqual(next, min(start, end))
                    XCTAssertLessThanOrEqual(next, max(start, end))
                    if frame == 99 { XCTAssertEqual(next, sqrt(start * end), accuracy: 0.0001) }
                    if frame == 149 { XCTAssertGreaterThan(abs(next - end), 0.01) }
                }
                XCTAssertEqual(filter.value, end, accuracy: 0.0001)
                XCTAssertLessThan(steps[0], steps[99])
                XCTAssertLessThan(steps[199], steps[99])
                // Dragging takes over smoothly from the reached position, without a timed move.
                filter.setTarget(start)
                XCTAssertFalse(filter.isTimed)
                XCTAssertEqual(filter.value, end, accuracy: 0.0001)
                XCTAssertNotEqual(filter.advance(seconds: 0.05, rate: 0.75), end)
            }
        }
    }
    func testDollyLensTargetsEaseInAndOutInBothDirections() throws {
        for (start, end) in [(1.0, 8.0), (8.0, 1.0), (1.0, 4.0), (4.0, 1.0)] {
            var filter = try XCTUnwrap(SmoothZoomFilter(current: start, minimum: 1, maximum: 16))
            filter.setTarget(end)
            var steps: [Double] = []
            for _ in 0..<240 {
                let previous = filter.value
                let next = filter.advance(seconds: 0.05, rate: 0.75)
                steps.append(abs(log2(next / previous)))
                XCTAssertGreaterThanOrEqual(next, min(start, end))
                XCTAssertLessThanOrEqual(next, max(start, end))
            }
            XCTAssertLessThan(steps[0], steps[6], "The beginning accelerates gently")
            XCTAssertLessThan(steps[100], steps[6], "The ending settles gently")
            XCTAssertEqual(filter.value, end, accuracy: 0.001)
        }
    }
    func testSmoothZoomRangeChangesClampTargetsAndCoordinatesRoundTrip() throws {
        var filter = try XCTUnwrap(SmoothZoomFilter(current: 8, minimum: 4, maximum: 12))
        filter.setTarget(1); XCTAssertEqual(filter.target, 4)
        filter.setTarget(16); XCTAssertEqual(filter.target, 12)
        for factor in [1.0, 2, 4, 8, 16] {
            let position = SmoothZoomFilter.position(factor, minimum: 1, maximum: 16)
            XCTAssertEqual(SmoothZoomFilter.factor(position, minimum: 1, maximum: 16), factor, accuracy: 0.0001)
        }
        XCTAssertEqual(SmoothZoomFilter.factor(-1, minimum: 4, maximum: 12), 4, accuracy: 0.0001)
        XCTAssertEqual(SmoothZoomFilter.factor(2, minimum: 4, maximum: 12), 12, accuracy: 0.0001)
        XCTAssertEqual(SmoothZoomFilter.factor(.nan, minimum: 1, maximum: 16), 1)
    }
    func testSmoothZoomDelayedTicksCannotJumpAndInvalidTimeDoesNotMove() throws {
        var filter = try XCTUnwrap(SmoothZoomFilter(current: 1, minimum: 1, maximum: 16)); filter.setTarget(16)
        let value = filter.advance(seconds: 10, rate: 0.75)
        XCTAssertLessThanOrEqual(log2(value), 0.075 + 0.0001, "A stalled capture queue must not jump to the target")
        XCTAssertEqual(filter.advance(seconds: .nan, rate: 0.75), value)
        XCTAssertEqual(filter.advance(seconds: -1, rate: 0.75), value)
        XCTAssertEqual(filter.advance(seconds: 0.05, rate: .infinity), value)
    }
    func testCaptureFormatUsesCameraAngleInBothDirections() {
        for angle in [CGFloat(0), 180, 360, -180] {
            XCTAssertEqual(MovieFormat.captureFormat(angle: angle), .landscape)
        }
        for angle in [CGFloat(90), 270, -90, 450] {
            XCTAssertEqual(MovieFormat.captureFormat(angle: angle), .portrait)
        }
        XCTAssertNil(MovieFormat.captureFormat(angle: .nan))
        XCTAssertNil(MovieFormat.captureFormat(angle: .infinity))
    }
    func testFirstSceneLocksOrientationAcrossRelaunchAndSceneDeletion() async throws {
        for format in MovieFormat.allCases {
            let store = try await makeStore()
            let movie = try await store.create(name: "Automatic", format: format == .portrait ? .landscape : .portrait)
            XCTAssertNil(movie.recordingFormat)
            let ticket = try await store.begin(movieID: movie.id, format: format)
            try await footage(store.root.appendingPathComponent(ticket.staging), rotated: format == .portrait)
            try await store.commit(ticket)
            try await store.setSceneDeleted(movieID: movie.id, sceneID: ticket.sceneID, deleted: true)
            let reopened = ProjectStore(root: store.root); _ = try await reopened.load()
            let snapshot = await reopened.snapshot()
            let saved = try XCTUnwrap(snapshot.first)
            XCTAssertEqual(saved.format, format)
            XCTAssertEqual(saved.recordingFormat, format)
            XCTAssertTrue(saved.activeScenes.isEmpty)
            do {
                _ = try await reopened.begin(movieID: movie.id, format: format == .portrait ? .landscape : .portrait)
                XCTFail("A later scene must use the original movie orientation")
            } catch {}
            let next = try await reopened.begin(movieID: movie.id, format: format)
            try await reopened.abandonUnstarted(next)
        }
    }
    func testCancelledFirstCaptureLeavesOrientationAutomatic() async throws {
        let store = try await makeStore(), movie = try await store.create(name: "Draft", format: .portrait)
        let canceled = try await store.begin(movieID: movie.id, format: .portrait)
        try await store.abandonUnstarted(canceled)
        let snapshot = await store.snapshot()
        XCTAssertNil(snapshot.first?.recordingFormat)
        let ticket = try await store.begin(movieID: movie.id, format: .landscape)
        try await footage(store.root.appendingPathComponent(ticket.staging))
        try await store.commit(ticket)
        let saved = await store.snapshot()
        XCTAssertEqual(saved.first?.recordingFormat, .landscape)
    }
    func testFirstSceneRecoveryRetainsOrientationAndLegacyTicketsDecode() async throws {
        let store = try await makeStore(), movie = try await store.create(name: "Recovered", format: .landscape)
        let ticket = try await store.begin(movieID: movie.id, format: .portrait)
        try await footage(store.root.appendingPathComponent(ticket.staging), rotated: true)
        let reopened = ProjectStore(root: store.root); _ = try await reopened.load()
        let saved = await reopened.snapshot()
        XCTAssertEqual(saved.first?.recordingFormat, .portrait)
        XCTAssertEqual(saved.first?.scenes.first?.id, ticket.sceneID)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(ticket)) as? [String: Any])
        legacy.removeValue(forKey: "format")
        let decoded = try JSONDecoder().decode(CaptureTicket.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(decoded.format)
        XCTAssertEqual(decoded.sceneID, ticket.sceneID)
    }
    func testNativeResolutionZoomChoicesIncludeSupportedEightTimes() {
        let choices = LensChoice.available(minimum: 1, maximum: 20, multiplier: 0.5,
            switchFactors: [2, 8], secondaryFactors: [4, 16, 16])
        XCTAssertEqual(choices.map(\.displayed), [0.5, 1, 2, 4, 8])
        XCTAssertEqual(choices.last?.factor, 16)
    }
    func testInternalSwitchBoundaryDoesNotBecomeAnExtraLensButton() {
        let choices = LensChoice.available(minimum: 1, maximum: 20, multiplier: 0.5,
            switchFactors: [1.8, 1.91, 2, 8], secondaryFactors: [4, 16, 16.01])
        XCTAssertEqual(choices.map(\.displayed), [0.5, 1, 2, 4, 8])
        XCTAssertEqual(choices.first(where: { $0.displayed == 1 })?.factor, 2,
            "Use the system multiplier's true 1× anchor, not a nearby switch boundary")
        XCTAssertFalse(choices.contains(where: { $0.displayed == 0.9 }))
        let single = LensChoice.available(minimum: 1, maximum: 12, multiplier: 1,
            switchFactors: [], secondaryFactors: [2])
        XCTAssertEqual(single.map(\.displayed), [1, 2])
    }
    func testZoomChoicesRespectDeviceRangeAndDoNotInventEightTimes() {
        let olderPhone = LensChoice.available(minimum: 1, maximum: 12, multiplier: 0.5,
            switchFactors: [2, 6], secondaryFactors: [])
        XCTAssertEqual(olderPhone.map(\.displayed), [0.5, 1, 3])
        let restricted = LensChoice.available(minimum: 1, maximum: 8, multiplier: 0.5,
            switchFactors: [2, 8], secondaryFactors: [4, 16])
        XCTAssertEqual(restricted.map(\.displayed), [0.5, 1, 2, 4])
    }
    func testInvalidVideoGeometryIsRejectedBeforeComposition() {
        let valid = CGSize(width: 1920, height: 1080)
        XCTAssertTrue(MediaAssembler.hasValidGeometry(size: valid, preferred: CGAffineTransform(rotationAngle: .pi / 2)))
        XCTAssertFalse(MediaAssembler.hasValidGeometry(size: .zero, preferred: .identity))
        XCTAssertFalse(MediaAssembler.hasValidGeometry(size: CGSize(width: CGFloat.infinity, height: 1080), preferred: .identity))
        XCTAssertFalse(MediaAssembler.hasValidGeometry(size: valid, preferred: CGAffineTransform(a: .nan, b: 0, c: 0, d: 1, tx: 0, ty: 0)))
    }
    func testDurationLabelsHandleExtremeAndInvalidTimes() {
        XCTAssertEqual(durationLabel(CMTime(value: Int64.max, timescale: 1)), "2562047788015215:30:07")
        XCTAssertEqual(durationLabel(.indefinite), "0:00")
        XCTAssertEqual(durationLabel(CMTime(seconds: -1, preferredTimescale: 600)), "0:00")
        XCTAssertEqual(durationLabel(CMTime(seconds: 3661, preferredTimescale: 600)), "1:01:01")
    }
    func testOversizedCatalogStorageIsRejectedWithoutOverwriting() async throws {
        let store = try await makeStore()
        _ = try await store.create(name: "Preserve", format: .landscape)
        for aggregate in [false, true] {
            var catalog = await store.catalogSnapshot()
            catalog.movies[0].scenes = (0..<(aggregate ? 5 : 1)).map { position in
                let id = UUID()
                return Scene(id: id, sequence: position, source: "Originals/\(id).mov", capturedAt: Date(), timeZone: "UTC",
                    sourceDuration: MediaTime(seconds: 1), trimStart: MediaTime(.zero), trimEnd: MediaTime(seconds: 1),
                    width: 320, height: 240, hasAudio: false, bytes: aggregate ? Int64.max / 4 : Int64.max)
            }
            let file = store.root.appendingPathComponent("catalog.json")
            let damaged = try JSONEncoder().encode(catalog)
            try damaged.write(to: file)
            let preservedMedia = store.root.appendingPathComponent(catalog.movies[0].scenes[0].source)
            try Data([1, 2, 3]).write(to: preservedMedia)
            let reopened = ProjectStore(root: store.root)
            do { _ = try await reopened.load(); XCTFail("Unsafe storage metadata must be rejected") } catch {}
            XCTAssertEqual(try Data(contentsOf: file), damaged)
            let recovery = try await reopened.recoveryFiles()
            XCTAssertTrue(recovery.contains { $0.url == preservedMedia }, "Rejected metadata must not hide preserved footage")
        }
    }
    @MainActor func testFailedLibraryReloadClearsReadyStateAndPreservesCatalog() async throws {
        let store = try await makeStore(), app = AppModel(store: store)
        await app.load()
        XCTAssertTrue(app.loaded)
        try await store.beginMaintenance()
        try await store.installImportedMovies([])
        await store.endMaintenance()
        let file = store.root.appendingPathComponent("catalog.json")
        let damaged = Data("broken reload".utf8)
        try damaged.write(to: file)
        await app.load()
        XCTAssertFalse(app.loaded)
        XCTAssertNotNil(app.loadFailure)
        XCTAssertEqual(try Data(contentsOf: file), damaged)
    }
    func testEstablishedRecordingAnglesDoNotRequirePhysicalRotation() {
        for format in MovieFormat.allCases {
            for observed in [CGFloat(0), 90, 180, 270, 360, -90] {
                XCTAssertEqual(MovieFormat.captureFormat(angle: format.recordingAngle(observed: observed)), format)
            }
        }
        XCTAssertEqual(MovieFormat.portrait.recordingAngle(observed: .nan), 90)
        XCTAssertEqual(MovieFormat.landscape.recordingAngle(observed: .infinity), 0)
    }
    func testLiveLookGeometryFillsBothOrientationsAndMirrorsFrontCamera() {
        let source = CGSize(width: 320, height: 240)
        for target in [CGSize(width: 393, height: 852), CGSize(width: 852, height: 393)] {
            for angle in [CGFloat(0), 90, 180, 270] {
                for front in [false, true] {
                    let transform = LiveLookGeometry.transform(source: source, target: target, angle: angle, front: front)
                    let bounds = CGRect(origin: .zero, size: source).applying(transform)
                    XCTAssertLessThanOrEqual(bounds.minX, 0.001); XCTAssertLessThanOrEqual(bounds.minY, 0.001)
                    XCTAssertGreaterThanOrEqual(bounds.maxX, target.width - 0.001)
                    XCTAssertGreaterThanOrEqual(bounds.maxY, target.height - 0.001)
                }
            }
        }
        let target = source
        let normal = LiveLookGeometry.transform(source: source, target: target, angle: 0, front: false)
        let mirror = LiveLookGeometry.transform(source: source, target: target, angle: 0, front: true)
        XCTAssertEqual(CGPoint(x: 20, y: 30).applying(normal).x, 20, accuracy: 0.001)
        XCTAssertEqual(CGPoint(x: 20, y: 30).applying(mirror).x, 300, accuracy: 0.001)
    }
    func testLiveMailboxReplacesFramesAndClearsWithoutQueuing() throws {
        func frame(width: Int) throws -> CVPixelBuffer {
            var buffer: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, width, 16, kCVPixelFormatType_32BGRA, nil, &buffer), kCVReturnSuccess)
            return try XCTUnwrap(buffer)
        }
        let mailbox = LiveFrames()
        mailbox.push(try frame(width: 16)); XCTAssertEqual(CVPixelBufferGetWidth(try XCTUnwrap(mailbox.latest())), 16)
        mailbox.push(try frame(width: 32)); XCTAssertEqual(CVPixelBufferGetWidth(try XCTUnwrap(mailbox.latest())), 32)
        mailbox.clear(); XCTAssertNil(mailbox.latest())
    }
    private var testCube: String { "TITLE \"Test\"\nLUT_3D_SIZE 2\n" + Array(repeating: "0.9 0.1 0.2", count: 8).joined(separator: "\n") }
    func testCubeParserBoundsDomainsAndRejectsMalformedFiles() throws {
        let cube = try ColorCube.parse(testCube, name: "Cinema LUT")
        XCTAssertEqual(cube.name, "Cinema")
        XCTAssertEqual(cube.dimension, 2)
        XCTAssertEqual(cube.rgba.count, 128)
        for text in ["LUT_1D_SIZE 4096", "LUT_3D_SIZE 128", "LUT_3D_SIZE 2\n0 0 0", testCube + "\n0 0 0",
                     testCube.replacingOccurrences(of: "0.9", with: "nan"), "LUT_3D_SIZE 2\nDOMAIN_MIN 1 1 1\nDOMAIN_MAX 0 0 0\n" + Array(repeating: "0 0 0", count: 8).joined(separator: "\n")] {
            XCTAssertThrowsError(try ColorCube.parse(text, name: "Invalid"))
        }
    }
    func testStandardLookAssetAndLegacyProfiles() throws {
        let cube = try ColorCube.appleStandard.get(); try cube.validate()
        XCTAssertEqual(cube.dimension, 65)
        let movie = Movie(name: "Legacy", format: .portrait)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(movie)) as? [String: Any])
        json.removeValue(forKey: "profile"); json.removeValue(forKey: "look")
        let decoded = try JSONDecoder().decode(Movie.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.captureProfile, .standard)
        XCTAssertNil(decoded.look)
    }
    func testBundledFilmicaDefaultsPersistAndStandardRemainsSelectable() async throws {
        let cube = try ColorCube.filmica.get(); try cube.validate()
        XCTAssertEqual(cube.name, "Cinema"); XCTAssertEqual(cube.dimension, 65)
        let first = cube.rgba.withUnsafeBytes { $0.loadUnaligned(as: Float.self) }
        XCTAssertEqual(first, 0.0308995, accuracy: 0.0000001)
        let store = try await makeStore()
        let looks = await store.availableLooks()
        XCTAssertTrue(looks.contains(.filmica))
        let movie = try await store.create(name: "Filmica", format: .portrait, profile: .appleLog)
        XCTAssertEqual(movie.look, .filmica)
        let stored = try ColorCube.load(.filmica, root: store.root)
        XCTAssertEqual(stored.rgba, cube.rgba)
        try await store.setLook(movieID: movie.id, look: nil)
        let reopened = ProjectStore(root: store.root); _ = try await reopened.load()
        let movies = await reopened.snapshot()
        XCTAssertNil(movies.first?.look, "An explicit Apple Standard selection survives relaunch")
        let standard = try await reopened.create(name: "SDR", format: .portrait)
        XCTAssertNil(standard.look)
        XCTAssertEqual(standard.captureProfile, .standard)
        XCTAssertEqual(LUTReference(id: LUTReference.filmica.id, name: "Filmica").displayName, "Cinema")
        let explicit = try await reopened.create(name: "Apple Standard", format: .portrait, profile: .appleLog, useDefaultLook: false)
        XCTAssertNil(explicit.look)
    }
    func testBundledFilmicaBackupIncludesExactSamples() async throws {
        let store = try await makeStore()
        let movie = try await store.create(name: "Default look backup", format: .portrait, profile: .appleLog)
        _ = try await record(movie, into: store)
        let service = BackupService(), backup = try await service.create(store: store) { _ in }
        let destination = try await makeStore()
        try await service.restore(from: backup.url, store: destination) { _ in }
        let movies = await destination.snapshot()
        let look = try XCTUnwrap(movies.first?.look)
        XCTAssertEqual(look.name, "Cinema")
        let restored = try ColorCube.load(look, root: destination.root)
        XCTAssertEqual(restored.rgba, try ColorCube.filmica.get().rgba)
        try await service.discard(backup.url)
    }
    func testAppleLogVerificationReadsExactTransferIdentifier() throws {
        func description(_ extensions: [String: Any]) throws -> CMFormatDescription {
            var result: CMFormatDescription?
            let status = CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                codecType: kCMVideoCodecType_AppleProRes422, width: 1920, height: 1080,
                extensions: extensions as CFDictionary, formatDescriptionOut: &result)
            XCTAssertEqual(status, noErr)
            return try XCTUnwrap(result)
        }
        let key = kCMFormatDescriptionExtension_LogTransferFunction as String
        let log = try description([key: kCMFormatDescriptionLogTransferFunction_AppleLog as String])
        XCTAssertEqual(MediaInspector.captureProfile(for: [log]), .appleLog)
        let standard = try description([:])
        XCTAssertNil(MediaInspector.captureProfile(for: [standard]))
        XCTAssertNil(MediaInspector.captureProfile(for: []))
        XCTAssertNil(MediaInspector.captureProfile(for: [log, standard]))
        let log2 = try description([key: "com.apple.apple-wide-gamut.apple-log"])
        XCTAssertNil(MediaInspector.captureProfile(for: [log2]), "Apple Log 2 needs a different color pipeline")
        let unrelated = try description(["Comment": "AppleLog"])
        XCTAssertNil(MediaInspector.captureProfile(for: [unrelated]), "A label is not verified Log metadata")
        let hdr = try description([kCMFormatDescriptionExtension_TransferFunction as String:
            kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String])
        XCTAssertNil(MediaInspector.captureProfile(for: [hdr]))
    }
    func testRecoveryRejectsSDRIntoLogAndPreservesSource() async throws {
        let store = try await makeStore()
        let movie = try await store.create(name: "Log recovery", format: .portrait, profile: .appleLog)
        let source = store.root.appendingPathComponent("Recovery/sdr.mov")
        try await footage(source)
        let files = try await store.recoveryFiles()
        let file = try XCTUnwrap(files.first { $0.url == source })
        do { try await store.recoverFile(file, movieID: movie.id); XCTFail("SDR must not be treated as Log") } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        let movies = await store.snapshot(); XCTAssertTrue(movies.first!.scenes.isEmpty)
        let standard = try await store.create(name: "SDR recovery", format: .landscape)
        try await store.recoverFile(file, movieID: standard.id)
        let recovered = await store.snapshot().first { $0.id == standard.id }
        XCTAssertEqual(recovered?.scenes.first?.profile, .standard)
    }
    func testThumbnailsHonorFilmicaAndInvalidateOnLookChange() async throws {
        let store = try await makeStore()
        var movie = try await store.create(name: "Thumbnail", format: .landscape, profile: .appleLog)
        _ = try await record(movie, into: store)
        let saved = await store.snapshot(); movie = try XCTUnwrap(saved.first)
        let scene = try XCTUnwrap(movie.activeScenes.first)
        let filmica = try await ThumbnailService.shared.image(scene: scene, root: store.root, movie: movie)
        movie.look = nil; movie.revision += 1
        let standard = try await ThumbnailService.shared.image(scene: scene, root: store.root, movie: movie)
        XCTAssertNotEqual(filmica.pngData(), standard.pngData(), "Look changes must not return a stale cached thumbnail")
        movie.profile = nil; movie.revision += 1
        let original = try await ThumbnailService.shared.image(scene: scene, root: store.root, movie: movie)
        XCTAssertNotEqual(filmica.pngData(), original.pngData())
    }
    func testUndoLastTakeIsRecoverableAndRejectsStaleTargets() async throws {
        let store = try await makeStore()
        let movie = try await store.create(name: "Undo", format: .landscape)
        let first = try await record(movie, into: store)
        let last = try await record(movie, into: store)
        let source = store.root.appendingPathComponent(last.source)
        let original = try Data(contentsOf: source)
        let before = await store.snapshot().first!
        do { try await store.undoLastTake(movieID: movie.id, expectedSceneID: first.sceneID); XCTFail("Must not undo an older take") } catch {}
        try await store.undoLastTake(movieID: movie.id, expectedSceneID: last.sceneID)
        let undone = await store.snapshot().first!
        XCTAssertEqual(undone.activeScenes.map(\.id), [first.sceneID])
        XCTAssertEqual(undone.revision, before.revision + 1)
        XCTAssertLessThan(undone.duration.seconds, before.duration.seconds)
        XCTAssertNotNil(undone.scenes.last?.deletedAt)
        XCTAssertEqual(try Data(contentsOf: source), original)
        do { try await store.undoLastTake(movieID: movie.id, expectedSceneID: last.sceneID); XCTFail("A second stale tap must not remove another take") } catch {}
        let reopened = ProjectStore(root: store.root); _ = try await reopened.load()
        let saved = await reopened.snapshot().first!
        XCTAssertEqual(saved.activeScenes.map(\.id), [first.sceneID])
        XCTAssertEqual(saved.recordingFormat, .landscape)
        try await reopened.setSceneDeleted(movieID: movie.id, sceneID: last.sceneID, deleted: false)
        let restored = await reopened.snapshot().first!
        XCTAssertEqual(restored.activeScenes.map(\.id), [first.sceneID, last.sceneID])
        XCTAssertEqual(try Data(contentsOf: source), original)
    }
    func testLookSelectionPersistsAndInvalidatesExportRevision() async throws {
        let store = try await makeStore(), movie = try await store.create(name: "Log", format: .landscape, profile: .appleLog)
        do { _ = try await store.begin(movieID: movie.id, profile: .standard); XCTFail("A Log movie must not silently record Standard") } catch {}
        let file = store.root.appendingPathComponent("Cinema.cube"); try testCube.write(to: file, atomically: true, encoding: .utf8)
        let look = try await store.importLook(from: file)
        try await store.setLook(movieID: movie.id, look: look)
        let revision = await store.snapshot().first!.revision
        try await store.setLook(movieID: movie.id, look: look)
        let unchanged = await store.snapshot()
        XCTAssertEqual(unchanged.first?.revision, revision)
        let reopened = ProjectStore(root: store.root); _ = try await reopened.load()
        let saved = await reopened.snapshot()
        XCTAssertEqual(saved.first?.look, look)
        XCTAssertEqual(saved.first?.captureProfile, .appleLog)
        let restoredCube = try ColorCube.load(look, root: store.root)
        XCTAssertEqual(restoredCube.rgba.count, 128)
        try await reopened.setLook(movieID: movie.id, look: nil)
        let standard = await reopened.snapshot()
        XCTAssertEqual(standard.first?.revision, revision + 1)
        XCTAssertNil(standard.first?.look)
    }
    func testInitialLookCreationIsAtomicWhenLookIsMissing() async throws {
        let store = try await makeStore()
        do {
            _ = try await store.create(name: "Missing", format: .portrait, profile: .appleLog, look: LUTReference(id: UUID(), name: "Missing"))
            XCTFail("Missing looks must fail before creating a movie")
        } catch {}
        let empty = await store.snapshot(); XCTAssertTrue(empty.isEmpty)
        let file = store.root.appendingPathComponent("Initial.cube"); try testCube.write(to: file, atomically: true, encoding: .utf8)
        let look = try await store.importLook(from: file)
        let movie = try await store.create(name: "Initial", format: .portrait, profile: .appleLog, look: look)
        XCTAssertEqual(movie.look, look); XCTAssertEqual(movie.revision, 0)
        let reopened = ProjectStore(root: store.root); _ = try await reopened.load()
        let saved = await reopened.snapshot(); XCTAssertEqual(saved.first?.look, look)
    }
    func testBackupCarriesSelectedLookWithoutChangingExistingFiles() async throws {
        let store = try await makeStore(), movie = try await store.create(name: "Look Backup", format: .landscape, profile: .appleLog)
        let ticket = try await record(movie, into: store)
        let original = try Data(contentsOf: store.root.appendingPathComponent(ticket.source))
        let file = store.root.appendingPathComponent("Cinema.cube"); try testCube.write(to: file, atomically: true, encoding: .utf8)
        let look = try await store.importLook(from: file); try await store.setLook(movieID: movie.id, look: look)
        let backup = BackupService(), prepared = try await backup.create(store: store) { _ in }
        let destination = try await makeStore()
        try await backup.restore(from: prepared.url, store: destination) { _ in }
        let restored = await destination.snapshot()
        let imported = try XCTUnwrap(restored.first?.look)
        XCTAssertNotEqual(imported.id, look.id)
        let a = try ColorCube.load(imported, root: destination.root), b = try ColorCube.load(look, root: store.root)
        XCTAssertEqual(a.rgba, b.rgba)
        XCTAssertEqual(try Data(contentsOf: store.root.appendingPathComponent(ticket.source)), original)
        try await backup.discard(prepared.url)
    }
    @MainActor func testLightToolsPersistMatchExportAndRefreshPausedHistogram() async throws {
        let store = try await makeStore(), movie = try await store.create(name: "Light Tools", format: .landscape)
        _ = try await record(movie, into: store)
        let initialMovies = await store.snapshot()
        let original = try XCTUnwrap(initialMovies.first?.activeScenes.first)
        var recipe = SceneAdjustments.neutral
        recipe.fade = 0.7; recipe.curve = LightCurve(shadows: 0.12, midtones: 0.58, highlights: 0.88)
        try await store.editScene(movieID: movie.id, sceneID: original.id,
            start: original.trimStart.cmTime, end: original.trimEnd.cmTime, adjustments: recipe)
        let reopened = ProjectStore(root: store.root); _ = try await reopened.load()
        let reopenedMovies = await reopened.snapshot()
        let saved = try XCTUnwrap(reopenedMovies.first)
        let scene = try XCTUnwrap(saved.activeScenes.first)
        XCTAssertEqual(scene.lightAdjustments, recipe)
        let bundle = try await MediaAssembler().build(movie: saved, root: store.root)
        let generator = AVAssetImageGenerator(asset: bundle.asset)
        generator.videoComposition = bundle.videoComposition
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let previewImage = try await generator.image(at: .zero).image
        let url = store.root.appendingPathComponent("light-tools-export.mp4")
        let exporter = try XCTUnwrap(AVAssetExportSession(asset: bundle.asset, presetName: AVAssetExportPresetHighestQuality))
        exporter.videoComposition = bundle.videoComposition
        try await exporter.export(to: url, as: .mp4)
        let exported = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        exported.requestedTimeToleranceBefore = .zero; exported.requestedTimeToleranceAfter = .zero
        let exportedImage = try await exported.image(at: .zero).image
        func center(_ image: CGImage) -> [UInt8] {
            var pixel = [UInt8](repeating: 0, count: 4)
            CIContext().render(CIImage(cgImage: image), toBitmap: &pixel, rowBytes: 4,
                bounds: CGRect(x: image.width / 2, y: image.height / 2, width: 1, height: 1),
                format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            return pixel
        }
        let a = center(previewImage), b = center(exportedImage)
        for channel in 0..<3 { XCTAssertEqual(Double(a[channel]), Double(b[channel]), accuracy: 8) }
        let app = AppModel(store: reopened), model = SceneReviewPreviewModel()
        await model.prepare(movie: saved, scene: scene, app: app)
        XCTAssertNil(model.error)
        let monitor = Task { await model.monitorHistogram(enabled: true) }
        defer { monitor.cancel(); model.stop() }
        let deadline = Date().addingTimeInterval(15)
        while model.histogram == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        let before = try XCTUnwrap(model.histogram, "Light must receive a rendered frame while paused")
        XCTAssertGreaterThan(before.samples, 0)
        await model.update(adjustments: .neutral, filmEffects: .off)
        let updateDeadline = Date().addingTimeInterval(15)
        while (model.histogram == nil || model.histogram?.bins == before.bins), Date() < updateDeadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        let after = try XCTUnwrap(model.histogram)
        XCTAssertNotEqual(before.bins, after.bins, "Paused edits must refresh the histogram")
        monitor.cancel(); await model.monitorHistogram(enabled: false)
        XCTAssertNil(model.histogram)
        XCTAssertTrue(model.player?.currentItem?.outputs.isEmpty == true)
    }
    func testCustomLookPlaybackAndExportUseSameCompositor() async throws {
        let store = try await makeStore(), movie = try await store.create(name: "Look Export", format: .portrait, profile: .appleLog)
        _ = try await record(movie, into: store, rotated: true)
        let file = store.root.appendingPathComponent("Look.cube"); try testCube.write(to: file, atomically: true, encoding: .utf8)
        let look = try await store.importLook(from: file); try await store.setLook(movieID: movie.id, look: look)
        let snapshot = await store.snapshot().first!, assembler = MediaAssembler()
        let bundle = try await assembler.build(movie: snapshot, root: store.root)
        XCTAssertEqual(bundle.videoComposition.customVideoCompositorClass.map { ObjectIdentifier($0) }, ObjectIdentifier(LogVideoCompositor.self))
        let original = try await assembler.build(movie: snapshot, root: store.root, showOriginalLog: true)
        XCTAssertNil((original.videoComposition.instructions.first as? ColorInstruction)?.cube)
        let preview = AVAssetImageGenerator(asset: bundle.asset); preview.videoComposition = bundle.videoComposition
        let previewImage = try await preview.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image
        let output = store.root.appendingPathComponent("look-export.mp4")
        let exporter = try XCTUnwrap(AVAssetExportSession(asset: bundle.asset, presetName: AVAssetExportPresetHighestQuality))
        exporter.videoComposition = bundle.videoComposition; try await exporter.export(to: output, as: .mp4)
        let result = try await MediaInspector.inspect(output)
        XCTAssertEqual(result.size.width, 1080, accuracy: 1); XCTAssertEqual(result.size.height, 1920, accuracy: 1)
        let exportImage = try await AVAssetImageGenerator(asset: AVURLAsset(url: output)).image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image
        func sample(_ image: CGImage) -> [UInt8] {
            var pixel = [UInt8](repeating: 0, count: 4)
            CIContext().render(CIImage(cgImage: image), toBitmap: &pixel, rowBytes: 4,
                bounds: CGRect(x: image.width / 2, y: image.height / 2, width: 1, height: 1), format: .RGBA8,
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            return pixel
        }
        let a = sample(previewImage), b = sample(exportImage)
        XCTAssertGreaterThan(a[0], 180); XCTAssertLessThan(a[1], 80)
        for channel in 0..<3 { XCTAssertEqual(Double(a[channel]), Double(b[channel]), accuracy: 8) }
    }
    @MainActor func testPastedAdjustmentsPersistWithoutCopyingTrimLookMediaOrMovieFX() async throws {
        let store = try await makeStore(), project = try await store.create(name: "Copy edits", format: .landscape)
        _ = try await record(project, into: store); _ = try await record(project, into: store)
        let snapshots = await store.snapshot()
        let before = try XCTUnwrap(snapshots.first)
        let first = before.activeScenes[0], second = before.activeScenes[1]
        var source = SceneAdjustments.neutral, target = SceneAdjustments.neutral
        source.contrast = 0.4; source.saturation = -0.2; source.exposure = 0.8
        target.exposure = -0.3; target.warmth = 0.2
        var fx = FilmEffectsSettings.off; fx.grainEnabled = true; fx.grainAmount = 0.4
        try await store.editScene(movieID: before.id, sceneID: first.id, start: .zero,
            end: first.sourceDuration.cmTime, adjustments: source, filmEffects: fx)
        let pasted = try SceneAdjustmentClipboard(source: source, selection: .suggested).applying(to: target)
        try await store.editScene(movieID: before.id, sceneID: second.id,
            start: CMTime(seconds: 0.3, preferredTimescale: 600), end: CMTime(seconds: 1.7, preferredTimescale: 600), adjustments: pasted)
        let reopened = ProjectStore(root: store.root); _ = try await reopened.load()
        let saved = await reopened.snapshot(), movie = try XCTUnwrap(saved.first)
        XCTAssertEqual(movie.exportEffects, fx); XCTAssertEqual(movie.look, before.look)
        XCTAssertEqual(movie.activeScenes.map(\.source), before.activeScenes.map(\.source))
        XCTAssertEqual(movie.activeScenes[0].lightAdjustments, source)
        XCTAssertEqual(movie.activeScenes[1].lightAdjustments, pasted)
        XCTAssertEqual(movie.activeScenes[1].trimStart.seconds, 0.3, accuracy: 0.001)
        XCTAssertEqual(movie.activeScenes[1].trimEnd.seconds, 1.7, accuracy: 0.001)
        XCTAssertEqual(movie.activeScenes[1].lightAdjustments.exposure, -0.3)
        XCTAssertEqual(movie.activeScenes[1].lightAdjustments.warmth, 0.2)
    }
    private func makeStore() async throws -> ProjectStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ProjectStore(root: root); _ = try await store.load()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return store
    }
    private func footage(_ url: URL, rotated: Bool = false, width: Int = 320, height: Int = 240, frames: Int = 60) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height])
        if rotated { input.transform = CGAffineTransform(rotationAngle: .pi / 2) }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? HomeMovieError.message("Fixture writer failed") }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<frames {
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed { throw writer.error ?? HomeMovieError.message("Fixture writer failed") }
                await Task.yield()
            }
            var buffer: CVPixelBuffer?
            let result = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
            guard result == kCVReturnSuccess, let buffer else { throw HomeMovieError.message("Fixture buffer failed") }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) { memset(base, frame % 2 == 0 ? 60 : 120, CVPixelBufferGetBytesPerRow(buffer) * height) }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else { throw writer.error ?? HomeMovieError.message("Fixture append failed") }
        }
        writer.endSession(atSourceTime: CMTime(value: Int64(frames), timescale: 30)); input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? HomeMovieError.message("Fixture did not finish") }
    }
    private func record(_ movie: Movie, into store: ProjectStore, rotated: Bool = false) async throws -> CaptureTicket {
        let ticket = try await store.begin(movieID: movie.id)
        let staging = try await store.url(ticket.staging)
        try await footage(staging, rotated: rotated)
        try await store.commit(ticket); return ticket
    }
    func testIndependentMoviesPersistAndCommitIsIdempotent() async throws {
        let store = try await makeStore()
        let a = try await store.create(name: "A", format: .landscape), b = try await store.create(name: "B", format: .portrait)
        let ticket = try await record(a, into: store)
        _ = try await record(b, into: store, rotated: true)
        try await store.commit(ticket)
        let reopened = ProjectStore(root: store.root); _ = try await reopened.load()
        let movies = await reopened.snapshot()
        XCTAssertEqual(movies.count, 2)
        XCTAssertEqual(movies.first { $0.id == a.id }?.scenes.count, 1)
        XCTAssertEqual(movies.first { $0.id == b.id }?.scenes.count, 1)
        XCTAssertEqual(movies.first { $0.id == a.id }?.scenes.first?.id, ticket.sceneID)
    }
    func testCancelledUnstartedCaptureRemovesOnlyEmptyJournal() async throws {
        let store = try await makeStore(), movie = try await store.create(name: "Cancel", format: .landscape)
        let ticket = try await store.begin(movieID: movie.id)
        let journal = try await store.url(ticket.journal)
        XCTAssertTrue(FileManager.default.fileExists(atPath: journal.path))
        try await store.abandonUnstarted(ticket)
        try await store.abandonUnstarted(ticket)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
        let reopened = ProjectStore(root: store.root)
        let notices = try await reopened.load()
        XCTAssertTrue(notices.isEmpty)
        let movies = await reopened.snapshot()
        XCTAssertTrue(movies.first!.scenes.isEmpty)
        _ = try await record(movie, into: reopened)
        let afterRecording = await reopened.snapshot()
        XCTAssertEqual(afterRecording.first!.scenes.count, 1)
    }
    func testCancellingNeverRemovesStagingOrOriginalBytes() async throws {
        let store = try await makeStore(), movie = try await store.create(name: "Keep footage", format: .landscape)
        for original in [false, true] {
            let ticket = try await store.begin(movieID: movie.id)
            let media = try await store.url(original ? ticket.source : ticket.staging)
            let journal = try await store.url(ticket.journal)
            let bytes = Data([1, 2, 3])
            try bytes.write(to: media)
            do { try await store.abandonUnstarted(ticket); XCTFail("Existing footage must be preserved") } catch {}
            XCTAssertEqual(try Data(contentsOf: media), bytes)
            XCTAssertTrue(FileManager.default.fileExists(atPath: journal.path))
        }
    }
    func testJournalRecoversCompletedButUncommittedTake() async throws {
        let store = try await makeStore(), movie = try await store.create(name: "Recovery", format: .landscape)
        let ticket = try await store.begin(movieID: movie.id)
        let staging = try await store.url(ticket.staging)
        try await footage(staging)
        let reopened = ProjectStore(root: store.root)
        let notices = try await reopened.load(), movies = await reopened.snapshot()
        XCTAssertFalse(notices.isEmpty)
        XCTAssertEqual(movies.first?.scenes.first?.id, ticket.sceneID)
        let original = try await reopened.url(ticket.source)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
    }
    func testInvalidTakePreservedAndNeverCommitted() async throws {
        let store = try await makeStore(), movie = try await store.create(name: "Interrupted", format: .landscape)
        let ticket = try await store.begin(movieID: movie.id), path = try await store.url(ticket.staging)
        try Data([1, 2, 3]).write(to: path)
        do { try await store.commit(ticket); XCTFail("Invalid media must not commit") } catch {}
        let movies = await store.snapshot()
        XCTAssertTrue(movies.first!.scenes.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
    }
    func testTrimAndDeletionPreserveOriginalBytesAndRevision() async throws {
        let store = try await makeStore(), movie = try await store.create(name: "Originals", format: .landscape)
        let ticket = try await record(movie, into: store), path = try await store.url(ticket.source)
        let original = try Data(contentsOf: path)
        try await store.trim(movieID: movie.id, sceneID: ticket.sceneID, start: CMTime(value: 15, timescale: 30), end: CMTime(value: 45, timescale: 30))
        try await store.setSceneDeleted(movieID: movie.id, sceneID: ticket.sceneID, deleted: true)
        try await store.setSceneDeleted(movieID: movie.id, sceneID: ticket.sceneID, deleted: false)
        let restored = await store.snapshot().first!
        XCTAssertEqual(try Data(contentsOf: path), original)
        XCTAssertEqual(restored.revision, 4)
        XCTAssertEqual(restored.duration.seconds, 1, accuracy: 0.001)
        do { try await store.trim(movieID: movie.id, sceneID: ticket.sceneID, start: CMTime(seconds: -1, preferredTimescale: 600), end: CMTime(seconds: 10, preferredTimescale: 600)); XCTFail("Invalid trim must be rejected") } catch {}
        let afterInvalid = await store.snapshot().first!
        XCTAssertEqual(afterInvalid.revision, restored.revision)
    }
    func testCompositionSnapshotAndExportAgreeWithoutAudio() async throws {
        let store = try await makeStore(), movie = try await store.create(name: "Joins", format: .landscape)
        _ = try await record(movie, into: store)
        _ = try await record(movie, into: store, rotated: true)
        let snapshot = await store.snapshot().first!, assembler = MediaAssembler()
        let bundle = try await assembler.build(movie: snapshot, root: store.root)
        XCTAssertEqual(bundle.duration.seconds, 4, accuracy: 0.05)
        XCTAssertEqual(bundle.videoComposition.instructions.count, 2)
        let audioTracks = try await bundle.asset.loadTracks(withMediaType: .audio)
        XCTAssertTrue(audioTracks.isEmpty, "Video-only movies must not include formatless audio tracks")
        _ = try await record(movie, into: store)
        XCTAssertEqual(bundle.duration.seconds, 4, accuracy: 0.05)
        let output = store.root.appendingPathComponent("test-export.mp4")
        let exporter = try XCTUnwrap(AVAssetExportSession(asset: bundle.asset, presetName: AVAssetExportPresetHighestQuality))
        exporter.videoComposition = bundle.videoComposition
        try await exporter.export(to: output, as: .mp4)
        let info = try await MediaInspector.inspect(output)
        XCTAssertEqual(info.duration.seconds, bundle.duration.seconds, accuracy: 0.15)
        XCTAssertEqual(info.size.width, 1920, accuracy: 1)
        XCTAssertEqual(info.size.height, 1080, accuracy: 1)
        XCTAssertFalse(info.hasAudio)
    }
    func testPortraitExportUsesFullPortraitCanvas() async throws {
        let store = try await makeStore(), movie = try await store.create(name: "Portrait", format: .portrait)
        _ = try await record(movie, into: store, rotated: true)
        let snapshot = await store.snapshot().first!, assembler = MediaAssembler()
        let bundle = try await assembler.build(movie: snapshot, root: store.root)
        let output = store.root.appendingPathComponent("portrait.mp4")
        let exporter = try XCTUnwrap(AVAssetExportSession(asset: bundle.asset, presetName: AVAssetExportPresetHighestQuality))
        exporter.videoComposition = bundle.videoComposition
        try await exporter.export(to: output, as: .mp4)
        let info = try await MediaInspector.inspect(output)
        XCTAssertEqual(info.size.width, 1080, accuracy: 1)
        XCTAssertEqual(info.size.height, 1920, accuracy: 1)
        XCTAssertFalse(info.hasAudio)
    }
    func testRotatedClipsRetainOriginalGeometryInsideAnEstablishedMovieCanvas() async throws {
        let store = try await makeStore(), movie = try await store.create(name: "Rotate between takes", format: .portrait)
        _ = try await record(movie, into: store, rotated: true)
        _ = try await record(movie, into: store, rotated: false)
        let movies = await store.snapshot()
        let snapshot = try XCTUnwrap(movies.first)
        XCTAssertEqual(snapshot.recordingFormat, .portrait)
        XCTAssertEqual(snapshot.activeScenes.count, 2)
        XCTAssertLessThan(snapshot.activeScenes[0].width, snapshot.activeScenes[0].height)
        XCTAssertGreaterThan(snapshot.activeScenes[1].width, snapshot.activeScenes[1].height)
        let bundle = try await MediaAssembler().build(movie: snapshot, root: store.root)
        XCTAssertEqual(bundle.videoComposition.renderSize, MovieFormat.portrait.canvas)
        XCTAssertEqual(bundle.duration.seconds, snapshot.duration.seconds, accuracy: 0.001)
    }
    func testDamagedCatalogIsNeverReplacedWithAnEmptyLibrary() async throws {
        let store = try await makeStore()
        _ = try await store.create(name: "Keep me", format: .landscape)
        let path = store.root.appendingPathComponent("catalog.json")
        let damaged = Data("{broken manifest".utf8)
        try damaged.write(to: path)
        let reopened = ProjectStore(root: store.root)
        do { _ = try await reopened.load(); XCTFail("A damaged manifest must fail closed") } catch {}
        XCTAssertEqual(try Data(contentsOf: path), damaged)
    }
    func testRotatedPortraitFitsLandscapeWithoutCropping() {
        let size = CGSize(width: 1920, height: 1080), canvas = CGSize(width: 1920, height: 1080)
        let rotation = CGAffineTransform(rotationAngle: .pi / 2)
        let transform = MediaAssembler.fitTransform(size: size, preferred: rotation, canvas: canvas)
        let fitted = CGRect(origin: .zero, size: size).applying(transform)
        XCTAssertGreaterThanOrEqual(fitted.minX, -0.001)
        XCTAssertGreaterThanOrEqual(fitted.minY, -0.001)
        XCTAssertLessThanOrEqual(fitted.maxX, canvas.width + 0.001)
        XCTAssertLessThanOrEqual(fitted.maxY, canvas.height + 0.001)
        XCTAssertEqual(fitted.midX, canvas.width / 2, accuracy: 0.01)
        XCTAssertEqual(fitted.midY, canvas.height / 2, accuracy: 0.01)
    }
}



extension PipelineTests {
    func testDisplayLookCompositionPreservesConversionAndNotices() throws {
        let identity = try ColorCube.parse("""
        # Original test notice
        TITLE "Identity"
        LUT_3D_SIZE 2
        0 0 0
        1 0 0
        0 1 0
        1 1 0
        0 0 1
        1 0 1
        0 1 1
        1 1 1
        """, name: "Display Test")
        let standard = try ColorCube.appleStandard.get()
        var display = identity; display.colorContract = .displayLook
        let combined = try display.following(standard)
        XCTAssertEqual(combined.dimension, standard.dimension)
        XCTAssertEqual(combined.minimum, standard.minimum)
        XCTAssertEqual(combined.maximum, standard.maximum)
        XCTAssertTrue(combined.sourceNotices?.contains("Original test notice") == true)
        var maximumError: Float = 0
        combined.rgba.withUnsafeBytes { actual in
            standard.rgba.withUnsafeBytes { expected in
                for index in 0..<(standard.rgba.count / 4) {
                    maximumError = max(maximumError, abs(actual.loadUnaligned(fromByteOffset: index * 4, as: Float.self) -
                        expected.loadUnaligned(fromByteOffset: index * 4, as: Float.self)))
                }
            }
        }
        XCTAssertLessThan(maximumError, 0.000002)
        let roundTrip = try JSONDecoder().decode(ColorCube.self, from: JSONEncoder().encode(combined))
        XCTAssertEqual(roundTrip.sourceNotices, identity.sourceNotices)
    }
}


extension PipelineTests {
    func testDisplayLookCompositionUsesDomainAndRedFastestOrder() throws {
        // Maps [0, 2] RGB to inverted [1, 0] RGB.
        let look = try ColorCube.parse("""
        LUT_3D_SIZE 2
        DOMAIN_MIN 0 0 0
        DOMAIN_MAX 2 2 2
        1 1 1
        0 1 1
        1 0 1
        0 0 1
        1 1 0
        0 1 0
        1 0 0
        0 0 0
        """, name: "Domain test")
        var points: [Float] = []
        for _ in 0..<8 { points.append(contentsOf: [0.5, 1, 1.5, 1]) }
        let conversion = ColorCube(name: "Test conversion", dimension: 2,
            rgba: points.withUnsafeBytes { Data($0) })
        var display = look; display.colorContract = .displayLook
        let combined = try display.following(conversion)
        combined.rgba.withUnsafeBytes { bytes in
            XCTAssertEqual(bytes.loadUnaligned(fromByteOffset: 0, as: Float.self), 0.75, accuracy: 0.000001)
            XCTAssertEqual(bytes.loadUnaligned(fromByteOffset: 4, as: Float.self), 0.50, accuracy: 0.000001)
            XCTAssertEqual(bytes.loadUnaligned(fromByteOffset: 8, as: Float.self), 0.25, accuracy: 0.000001)
        }
    }
}


extension PipelineTests {
    func testRemovedMorningLooksMigrateToCinemaWithoutChangingMovieIdentity() async throws {
        for retired in [LUTReference.amber, .heritage, .ember] {
            let store = try await makeStore()
            var movie = try await store.create(name: "Keep movie", format: .landscape, profile: .appleLog)
            movie.look = retired
            let originalRevision = movie.revision
            let catalog = Catalog(movies: [movie])
            try JSONEncoder().encode(catalog).write(to: store.root.appendingPathComponent("catalog.json"), options: .atomic)
            let reopened = ProjectStore(root: store.root)
            _ = try await reopened.load()
            let movies = await reopened.snapshot()
            let migrated = try XCTUnwrap(movies.first)
            XCTAssertEqual(migrated.id, movie.id)
            XCTAssertEqual(migrated.name, movie.name)
            XCTAssertEqual(migrated.look, .filmica)
            XCTAssertEqual(migrated.revision, originalRevision + 1)
            let available = await reopened.availableLooks()
            XCTAssertEqual(available.map(\.id), [LUTReference.filmica.id])
            XCTAssertEqual(try ColorCube.load(retired, root: reopened.root).rgba, try ColorCube.filmica.get().rgba)
        }
    }
}
