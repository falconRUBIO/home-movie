import SwiftUI
import UniformTypeIdentifiers
import UIKit

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
    @State private var playingMovie: Movie?
    @State private var coverMovie: Movie?
    @State private var rearranging = false
    @State private var selecting = false
    @State private var selected: Set<UUID> = []
    @State private var confirmingSelection = false
    @State private var deletingSelection = false
    @AppStorage("movieLibrarySort") private var sortValue = MovieLibrarySort.newest.rawValue
    private var sortedMovies: [Movie] { (MovieLibrarySort(rawValue: sortValue) ?? .newest).sorted(app.activeMovies) }
    @AppStorage("openLastMovie") private var openLastMovie = false
    @AppStorage("lastMovieID") private var lastMovieID = ""
    private var movieColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(minimum: 0), spacing: 16, alignment: .top),
              count: app.activeMovies.count >= 4 ? 2 : 1)
    }
    private func openMovie(_ movie: Movie) {
        lastMovieID = movie.id.uuidString
        app.prewarmCamera(movieID: movie.id)
        path.append(movie.id)
    }
    private func toggleSelection(_ id: UUID) {
        if !selected.insert(id).inserted { selected.remove(id) }
        UISelectionFeedbackGenerator().selectionChanged()
    }
    @ViewBuilder private func movieActions(_ movie: Movie) -> some View {
        Button("Play Movie", systemImage: "play.fill") { playingMovie = movie }.disabled(movie.activeScenes.isEmpty)
        Button("Rename", systemImage: "pencil") { renameText = movie.name; renameMovie = movie }
        Button("Change Cover", systemImage: "photo") { coverMovie = movie }.disabled(!movie.activeScenes.contains { !$0.missing })
        Button("Share / Export", systemImage: "square.and.arrow.up") { exportMovie = movie }.disabled(movie.activeScenes.isEmpty)
        Button("Rearrange", systemImage: "arrow.up.arrow.down") { rearranging = true }.disabled(app.activeMovies.count < 2)
        Divider()
        Button("Delete Movie", systemImage: "trash", role: .destructive) { deleteMovie = movie }
    }
    private func createMovie() {
        guard !creating, app.loaded else { return }
        creating = true
        Task {
            defer { creating = false }
            do {
                let movie = try await app.createQuickMovie()
                openMovie(movie)
            } catch { app.error = error.localizedDescription }
        }
    }
    private var newMovieButton: some View {
        Button { createMovie() } label: {
            Group {
                if creating {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: "plus")
                        .font(.system(size: 24, weight: .semibold))
                }
            }
            .frame(width: 24, height: 24)
        }.modifier(LibraryCreateButtonStyle())
            .buttonBorderShape(.circle)
            .tint(.blue)
            .controlSize(.large)
            .accessibilityLabel(creating ? "Creating Movie" : "New Movie")
            .accessibilityHint("Creates a movie and opens the camera")
            .disabled(!app.loaded || creating)
    }
    private func thumbnailActionIcon(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 18, weight: .semibold))
            .foregroundStyle(.white).frame(width: 48, height: 48)
            .background(.black.opacity(0.4), in: Circle()).homeGlass()
            .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
    }
    private func movieCard(_ movie: Movie) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            ZStack(alignment: .bottom) {
                Button { openMovie(movie) } label: {
                    SceneThumbnail(scene: movie.coverScene, root: app.store.root, movie: movie)
                        .frame(height: 210).clipShape(RoundedRectangle(cornerRadius: 22))
                        .overlay(alignment: .topTrailing) {
                            if !movie.activeScenes.isEmpty {
                                Text(durationLabel(movie.duration)).font(.caption.monospacedDigit())
                                    .padding(.horizontal, 9).padding(.vertical, 5)
                                    .homeGlass(interactive: false).padding(12)
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 22))
                }.buttonStyle(.plain).accessibilityLabel("Record into \(movie.name), \(durationLabel(movie.duration))")
                    .accessibilityHint("Opens the camera to add scenes")
                HStack {
                    if !movie.activeScenes.isEmpty {
                        Button { playingMovie = movie } label: {
                            thumbnailActionIcon("play.fill")
                        }.buttonStyle(.plain)
                            .accessibilityLabel("Play \(movie.name)")
                            .accessibilityHint("Plays the full movie from the beginning")
                    }
                    Spacer(minLength: 8)
                    Button { openMovie(movie) } label: {
                        thumbnailActionIcon("video.fill")
                    }.buttonStyle(.plain)
                        .accessibilityLabel(movie.activeScenes.isEmpty
                            ? "Start Recording in \(movie.name)" : "Continue Recording in \(movie.name)")
                        .accessibilityHint("Opens the camera. Recording starts when you tap Record.")
                }.padding(12)
            }
            HStack(alignment: .top) {
                Button { openMovie(movie) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(movie.name).font(.headline)
                        Text(movie.activeScenes.count == 1 ? "1 scene" : "\(movie.activeScenes.count) scenes").font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel("Record into \(movie.name)")
                    .accessibilityHint("Opens the camera to add scenes")
                Menu { movieActions(movie) } label: {
                    Image(systemName: "ellipsis").frame(width: 44, height: 44).contentShape(Rectangle())
                }.menuOrder(.fixed).accessibilityLabel("Manage \(movie.name)")
            }
        }
        .allowsHitTesting(!selecting)
        .accessibilityHidden(selecting)
        .contextMenu { if !selecting { movieActions(movie) } }
        .overlay {
            if selecting {
                Button { toggleSelection(movie.id) } label: {
                    RoundedRectangle(cornerRadius: 22).fill(.clear)
                        .contentShape(Rectangle())
                        .overlay(alignment: .topTrailing) {
                            Image(systemName: selected.contains(movie.id) ? "checkmark.circle.fill" : "circle")
                                .font(.title).foregroundStyle(selected.contains(movie.id) ? Color.accentColor : .white)
                                .background(.regularMaterial, in: Circle()).padding(12)
                        }
                }.buttonStyle(.plain).accessibilityLabel(movie.name)
                    .accessibilityValue(selected.contains(movie.id) ? "Selected" : "Not selected")
                    .accessibilityAddTraits(selected.contains(movie.id) ? [.isSelected] : [])
            }
        }
    }
    private var libraryContent: some View {
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
                    Label("Your movie starts here", systemImage: "video")
                } description: { Text("Record a moment. Come back for the next.") }
            } else {
                ScrollView {
                    LazyVGrid(columns: movieColumns, alignment: .leading, spacing: 24) {
                        ForEach(sortedMovies) { movie in
                            movieCard(movie)
                        }
                    }
                    .padding(.horizontal, 20).padding(.top, 8)
                    // The last row can scroll fully above the floating create control.
                    .padding(.bottom, selecting ? 24 : 96)
                }
                .modifier(LibraryScrollEdgeStyle())
            }
        }
    }

    private var libraryPage: some View {
        libraryContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Movies").navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.automatic, for: .navigationBar)
            .overlay(alignment: .bottom) {
                if !selecting {
                    newMovieButton
                        .padding(.bottom, 12)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if selecting {
                    HStack {
                        Text("\(selected.count) selected").font(.subheadline)
                        Spacer()
                        Button("Delete", systemImage: "trash", role: .destructive) { confirmingSelection = true }
                            .disabled(selected.isEmpty || deletingSelection).frame(minHeight: 44)
                    }.padding(.horizontal, 20).background(.bar)
                }
            }
            .toolbar { libraryToolbar }
    }

    @ToolbarContentBuilder private var libraryToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            if selecting {
                Button(selected.count == app.activeMovies.count ? "Deselect All" : "Select All") {
                    selected = selected.count == app.activeMovies.count ? [] : Set(app.activeMovies.map(\.id))
                }.disabled(deletingSelection)
            }
        }
        ToolbarItem(placement: .topBarLeading) {
            if selecting {
                Button("Done") { selecting = false; selected = [] }.disabled(deletingSelection)
            } else {
                Button { settings = true } label: { MovieControlIcon(systemName: "gearshape") }
                    .accessibilityLabel("Settings").disabled(!app.loaded)
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            if !selecting {
                Menu {
                    Button("Select", systemImage: "checkmark.circle") { selected = []; selecting = true }
                    Button("Rearrange", systemImage: "arrow.up.arrow.down") { rearranging = true }.disabled(app.activeMovies.count < 2)
                    Picker("Sort", selection: $sortValue) {
                        ForEach(MovieLibrarySort.allCases) { Text($0.rawValue).tag($0.rawValue) }
                    }
                } label: { MovieControlIcon(systemName: "ellipsis.circle") }
                    .accessibilityLabel("Library options").disabled(!app.loaded || app.activeMovies.isEmpty)
            }
        }
    }

    private var librarySheets: some View {
        libraryPage
            .onChange(of: app.activeMovies.map(\.id)) { _, ids in selected.formIntersection(ids) }
            .sheet(item: $coverMovie) { MovieCoverPicker(movie: $0).environmentObject(app) }
            .sheet(isPresented: $rearranging) {
                MovieReorderView(movies: sortedMovies) { sortValue = MovieLibrarySort.custom.rawValue }.environmentObject(app)
            }
            .alert("Delete \(selected.count) movies?", isPresented: $confirmingSelection) {
                Button("Cancel", role: .cancel) { }
                Button("Move to Recently Deleted", role: .destructive) {
                    let ids = selected
                    deletingSelection = true
                    Task {
                        defer { deletingSelection = false }
                        do {
                            try await app.store.setMoviesDeleted(ids); await app.refresh()
                            selected = []; selecting = false
                        } catch { app.error = error.localizedDescription }
                    }
                }
            } message: { Text("You can restore these movies and their original scenes in Settings.") }
            .navigationDestination(for: UUID.self) { id in CameraView(app: app, movieID: id) }
            .sheet(isPresented: $settings) { SettingsView() }
            .sheet(isPresented: $backups) { BackupView() }
            .sheet(isPresented: $recovery) { RecordingRecoveryView() }
            .fullScreenCover(item: $playingMovie) { movie in
                WatchMovieView(movieID: movie.id, playbackOnly: true, autoplay: true).environmentObject(app)
            }
            .sheet(item: $exportMovie) { movie in ExportView(movie: movie).environmentObject(app) }
    }

    private var libraryActions: some View {
        librarySheets
            .alert("Rename Movie", isPresented: Binding(get: { renameMovie != nil }, set: { if !$0 { renameMovie = nil } })) {
                TextField("Movie name", text: $renameText)
                Button("Cancel", role: .cancel) { renameMovie = nil }
                Button("Save") {
                    if let movie = renameMovie { Task { await app.run { try await app.store.rename(movie.id, name: renameText) } } }
                    renameMovie = nil
                }
            }
            .alert("Delete this movie?", isPresented: Binding(get: { deleteMovie != nil }, set: { if !$0 { deleteMovie = nil } })) {
                Button("Cancel", role: .cancel) { deleteMovie = nil }
                Button("Move to Recently Deleted", role: .destructive) {
                    if let movie = deleteMovie { Task { await app.run { try await app.store.setMovieDeleted(movie.id, deleted: true) } } }
                    deleteMovie = nil
                }
            } message: { Text("You can restore the movie and its original scenes in Settings.") }
            .task { if !app.loaded { await app.load() } }
            .onChange(of: app.loaded) { _, ready in
                if ready && openLastMovie, let id = UUID(uuidString: lastMovieID), app.activeMovies.contains(where: { $0.id == id }) { app.prewarmCamera(movieID: id); path = [id] }
            }
    }

    var body: some View {
        NavigationStack(path: $path) { libraryActions }
        .alert("MOVIE MODE", isPresented: Binding(get: { app.error != nil }, set: { if !$0 { app.error = nil } })) {
            Button("OK") { app.error = nil }
        } message: { Text(app.error ?? "") }
        .alert("Recording Recovery", isPresented: Binding(get: { app.recoveryNotice != nil }, set: { if !$0 { app.recoveryNotice = nil } })) {
            Button("OK") { app.recoveryNotice = nil }
        } message: { Text(app.recoveryNotice ?? "") }
    }
}


