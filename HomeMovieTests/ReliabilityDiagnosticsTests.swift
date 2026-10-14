import XCTest
@testable import HomeMovie

final class ReliabilityDiagnosticsTests: XCTestCase {
    func testBoundedEventsSurviveReopeningWithoutPrivateErrorDetails() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("events.json")
        let log = ReliabilityDiagnostics(file: file, limit: 3)
        log.record(.cameraRequested)
        log.record(.cameraReady)
        log.record(.recordingStarted)
        log.record(.recordingFailed, error: NSError(domain: "private/movie/path", code: 42,
            userInfo: [NSLocalizedDescriptionKey: "Private movie title and recording path"]))
        let report = await log.report()
        XCTAssertFalse(report.contains("cameraRequested"))
        XCTAssertTrue(report.contains("cameraReady"))
        XCTAssertTrue(report.contains("OtherError:42"))
        XCTAssertFalse(report.contains("private/movie/path"))
        XCTAssertFalse(report.contains("Private movie title"))
        let reopened = ReliabilityDiagnostics(file: file, limit: 3)
        let restored = await reopened.report()
        XCTAssertEqual(report, restored)
        await reopened.clear()
        let cleared = await ReliabilityDiagnostics(file: file).report()
        XCTAssertFalse(cleared.contains("recordingStarted"))
        XCTAssertFalse(cleared.contains("OtherError:42"))
    }
    func testStorageFailureDoesNotPreventInMemoryDiagnostics() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = ReliabilityDiagnostics(file: directory)
        log.record(.exportFailed, error: NSError(domain: NSCocoaErrorDomain, code: 640))
        let report = await log.report()
        XCTAssertTrue(report.contains("exportFailed"))
        XCTAssertTrue(report.contains("NSCocoaErrorDomain:640"))
    }
}
