import XCTest
import AVFoundation
import CoreImage
import MetalKit
@testable import HomeMovie

final class PipelineTests: XCTestCase {
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
    private func makeStore() async throws -> ProjectStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ProjectStore(root: root); _ = try await store.load()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return store
    }
    private func footage(_ url: URL, rotated: Bool = false) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 240])
        if rotated { input.transform = CGAffineTransform(rotationAngle: .pi / 2) }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 240])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? HomeMovieError.message("Fixture writer failed") }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<60 {
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed { throw writer.error ?? HomeMovieError.message("Fixture writer failed") }
                await Task.yield()
            }
            var buffer: CVPixelBuffer?
            let result = CVPixelBufferCreate(kCFAllocatorDefault, 320, 240, kCVPixelFormatType_32BGRA, nil, &buffer)
            guard result == kCVReturnSuccess, let buffer else { throw HomeMovieError.message("Fixture buffer failed") }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) { memset(base, frame % 2 == 0 ? 60 : 120, CVPixelBufferGetBytesPerRow(buffer) * 240) }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else { throw writer.error ?? HomeMovieError.message("Fixture append failed") }
        }
        writer.endSession(atSourceTime: CMTime(value: 60, timescale: 30)); input.markAsFinished()
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
