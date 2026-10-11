import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject private var app: AppModel
    @State private var path: [UUID] = []
    @State private var creating = false
    @State private var settings = false
    @State private var recovery = false
    @State private var backups = false
    @State private var renameMovie: Movie?
    @State private var renameText = ""
    @State private var deleteMovie: Movie?
    @State private var exportMovie: Movie?
    @AppStorage("openLastMovie") private var openLastMovie = false
    @AppStorage("lastMovieID") private var lastMovieID = ""
    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if !app.loaded {
                    VStack(spacing: 16) {
                        if app.loadFailure == nil { ProgressView("Opening your movies…") }
                        else {
                            Text("Your movies could not be opened.")
                            Text(app.loadFailure ?? "").font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            Button("Try Again") { Task { await app.load() } }
                            Button("Backup & Catalog Recovery") { backups = true }
                            Button("Preserved Recording Files") { recovery = true }
                        }
                    }
                } else if app.activeMovies.isEmpty {
                    ContentUnavailableView {
                        Label("Your home movie starts here", systemImage: "video")
                    } description: { Text("Record a moment. Come back for the next.") } actions: {
                        Button("Create Your First Movie") { creating = true }.buttonStyle(.borderedProminent)
                    }
                } else {
                    ScrollView {
                        LazyVStack(spacing: 24) {
                            ForEach(app.activeMovies) { movie in
                                VStack(alignment: .leading, spacing: 9) {
                                    Button { lastMovieID = movie.id.uuidString; path.append(movie.id) } label: {
                                        SceneThumbnail(scene: movie.activeScenes.first, root: app.store.root)
                                            .frame(height: 210).clipShape(RoundedRectangle(cornerRadius: 22))
                                            .overlay(alignment: .bottomTrailing) {
                                                Text(durationLabel(movie.duration)).font(.caption.monospacedDigit())
                                                    .padding(.horizontal, 9).padding(.vertical, 5).homeGlass(interactive: false).padding(12)
                                            }
                                    }.buttonStyle(.plain).accessibilityLabel("Record into \(movie.name), \(durationLabel(movie.duration))")
                                    HStack(alignment: .top) {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(movie.name).font(.headline)
                                            Text(movie.activeScenes.count == 1 ? "1 scene" : "\(movie.activeScenes.count) scenes").font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Menu {
                                            Button("Export", systemImage: "square.and.arrow.up") { exportMovie = movie }
                                                .disabled(movie.activeScenes.isEmpty)
                                            Divider()
                                            Button("Rename", systemImage: "pencil") { renameText = movie.name; renameMovie = movie }
                                            Button("Delete Movie", systemImage: "trash", role: .destructive) { deleteMovie = movie }
                                        } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                                        .accessibilityLabel("Manage \(movie.name)")
                                    }
                                }
                            }
                        }.padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 25)
                    }
                }
            }
            .navigationTitle("Movies").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("New Movie", systemImage: "plus") { creating = true }.disabled(!app.loaded) }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Settings", systemImage: "gearshape") { settings = true }.disabled(!app.loaded)
                }
            }
            .navigationDestination(for: UUID.self) { id in CameraView(app: app, movieID: id) }
            .sheet(isPresented: $creating) {
                NewMovieView { id in creating = false; lastMovieID = id.uuidString; path.append(id) }
            }
            .sheet(isPresented: $settings) { SettingsView() }
            .sheet(isPresented: $backups) { BackupView() }
            .sheet(isPresented: $recovery) { RecordingRecoveryView() }
            .sheet(item: $exportMovie) { movie in ExportView(movie: movie).environmentObject(app) }
            .alert("Rename Movie", isPresented: Binding(get: { renameMovie != nil }, set: { if !$0 { renameMovie = nil } })) {
                TextField("Movie name", text: $renameText)
                Button("Cancel", role: .cancel) { renameMovie = nil }
                Button("Save") {
                    if let movie = renameMovie { Task { await app.run { try await app.store.rename(movie.id, name: renameText) } } }
                    renameMovie = nil
                }
            }
            .confirmationDialog("Delete this movie?", isPresented: Binding(get: { deleteMovie != nil }, set: { if !$0 { deleteMovie = nil } }), titleVisibility: .visible) {
                Button("Move to Recently Deleted", role: .destructive) {
                    if let movie = deleteMovie { Task { await app.run { try await app.store.setMovieDeleted(movie.id, deleted: true) } } }
                    deleteMovie = nil
                }
            } message: { Text("You can restore the movie and its original scenes in Settings.") }
            .task { if !app.loaded { await app.load() } }
            .onChange(of: app.loaded) { _, ready in
                if ready && openLastMovie, let id = UUID(uuidString: lastMovieID), app.activeMovies.contains(where: { $0.id == id }) { path = [id] }
            }
        }
        .alert("Home Movie", isPresented: Binding(get: { app.error != nil }, set: { if !$0 { app.error = nil } })) {
            Button("OK") { app.error = nil }
        } message: { Text(app.error ?? "") }
        .alert("Recording Recovery", isPresented: Binding(get: { app.recoveryNotice != nil }, set: { if !$0 { app.recoveryNotice = nil } })) {
            Button("OK") { app.recoveryNotice = nil }
        } message: { Text(app.recoveryNotice ?? "") }
    }
}

