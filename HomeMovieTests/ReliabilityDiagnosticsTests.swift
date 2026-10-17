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
    func testCaptureGeometryRoundTripsWithoutPathsOrTitles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("events.json")
        let log = ReliabilityDiagnostics(file: file)
        log.record(.recordingRequested, capture: .init(camera: .front, interface: .portrait,
            canvas: .portrait, sensorAngle: 0))
        log.record(.recordingGeometry, capture: .init(canvas: .portrait, savedWidth: 1080, savedHeight: 1920))
        let report = await log.report()
        XCTAssertTrue(report.contains("camera=front interface=portrait canvas=portrait sensor=0.0"))
        XCTAssertTrue(report.contains("saved=1080x1920"))
        let restored = await ReliabilityDiagnostics(file: file).report()
        XCTAssertEqual(restored, report)
    }

    func testAppleReportsAreBoundedPersistedAndCleared() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = ReliabilityDiagnostics(file: directory.appendingPathComponent("events.json"))
        for index in 0..<6 { log.saveSystemReport(Data("{\"sample\":\(index)}".utf8)) }
        log.saveSystemReport(Data("not JSON".utf8))
        log.saveSystemReport(Data(repeating: 32, count: 1_048_577))
        let report = await log.report()
        XCTAssertTrue(report.contains("sample"))
        let files = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("AppleReports"), includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 4)
        let reopened = ReliabilityDiagnostics(file: directory.appendingPathComponent("events.json"))
        let restored = await reopened.report()
        XCTAssertTrue(restored.contains("sample"))
        await reopened.clear()
        let cleared = await reopened.report()
        XCTAssertFalse(cleared.contains("sample"))
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