// Keep system glass on the control itself, without a second material plate.
// Native styles also adapt to Reduce Transparency, contrast and pressed states.
private struct LibraryCreateButtonStyle: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.buttonStyle(.glassProminent)
        } else {
            content.buttonStyle(.borderedProminent)
                .shadow(color: .black.opacity(0.16), radius: 8, y: 4)
        }
    }
}

private struct LibraryScrollEdgeStyle: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            content
        }
    }
}


private struct MovieReorderView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var movies: [Movie]
    @State private var saving = false
    @State private var error: String?
    private let expected: Set<UUID>
    let onSave: () -> Void
    init(movies: [Movie], onSave: @escaping () -> Void) {
        _movies = State(initialValue: movies); expected = Set(movies.map(\.id)); self.onSave = onSave
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(movies) { movie in
                        HStack(spacing: 12) {
                            SceneThumbnail(scene: movie.coverScene, root: app.store.root, movie: movie)
                                .frame(width: 64, height: 48).clipShape(RoundedRectangle(cornerRadius: 8))
                            Text(movie.name)
                        }.padding(.vertical, 4)
                    }.onMove { offsets, destination in
                        movies.move(fromOffsets: offsets, toOffset: destination)
                        UISelectionFeedbackGenerator().selectionChanged()
                    }
                } footer: { Text("Drag the handles to reorder your movies. Done saves Custom Order.") }
            }.environment(\.editMode, .constant(.active)).disabled(saving)
                .navigationTitle("Rearrange Movies").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            saving = true
                            Task {
                                defer { saving = false }
                                do {
                                    try await app.store.reorderMovies(movies.map(\.id), expected: expected)
                                    await app.refresh(); onSave(); dismiss()
                                } catch { self.error = error.localizedDescription }
                            }
                        }.disabled(saving)
                    }
                }
                .interactiveDismissDisabled(saving)
                .alert("Couldn’t Save Order", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                    Button("OK") { error = nil }
                } message: { Text(error ?? "") }
        }
    }
}

