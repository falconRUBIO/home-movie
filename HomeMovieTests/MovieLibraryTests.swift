import XCTest
@testable import HomeMovie

final class MovieLibraryTests: XCTestCase {
    func testCustomOrderSurvivesReopenAndRejectsStaleOrDuplicateLists() async throws {
        let store = try await makeStore()
        let a = try await store.createQuickMovie(), b = try await store.createQuickMovie(), c = try await store.createQuickMovie()
        let ids = Set([a.id, b.id, c.id])
        try await store.reorderMovies([b.id, a.id, c.id], expected: ids)
        let reopened = ProjectStore(root: store.root); _ = try await reopened.load()
        let saved = await reopened.snapshot()
        XCTAssertEqual(MovieLibrarySort.custom.sorted(saved).map(\.id), [b.id, a.id, c.id])
        do { try await reopened.reorderMovies([a.id, a.id, c.id], expected: ids); XCTFail("Duplicate order accepted") } catch { }
        let new = try await reopened.createQuickMovie()
        do { try await reopened.reorderMovies([a.id, b.id, c.id], expected: ids); XCTFail("Stale order accepted") } catch { }
        let after = await reopened.snapshot()
        XCTAssertEqual(MovieLibrarySort.custom.sorted(after).map(\.id), [new.id, b.id, a.id, c.id])
    }

    func testBulkDeleteIsAtomicRecoverableAndPreservesOrder() async throws {
        let store = try await makeStore()
        let a = try await store.createQuickMovie(), b = try await store.createQuickMovie()
        try await store.reorderMovies([b.id, a.id], expected: Set([a.id, b.id]))
        do { try await store.setMoviesDeleted(Set([a.id, UUID()])); XCTFail("Partial selection accepted") } catch { }
        let unchanged = await store.snapshot()
        XCTAssertTrue(unchanged.allSatisfy { $0.deletedAt == nil })
        try await store.setMoviesDeleted(Set([a.id, b.id]))
        let reopened = ProjectStore(root: store.root); _ = try await reopened.load()
        let deleted = await reopened.snapshot()
        XCTAssertTrue(deleted.allSatisfy { $0.deletedAt != nil })
        XCTAssertEqual(deleted[0].deletedAt, deleted[1].deletedAt)
        try await reopened.setMovieDeleted(a.id, deleted: false)
        try await reopened.setMovieDeleted(b.id, deleted: false)
        let restored = await reopened.snapshot()
        XCTAssertEqual(MovieLibrarySort.custom.sorted(restored).map(\.id), [b.id, a.id])
    }

    func testLegacyDecodeAndCoverFallbackDoNotAlterSceneOrder() throws {
        var movie = Movie(name: "Cover", format: .portrait)
        let a = scene(sequence: 0), b = scene(sequence: 1)
        movie.scenes = [a, b]; movie.coverSceneID = b.id
        let decoded = try JSONDecoder().decode(Movie.self, from: JSONEncoder().encode(movie))
        XCTAssertEqual(decoded.coverScene?.id, b.id)
        XCTAssertEqual(decoded.activeScenes.map(\.id), [a.id, b.id])
        movie.scenes[1].deletedAt = Date()
        XCTAssertEqual(movie.coverScene?.id, a.id)
        movie.scenes[1].deletedAt = nil; movie.scenes[1].missing = true
        XCTAssertEqual(movie.coverScene?.id, a.id)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(movie)) as? [String: Any])
        json.removeValue(forKey: "coverSceneID"); json.removeValue(forKey: "libraryOrder")
        let legacy = try JSONDecoder().decode(Movie.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(legacy.coverSceneID); XCTAssertNil(legacy.libraryOrder)
        XCTAssertEqual(legacy.coverScene?.id, a.id)
    }

    func testSortDirectionAndTiesAreDeterministic() {
        var a = Movie(name: "A", format: .portrait), b = Movie(name: "B", format: .portrait)
        a.createdAt = Date(timeIntervalSince1970: 100); b.createdAt = Date(timeIntervalSince1970: 200)
        XCTAssertEqual(MovieLibrarySort.newest.sorted([a, b]).map(\.id), [b.id, a.id])
        XCTAssertEqual(MovieLibrarySort.oldest.sorted([a, b]).map(\.id), [a.id, b.id])
        a.lastRecordedAt = b.createdAt
        XCTAssertEqual(MovieLibrarySort.newest.sorted([a, b]), MovieLibrarySort.newest.sorted([b, a]))
    }

    private func scene(sequence: Int) -> Scene {
        let id = UUID()
        return Scene(id: id, sequence: sequence, source: "Originals/\(id.uuidString).mov", capturedAt: Date(), timeZone: "UTC",
            sourceDuration: MediaTime(seconds: 2), trimStart: MediaTime(seconds: 0), trimEnd: MediaTime(seconds: 2),
            width: 320, height: 240, hasAudio: false, bytes: 0)
    }
    private func makeStore() async throws -> ProjectStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ProjectStore(root: root); _ = try await store.load()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return store
    }
}
