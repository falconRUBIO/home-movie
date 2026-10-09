import SwiftUI
import AVFoundation

@MainActor final class AppModel: ObservableObject {
    let store = ProjectStore()
    let assembler = MediaAssembler()
    let photosSafety = PhotosSafetyService()
    @Published var movies: [Movie] = []
    @Published var loaded = false
    private var loading = false
    @Published var error: String?
    @Published var loadFailure: String?
    @Published var photosCopyStatus: String?
    @Published var recoveryNotice: String?
    @Published var storageBytes: Int64 = 0
    var activeMovies: [Movie] { movies.filter { $0.deletedAt == nil } }
    func movie(_ id: UUID) -> Movie? { movies.first { $0.id == id } }
    func load() async {
        guard !loading else { return }; loading = true
        defer { loading = false }
        do {
            let notices = try await store.load()
            recoveryNotice = notices.isEmpty ? nil : notices.joined(separator: "\n")
            await refresh(); loaded = true; loadFailure = nil
            if UserDefaults.standard.bool(forKey: "copyScenesToPhotos") { retryPhotosCopies() }
        } catch { self.error = error.localizedDescription; loadFailure = error.localizedDescription }
    }
    func refresh() async { movies = await store.snapshot(); storageBytes = await store.storageBytes() }
    func run(_ operation: () async throws -> Void) async {
        do { try await operation(); await refresh() } catch { self.error = error.localizedDescription }
    }
    func copySceneToPhotos(_ id: UUID) {
        guard UserDefaults.standard.bool(forKey: "copyScenesToPhotos"),
              let scene = movies.flatMap(\.scenes).first(where: { $0.id == id }), scene.photosAssetID == nil else { return }
        Task {
            do { try await photosSafety.copy(scene: scene, store: store); await refresh(); photosCopyStatus = "Original scene copied to Photos." }
            catch { photosCopyStatus = "\(error.localizedDescription) Retry from Settings." }
        }
    }
    func retryPhotosCopies() {
        guard loaded else { return }
        let pending = activeMovies.flatMap(\.activeScenes).filter { !$0.missing && $0.photosAssetID == nil }
        Task {
            guard await photosSafety.authorize() else { photosCopyStatus = "Allow add-only Photos access in Settings to create separate scene copies."; return }
            for scene in pending {
                do { try await photosSafety.copy(scene: scene, store: store); await refresh() }
                catch { photosCopyStatus = error.localizedDescription; return }
            }
            photosCopyStatus = pending.isEmpty ? "No scenes awaiting a Photos copy." : "Saved original scenes were copied to Photos."
        }
    }

}