private struct MovieCoverPicker: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    let movie: Movie
    @State private var saving = false
    @State private var error: String?
    private var current: Movie { app.movie(movie.id) ?? movie }
    private func save(_ sceneID: UUID?) {
        saving = true
        Task {
            defer { saving = false }
            do {
                try await app.store.setMovieCover(movie.id, sceneID: sceneID)
                await app.refresh(); UISelectionFeedbackGenerator().selectionChanged(); dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { save(nil) } label: {
                        HStack {
                            Text("Automatic"); Spacer()
                            if current.coverSceneID == nil { Image(systemName: "checkmark").accessibilityLabel("Selected") }
                        }.frame(minHeight: 44)
                    }
                } footer: { Text("Choose a scene for the cover. Automatic uses the first scene. Your movie stays the same.") }
                Section("Scenes") {
                    ForEach(Array(current.activeScenes.enumerated()), id: \.element.id) { index, scene in
                        if !scene.missing {
                            Button { save(scene.id) } label: {
                                HStack(spacing: 12) {
                                    SceneThumbnail(scene: scene, root: app.store.root, movie: current)
                                        .frame(width: 96, height: 68).clipShape(RoundedRectangle(cornerRadius: 8))
                                    Text("Scene \(index + 1)").foregroundStyle(.primary)
                                    Spacer()
                                    if current.coverSceneID == scene.id { Image(systemName: "checkmark").accessibilityLabel("Selected") }
                                }
                            }.accessibilityLabel("Scene \(index + 1)")
                                .accessibilityAddTraits(current.coverSceneID == scene.id ? [.isSelected] : [])
                        }
                    }
                }
            }.disabled(saving)
                .navigationTitle("Change Cover").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) } }
                .interactiveDismissDisabled(saving)
                .alert("Couldn’t Change Cover", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                    Button("OK") { error = nil }
                } message: { Text(error ?? "") }
        }
    }
}

