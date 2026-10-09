import SwiftUI
import AVFoundation
import UIKit
import UniformTypeIdentifiers

extension View {
    @ViewBuilder func homeGlass(interactive: Bool = true) -> some View {
        if #available(iOS 26.0, *) {
            if interactive { self.glassEffect(.regular.interactive(), in: Capsule()) }
            else { self.glassEffect(.regular, in: Capsule()) }
        } else { self.background(.regularMaterial, in: Capsule()) }
    }
}

actor ThumbnailService {
    static let shared = ThumbnailService()
    private let cache = NSCache<NSString, UIImage>()
    init() { cache.countLimit = 48; cache.totalCostLimit = 32 * 1024 * 1024 }
    func image(scene: Scene, root: URL) async throws -> UIImage {
        let key = "\(scene.id)-\(scene.trimStart.value)-\(scene.trimStart.scale)" as NSString
        if let image = cache.object(forKey: key) { return image }
        let asset = AVURLAsset(url: root.appendingPathComponent(scene.source))
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else { throw HomeMovieError.message("No preview available.") }
        let range = try await track.load(.timeRange)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 700, height: 700)
        let (cg, _) = try await generator.image(at: CMTimeAdd(range.start, scene.trimStart.cmTime))
        let image = UIImage(cgImage: cg)
        cache.setObject(image, forKey: key, cost: cg.bytesPerRow * cg.height); return image
    }
}

struct SceneThumbnail: View {
    let scene: Scene?
    let root: URL
    @State private var image: UIImage?
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color(uiColor: .secondarySystemGroupedBackground)
                if let image { Image(uiImage: image).resizable().scaledToFill().frame(width: proxy.size.width, height: proxy.size.height).clipped() }
                else { Image(systemName: "film").font(.title2).foregroundStyle(.secondary) }
            }
        }
        .accessibilityHidden(true)
        .task(id: scene.map { "\($0.id)-\($0.trimStart.value)" }) {
            image = nil
            guard let scene, !scene.missing else { return }
            image = try? await ThumbnailService.shared.image(scene: scene, root: root)
        }
    }
}

final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let angle: CGFloat
    let front: Bool
    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView(); view.backgroundColor = .black
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspect
        return view
    }
    func updateUIView(_ view: PreviewUIView, context: Context) {
        guard let connection = view.previewLayer.connection else { return }
        if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
        connection.automaticallyAdjustsVideoMirroring = false
        if connection.isVideoMirroringSupported { connection.isVideoMirrored = front }
    }
}

struct SystemShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
struct SystemFilesExporter: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        UIDocumentPickerViewController(forExporting: [url], asCopy: true)
    }
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
}

struct BackupFilesExporter: UIViewControllerRepresentable {
    let url: URL
    let finished: (Bool) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(finished: finished) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        picker.delegate = context.coordinator; return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let finished: (Bool) -> Void
        init(finished: @escaping (Bool) -> Void) { self.finished = finished }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { finished(!urls.isEmpty) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finished(false) }
    }
}
