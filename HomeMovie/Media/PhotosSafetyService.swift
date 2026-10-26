import Foundation
import Photos

private final class PhotoReceipt: @unchecked Sendable {
    private let lock = NSLock()
    private var identifier: String?
    func set(_ value: String?) { lock.lock(); defer { lock.unlock() }; identifier = value }
    func get() -> String? { lock.lock(); defer { lock.unlock() }; return identifier }
}
enum PhotosVideoWriter {
    static func write(_ source: URL) async throws -> String {
        let receipt = PhotoReceipt()
        try Task.checkCancellation()
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: source)
            receipt.set(request?.placeholderForCreatedAsset?.localIdentifier)
        }
        guard let identifier = receipt.get(), !identifier.isEmpty else {
            throw HomeMovieError.message("Photos did not confirm a saved video. Your original stays in MOVIE MODE; try again or save to Files.")
        }
        return identifier
    }
}

actor PhotosSafetyService {
    private var copying: Set<UUID> = []
    func authorize() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        return status == .authorized || status == .limited
    }
    func copy(scene: Scene, store: ProjectStore) async throws {
        guard scene.photosAssetID == nil, !copying.contains(scene.id) else { return }
        let current = await store.snapshot().flatMap(\.scenes).first { $0.id == scene.id }
        guard let current, current.photosAssetID == nil, !copying.contains(scene.id) else { return }
        copying.insert(scene.id); defer { copying.remove(scene.id) }
        guard await authorize() else { throw HomeMovieError.message("Photos copy is not enabled by permission. The clip remains saved in MOVIE MODE.") }
        try Task.checkCancellation()
        let source = try await store.url(scene.source)
        let identifier = try await PhotosVideoWriter.write(source)
        try await store.markPhotosCopy(sceneID: scene.id, assetID: identifier)
    }
}
