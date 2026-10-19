import XCTest
import AVFoundation
@testable import HomeMovie

final class NewMovieTests: XCTestCase {
    private func makeStore() async throws -> ProjectStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(root: root)
        _ = try await store.load()
        return store
    }
    @MainActor func testNewMoviePublishesImmediatelyAfterLogMovieWithoutInheritingItsSettings() async throws {
        let store = try await makeStore()
        let log = try await store.create(name: "Log", format: .portrait, profile: .appleLog)
        let app = AppModel(store: store)
        await app.load()
        let movie = try await app.createQuickMovie()
        XCTAssertEqual(app.movies.first?.id, movie.id)
        XCTAssertEqual(app.movie(log.id)?.captureProfile, .appleLog)
        XCTAssertEqual(movie.captureProfile, .standard)
        XCTAssertNil(movie.look)
        XCTAssertEqual(app.activeMovies.count, 2)
        let reopened = ProjectStore(root: store.root)
        _ = try await reopened.load()
        let saved = await reopened.snapshot()
        XCTAssertEqual(saved.first { $0.id == movie.id }, movie)
    }
    @MainActor func testLookScanDoesNotNeedCatalogActorAndHonorsCancellation() async throws {
        let store = try await makeStore()
        let entered = expectation(description: "Catalog actor held")
        let release = DispatchSemaphore(value: 0)
        let holder = Task.detached { await store.holdCatalogForLookScanTest(entered: entered, release: release) }
        await fulfillment(of: [entered], timeout: 5)
        let scanned = expectation(description: "LUT scan finishes independently of catalog")
        let scan = Task {
            let looks = await store.availableLooks()
            scanned.fulfill()
            return looks
        }
        await fulfillment(of: [scanned], timeout: 15)
        release.signal()
        await holder.value
        let looks = await scan.value
        XCTAssertTrue(looks.contains(.cinema))
        let canceled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await store.availableLooks()
        }
        let canceledLooks = await canceled.value
        XCTAssertTrue(canceledLooks.isEmpty)
    }

}

// Hold only the catalog actor, not the UI or LUT worker. This catches accidental
// reintroduction of look scanning onto the actor used by new-movie creation.
private extension ProjectStore {
    func holdCatalogForLookScanTest(entered: XCTestExpectation, release: DispatchSemaphore) {
        entered.fulfill()
        release.wait()
    }
}
