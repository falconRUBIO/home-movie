import XCTest
import AVFoundation
@testable import HomeMovie

final class PipelineTests: XCTestCase {
    func testNativeResolutionZoomChoicesIncludeSupportedEightTimes() {
        let choices = LensChoice.available(minimum: 1, maximum: 20, multiplier: 0.5,
            switchFactors: [2, 8], secondaryFactors: [4, 16, 16])
        XCTAssertEqual(choices.map(\.displayed), [0.5, 1, 2, 4, 8])
        XCTAssertEqual(choices.last?.factor, 16)
    }
    func testZoomChoicesRespectDeviceRangeAndDoNotInventEightTimes() {
        let olderPhone = LensChoice.available(minimum: 1, maximum: 12, multiplier: 0.5,
            switchFactors: [2, 6], secondaryFactors: [])
        XCTAssertEqual(olderPhone.map(\.displayed), [0.5, 1, 3])
        let restricted = LensChoice.available(minimum: 1, maximum: 8, multiplier: 0.5,
            switchFactors: [2, 8], secondaryFactors: [4, 16])
        XCTAssertEqual(restricted.map(\.displayed), [0.5, 1, 2, 4])
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
