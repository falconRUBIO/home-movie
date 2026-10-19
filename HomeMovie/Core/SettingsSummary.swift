import Foundation

struct SettingsSummary {
    let activeBytes: Int64
    let deletedBytes: Int64
    let pendingPhotosCopies: Int
    let latestFilesBackup: Date?
    let moviesNeedingBackup: Int

    init(movies: [Movie]) {
        let active = movies.filter { $0.deletedAt == nil }
        activeBytes = active.flatMap(\.activeScenes).filter { !$0.missing }.reduce(0) { $0 + $1.bytes }
        deletedBytes = movies.reduce(0) { total, movie in
            total + movie.scenes.filter { !$0.missing && (movie.deletedAt != nil || $0.deletedAt != nil) }.reduce(0) { $0 + $1.bytes }
        }
        pendingPhotosCopies = active.flatMap(\.activeScenes).filter { !$0.missing && $0.photosAssetID == nil }.count
        latestFilesBackup = movies.compactMap(\.lastFilesBackupAt).max()
        moviesNeedingBackup = active.filter { $0.lastFilesBackupRevision != $0.revision }.count
    }
}

struct SettingsStorage: Sendable {
    let temporaryExportBytes: Int64?
    let pendingCleanupBytes: Int64?
    let availableBytes: Int64?

    // Measures only regular, app-owned files. An unreadable directory is unknown,
    // not zero. Never follow a symbolic link while reporting cache storage.
    static func exportBytes(in directory: URL) -> Int64? {
        do {
            let directoryValues = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard directoryValues.isDirectory == true, directoryValues.isSymbolicLink != true else { return nil }
            let files = try FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey], options: [.skipsHiddenFiles])
            var total: Int64 = 0
            for file in files where file.pathExtension.lowercased() == "mp4" {
                do {
                    let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                    if values.isRegularFile == true, values.isSymbolicLink != true {
                        guard let size = values.fileSize else { return nil }
                        total += Int64(size)
                    }
                } catch {
                    let failure = error as NSError
                    // An export may be removed while this snapshot is measured.
                    if failure.domain != NSCocoaErrorDomain || (failure.code != NSFileReadNoSuchFileError && failure.code != NSFileNoSuchFileError) { return nil }
                }
            }
            return total
        } catch {
            let failure = error as NSError
            if failure.domain == NSCocoaErrorDomain && (failure.code == NSFileReadNoSuchFileError || failure.code == NSFileNoSuchFileError) { return 0 }
            return nil
        }
    }
}
