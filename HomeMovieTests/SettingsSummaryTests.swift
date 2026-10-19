import XCTest
@testable import HomeMovie

final class SettingsSummaryTests: XCTestCase {
    func testStorageCategoriesAndBackupStatusNeverDoubleCountDeletedScenes() {
        var a = Movie(name: "Active", format: .portrait), b = Movie(name: "Deleted", format: .portrait)
        var active = scene(bytes: 100), deleted = scene(bytes: 200), missing = scene(bytes: 400)
        active.photosAssetID = "saved"; deleted.deletedAt = Date(); missing.missing = true
        a.scenes = [active, deleted, missing, scene(bytes: 50)]
        a.revision = 5; a.lastFilesBackupRevision = 4; a.lastFilesBackupAt = Date(timeIntervalSince1970: 10)
        var alreadyDeleted = scene(bytes: 300); alreadyDeleted.deletedAt = Date()
        b.deletedAt = Date(); b.scenes = [alreadyDeleted, scene(bytes: 600)]
        b.lastFilesBackupAt = Date(timeIntervalSince1970: 20)
        let value = SettingsSummary(movies: [a, b])
        XCTAssertEqual(value.activeBytes, 150)
        XCTAssertEqual(value.deletedBytes, 1100)
        XCTAssertEqual(value.pendingPhotosCopies, 1)
        XCTAssertEqual(value.moviesNeedingBackup, 1)
        XCTAssertEqual(value.latestFilesBackup, b.lastFilesBackupAt)
        a.lastFilesBackupRevision = a.revision
        XCTAssertEqual(SettingsSummary(movies: [a]).moviesNeedingBackup, 0)
        XCTAssertNil(SettingsSummary(movies: []).latestFilesBackup)
    }
    func testTemporaryExportMeasurementIgnoresSymlinksDirectoriesAndOtherFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(SettingsStorage.exportBytes(in: root), 0)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let video = root.appendingPathComponent("movie.mp4")
        try Data(repeating: 1, count: 1024).write(to: video)
        try Data(repeating: 1, count: 2048).write(to: root.appendingPathComponent("note.txt"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("alias.mp4"), withDestinationURL: video)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("folder.mp4"), withIntermediateDirectories: true)
        XCTAssertEqual(SettingsStorage.exportBytes(in: root), 1024)
        XCTAssertNil(SettingsStorage.exportBytes(in: video), "A file in place of the directory must not report zero usage")
    }
    private func scene(bytes: Int64) -> Scene {
        let id = UUID()
        return Scene(id: id, sequence: 0, source: "Originals/\(id.uuidString).mov", capturedAt: Date(), timeZone: "UTC",
            sourceDuration: MediaTime(seconds: 1), trimStart: MediaTime(seconds: 0), trimEnd: MediaTime(seconds: 1),
            width: 320, height: 240, hasAudio: false, bytes: bytes)
    }
}