struct NewMovieView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var profile = CaptureProfile.standard
    @State private var supportsLog = false
    @State private var looks: [LUTReference] = []
    @State private var selectedLook: LUTReference?
    @State private var importingLook = false
    @State private var loadingLook = false
    @State private var saving = false
    @State private var problem: String?
    let created: (UUID) -> Void
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Movie name", text: $name).textInputAutocapitalization(.sentences).submitLabel(.done)
                    if supportsLog {
                        Picker("Recording", selection: $profile) {
                            Text("Standard").tag(CaptureProfile.standard)
                            Text("Apple Log").tag(CaptureProfile.appleLog)
                        }.pickerStyle(.menu)
                        if profile == .appleLog {
                            Menu {
                                Button("Apple Standard") { selectedLook = nil }
                                ForEach(looks, id: \.id) { look in Button(look.name) { selectedLook = look } }
                                Divider()
                                Button("Add Apple Log Look…", systemImage: "plus") { importingLook = true }
                            } label: {
                                HStack { Text("Look"); Spacer(); Text(selectedLook?.name ?? "Apple Standard").foregroundStyle(.secondary) }
                            }.foregroundStyle(.primary).disabled(loadingLook)
                        }
                    }
                } footer: { Text(profile == .appleLog ? "Keeps a flexible original. Choose its look after recording." : "Hold your iPhone upright or sideways. Your first recording sets the movie’s orientation. Each recording becomes the next scene.") }
                if let problem { Section { Text(problem).foregroundStyle(.red) } }
            }.navigationTitle("New Movie").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Create") {
                            saving = true
                            Task {
                                do { let movie = try await app.store.create(name: name, format: .portrait, profile: profile, look: profile == .appleLog ? selectedLook : nil); await app.refresh(); created(movie.id) }
                                catch { problem = error.localizedDescription; saving = false }
                            }
                        }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.trimmingCharacters(in: .whitespacesAndNewlines).count > 80 || saving || loadingLook)
                    }
                }
        }.presentationDetents([.medium]).interactiveDismissDisabled(saving)
            .fileImporter(isPresented: $importingLook, allowedContentTypes: [UTType(filenameExtension: "cube") ?? .data], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }; loadingLook = true
                    Task {
                        defer { loadingLook = false }
                        do { selectedLook = try await app.store.importLook(from: url); looks = await app.store.availableLooks() }
                        catch { problem = error.localizedDescription }
                    }
                case .failure(let error): problem = error.localizedDescription
                }
            }
            .task { supportsLog = await Task.detached { CaptureService.supportsAppleLog() }.value; looks = await app.store.availableLooks() }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("openLastMovie") private var openLastMovie = false
    @AppStorage("copyScenesToPhotos") private var copyScenesToPhotos = false
    @State private var backups = false
    @State private var recovery = false
    var body: some View {
        NavigationStack {
            Form {
                Section("Launch") { Toggle("Open last movie", isOn: $openLastMovie) }
                Section { NavigationLink("Privacy", destination: PrivacyView()) }
                Section("Protection") {
                    Toggle("Copy original scenes to Photos", isOn: $copyScenesToPhotos)
                        .onChange(of: copyScenesToPhotos) { _, enabled in if enabled { app.retryPhotosCopies() } else { app.stopPhotosRetries() } }
                    Text("Creates a separate Photos copy after each local save. Copies use extra storage. iCloud Photos syncing follows your Photos settings.").font(.footnote).foregroundStyle(.secondary)
                    if copyScenesToPhotos { Button("Retry Pending Photos Copies") { app.retryPhotosCopies() } }
                    if let status = app.photosCopyStatus { Text(status).font(.footnote).foregroundStyle(.secondary) }
                    Button("Backup & Restore", systemImage: "archivebox") { backups = true }
                    Button("Recording Recovery", systemImage: "arrow.counterclockwise") { recovery = true }
                }
                Section("Storage") {
                    LabeledContent("Source footage", value: ByteCountFormatter.string(fromByteCount: app.storageBytes, countStyle: .file))
                    Text("Projects stay on this iPhone. Deleting the app can delete your movies. Save finished videos to Photos or Files.").font(.footnote).foregroundStyle(.secondary)
                    Text("A finished video does not preserve editable scene boundaries. Use Backup & Restore to save originals together with movie order and trims.").font(.footnote).foregroundStyle(.secondary)
                }
                Section("Recently Deleted Movies") {
                    let deleted = app.movies.filter { $0.deletedAt != nil }
                    if deleted.isEmpty { Text("No deleted movies").foregroundStyle(.secondary) }
                    ForEach(deleted) { movie in
                        HStack { Text(movie.name); Spacer(); Button("Restore") { Task { await app.run { try await app.store.setMovieDeleted(movie.id, deleted: false) } } } }
                    }
                }
                Section("Recently Deleted Scenes") {
                    let deleted = app.movies.flatMap { m in m.scenes.filter { $0.deletedAt != nil }.map { (m, $0) } }
                    if deleted.isEmpty { Text("No deleted scenes").foregroundStyle(.secondary) }
                    ForEach(deleted, id: \.1.id) { item in
                        let (movie, scene) = item
                        HStack {
                            VStack(alignment: .leading) { Text(movie.name); Text(scene.capturedAt, style: .date).font(.caption).foregroundStyle(.secondary) }
                            Spacer(); Button("Restore") { Task { await app.run { try await app.store.setSceneDeleted(movieID: movie.id, sceneID: scene.id, deleted: false) } } }
                        }
                    }
                }
            }.navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .sheet(isPresented: $backups) { BackupView() }
        .sheet(isPresented: $recovery) { RecordingRecoveryView() }
    }
}


struct PrivacyView: View {
    var body: some View {
        List {
            Section("Your movies") {
                Text("Home Movie keeps recordings and edit information on this iPhone. It has no account system, advertising, or analytics service, and does not upload your movies to a developer server.")
            }
            Section("Permissions") {
                Text("Camera and microphone access record video and sound. Photos access only adds copies when you choose to save a movie or enable original-scene copies. Home Movie does not request access to read your photo library.")
            }
            Section("Copies and backups") {
                Text("When you save or share, the destination you choose handles that copy. Files backups include original recordings and project metadata. iCloud Drive and iCloud Photos follow your Apple settings; Home Movie does not confirm completed cloud syncing.")
            }
            Section("Deleting footage") {
                Text("Recently Deleted keeps original files so you can restore scenes and movies. Deleting this app can remove its local projects. Copies saved to Photos, Files, or shared elsewhere remain separate and must be managed at those destinations.")
            }
        }.navigationTitle("Privacy").navigationBarTitleDisplayMode(.inline)
    }
}
