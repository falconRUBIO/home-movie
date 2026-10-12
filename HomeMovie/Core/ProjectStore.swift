import Foundation
import AVFoundation

actor ProjectStore {
    // Immutable, Sendable configuration can be read without entering the storage actor.
    nonisolated let root: URL
    private var catalog = Catalog()
    private var loaded = false
    private var maintenance = false
    private var cleanedTransfers = false
    private let fm = FileManager.default
    private var encoder: JSONEncoder { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return e }

    init(root: URL? = nil) {
        self.root = root ?? URL.applicationSupportDirectory.appendingPathComponent("HomeMovie", isDirectory: true)
    }
    func url(_ relative: String) throws -> URL {
        guard !relative.hasPrefix("/"), !relative.split(separator: "/").contains("..") else {
            throw HomeMovieError.message("Invalid project file path.")
        }
        return root.appendingPathComponent(relative)
    }
    private func ensureDirectories() throws {
        for folder in ["", "Staging", "Originals", "Journal", "Recovery", "Looks"] {
            let directory = root.appendingPathComponent(folder)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
        }
    }
    private func validate(_ value: Catalog) throws {
        let scenes = value.movies.flatMap(\.scenes)
        guard Set(value.movies.map(\.id)).count == value.movies.count,
              Set(scenes.map(\.id)).count == scenes.count else { throw HomeMovieError.message("The catalog contains duplicate identifiers. Its file has been preserved.") }
        var totalBytes: Int64 = 0
        for movie in value.movies {
            if let look = movie.look {
                guard movie.captureProfile == .appleLog, !look.name.isEmpty, look.name.count <= 80 else {
                    throw HomeMovieError.message("The movie’s look metadata is invalid.")
                }
            }
            guard !movie.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  movie.revision >= 0 && movie.revision < Int.max,
                  Set(movie.scenes.map(\.sequence)).count == movie.scenes.count else {
                throw HomeMovieError.message("The movie catalog is inconsistent. Its file has been preserved.")
            }
            for scene in movie.scenes {
                guard scene.validTrim, scene.sequence >= 0 && scene.sequence < 1_000_000_000,
                      scene.source == "Originals/\(scene.id.uuidString).mov",
                      scene.width.isFinite && scene.height.isFinite && scene.width > 0 && scene.height > 0 && scene.bytes >= 0 && scene.bytes <= Int64.max / 4 else {
                    throw HomeMovieError.message("A scene has invalid metadata. The catalog has been preserved.")
                }
                let (sum, overflow) = totalBytes.addingReportingOverflow(scene.bytes)
                guard !overflow, sum <= Int64.max / 4 else {
                    throw HomeMovieError.message("The catalog's storage total is invalid. Its file has been preserved.")
                }
                totalBytes = sum
            }
        }
    }
    private func write(_ value: Catalog) throws {
        try validate(value)
        let current = root.appendingPathComponent("catalog.json")
        if loaded {
            try encoder.encode(catalog).write(to: root.appendingPathComponent("catalog.previous.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        try encoder.encode(value).write(to: current, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        catalog = value
    }
    private func index(_ id: UUID) throws -> Int {
        guard let i = catalog.movies.firstIndex(where: { $0.id == id }) else { throw HomeMovieError.message("This movie is no longer available.") }
        return i
    }
    func load() async throws -> [String] {
        guard !loaded else { return [] }
        try ensureDirectories()
        // Install exact supplied samples into durable storage so backups remain self-contained.
        let filmica = try ColorCube.filmica.get()
        let filmicaURL = root.appendingPathComponent(LUTReference.filmica.path)
        if !fm.fileExists(atPath: filmicaURL.path) {
            try encoder.encode(filmica).write(to: filmicaURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        if !cleanedTransfers {
            // These are app-owned temporary copies, never the source recordings.
            for folder in ["RestoreStaging", "OutgoingBackups"] {
                let directory = root.appendingPathComponent(folder)
                if let items = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey]) {
                    for item in items {
                        let complete = fm.fileExists(atPath: item.appendingPathComponent("manifest.json").path)
                        let created = (try? item.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
                        if folder == "RestoreStaging" || !complete || created < Date().addingTimeInterval(-7 * 24 * 60 * 60) {
                            try? fm.removeItem(at: item)
                        }
                    }
                }
            }
            cleanedTransfers = true
        }
        let path = root.appendingPathComponent("catalog.json")
        if fm.fileExists(atPath: path.path) {
            // A damaged or newer manifest must never be overwritten by an empty catalog.
            let decoded = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: path))
            guard decoded.schemaVersion == 1 else { throw HomeMovieError.message("This project uses a newer version of Home Movie.") }
            try validate(decoded)
            catalog = decoded
        } else { try write(catalog) }
        var notices: [String] = []
        let journalFiles = try fm.contentsOfDirectory(at: root.appendingPathComponent("Journal"), includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        var pending: [(URL, CaptureTicket)] = []
        for file in journalFiles {
            do { pending.append((file, try JSONDecoder().decode(CaptureTicket.self, from: Data(contentsOf: file)))) }
            catch { notices.append("A damaged recovery journal was preserved for inspection.") }
        }
        for (file, ticket) in pending.sorted(by: { $0.1.capturedAt == $1.1.capturedAt ? $0.1.sequence < $1.1.sequence : $0.1.capturedAt < $1.1.capturedAt }) {
            do {
                if catalog.movies.flatMap(\.scenes).contains(where: { $0.id == ticket.sceneID }) {
                    try fm.removeItem(at: file); continue
                }
                let source = try url(ticket.source), staging = try url(ticket.staging)
                if fm.fileExists(atPath: source.path) || fm.fileExists(atPath: staging.path) {
                    try await commit(ticket)
                    notices.append("Recovered a recording saved before the app closed.")
                } else { notices.append("An interrupted recording has no recoverable file.") }
            } catch { notices.append("An interrupted recording was preserved for recovery: \(error.localizedDescription)") }
        }
        let known = Set(catalog.movies.flatMap(\.scenes).map(\.source))
        let originals = try fm.contentsOfDirectory(at: root.appendingPathComponent("Originals"), includingPropertiesForKeys: nil)
        let staging = try fm.contentsOfDirectory(at: root.appendingPathComponent("Staging"), includingPropertiesForKeys: nil)
        for file in originals + staging where file.pathExtension.lowercased() == "mov" {
            let relative = "\(file.deletingLastPathComponent().lastPathComponent)/\(file.lastPathComponent)"
            guard !known.contains(relative) else { continue }
            let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent)
            if let id, fm.fileExists(atPath: root.appendingPathComponent("Journal/\(id.uuidString).json").path) { continue }
            do {
                let info = try await MediaInspector.inspect(file)
                let profile = info.profile ?? .standard
                let name = profile == .appleLog ? "Recovered Log Recordings" : "Recovered Recordings"
                var recovered = catalog.movies.first(where: {
                    $0.name == name && $0.deletedAt == nil && $0.captureProfile == profile
                })
                if recovered == nil { recovered = try create(name: name, format: .landscape, profile: profile) }
                let ticket = CaptureTicket(sceneID: id ?? UUID(), movieID: recovered!.id,
                    sequence: recovered!.nextSequence, profile: profile)
                let destination = try url(ticket.staging)
                let durable = try url(ticket.source)
                if file != destination && file != durable { try fm.copyItem(at: file, to: destination) }
                try encoder.encode(ticket).write(to: try url(ticket.journal), options: .atomic)
                try await commit(ticket)
                notices.append("Found additional footage in Recovered Recordings.")
            } catch { notices.append("Unrecognized footage was preserved; it could not be validated.") }
        }
        var updated = catalog
        for m in updated.movies.indices {
            for c in updated.movies[m].scenes.indices {
                let exists = fm.fileExists(atPath: try url(updated.movies[m].scenes[c].source).path)
                updated.movies[m].scenes[c].missing = !exists
            }
        }
        try write(updated)
        // Only disposable exports are eligible for age-based cleanup, never original footage.
        let exports = URL.cachesDirectory.appendingPathComponent("Exports", isDirectory: true)
        if let files = try? fm.contentsOfDirectory(at: exports, includingPropertiesForKeys: [.creationDateKey]) {
            for file in files where file.pathExtension == "mp4" {
                if let created = try? file.resourceValues(forKeys: [.creationDateKey]).creationDate,
                   created < Date().addingTimeInterval(-7 * 24 * 60 * 60) { try? fm.removeItem(at: file) }
            }
        }
        loaded = true
        return Array(Set(notices)).sorted()
    }
    func snapshot() -> [Movie] { catalog.movies.sorted { ($0.lastRecordedAt ?? $0.createdAt) > ($1.lastRecordedAt ?? $1.createdAt) } }
    @discardableResult func create(name: String, format: MovieFormat, profile: CaptureProfile = .standard, look: LUTReference? = nil, useDefaultLook: Bool = true) throws -> Movie {
        try requireIdle()
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 80 else { throw HomeMovieError.message("Give your movie a name of up to 80 characters.") }
        let look = look ?? (profile == .appleLog && useDefaultLook ? .filmica : nil)
        if let look {
            guard profile == .appleLog else { throw HomeMovieError.message("Choose Apple Log to use this look.") }
            _ = try ColorCube.load(look, root: root)
        }
        var movie = Movie(name: clean, format: format)
        movie.profile = profile == .standard ? nil : profile
        movie.look = look
        var next = catalog; next.movies.append(movie); try write(next); return movie
    }
    func availableLooks() -> [LUTReference] {
        let directory = root.appendingPathComponent("Looks")
        let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { file in
            guard file.pathExtension == "json", let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent) else { return nil }
            let reference = LUTReference(id: id, name: "Look")
            guard let cube = try? ColorCube.load(reference, root: root) else { return nil }
            return LUTReference(id: id, name: id == LUTReference.filmica.id ? LUTReference.filmica.name : cube.name)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    func importLook(from source: URL) throws -> LUTReference {
        try requireIdle()
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        var imported: ColorCube?, readError: Error?, coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { readable in
            do {
                let info = try readable.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
                guard info.isRegularFile == true, info.isSymbolicLink != true, let size = info.fileSize,
                      size > 0, size <= 32_000_000 else { throw HomeMovieError.message("Choose a cube file smaller than 32 MB.") }
                imported = try ColorCube.parse(String(contentsOf: readable, encoding: .utf8), name: source.deletingPathExtension().lastPathComponent)
            } catch { readError = error }
        }
        if let coordinationError { throw coordinationError }
        if let readError { throw readError }
        guard let imported else { throw HomeMovieError.message("This look could not be opened.") }
        let reference = LUTReference(id: UUID(), name: imported.name)
        try requireSpace(bytes: 20_000_000)
        try encoder.encode(imported).write(to: url(reference.path), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return reference
    }
    func setLook(movieID: UUID, look: LUTReference?) throws {
        try requireIdle()
        let i = try index(movieID)
        guard catalog.movies[i].captureProfile == .appleLog else { throw HomeMovieError.message("Looks are available for Apple Log movies.") }
        if let look { _ = try ColorCube.load(look, root: root) }
        guard catalog.movies[i].look != look else { return }
        var next = catalog; next.movies[i].look = look; next.movies[i].revision += 1; try write(next)
    }
    func rename(_ id: UUID, name: String) throws {
        try requireIdle()
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 80 else { throw HomeMovieError.message("Enter a name of up to 80 characters.") }
        let i = try index(id); var next = catalog; next.movies[i].name = clean; next.movies[i].revision += 1; try write(next)
    }
    func begin(movieID: UUID, format: MovieFormat? = nil, profile: CaptureProfile? = nil) throws -> CaptureTicket {
        try requireIdle()
        let i = try index(movieID)
        guard catalog.movies[i].deletedAt == nil else { throw HomeMovieError.message("Restore this movie before recording.") }
        if let profile, profile != catalog.movies[i].captureProfile { throw HomeMovieError.message("The camera’s recording profile does not match this movie.") }
        if let format, let locked = catalog.movies[i].recordingFormat, format != locked {
            throw HomeMovieError.message("This scene must use the movie’s saved format.")
        }
        try requireSpace(bytes: catalog.movies[i].captureProfile == .appleLog ? 1_000_000_000 : 300_000_000)
        let ticket = CaptureTicket(movieID: movieID, sequence: catalog.movies[i].nextSequence, format: format, profile: profile)
        try encoder.encode(ticket).write(to: try url(ticket.journal), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return ticket
    }
    // Only the caller that has NOT handed the ticket to AVFoundation may use this.
    // Even then, never remove a journal if any recording bytes exist.
    func abandonUnstarted(_ ticket: CaptureTicket) throws {
        guard !catalog.movies.flatMap(\.scenes).contains(where: { $0.id == ticket.sceneID }),
              !fm.fileExists(atPath: try url(ticket.staging).path),
              !fm.fileExists(atPath: try url(ticket.source).path) else {
            throw HomeMovieError.message("Recording data exists and has been preserved for recovery.")
        }
        let journal = try url(ticket.journal)
        if fm.fileExists(atPath: journal.path) { try fm.removeItem(at: journal) }
    }
    func commit(_ ticket: CaptureTicket) async throws {
        if catalog.movies.flatMap(\.scenes).contains(where: { $0.id == ticket.sceneID }) { return }
        let staging = try url(ticket.staging), source = try url(ticket.source)
        let input = fm.fileExists(atPath: source.path) ? source : staging
        let info = try await MediaInspector.inspect(input)
        if ticket.profile == .appleLog && info.profile != .appleLog {
            throw HomeMovieError.message("The recording’s Apple Log metadata could not be verified.")
        }
        guard !catalog.movies.flatMap(\.scenes).contains(where: { $0.id == ticket.sceneID }) else { return }
        let i = try index(ticket.movieID)
        if input != source { try fm.moveItem(at: input, to: source) }
        var next = catalog
        if next.movies[i].recordingFormat == nil {
            if info.profile == .appleLog { next.movies[i].profile = .appleLog }
            next.movies[i].format = ticket.format ?? (info.size.width > info.size.height ? .landscape : .portrait)
        }
        // Preserve uniqueness even if startup recovery finds competing journal positions.
        let position = max(ticket.sequence, next.movies[i].nextSequence)
        next.movies[i].scenes.append(Scene(id: ticket.sceneID, sequence: position, source: ticket.source,
            capturedAt: ticket.capturedAt, timeZone: ticket.timeZone, sourceDuration: MediaTime(info.duration),
            trimStart: MediaTime(.zero), trimEnd: MediaTime(info.duration), width: info.size.width,
            height: info.size.height, hasAudio: info.hasAudio, bytes: info.bytes, profile: ticket.profile ?? info.profile))
        next.movies[i].lastRecordedAt = ticket.capturedAt; next.movies[i].revision += 1
        try write(next)
        try? fm.removeItem(at: url(ticket.journal))
    }
    func trim(movieID: UUID, sceneID: UUID, start: CMTime, end: CMTime) throws {
        try requireIdle()
        let m = try index(movieID)
        guard let c = catalog.movies[m].scenes.firstIndex(where: { $0.id == sceneID }) else { throw HomeMovieError.message("Scene not found.") }
        var next = catalog
        next.movies[m].scenes[c].trimStart = MediaTime(start); next.movies[m].scenes[c].trimEnd = MediaTime(end)
        guard next.movies[m].scenes[c].validTrim else { throw HomeMovieError.message("The trim must stay inside the original scene.") }
        next.movies[m].revision += 1; try write(next)
    }
    func undoLastTake(movieID: UUID, expectedSceneID: UUID) throws {
        try requireIdle()
        let m = try index(movieID)
        guard catalog.movies[m].deletedAt == nil,
              catalog.movies[m].activeScenes.last?.id == expectedSceneID else {
            throw HomeMovieError.message("The latest take has changed. Please try again.")
        }
        try setSceneDeleted(movieID: movieID, sceneID: expectedSceneID, deleted: true)
    }
    func setSceneDeleted(movieID: UUID, sceneID: UUID, deleted: Bool) throws {
        try requireIdle()
        let m = try index(movieID)
        guard let c = catalog.movies[m].scenes.firstIndex(where: { $0.id == sceneID }) else { throw HomeMovieError.message("Scene not found.") }
        var next = catalog; next.movies[m].scenes[c].deletedAt = deleted ? Date() : nil
        next.movies[m].revision += 1; try write(next)
    }
    func setMovieDeleted(_ id: UUID, deleted: Bool) throws {
        try requireIdle()
        let m = try index(id); var next = catalog; next.movies[m].deletedAt = deleted ? Date() : nil; next.movies[m].revision += 1; try write(next)
    }
    func storageBytes() -> Int64 { catalog.movies.flatMap(\.scenes).reduce(0) { $0 + $1.bytes } }
    func availableBytes() throws -> Int64 {
        let values = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        guard let capacity = values.volumeAvailableCapacityForImportantUsage ?? values.volumeAvailableCapacity.map(Int64.init) else {
            throw HomeMovieError.message("Free storage could not be checked. Please try again.")
        }
        return capacity
    }
    func requireSpace(bytes: Int64) throws {
        guard try availableBytes() > bytes else { throw HomeMovieError.message("Not enough free storage. Free space on your iPhone and try again. Your saved scenes are safe.") }
    }
    private func requireIdle() throws {
        guard !maintenance else { throw HomeMovieError.message("Wait for backup or restore to finish before changing movies.") }
    }
    func beginMaintenance(requireLoaded: Bool = true) throws {
        try requireIdle()
        if requireLoaded && !loaded { throw HomeMovieError.message("Open the movie library before making a backup.") }
        try ensureDirectories(); maintenance = true
    }
    func endMaintenance() { maintenance = false }
    func catalogSnapshot() -> Catalog { catalog }
    func validateBackupCatalog(_ value: Catalog) throws {
        guard value.schemaVersion == 1 else { throw HomeMovieError.message("This backup requires a newer version of Home Movie.") }
        try validate(value)
    }
    private func preserveCatalog() throws {
        let original = root.appendingPathComponent("catalog.json")
        if fm.fileExists(atPath: original.path) {
            try fm.copyItem(at: original, to: root.appendingPathComponent("Recovery/catalog-preserved-\(UUID()).json"))
        }
    }
    func repairFromPreviousCatalog() async throws -> [String] {
        try requireIdle(); try ensureDirectories()
        let previous = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: root.appendingPathComponent("catalog.previous.json")))
        try validateBackupCatalog(previous)
        try preserveCatalog()
        catalog = previous; loaded = false
        try write(previous)
        return try await load()
    }
    func installImportedMovies(_ movies: [Movie]) throws {
        guard maintenance else { throw HomeMovieError.message("Restore is not active.") }
        if !loaded {
            try preserveCatalog()
            catalog = Catalog()
        }
        var next = catalog; next.movies.append(contentsOf: movies)
        try write(next); loaded = false
    }
    func markFilesBackup(_ snapshot: Catalog) throws {
        var next = catalog
        for movie in snapshot.movies {
            if let index = next.movies.firstIndex(where: { $0.id == movie.id }) {
                next.movies[index].lastFilesBackupRevision = movie.revision
                next.movies[index].lastFilesBackupAt = Date()
            }
        }
        try write(next)
    }
    func markPhotosCopy(sceneID: UUID, assetID: String) throws {
        var next = catalog
        for m in next.movies.indices {
            if let c = next.movies[m].scenes.firstIndex(where: { $0.id == sceneID }) {
                next.movies[m].scenes[c].photosAssetID = assetID
                next.movies[m].scenes[c].photosCopiedAt = Date()
                try write(next); return
            }
        }
        throw HomeMovieError.message("The scene was copied to Photos but its receipt could not be attached.")
    }
    func recoveryFiles() throws -> [RecoveryFile] {
        try ensureDirectories()
        let known = Set(catalog.movies.flatMap(\.scenes).map(\.source))
        var files: [RecoveryFile] = []
        for directory in ["Staging", "Originals", "Recovery"] {
            for file in try fm.contentsOfDirectory(at: root.appendingPathComponent(directory), includingPropertiesForKeys: [.fileSizeKey]) {
                let path = "\(directory)/\(file.lastPathComponent)"
                guard !known.contains(path) else { continue }
                let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                files.append(RecoveryFile(id: path, url: file, bytes: Int64(size)))
            }
        }
        return files.sorted { $0.id < $1.id }
    }
    func recoverFile(_ file: RecoveryFile, movieID: UUID) async throws {
        try requireIdle()
        // Files must come from the app's own enumerated recovery list, never arbitrary URLs.
        guard try recoveryFiles().contains(where: { $0.id == file.id && $0.url == file.url }), file.url.pathExtension == "mov" else {
            throw HomeMovieError.message("This recovery item cannot be imported as a recording.")
        }
        let info = try await MediaInspector.inspect(file.url)
        let m = try index(movieID)
        let profile = info.profile ?? .standard
        guard profile == catalog.movies[m].captureProfile else {
            throw HomeMovieError.message("This recording’s color format does not match the movie. Recover it into a matching Standard or Apple Log movie, or save a copy to Files.")
        }
        let ticket = CaptureTicket(movieID: movieID, sequence: catalog.movies[m].nextSequence, profile: profile)
        try requireSpace(bytes: file.bytes + 300_000_000)
        try fm.copyItem(at: file.url, to: url(ticket.staging))
        try encoder.encode(ticket).write(to: url(ticket.journal), options: .atomic)
        try await commit(ticket)
        // Keep the recovery source until the user has safely exported it; no automatic deletion.
    }

}