struct MovieSettingsView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    let movie: Movie
    @AppStorage(FalseColorPreview.preferenceKey) private var falseColorEnabled = false
    @State private var originalLogPreview = UserDefaults.standard.bool(forKey: "originalLogPreview")
    @State private var profile: CaptureProfile
    @State private var selectedLook: LUTReference?
    @State private var supportsLog = false
    @State private var checking = true
    @State private var looks: [LUTReference] = []
    @State private var importingLook = false
    @State private var importingDisplayLook = false
    @State private var loadingLook = false
    @State private var saving = false
    @State private var problem: String?
    init(movie: Movie) {
        self.movie = movie
        _profile = State(initialValue: movie.captureProfile)
        _selectedLook = State(initialValue: movie.captureProfile == .appleLog ? movie.look : .cinema)
    }
    private var hasRecordedScenes: Bool { !movie.scenes.isEmpty || movie.lastRecordedAt != nil }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Recording", selection: $profile.withSelectionFeedback()) {
                        Text("Standard").tag(CaptureProfile.standard)
                        Text("Apple Log").tag(CaptureProfile.appleLog)
                    }.pickerStyle(.segmented)
                        .disabled(hasRecordedScenes || checking || !supportsLog || saving)
                } header: { Text("Recording") } footer: {
                    Text(hasRecordedScenes
                        ? "The recording format is set by your first scene."
                        : supportsLog ? "Choose Standard or Apple Log before your first recording." : "Apple Log is unavailable on this iPhone.")
                }
                if profile == .appleLog {
                    Section {
                        Picker("Preview Look", selection: $originalLogPreview.withSelectionFeedback()) {
                            Text("Cinema").tag(false)
                            Text("Log").tag(true)
                        }.pickerStyle(.segmented)
                        Toggle("False Color", isOn: $falseColorEnabled.withSelectionFeedback())
                    } header: { Text("Live Preview") } footer: {
                        Text("Cinema shows your selected look. Log shows the flat image. False Color temporarily replaces either preview with an exposure map. Blue/purple mark low exposure; green marks middle gray; orange/red mark high exposure. These are exposure guides, not guaranteed clipping limits. Recordings stay in Apple Log.")
                    }
                    Section {
                        Menu {
                            Button("Apple Standard") { UISelectionFeedbackGenerator().selectionChanged(); selectedLook = nil }
                            ForEach(looks, id: \.id) { look in
                                Button(look.displayName) { UISelectionFeedbackGenerator().selectionChanged(); selectedLook = look }
                            }
                        } label: {
                            HStack {
                                Text("Cinema Look")
                                Spacer()
                                Text(selectedLook?.displayName ?? "Apple Standard").foregroundStyle(.secondary)
                            }
                        }.foregroundStyle(.primary)
                        Button("Add Apple Log Look…", systemImage: "plus") { importingDisplayLook = false; importingLook = true }
                        Button("Add Rec.709 Look…", systemImage: "plus") { importingDisplayLook = true; importingLook = true }
                    } header: { Text("Cinema Look") } footer: {
                        Text("Applied to playback, export and Cinema preview. Your Apple Log originals stay intact.")
                    }
                }
                if let problem { Section { Text(problem).foregroundStyle(.red) } }
            }
            .disabled(saving || loadingLook)
            .navigationTitle("Movie Settings").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(saving || loadingLook)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        saving = true
                        Task {
                            do {
                                try await app.store.setMovieRecordingSettings(movieID: movie.id,
                                    profile: profile, look: selectedLook)
                                UserDefaults.standard.set(originalLogPreview, forKey: "originalLogPreview")
                                await app.refresh(); dismiss()
                            } catch { problem = error.localizedDescription; saving = false }
                        }
                    }.disabled(checking || saving || loadingLook)
                }
            }
            .task {
                supportsLog = await Task.detached { CaptureService.supportsAppleLog() }.value
                looks = await app.store.availableLooks()
                checking = false
            }
            .fileImporter(isPresented: $importingLook,
                allowedContentTypes: [UTType(filenameExtension: "cube") ?? .data],
                allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    loadingLook = true
                    Task {
                        defer { loadingLook = false }
                        do {
                            selectedLook = try await app.store.importLook(from: url, displayReferred: importingDisplayLook)
                            looks = await app.store.availableLooks()
                        } catch { problem = error.localizedDescription }
                    }
                case .failure(let error): problem = error.localizedDescription
                }
            }
        }.presentationDetents([.medium, .large]).interactiveDismissDisabled(saving || loadingLook)
    }
}

