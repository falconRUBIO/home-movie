import Foundation
import CryptoKit
import AVFoundation

struct RecoveryFile: Identifiable, Sendable {
    let id: String
    let url: URL
    let bytes: Int64
    var title: String { url.pathExtension == "mov" ? (id.hasPrefix("Staging/") ? "Interrupted recording" : "Unassigned recording") : "Preserved library data" }
}
struct BackupEntry: Codable, Sendable {
    let bytes: Int64
    let sha256: String
}
struct ProjectBackup: Codable, Sendable {
    var format = "HomeMovieBackup"
    var version = 1
    var createdAt = Date()
    var catalog: Catalog
    var files: [String: BackupEntry]
}
struct PreparedBackup: Sendable {
    let url: URL
    let snapshot: Catalog
}

actor BackupService {
    // Bounded byte streaming; no whole video or decoded frames are loaded into memory.
    nonisolated private func streamCopy(_ source: URL, to destination: URL, expectedBytes: Int64,
                            onBytes: (Int64) -> Void) throws -> BackupEntry {
        let attributes = try source.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
        guard attributes.isSymbolicLink != true, attributes.isRegularFile == true,
              Int64(attributes.fileSize ?? -1) == expectedBytes else { throw HomeMovieError.message("A backup source changed or is not a regular file.") }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else { throw HomeMovieError.message("Could not create a backup file.") }
        let input = try FileHandle(forReadingFrom: source), output = try FileHandle(forWritingTo: destination)
        defer { try? input.close(); try? output.close() }
        var hasher = SHA256(), total: Int64 = 0
        var lastUpdate = Date.distantPast
        while let data = try input.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            try output.write(contentsOf: data); hasher.update(data: data)
            total += Int64(data.count)
            if Date().timeIntervalSince(lastUpdate) >= 0.1 || total == expectedBytes { onBytes(total); lastUpdate = Date() }
            guard total <= expectedBytes else { throw HomeMovieError.message("A video changed while it was being copied.") }
        }
        try output.synchronize()
        guard total == expectedBytes else { throw HomeMovieError.message("A backup file was incomplete.") }
        return BackupEntry(bytes: total, sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }
    nonisolated private func packageRoot(_ url: URL) throws {
        let info = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard info.isDirectory == true, info.isSymbolicLink != true else { throw HomeMovieError.message("Choose a Home Movie backup document.") }
        let originals = try url.appendingPathComponent("Originals").resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard originals.isDirectory == true, originals.isSymbolicLink != true else { throw HomeMovieError.message("The backup's Originals folder is invalid.") }
    }
    nonisolated private func manifest(_ package: URL) throws -> ProjectBackup {
        try packageRoot(package)
        let file = package.appendingPathComponent("manifest.json")
        let info = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true, let size = info.fileSize,
              size > 0, size <= 10_000_000 else { throw HomeMovieError.message("The backup manifest is invalid or too large.") }
        let value = try JSONDecoder().decode(ProjectBackup.self, from: Data(contentsOf: file))
        guard value.format == "HomeMovieBackup", value.version == 1 else { throw HomeMovieError.message("This backup format is not supported.") }
        let scenes = value.catalog.movies.flatMap(\.scenes)
        let lookPaths = Set(value.catalog.movies.compactMap { $0.look?.path })
        if !lookPaths.isEmpty {
            let looks = try package.appendingPathComponent("Looks").resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard looks.isDirectory == true, looks.isSymbolicLink != true else { throw HomeMovieError.message("The backup’s Looks folder is invalid.") }
        }
        guard Set(scenes.map(\.source)).union(lookPaths) == Set(value.files.keys), value.files.values.allSatisfy({ $0.bytes >= 0 && $0.bytes < Int64.max / 4 && $0.sha256.count == 64 }) else {
            throw HomeMovieError.message("The backup file list does not match its scenes.")
        }
        return value
    }
    func create(store: ProjectStore, progress: @Sendable (Double) -> Void) async throws -> PreparedBackup {
        try await store.beginMaintenance()
        let snapshot = await store.catalogSnapshot()
        let scenes = snapshot.movies.flatMap(\.scenes)
        guard !scenes.isEmpty else { await store.endMaintenance(); throw HomeMovieError.message("Record a scene before making a project backup.") }
        let folder = store.root.appendingPathComponent("OutgoingBackups", isDirectory: true)
        let package = folder.appendingPathComponent("Home Movie-\(UUID()).homemovie", isDirectory: true)
        do {
            try await store.validateBackupCatalog(snapshot)
            let references = Dictionary(snapshot.movies.compactMap { $0.look }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var lookSizes: [String: Int64] = [:]
            for look in references.values {
                if look.isRetiredBundledLook {
                    restoredLooks[look.id] = .filmica
                    continue
                }
                _ = try ColorCube.load(look, root: store.root)
                lookSizes[look.path] = Int64(try store.root.appendingPathComponent(look.path).resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            }
            let total = scenes.reduce(0.0) { $0 + Double($1.bytes) } + lookSizes.values.reduce(0.0) { $0 + Double($1) }
            guard total < Double(Int64.max / 4) else { throw HomeMovieError.message("This backup is too large.") }
            try await store.requireSpace(bytes: Int64(total) + 300_000_000)
            try FileManager.default.createDirectory(at: package.appendingPathComponent("Originals"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: package.appendingPathComponent("Looks"), withIntermediateDirectories: true)
            var entries: [String: BackupEntry] = [:], completed: Int64 = 0
            for scene in scenes {
                try Task.checkCancellation()
                let source = store.root.appendingPathComponent(scene.source)
                let before = completed
                let entry = try streamCopy(source, to: package.appendingPathComponent(scene.source), expectedBytes: scene.bytes) { copied in
                    progress(min(0.99, Double(before + copied) / max(1, total)))
                }
                entries[scene.source] = entry; completed += entry.bytes
            }
            for (path, bytes) in lookSizes {
                try Task.checkCancellation()
                let before = completed
                let entry = try streamCopy(store.root.appendingPathComponent(path), to: package.appendingPathComponent(path), expectedBytes: bytes) { count in
                    progress(min(0.99, Double(before + count) / max(1, total)))
                }
                entries[path] = entry; completed += entry.bytes
            }
            try Task.checkCancellation()
            let backup = ProjectBackup(catalog: snapshot, files: entries)
            let manifestData = try JSONEncoder().encode(backup)
            guard manifestData.count <= 10_000_000 else { throw HomeMovieError.message("This project is too large for a single backup manifest.") }
            try manifestData.write(to: package.appendingPathComponent("manifest.json"), options: .atomic)
            progress(1); await store.endMaintenance()
            return PreparedBackup(url: package, snapshot: snapshot)
        } catch {
            try? FileManager.default.removeItem(at: package); await store.endMaintenance(); throw error
        }
    }
    func restore(from source: URL, store: ProjectStore, progress: @Sendable (Double) -> Void) async throws {
        try await store.beginMaintenance(requireLoaded: false)
        let staging = store.root.appendingPathComponent("RestoreStaging/\(UUID())", isDirectory: true)
        var installed: [URL] = []
        var committed = false
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        do {
            // Coordinate the file-provider read so iCloud Drive can materialize the package.
            var incoming: ProjectBackup?
            var readError: Error?
            var coordinationError: NSError?
            let coordinator = NSFileCoordinator()
            coordinator.coordinate(readingItemAt: source, options: [], error: &coordinationError) { readable in
                do { incoming = try self.manifest(readable) } catch { readError = error }
            }
            if let coordinationError { throw coordinationError }
            if let readError { throw readError }
            guard let backup = incoming else { throw HomeMovieError.message("The backup could not be read.") }
            try await store.validateBackupCatalog(backup.catalog)
            let total = backup.files.values.reduce(0.0) { $0 + Double($1.bytes) }
            guard total < Double(Int64.max / 4) else { throw HomeMovieError.message("This backup is too large.") }
            try await store.requireSpace(bytes: Int64(total) + 300_000_000)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            var restored = backup.catalog.movies
            var completed: Int64 = 0
            let references = Dictionary(restored.compactMap { $0.look }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var restoredLooks: [UUID: LUTReference] = [:]
            for look in references.values {
                try Task.checkCancellation()
                guard let expected = backup.files[look.path], expected.bytes > 0, expected.bytes <= 8_000_000 else {
                    throw HomeMovieError.message("The backup’s look data is invalid.")
                }
                let newLook = LUTReference(id: UUID(), name: look.displayName)
                let copied = staging.appendingPathComponent("\(newLook.id).json")
                var entry: BackupEntry?; readError = nil; coordinationError = nil
                coordinator.coordinate(readingItemAt: source.appendingPathComponent(look.path), options: [], error: &coordinationError) { readable in
                    do { entry = try self.streamCopy(readable, to: copied, expectedBytes: expected.bytes) { _ in } }
                    catch { readError = error }
                }
                if let coordinationError { throw coordinationError }
                if let readError { throw readError }
                guard entry?.sha256 == expected.sha256 else { throw HomeMovieError.message("Backup look verification failed.") }
                let cube = try JSONDecoder().decode(ColorCube.self, from: Data(contentsOf: copied)); try cube.validate()
                if look.id == LUTReference.filmica.id, cube.name != newLook.name {
                    // Rename only the verified built-in copy; preserve every color sample and the source backup.
                    let renamed = ColorCube(name: newLook.name, dimension: cube.dimension, rgba: cube.rgba,
                        minimum: cube.minimum, maximum: cube.maximum)
                    try JSONEncoder().encode(renamed).write(to: copied, options: .atomic)
                }
                restoredLooks[look.id] = newLook; completed += expected.bytes
            }
            for m in restored.indices {
                if let look = restored[m].look { restored[m].look = restoredLooks[look.id] }
                restored[m].id = UUID(); restored[m].name += " (Restored)"
                restored[m].lastFilesBackupRevision = nil; restored[m].lastFilesBackupAt = nil
                for c in restored[m].scenes.indices {
                    try Task.checkCancellation()
                    let old = restored[m].scenes[c]
                    guard let expected = backup.files[old.source], old.bytes == expected.bytes else { throw HomeMovieError.message("Backup scene sizes disagree.") }
                    let newID = UUID(), copied = staging.appendingPathComponent("\(newID).mov")
                    let before = completed
                    var entry: BackupEntry?
                    readError = nil; coordinationError = nil
                    coordinator.coordinate(readingItemAt: source.appendingPathComponent(old.source), options: [], error: &coordinationError) { readable in
                        do { entry = try self.streamCopy(readable, to: copied, expectedBytes: expected.bytes) { count in
                            progress(min(0.95, Double(before + count) / max(1, total) * 0.95))
                        }} catch { readError = error }
                    }
                    if let coordinationError { throw coordinationError }
                    if let readError { throw readError }
                    guard entry?.sha256 == expected.sha256 else { throw HomeMovieError.message("Backup verification failed. Existing movies have not been changed.") }
                    let media = try await MediaInspector.inspect(copied)
                    guard abs(media.duration.seconds - old.sourceDuration.seconds) < 0.1,
                          abs(media.size.width - old.width) < 1, abs(media.size.height - old.height) < 1 else {
                        throw HomeMovieError.message("A backup video's duration or dimensions do not match its metadata.")
                    }
                    if let declared = old.profile, declared != (media.profile ?? .standard) {
                        throw HomeMovieError.message("A backup recording’s color format does not match its scene metadata. Existing movies have not been changed.")
                    }
                    restored[m].scenes[c].id = newID; restored[m].scenes[c].source = "Originals/\(newID).mov"
                    restored[m].scenes[c].missing = false
                    restored[m].scenes[c].photosAssetID = nil; restored[m].scenes[c].photosCopiedAt = nil
                    completed += expected.bytes
                }
            }
            try await store.validateBackupCatalog(Catalog(movies: restored))
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: store.root.appendingPathComponent("Looks"), withIntermediateDirectories: true)
            for look in restoredLooks.values {
                try Task.checkCancellation()
                let staged = staging.appendingPathComponent("\(look.id).json"), target = store.root.appendingPathComponent(look.path)
                try FileManager.default.moveItem(at: staged, to: target); installed.append(target)
            }
            for scene in restored.flatMap(\.scenes) {
                try Task.checkCancellation()
                let staged = staging.appendingPathComponent("\(scene.id).mov"), target = store.root.appendingPathComponent(scene.source)
                try FileManager.default.moveItem(at: staged, to: target); installed.append(target)
            }
            try Task.checkCancellation()
            try await store.installImportedMovies(restored); committed = true
            try? FileManager.default.removeItem(at: staging)
            await store.endMaintenance()
            _ = try await store.load(); progress(1)
        } catch {
            // Never remove footage after the catalog has accepted it.
            if !committed { installed.forEach { try? FileManager.default.removeItem(at: $0) } }
            try? FileManager.default.removeItem(at: staging); await store.endMaintenance(); throw error
        }
    }
    func discard(_ url: URL) throws { try FileManager.default.removeItem(at: url) }

}
