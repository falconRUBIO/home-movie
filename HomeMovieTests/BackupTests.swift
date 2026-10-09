import XCTest
import AVFoundation
@testable import HomeMovie

final class BackupTests: XCTestCase {
    private func sourceMovie() async throws -> (ProjectStore, Movie) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(root: root); _ = try await store.load()
        let movie = try await store.create(name: "Family", format: .landscape)
        let ticket = try await store.begin(movieID: movie.id)
        let file = try await store.url(ticket.staging)
        let writer = try AVAssetWriter(outputURL: file, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 240])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 240])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? HomeMovieError.message("Fixture failed") }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<30 {
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed { throw writer.error ?? HomeMovieError.message("Fixture failed") }; await Task.yield()
            }
            var pixel: CVPixelBuffer?
            guard CVPixelBufferCreate(kCFAllocatorDefault, 320, 240, kCVPixelFormatType_32BGRA, nil, &pixel) == kCVReturnSuccess, let pixel else { throw HomeMovieError.message("Fixture failed") }
            CVPixelBufferLockBaseAddress(pixel, [])
            if let base = CVPixelBufferGetBaseAddress(pixel) { memset(base, 80, CVPixelBufferGetBytesPerRow(pixel) * 240) }
            CVPixelBufferUnlockBaseAddress(pixel, [])
            guard adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else { throw writer.error ?? HomeMovieError.message("Fixture failed") }
        }
        writer.endSession(atSourceTime: CMTime(value: 30, timescale: 30)); input.markAsFinished(); await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? HomeMovieError.message("Fixture failed") }
        try await store.commit(ticket)
        let scene = await store.snapshot().first!.scenes.first!
        try await store.trim(movieID: movie.id, sceneID: scene.id, start: CMTime(value: 5, timescale: 30), end: CMTime(value: 25, timescale: 30))
        return (store, movie)
    }
    func testRoundTripPreservesBytesTrimsAndExistingMovies() async throws {
        let (store, _) = try await sourceMovie(), service = BackupService()
        let before = await store.snapshot().first!
        let prepared = try await service.create(store: store, progress: { _ in })
        try await service.restore(from: prepared.url, store: store, progress: { _ in })
        let after = await store.snapshot()
        XCTAssertEqual(after.count, 2)
        let imported = try XCTUnwrap(after.first { $0.id != before.id })
        XCTAssertEqual(imported.scenes[0].trimStart, before.scenes[0].trimStart)
        XCTAssertEqual(imported.scenes[0].trimEnd, before.scenes[0].trimEnd)
        XCTAssertNotEqual(imported.scenes[0].id, before.scenes[0].id)
        let original = store.root.appendingPathComponent(before.scenes[0].source)
        let restored = store.root.appendingPathComponent(imported.scenes[0].source)
        XCTAssertEqual(try Data(contentsOf: original), try Data(contentsOf: restored))
    }
    func testTamperedBackupIsRejectedWithoutChangingLibrary() async throws {
        let (store, _) = try await sourceMovie(), service = BackupService()
        let prepared = try await service.create(store: store, progress: { _ in })
        let before = await store.snapshot(), scene = before.first!.scenes.first!
        let file = prepared.url.appendingPathComponent(scene.source)
        var bytes = try Data(contentsOf: file); bytes[bytes.count / 2] ^= 0xff; try bytes.write(to: file)
        do { try await service.restore(from: prepared.url, store: store, progress: { _ in }); XCTFail("Tampered video must fail verification") } catch {}
        let after = await store.snapshot()
        XCTAssertEqual(before, after)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.root.appendingPathComponent(scene.source).path))
    }
    func testMaintenanceBlocksEditsAndCancellationReleasesIt() async throws {
        let (store, movie) = try await sourceMovie()
        try await store.beginMaintenance()
        do { try await store.rename(movie.id, name: "Blocked"); XCTFail("An edit must not change a backup snapshot") } catch {}
        await store.endMaintenance()
        try await store.rename(movie.id, name: "Allowed")
        let service = BackupService()
        let job = Task { try await service.create(store: store, progress: { _ in }) }
        job.cancel()
        _ = try? await job.value
        try await store.rename(movie.id, name: "Still allowed")
    }
    func testPreviousCatalogRecoveryPreservesDamagedFile() async throws {
        let (store, _) = try await sourceMovie()
        let original = store.root.appendingPathComponent("catalog.json")
        let damaged = Data("not json".utf8); try damaged.write(to: original)
        let reopened = ProjectStore(root: store.root)
        do { _ = try await reopened.load(); XCTFail("Damaged catalog must fail") } catch {}
        _ = try await reopened.repairFromPreviousCatalog()
        let snapshot = await reopened.snapshot()
        XCTAssertFalse(snapshot.isEmpty)
        let files = try await reopened.recoveryFiles()
        let preserved = try XCTUnwrap(files.first { $0.url.pathExtension == "json" })
        XCTAssertEqual(try Data(contentsOf: preserved.url), damaged)
    }
    func testLegacyMetadataWithoutSafetyFieldsStillDecodes() async throws {
        let (store, _) = try await sourceMovie()
        let file = store.root.appendingPathComponent("catalog.json")
        var value = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        var movies = value["movies"] as! [[String: Any]]
        for m in movies.indices {
            movies[m].removeValue(forKey: "lastFilesBackupAt"); movies[m].removeValue(forKey: "lastFilesBackupRevision")
            var scenes = movies[m]["scenes"] as! [[String: Any]]
            for c in scenes.indices { scenes[c].removeValue(forKey: "photosAssetID"); scenes[c].removeValue(forKey: "photosCopiedAt") }
            movies[m]["scenes"] = scenes
        }
        value["movies"] = movies
        let decoded = try JSONDecoder().decode(Catalog.self, from: JSONSerialization.data(withJSONObject: value))
        XCTAssertNil(decoded.movies[0].scenes[0].photosAssetID)
        XCTAssertNil(decoded.movies[0].lastFilesBackupRevision)
    }
}