struct SettingsView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("openLastMovie") private var openLastMovie = false
    @AppStorage("copyScenesToPhotos") private var copyScenesToPhotos = false
    @State private var backups = false
    @State private var recovery = false
    @State private var storage: SettingsStorage?
    private var summary: SettingsSummary { SettingsSummary(movies: app.movies) }
    private func bytes(_ value: Int64?) -> String {
        value.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Unavailable"
    }
    private func refreshStorage() async { storage = await app.store.settingsStorage() }
    private var supportURL: URL { URL(string: "https://home-movie-support.falcon-craft-4475.chatgpt.site/")! }
    private var storageSection: some View {
        Section {
            LabeledContent("Active Footage", value: bytes(summary.activeBytes))
            NavigationLink {
                RecentlyDeletedView().environmentObject(app)
            } label: {
                LabeledContent("Recently Deleted", value: bytes(summary.deletedBytes))
            }
            if let storage {
                LabeledContent("Temporary Exports", value: bytes(storage.temporaryExportBytes))
                if storage.pendingCleanupBytes == nil || (storage.pendingCleanupBytes ?? 0) > 0 {
                    LabeledContent("Pending Cleanup", value: bytes(storage.pendingCleanupBytes))
                }
                LabeledContent("Available on iPhone", value: bytes(storage.availableBytes))
            } else { ProgressView("Checking storage…") }
        } header: { Text("Storage") }
        footer: { Text("Footage totals exclude missing files. Temporary exports can be recreated; available space is shared with other apps.") }
    }
    private var backupSection: some View {
        Section {
            Button("Backup & Restore", systemImage: "archivebox") { backups = true }
            if let date = summary.latestFilesBackup {
                LabeledContent("Latest Files Backup") { Text(date, format: .dateTime.month(.abbreviated).day().hour().minute()) }
            } else { LabeledContent("Latest Files Backup", value: "Not yet saved") }
            LabeledContent("Movies Needing Backup", value: "\(summary.moviesNeedingBackup)")
            Toggle("Copy Original Scenes to Photos", isOn: $copyScenesToPhotos.withSelectionFeedback())
                .onChange(of: copyScenesToPhotos) { _, enabled in
                    if enabled { app.retryPhotosCopies() } else { app.stopPhotosRetries() }
                }
            if copyScenesToPhotos {
                LabeledContent("Awaiting Photos Copy", value: "\(summary.pendingPhotosCopies)")
                if summary.pendingPhotosCopies > 0 {
                    Button("Retry Photos Copies") { app.retryPhotosCopies() }
                }
                if let status = app.photosCopyStatus { Text(status).font(.footnote).foregroundStyle(.secondary) }
            }
            Button("Recording Recovery", systemImage: "arrow.counterclockwise") { recovery = true }
        } header: { Text("Backup & Recovery") }
        footer: {
            Text("Latest Files Backup may cover only part of your library. See Backup & Restore for each movie’s status. Photos copies use extra space and don’t preserve editable projects.")
        }
    }
    private var helpSection: some View {
        Section {
            Link(destination: supportURL) {
                Label("Contact Support", systemImage: "bubble.left.and.bubble.right")
            }.accessibilityHint("Opens the public support page with email contact information.")
            NavigationLink("Diagnostics", destination: DiagnosticsView())
            NavigationLink("Privacy", destination: PrivacyView())
            Button("App Permissions", systemImage: "hand.raised") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
        } header: { Text("Help & Privacy") }
        footer: { Text("Contact Support opens our public help page. Tap Email MOVIE MODE Support there, or copy the contact address into your email service. App Permissions opens iPhone Settings for camera, microphone, and Photos access.") }
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("General") {
                    Toggle("Open Last Movie", isOn: $openLastMovie.withSelectionFeedback())
                }
                storageSection
                backupSection
                helpSection
                Section("About") {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                    LabeledContent("Build", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—")
                }
            }.navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
                .task { await app.refresh(); await refreshStorage() }
                .onChange(of: app.movies) { _, _ in Task { await refreshStorage() } }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await app.refresh(); await refreshStorage() } }
                }
        }
        .sheet(isPresented: $backups, onDismiss: { Task { await refreshStorage() } }) { BackupView() }
        .sheet(isPresented: $recovery, onDismiss: { Task { await refreshStorage() } }) { RecordingRecoveryView() }
    }
}


