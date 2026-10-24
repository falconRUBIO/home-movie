import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let homeMovieBackup = UTType(exportedAs: "com.falconcraft.homemovie.backup", conformingTo: .package)
}

@MainActor final class BackupModel: ObservableObject {
    private let service = BackupService()
    @Published var running = false
    @Published var progress = 0.0
    @Published var prepared: PreparedBackup?
    @Published var message: String?
    private var job: Task<Void, Never>?
    func create(app: AppModel) {
        guard !running else { return }; running = true; progress = 0; message = nil
        if let prepared { try? FileManager.default.removeItem(at: prepared.url); self.prepared = nil }
        job = Task {
            defer { running = false; job = nil }
            do {
                prepared = try await service.create(store: app.store) { [weak self] value in
                    Task { @MainActor in self?.progress = value }
                }
                message = "Backup prepared. Choose Save Backup to Files to store a separate copy."
            } catch { if !(error is CancellationError) { message = error.localizedDescription } }
        }
    }
    func restore(url: URL, app: AppModel) {
        guard !running else { return }; running = true; progress = 0; message = nil
        job = Task {
            defer { running = false; job = nil }
            do {
                try await service.restore(from: url, store: app.store) { [weak self] value in Task { @MainActor in self?.progress = value } }
                app.error = nil; await app.load(); await app.refresh()
                message = "Backup verified and restored as separate movies. Existing footage was preserved."
            } catch { if !(error is CancellationError) { message = error.localizedDescription } }
        }
    }
    func savedToFiles(app: AppModel) async {
        guard let prepared else { return }
        do {
            try await app.store.markFilesBackup(prepared.snapshot); await app.refresh()
            message = "Backup saved to Files. If you selected iCloud Drive, wait for Files to finish syncing before relying on the cloud copy."
        } catch { message = "The backup was saved, but its status could not be updated: \(error.localizedDescription)" }
        try? await service.discard(prepared.url); self.prepared = nil
    }
    func discardPrepared() {
        guard !running, let prepared else { return }; self.prepared = nil
        Task { try? await service.discard(prepared.url) }
    }
    func cancel() { message = "Operation canceled. Previously saved movies are safe."; job?.cancel() }
}

struct BackupView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var backup = BackupModel()
    @State private var importing = false
    @State private var saving = false
    @State private var repairRunning = false
    var body: some View {
        NavigationStack {
            Form {
                Section("Protect your movies") {
                    Text("A project backup includes every saved original scene, movie name, scene order, trim and recoverable deletion.").font(.footnote)
                    Text("Save it to iCloud Drive or another location outside MOVIE ROLL. A copy inside this app can disappear if the app is deleted.").font(.footnote).foregroundStyle(.secondary)
                    Text("Unfinished recovery files are separate; export them from Recording Recovery.").font(.footnote).foregroundStyle(.secondary)
                }
                if backup.running { Section {
                    ProgressView(value: backup.progress) { Text("Copying and verifying…") }
                    Button("Cancel", role: .destructive) { backup.cancel() }
                } }
                Section {
                    Button("Prepare Project Backup", systemImage: "archivebox") { backup.create(app: app) }.disabled(!app.loaded || backup.running || repairRunning)
                    if backup.prepared != nil {
                        Button("Save Backup to Files", systemImage: "folder") { saving = true }.disabled(backup.running || repairRunning)
                    }
                    Button("Restore Project Backup", systemImage: "arrow.counterclockwise") { importing = true }.disabled(backup.running || repairRunning)
                }
                if !app.loaded {
                    Section("Recover the library") {
                        Button("Recover Previous Catalog") {
                            repairRunning = true
                            Task {
                                do { _ = try await app.store.repairFromPreviousCatalog(); app.error = nil; await app.load() }
                                catch { app.error = error.localizedDescription }
                                repairRunning = false
                            }
                        }.disabled(repairRunning || backup.running)
                        Text("Preserves the damaged catalog, then tries the last known valid copy. Newer footage is reconciled afterward.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if let message = backup.message { Section { Text(message).font(.footnote) } }
                Section("Last saved backup") {
                    ForEach(app.movies) { movie in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(movie.name)
                            if let date = movie.lastFilesBackupAt {
                                Text(date, style: .date).font(.caption).foregroundStyle(.secondary)
                                Text(movie.lastFilesBackupRevision == movie.revision ? "This revision was saved to Files" : "Movie changed since its last Files backup").font(.caption).foregroundStyle(.secondary)
                            } else { Text("No Files backup recorded").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            }.navigationTitle("Backup & Restore").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(backup.running || repairRunning) } }
                .fileImporter(isPresented: $importing, allowedContentTypes: [.homeMovieBackup, .folder]) { result in
                    switch result { case .success(let url): backup.restore(url: url, app: app)
                    case .failure(let error): backup.message = error.localizedDescription }
                }
                .sheet(isPresented: $saving) {
                    if let prepared = backup.prepared {
                        BackupFilesExporter(url: prepared.url) { saved in
                            saving = false
                            if saved { Task { await backup.savedToFiles(app: app) } }
                        }
                    }
                }
        }.interactiveDismissDisabled(backup.running || repairRunning)
            .onDisappear { if !saving { backup.discardPrepared() } }
    }
}

struct RecordingRecoveryView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var files: [RecoveryFile] = []
    @State private var exported: RecoveryFile?
    @State private var selected: RecoveryFile?
    @State private var working = false
    @State private var message: String?
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("These files were preserved after interrupted or incomplete operations. You can save a copy to Files, or try attaching a playable recording to a movie.").font(.footnote)
                    Text("A file with an unfinished video header may not be playable. Recovery is not guaranteed.").font(.footnote).foregroundStyle(.secondary)
                }
                if files.isEmpty { Text("No unassigned recording files").foregroundStyle(.secondary) }
                ForEach(files) { file in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(file.title).font(.subheadline)
                        Text(file.url.lastPathComponent).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        Text(ByteCountFormatter.string(fromByteCount: file.bytes, countStyle: .file)).font(.caption2).foregroundStyle(.secondary)
                        HStack {
                            Button("Save Copy to Files") { exported = file }
                            if file.url.pathExtension == "mov" && app.loaded { Button("Recover into Movie") { selected = file } }
                        }.font(.footnote).disabled(working)
                    }
                }
                if let message { Text(message).font(.footnote) }
            }.navigationTitle("Recording Recovery").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(working) } }
                .task { do { files = try await app.store.recoveryFiles() } catch { message = error.localizedDescription } }
                .sheet(item: $exported) { file in SystemFilesExporter(url: file.url) }
                .confirmationDialog("Recover into", isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } }), titleVisibility: .visible) {
                    ForEach(app.activeMovies) { movie in
                        Button(movie.name) {
                            guard let file = selected else { return }; working = true; selected = nil
                            Task {
                                do { try await app.store.recoverFile(file, movieID: movie.id); await app.refresh(); message = "A validated copy was added. The recovery source has been kept." }
                                catch { message = error.localizedDescription }
                                working = false
                            }
                        }
                    }
                }
        }.interactiveDismissDisabled(working)
    }
}
