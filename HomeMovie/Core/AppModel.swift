import SwiftUI
import AVFoundation

@MainActor final class AppModel: ObservableObject {
    let store: ProjectStore
    lazy var camera = CameraModel(app: self)
    private var cameraWarmup: Task<Void, Never>?
    let assembler = MediaAssembler()
    let photosSafety = PhotosSafetyService()
    @Published var copiedSceneAdjustments: SceneAdjustmentClipboard?
    @Published var movies: [Movie] = []
    @Published var loaded = false
    private var loading = false
    private var photosRetryTask: Task<Void, Never>?
    @Published var error: String?
    @Published var loadFailure: String?
    @Published var photosCopyStatus: String?
    @Published var recoveryNotice: String?
    @Published var storageBytes: Int64 = 0
    init(store: ProjectStore = ProjectStore()) { self.store = store; ReliabilityDiagnostics.shared.record(.appLaunched) }
    var activeMovies: [Movie] { movies.filter { $0.deletedAt == nil } }
    func movie(_ id: UUID) -> Movie? { movies.first { $0.id == id } }
    func prewarmCamera(movieID: UUID) {
        guard let movie = movie(movieID) else { return }
        let camera = camera
        cameraWarmup?.cancel()
        cameraWarmup = Task {
            guard !Task.isCancelled else { return }
            await camera.prepare(profile: movie.captureProfile, movieID: movieID,
                dualCamera: movie.dualCameraCapture == true, layout: movie.preferredPiPLayout,
                canvasFormat: movie.recordingFormat, enablePiP: movie.dualCameraCapture == true)
        }
    }
    func cancelCameraWarmup() { cameraWarmup?.cancel(); cameraWarmup = nil }
    func load() async {
        guard !loading else { return }; loading = true
        defer { loading = false }
        do {
            let notices = try await store.load()
            recoveryNotice = notices.isEmpty ? nil : notices.joined(separator: "\n")
            await refresh(); loaded = true; loadFailure = nil
            if UserDefaults.standard.bool(forKey: "copyScenesToPhotos") { retryPhotosCopies() }
        } catch { loaded = false; self.error = error.localizedDescription; loadFailure = error.localizedDescription }
    }
    func createQuickMovie() async throws -> Movie {
        let movie = try await store.createQuickMovie()
        // Creation changes no media totals. Publish the durable movie immediately;
        // a second full catalog refresh only delays camera navigation.
        movies.insert(movie, at: 0)
        return movie
    }
    func refresh() async { movies = await store.snapshot(); storageBytes = await store.storageBytes() }
    func run(_ operation: () async throws -> Void) async {
        do { try await operation(); await refresh() } catch { self.error = error.localizedDescription }
    }
    func copySceneToPhotos(_ id: UUID) {
        guard UserDefaults.standard.bool(forKey: "copyScenesToPhotos"),
              let scene = movies.flatMap(\.scenes).first(where: { $0.id == id }), scene.photosAssetID == nil else { return }
        Task {
            guard UserDefaults.standard.bool(forKey: "copyScenesToPhotos") else { return }
            do { try await photosSafety.copy(scene: scene, store: store); await refresh(); photosCopyStatus = "Original clip copied to Photos." }
            catch { photosCopyStatus = "\(error.localizedDescription) Retry from Settings." }
        }
    }
    func retryPhotosCopies() {
        guard loaded, photosRetryTask == nil, UserDefaults.standard.bool(forKey: "copyScenesToPhotos") else { return }
        let pending = activeMovies.flatMap(\.activeScenes).filter { !$0.missing && $0.photosAssetID == nil }
        photosRetryTask = Task {
            defer { photosRetryTask = nil }
            guard !Task.isCancelled, UserDefaults.standard.bool(forKey: "copyScenesToPhotos") else { return }
            guard await photosSafety.authorize() else { photosCopyStatus = "Allow add-only Photos access in Settings to create separate clip copies."; return }
            for scene in pending {
                guard !Task.isCancelled, UserDefaults.standard.bool(forKey: "copyScenesToPhotos") else { return }
                do { try await photosSafety.copy(scene: scene, store: store); await refresh() }
                catch { if !(error is CancellationError) { photosCopyStatus = error.localizedDescription }; return }
            }
            photosCopyStatus = pending.isEmpty ? "No clips awaiting a Photos copy." : "Saved original clips were copied to Photos."
        }
    }
    func stopPhotosRetries() { photosRetryTask?.cancel() }

}
