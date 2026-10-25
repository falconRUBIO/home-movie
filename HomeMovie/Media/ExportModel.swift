import SwiftUI
import AVFoundation
import Photos
import UIKit

@MainActor final class ExportModel: ObservableObject {
    @Published var running = false
    @Published var progress = 0.0
    @Published var exportedURL: URL?
    @Published var error: String?
    @Published var notice: String?
    @Published var saveFeedback: SaveToast?
    private var session: AVAssetExportSession?
    private var job: Task<Void, Never>?
    private var backgroundObserver: NSObjectProtocol?
    private var thermalObserver: NSObjectProtocol?
    private var committedRevision: Int?
    private var committedMovieID: UUID?
    private var savingPhotos = false
    private let authorizePhotos: @Sendable () async -> Bool
    private let writePhotosVideo: @Sendable (URL) async throws -> String
    init(authorizePhotos: @escaping @Sendable () async -> Bool = {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        return status == .authorized || status == .limited
    }, writePhotosVideo: @escaping @Sendable (URL) async throws -> String = {
        try await PhotosVideoWriter.write($0)
    }) {
        self.authorizePhotos = authorizePhotos; self.writePhotosVideo = writePhotosVideo
        backgroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.running else { return }
                self.notice = "Export paused by leaving the app. Keep MOVIE MODE open and export again."
                self.cancel()
            }
        }
        thermalObserver = NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.running, ProcessInfo.processInfo.thermalState == .critical else { return }
                ReliabilityDiagnostics.shared.record(.resourcePressure)
                self.notice = "Export paused because your iPhone is too warm. Let it cool, then export again."
                self.cancel()
            }
        }
    }
    deinit {
        if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
        if let thermalObserver { NotificationCenter.default.removeObserver(thermalObserver) }
    }
    static func matchesExport(_ info: MediaInfo, movie: Movie) -> Bool {
        abs(info.duration.seconds - movie.duration.seconds) < 0.15 &&
        abs(info.size.width - movie.format.canvas.width) < 1 &&
        abs(info.size.height - movie.format.canvas.height) < 1 &&
        info.hasAudio == movie.activeScenes.contains(where: { $0.hasAudio })
    }
    static func cachePrefix(movie: Movie) -> String {
        "\(movie.id)-r\(movie.revision)-grade10v1-audio2-light\(SceneAdjustments.engineVersion)-film\(FilmEffectsSettings.engineVersion)-\(movie.exportEffects.cacheIdentity)-"
    }
    static func singleSceneMovie(movie: Movie, scene: Scene) throws -> Movie {
        guard movie.activeScenes.contains(where: { $0.id == scene.id }), scene.deletedAt == nil,
              !scene.missing, scene.validTrim else { throw HomeMovieError.message("This scene is unavailable.") }
        try scene.lightAdjustments.validate()
        try scene.filmEffectsTweaks?.validate()
        var clip = movie
        // Scene identity separates clip caches from the full movie and other clips.
        clip.id = scene.id; clip.scenes = [scene]
        clip.name = "Scene \(scene.sequence + 1)"
        return clip
    }
    func invalidate() {
        guard !running else { return }
        exportedURL = nil; committedRevision = nil; committedMovieID = nil; progress = 0; notice = nil
    }
    func start(movie: Movie, app: AppModel) {
        guard !running else { return }
        if committedMovieID == movie.id, committedRevision == movie.revision,
           let exportedURL, FileManager.default.fileExists(atPath: exportedURL.path) { return }
        ReliabilityDiagnostics.shared.record(.exportRequested)
        exportedURL = nil; running = true; progress = 0; error = nil; notice = nil
        job = Task {
            var output: URL?
            do {
                guard movie.duration.isNumeric, movie.duration.seconds.isFinite, movie.duration.seconds > 0 else {
                    throw HomeMovieError.message("The movie has no valid playable duration.")
                }
                let seconds = movie.duration.seconds
                let directory = URL.cachesDirectory.appendingPathComponent("Exports", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let prefix = Self.cachePrefix(movie: movie)
                let candidates = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                for candidate in candidates where candidate.lastPathComponent.hasPrefix(prefix) && candidate.pathExtension == "mp4" {
                    try Task.checkCancellation()
                    if let info = try? await MediaInspector.inspect(candidate), Self.matchesExport(info, movie: movie) {
                        try Task.checkCancellation()
                        ReliabilityDiagnostics.shared.record(.exportFinished)
                        exportedURL = candidate; committedRevision = movie.revision; committedMovieID = movie.id
                        progress = 1; running = false; job = nil; return
                    }
                }
                try await app.store.requireSpace(bytes: Int64(min(seconds * 4_000_000, Double(Int64.max / 2))) + 300_000_000)
                guard ProcessInfo.processInfo.thermalState != .critical else {
                    throw HomeMovieError.message("Let your iPhone cool before exporting again.")
                }
                let bundle = try await app.assembler.build(movie: movie, root: app.store.root, filmEffects: movie.exportEffects)
                try Task.checkCancellation()
                let destination = directory.appendingPathComponent("\(prefix)\(UUID()).mp4")
                output = destination
                let usesLog = movie.captureProfile == .appleLog || movie.activeScenes.contains { $0.profile == .appleLog }
                if usesLog {
                    try await GradedMovieExporter.export(bundle, to: destination) { [weak self] value in
                        await self?.updateProgress(value)
                    }
                } else {
                    guard let export = AVAssetExportSession(asset: bundle.asset, presetName: AVAssetExportPresetHighestQuality), export.supportedFileTypes.contains(.mp4) else {
                        throw HomeMovieError.message("MP4 export is not supported for this movie.")
                    }
                    session = export; export.videoComposition = bundle.videoComposition; export.audioMix = bundle.audioMix
                    export.shouldOptimizeForNetworkUse = true
                    let progressTask = Task { [weak self] in
                        for await state in export.states(updateInterval: 0.2) {
                            if Task.isCancelled { break }
                            if case .exporting(let progress) = state { self?.progress = progress.fractionCompleted }
                        }
                    }
                    defer { progressTask.cancel() }
                    try await export.export(to: destination, as: .mp4)
                }
                try Task.checkCancellation()
                let info = try await MediaInspector.inspect(destination)
                guard Self.matchesExport(info, movie: movie) else {
                    throw HomeMovieError.message("The exported duration, frame size or audio did not match your movie. Please try again.")
                }
                ReliabilityDiagnostics.shared.record(.exportFinished)
                exportedURL = destination; committedRevision = movie.revision; committedMovieID = movie.id; progress = 1
            } catch {
                ReliabilityDiagnostics.shared.record(error is CancellationError || notice != nil ? .exportCancelled : .exportFailed, error: error)
                if let output { try? FileManager.default.removeItem(at: output) }
                if !(error is CancellationError) && notice == nil { self.error = error.localizedDescription }
            }
            session = nil; running = false; job = nil
        }
    }
    private func updateProgress(_ value: Double) { progress = value }
    func cancel() { if running && notice == nil { notice = "Export canceled. Your original scenes are safe." }; session?.cancelExport(); job?.cancel() }
    func saveToPhotos() async {
        guard !savingPhotos else { return }
        guard let exportedURL else {
            saveFeedback = SaveToast(kind: .failure, message: "Prepare the video before saving.")
            return
        }
        savingPhotos = true; defer { savingPhotos = false }
        error = nil; notice = nil
        saveFeedback = SaveToast(kind: .saving, message: "Saving to Photos…")
        guard await authorizePhotos() else {
            error = "Allow MOVIE MODE to add videos to Photos in Settings, or save to Files instead."
            saveFeedback = SaveToast(kind: .failure, message: "Photos access needed. Check Settings.")
            return
        }
        do {
            let identifier = try await writePhotosVideo(exportedURL)
            guard !identifier.isEmpty else { throw HomeMovieError.message("Photos did not confirm a saved video. Try again or save to Files.") }
            notice = "Saved to Photos. You can keep adding to your movie."
            saveFeedback = SaveToast(kind: .success, message: "Saved to Photos")
        } catch {
            self.error = error.localizedDescription
            saveFeedback = SaveToast(kind: .failure, message: "Couldn’t save to Photos. Please try again.")
        }
    }
}