struct PrivacyView: View {
    var body: some View {
        List {
            Section {
                Link("Privacy Policy", destination: URL(string: "https://home-movie-support.falcon-craft-4475.chatgpt.site/privacy/")!)
            }
            Section("Your movies") {
                Text("MOVIE MODE keeps recordings and edit information on this iPhone. It has no account system, advertising, or analytics service, and does not upload your movies to a developer server.")
            }
            Section("Diagnostics") {
                Text("A bounded support log and Apple performance/crash reports stay on this iPhone. Reports can include technical device information and stack traces. They are shared only when you choose Share Diagnostics; no developer analytics endpoint receives them automatically.")
            }
            Section("Permissions") {
                Text("Camera and microphone access record video and sound. Photos access only adds copies when you choose to save a movie or enable original-scene copies. MOVIE MODE does not request access to read your photo library.")
            }
            Section("Copies and backups") {
                Text("When you save or share, the destination you choose handles that copy. Files backups include original recordings and project metadata. iCloud Drive and iCloud Photos follow your Apple settings; MOVIE MODE does not confirm completed cloud syncing.")
            }
            Section("Deleting footage") {
                Text("Recently Deleted keeps original files until you choose Delete Permanently. Copies saved to Photos, Files, or backups remain separate and must be managed at those destinations. Deleting this app can remove its local projects.")
            }
        }.navigationTitle("Privacy").navigationBarTitleDisplayMode(.inline)
    }
}
