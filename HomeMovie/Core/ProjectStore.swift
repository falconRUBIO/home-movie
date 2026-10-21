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
        let deleting = value.pendingDeletionIDs ?? []
        guard Set(deleting).count == deleting.count, Set(deleting).isDisjoint(with: scenes.map(\.id)) else {
            throw HomeMovieError.message("The pending deletion metadata is inconsistent.")
        }
        guard Set(value.movies.map(\.id)).count == value.movies.count,
              Set(scenes.map(\.id)).count == scenes.count else { throw HomeMovieError.message("The catalog contains duplicate identifiers. Its file has been preserved.") }
        var totalBytes: Int64 = 0
        for movie in value.movies {
            try movie.exportEffects.validate()
            guard movie.libraryOrder.map({ $0 >= 0 && $0 < 1_000_000_000 }) ?? true,
                  movie.coverSceneID == nil || movie.scenes.contains(where: { $0.id == movie.coverSceneID }) else {
                throw HomeMovieError.message("The movie’s library metadata is invalid.")
            }
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
                try scene.lightAdjustments.validate()
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
        let cinema = try ColorCube.cinema.get()
        let cinemaURL = root.appendingPathComponent(LUTReference.cinema.path)
        if !fm.fileExists(atPath: cinemaURL.path) {
            try encoder.encode(cinema).write(to: cinemaURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
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
            guard decoded.schemaVersion == 1 else { throw HomeMovieError.message("This project uses a newer version of HOME MOVIE CLIPS.") }
            try validate(decoded)
            catalog = decoded
        } else { try write(catalog) }
        var migrated = catalog
        for index in migrated.movies.indices where migrated.movies[index].look?.isRetiredBundledLook == true {
            migrated.movies[index].look = .cinema
            migrated.movies[index].revision += 1
        }
        if migrated.movies != catalog.movies { try write(migrated) }
        var notices: [String] = []
        if finishPermanentDeletions() > 0 { notices.append("Some deleted files could not be removed yet. HOME MOVIE CLIPS will retry when reopened.") }
        let deleting = Set(catalog.pendingDeletionIDs ?? [])
        let journalFiles = try fm.contentsOfDirectory(at: root.appendingPathComponent("Journal"), includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        var pending: [(URL, CaptureTicket)] = []
        for file in journalFiles {
            do { pending.append((file, try JSONDecoder().decode(CaptureTicket.self, from: Data(contentsOf: file)))) }
            catch { notices.append("A damaged recovery journal was preserved for inspection.") }
        }
        for (file, ticket) in pending.sorted(by: { $0.1.capturedAt == $1.1.capturedAt ? $0.1.sequence < $1.1.sequence : $0.1.capturedAt < $1.1.capturedAt }) {
            if deleting.contains(ticket.sceneID) { continue }
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
            if let id, deleting.contains(id) { continue }
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
        let look = look ?? (profile == .appleLog && useDefaultLook ? .cinema : nil)
        if let look {
            guard profile == .appleLog else { throw HomeMovieError.message("Choose Apple Log to use this look.") }
            _ = try ColorCube.load(look, root: root)
        }
        var movie = Movie(name: clean, format: format)
        movie.profile = profile == .standard ? nil : profile
        movie.look = look
        var next = catalog; next.movies.append(movie); try write(next); return movie
    }
    func createQuickMovie() throws -> Movie {
        try requireIdle()
        let names = Set(catalog.movies.map(\.name))
        var number = 1
        while names.contains("Movie \(number)") { number += 1 }
        return try create(name: "Movie \(number)", format: .portrait, profile: .standard, useDefaultLook: false)
    }
    func setMovieRecordingSettings(movieID: UUID, profile: CaptureProfile, look: LUTReference?) throws {
        try requireIdle()
        let i = try index(movieID)
        let movie = catalog.movies[i]
        guard movie.deletedAt == nil else { throw HomeMovieError.message("This movie is unavailable.") }
        guard movie.captureProfile == profile || movie.scenes.isEmpty && movie.lastRecordedAt == nil else {
            throw HomeMovieError.message("The recording format is set by the first scene.")
        }
        let selected = profile == .appleLog ? look : nil
        if let selected { _ = try ColorCube.load(selected, root: root) }
        var next = catalog
        next.movies[i].profile = profile == .standard ? nil : profile
        next.movies[i].look = selected
        guard next.movies[i] != movie else { return }
        next.movies[i].revision += 1
        try write(next)
    }
    // LUT decoding must never occupy the catalog actor: a canceled camera task
    // may still be finishing a scan when the user taps + on the library.
    nonisolated func availableLooks() async -> [LUTReference] {
        guard !Task.isCancelled else { return [] }
        let root = root
        let scan = Task.detached(priority: .utility) { Self.readAvailableLooks(root: root) }
        return await withTaskCancellationHandler {
            await scan.value
        } onCancel: {
            scan.cancel()
        }
    }
    private nonisolated static func readAvailableLooks(root: URL) -> [LUTReference] {
        let directory = root.appendingPathComponent("Looks")
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { file in
            guard !Task.isCancelled, file.pathExtension == "json", let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent) else { return nil }
            let reference = LUTReference(id: id, name: "Look")
            guard !reference.isRetiredBundledLook else { return nil }
            guard let cube = try? ColorCube.load(reference, root: root) else { return nil }
            return LUTReference(id: id, name: id == LUTReference.cinema.id ? LUTReference.cinema.name : cube.name)
        }.sorted {
            if $0.id == LUTReference.cinema.id { return $1.id != LUTReference.cinema.id }
            if $1.id == LUTReference.cinema.id { return false }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
    func importLook(from source: URL, displayReferred: Bool = false) throws -> LUTReference {
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
        guard var imported else { throw HomeMovieError.message("This look could not be opened.") }
        if displayReferred {
            imported.colorContract = .displayLook
            imported = try imported.following(ColorCube.appleStandard.get())
        }
        let reference = LUTReference(id: UUID(), name: imported.name)
        try requireSpace(bytes: 20_000_000)
        try encoder.encode(imported).write(to: url(reference.path), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return reference
    }
    func setLook(movieID: UUID, look: LUTReference?) throws {
        try requireIdle()
        let i = try index(movieID)
        guard catalog.movies[i].captureProfile == .appleLog else { throw HomeMovieError.message("Looks are available for Apple Log movies.") }
        let look = look?.isRetiredBundledLook == true ? LUTReference.cinema : look
        if let look { _ = try ColorCube.load(look, root: root) }
        guard catalog.movies[i].look != look else { return }
        var next = catalog; next.movies[i].look = look; next.movies[i].revision += 1; try write(next)
    }
    func setFilmEffects(movieID: UUID, settings: FilmEffectsSettings) throws {
        try requireIdle(); try settings.validate()
        let i = try index(movieID)
        guard catalog.movies[i].exportEffects != settings else { return }
        var next = catalog; next.movies[i].filmEffects = settings; next.movies[i].revision += 1
        try write(next)
    }
    func setPiPLayout(movieID: UUID, layout: PiPLayout) throws {
        try requireIdle(); let i = try index(movieID)
        guard catalog.movies[i].preferredPiPLayout != layout else { return }
        var next = catalog; next.movies[i].pipLayout = layout; next.movies[i].revision += 1; try write(next)
    }
    func setDualCameraCapture(movieID: UUID, enabled: Bool) throws {
        try requireIdle(); let i = try index(movieID)
        var next = catalog; next.movies[i].dualCameraCapture = enabled; next.movies[i].revision += 1; try write(next)
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
        ReliabilityDiagnostics.shared.record(.recordingGeometry, capture: .init(canvas: ticket.format,
            savedWidth: Int(info.size.width), savedHeight: Int(info.size.height)))
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
    func editScene(movieID: UUID, sceneID: UUID, start: CMTime, end: CMTime, adjustments: SceneAdjustments,
                   filmEffects: FilmEffectsSettings? = nil) throws {
        try requireIdle(); try adjustments.validate(); try filmEffects?.validate()
        let m = try index(movieID)
        guard catalog.movies[m].deletedAt == nil,
              let c = catalog.movies[m].scenes.firstIndex(where: { $0.id == sceneID && $0.deletedAt == nil }) else {
            throw HomeMovieError.message("This scene is no longer available.")
        }
        var next = catalog
        next.movies[m].scenes[c].trimStart = MediaTime(start)
        next.movies[m].scenes[c].trimEnd = MediaTime(end)
        next.movies[m].scenes[c].adjustments = adjustments.isActive ? adjustments : nil
        guard next.movies[m].scenes[c].validTrim else { throw HomeMovieError.message("The trim must stay inside the original scene.") }
        if let filmEffects { next.movies[m].filmEffects = filmEffects }
        guard next.movies[m] != catalog.movies[m] else { return }
        next.movies[m].revision += 1; try write(next)
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
    /// Save current edits and insert an independently owned copy directly after this scene.
    func duplicateScene(movieID: UUID, sceneID: UUID, start: CMTime, end: CMTime,
                        adjustments: SceneAdjustments, filmEffects: FilmEffectsSettings? = nil) throws {
        try requireIdle()
        try adjustments.validate(); try filmEffects?.validate()
        let m = try index(movieID)
        guard catalog.movies[m].deletedAt == nil,
              let c = catalog.movies[m].scenes.firstIndex(where: { $0.id == sceneID && $0.deletedAt == nil }),
              !catalog.movies[m].scenes[c].missing else {
            throw HomeMovieError.message("This scene is unavailable.")
        }
        var edited = catalog.movies[m].scenes[c]
        edited.trimStart = MediaTime(start); edited.trimEnd = MediaTime(end)
        edited.adjustments = adjustments.isActive ? adjustments : nil
        guard edited.validTrim else { throw HomeMovieError.message("The trim must stay inside the original scene.") }
        try requireSpace(bytes: edited.bytes + 100_000_000)
        var copy = edited
        copy.id = UUID()
        copy.source = "Originals/\(copy.id.uuidString).mov"
        copy.sequence = edited.sequence + 1
        copy.duplicateOf = edited.duplicateOf ?? edited.id
        copy.photosAssetID = nil; copy.photosCopiedAt = nil
        let destination = try url(copy.source)
        try fm.copyItem(at: url(edited.source), to: destination)
        do {
            var next = catalog
            next.movies[m].scenes[c] = edited
            if let filmEffects { next.movies[m].filmEffects = filmEffects }
            for index in next.movies[m].scenes.indices where next.movies[m].scenes[index].sequence >= copy.sequence {
                next.movies[m].scenes[index].sequence += 1
            }
            next.movies[m].scenes.append(copy)
            next.movies[m].revision += 1
            try write(next)
        } catch {
            try? fm.removeItem(at: destination)
            throw error
        }
    }

    /// Compare the complete active order before saving, including Undo, to avoid losing newer edits.
    func reorderScenes(movieID: UUID, order: [UUID], expected: [UUID]) throws {
        try requireIdle()
        let m = try index(movieID)
        let active = catalog.movies[m].activeScenes
        guard catalog.movies[m].deletedAt == nil, active.map(\.id) == expected,
              order.count == active.count, Set(order) == Set(expected) else {
            throw HomeMovieError.message("The scenes have changed. Please try reordering again.")
        }
        guard order != expected else { return }
        let slots = active.map(\.sequence)
        var next = catalog
        for (offset, id) in order.enumerated() {
            if let index = next.movies[m].scenes.firstIndex(where: { $0.id == id }) {
                next.movies[m].scenes[index].sequence = slots[offset]
            }
        }
        next.movies[m].revision += 1
        try write(next)
    }

    /// Move an active scene to the target's position without altering any clip media or edits.
    func moveScene(movieID: UUID, sceneID: UUID, to targetID: UUID) throws {
        try requireIdle()
        let m = try index(movieID)
        var ordered = catalog.movies[m].activeScenes
        guard catalog.movies[m].deletedAt == nil,
              let source = ordered.firstIndex(where: { $0.id == sceneID }),
              let target = ordered.firstIndex(where: { $0.id == targetID }) else {
            throw HomeMovieError.message("This scene is no longer available.")
        }
        guard source != target else { return }
        let moved = ordered.remove(at: source)
        ordered.insert(moved, at: target)
        // Reuse active sequence slots so deleted scenes retain unique positions for restore.
        let positions = catalog.movies[m].activeScenes.map(\.sequence)
        var next = catalog
        for (offset, scene) in ordered.enumerated() {
            if let index = next.movies[m].scenes.firstIndex(where: { $0.id == scene.id }) {
                next.movies[m].scenes[index].sequence = positions[offset]
            }
        }
        next.movies[m].revision += 1
        try write(next)
    }

    func undoLastTake(movieID: UUID, expectedSceneID: UUID) throws {
        try requireIdle()
        let m = try index(movieID)
        guard catalog.movies[m].deletedAt == nil,
              catalog.movies[m].latestTake?.id == expectedSceneID else {
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
    func setMoviesDeleted(_ ids: Set<UUID>) throws {
        try requireIdle()
        guard !ids.isEmpty, ids.isSubset(of: Set(catalog.movies.filter { $0.deletedAt == nil }.map(\.id))) else {
            throw HomeMovieError.message("The movie selection changed. Select the movies again.")
        }
        var next = catalog
        let date = Date()
        for i in next.movies.indices where ids.contains(next.movies[i].id) {
            next.movies[i].deletedAt = date; next.movies[i].revision += 1
        }
        try write(next)
    }
    func reorderMovies(_ order: [UUID], expected: Set<UUID>) throws {
        try requireIdle()
        let active = Set(catalog.movies.filter { $0.deletedAt == nil }.map(\.id))
        guard active == expected, Set(order) == active, order.count == active.count else {
            throw HomeMovieError.message("Your movie library changed. Open Rearrange again.")
        }
        var next = catalog
        for (position, id) in order.enumerated() {
            let i = try index(id)
            if next.movies[i].libraryOrder != position {
                next.movies[i].libraryOrder = position; next.movies[i].revision += 1
            }
        }
        try write(next)
    }
    func setMovieCover(_ id: UUID, sceneID: UUID?) throws {
        try requireIdle()
        let i = try index(id)
        guard catalog.movies[i].deletedAt == nil,
              sceneID == nil || catalog.movies[i].activeScenes.contains(where: { $0.id == sceneID && !$0.missing }) else {
            throw HomeMovieError.message("Choose an available scene for the cover.")
        }
        var next = catalog; next.movies[i].coverSceneID = sceneID
        next.movies[i].revision += 1; try write(next)
    }
    /// Persist removal and cleanup intent together before touching any original.
    /// Failed/interrupted cleanup stays excluded from automatic recording recovery.
    @discardableResult func permanentlyDelete(movieIDs: Set<UUID>, sceneIDs: Set<UUID>) throws -> Int {
        try requireIdle()
        guard !movieIDs.isEmpty || !sceneIDs.isEmpty else { throw HomeMovieError.message("Select deleted items first.") }
        let deletedMovies = Set(catalog.movies.filter { $0.deletedAt != nil }.map(\.id))
        let deletedScenes = Set(catalog.movies.filter { $0.deletedAt == nil }.flatMap(\.scenes).filter { $0.deletedAt != nil }.map(\.id))
        guard movieIDs.isSubset(of: deletedMovies), sceneIDs.isSubset(of: deletedScenes) else {
            throw HomeMovieError.message("Recently Deleted changed. Select the items again.")
        }
        let journals = try fm.contentsOfDirectory(at: root.appendingPathComponent("Journal"), includingPropertiesForKeys: nil)
        for file in journals where file.pathExtension == "json" {
            if let data = try? Data(contentsOf: file), let ticket = try? JSONDecoder().decode(CaptureTicket.self, from: data),
               movieIDs.contains(ticket.movieID) {
                throw HomeMovieError.message("Recover the unfinished recording before permanently deleting this movie.")
            }
        }
        var next = catalog
        let removed = Set(next.movies.filter { movieIDs.contains($0.id) }.flatMap(\.scenes).map(\.id)).union(sceneIDs)
        next.movies.removeAll { movieIDs.contains($0.id) }
        for i in next.movies.indices where next.movies[i].scenes.contains(where: { sceneIDs.contains($0.id) }) {
            next.movies[i].scenes.removeAll { sceneIDs.contains($0.id) }
            if let cover = next.movies[i].coverSceneID, removed.contains(cover) { next.movies[i].coverSceneID = nil }
            next.movies[i].revision += 1
        }
        next.pendingDeletionIDs = Array(Set(next.pendingDeletionIDs ?? []).union(removed)).sorted { $0.uuidString < $1.uuidString }
        try write(next)
        return finishPermanentDeletions()
    }
    private func finishPermanentDeletions() -> Int {
        guard let ids = catalog.pendingDeletionIDs, !ids.isEmpty else { return 0 }
        var remaining: [UUID] = []
        for id in ids {
            do {
                for path in ["Originals/\(id.uuidString).mov", "Staging/\(id.uuidString).mov", "Journal/\(id.uuidString).json"] {
                    let file = try url(path)
                    do { try fm.removeItem(at: file) }
                    catch {
                        let failure = error as NSError
                        guard failure.domain == NSCocoaErrorDomain,
                              failure.code == NSFileNoSuchFileError || failure.code == NSFileReadNoSuchFileError else { throw error }
                    }
                }
            } catch { remaining.append(id) }
        }
        if remaining != ids {
            var next = catalog; next.pendingDeletionIDs = remaining.isEmpty ? nil : remaining
            try? write(next) // Durable intent remains if this cleanup-only write fails.
        }
        return catalog.pendingDeletionIDs?.count ?? 0
    }
    func restoreDeleted(movieIDs: Set<UUID>, sceneIDs: Set<UUID>) throws {
        try requireIdle()
        guard movieIDs.isSubset(of: Set(catalog.movies.filter { $0.deletedAt != nil }.map(\.id))),
              sceneIDs.isSubset(of: Set(catalog.movies.filter { $0.deletedAt == nil }.flatMap(\.scenes).filter { $0.deletedAt != nil }.map(\.id))) else {
            throw HomeMovieError.message("Recently Deleted changed. Select the items again.")
        }
        var next = catalog
        for i in next.movies.indices {
            if movieIDs.contains(next.movies[i].id) { next.movies[i].deletedAt = nil; next.movies[i].revision += 1 }
            for c in next.movies[i].scenes.indices where sceneIDs.contains(next.movies[i].scenes[c].id) {
                next.movies[i].scenes[c].deletedAt = nil; next.movies[i].revision += 1
            }
        }
        try write(next)
    }
    func storageBytes() -> Int64 { catalog.movies.flatMap(\.scenes).reduce(0) { $0 + $1.bytes } }
    func settingsStorage() -> SettingsStorage {
        var pending: Int64 = 0
        var cleanupKnown = true
        for id in catalog.pendingDeletionIDs ?? [] {
            for folder in ["Originals", "Staging"] {
                do {
                    let values = try root.appendingPathComponent("\(folder)/\(id.uuidString).mov")
                        .resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
                    if values.isRegularFile == true, values.isSymbolicLink != true { pending += Int64(values.fileSize ?? 0) }
                } catch {
                    let failure = error as NSError
                    if failure.domain != NSCocoaErrorDomain || (failure.code != NSFileReadNoSuchFileError && failure.code != NSFileNoSuchFileError) { cleanupKnown = false }
                }
            }
        }
        return SettingsStorage(temporaryExportBytes: SettingsStorage.exportBytes(in: URL.cachesDirectory.appendingPathComponent("Exports", isDirectory: true)),
            pendingCleanupBytes: cleanupKnown ? pending : nil, availableBytes: try? availableBytes())
    }
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
        guard value.schemaVersion == 1 else { throw HomeMovieError.message("This backup requires a newer version of HOME MOVIE CLIPS.") }
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
            var existing = Catalog()
            let current = root.appendingPathComponent("catalog.json")
            if fm.fileExists(atPath: current.path) {
                let data = try Data(contentsOf: current)
                if let header = try? JSONSerialization.jsonObject(with: data),
                   let fields = header as? [String: Any], let version = fields["schemaVersion"] as? Int, version != 1 {
                    throw HomeMovieError.message("This library uses an unsupported version. Its catalog and recordings have been preserved.")
                }
                if let decoded = try? JSONDecoder().decode(Catalog.self, from: data) {
                    guard decoded.schemaVersion == 1 else {
                        throw HomeMovieError.message("This library uses an unsupported version. Its catalog and recordings have been preserved.")
                    }
                    // A healthy unopened library keeps all names, trims and movie identities.
                    // A damaged catalog is preserved separately before importing the backup.
                    do { try validate(decoded); existing = decoded } catch { existing = Catalog() }
                }
            }
            try preserveCatalog()
            catalog = existing
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
        let deleting = Set(catalog.pendingDeletionIDs ?? [])
        var files: [RecoveryFile] = []
        for directory in ["Staging", "Originals", "Recovery"] {
            for file in try fm.contentsOfDirectory(at: root.appendingPathComponent(directory), includingPropertiesForKeys: [.fileSizeKey]) {
                let path = "\(directory)/\(file.lastPathComponent)"
                guard !known.contains(path) else { continue }
                if directory != "Recovery", let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent), deleting.contains(id) { continue }
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
