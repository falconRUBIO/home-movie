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

final class PreviewUIView: UIView, UIGestureRecognizerDelegate {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    var onFocus: ((CGPoint, Bool) -> Bool)?
    var onExposure: ((Float) -> Void)?
    var exposureBias: Float = 0
    var exposureRange: ClosedRange<Float> = -2...2
    var locked = false
    private let focusIndicator = UIView()
    private let sun = UIImageView(image: UIImage(systemName: "sun.max.fill"))
    private var dragBias: Float = 0
    private var lastExposureAt = Date.distantPast
    private var hideIndicator: DispatchWorkItem?
    override init(frame: CGRect) {
        super.init(frame: frame)
        focusIndicator.bounds = CGRect(x: 0, y: 0, width: 68, height: 68)
        focusIndicator.layer.borderColor = UIColor.systemYellow.cgColor
        focusIndicator.layer.borderWidth = 1.5
        focusIndicator.layer.cornerRadius = 3
        focusIndicator.isUserInteractionEnabled = false
        focusIndicator.alpha = 0
        addSubview(focusIndicator)
        sun.tintColor = .systemYellow
        sun.bounds = CGRect(x: 0, y: 0, width: 20, height: 20)
        sun.isUserInteractionEnabled = false
        sun.alpha = 0
        addSubview(sun)
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(focusHeld(_:)))
        hold.minimumPressDuration = 0.5
        addGestureRecognizer(hold)
        let tap = UITapGestureRecognizer(target: self, action: #selector(focusTapped(_:)))
        tap.require(toFail: hold)
        tap.cancelsTouchesInView = false
        addGestureRecognizer(tap)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(exposureDragged(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        addGestureRecognizer(pan)
    }
    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }
    @objc private func focusTapped(_ gesture: UITapGestureRecognizer) {
        requestFocus(at: gesture.location(in: self), locked: false)
    }
    @objc private func focusHeld(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        requestFocus(at: gesture.location(in: self), locked: true)
    }
    private func requestFocus(at point: CGPoint, locked: Bool) {
        let devicePoint = previewLayer.captureDevicePointConverted(fromLayerPoint: point)
        guard onFocus?(devicePoint, locked) == true else { return }
        self.locked = locked
        if !locked { exposureBias = 0 }
        hideIndicator?.cancel()
        focusIndicator.layer.removeAllAnimations()
        sun.layer.removeAllAnimations()
        focusIndicator.center = CGPoint(x: min(max(36, point.x), max(36, bounds.width - 36)),
                                        y: min(max(36, point.y), max(36, bounds.height - 36)))
        focusIndicator.alpha = 1; sun.alpha = 1
        focusIndicator.transform = CGAffineTransform(scaleX: 1.2, y: 1.2)
        positionSun()
        UIView.animate(withDuration: 0.18) { self.focusIndicator.transform = .identity }
        if locked { UISelectionFeedbackGenerator().selectionChanged() }
        scheduleHide()
    }
    func updateMetering(_ options: CameraOptions) {
        let wasLocked = locked
        exposureBias = options.exposureBias
        exposureRange = options.minimumExposureBias...options.maximumExposureBias
        locked = options.focusLocked
        positionSun()
        if wasLocked && !locked { scheduleHide() }
    }
    private func positionSun() {
        let right = focusIndicator.center.x + 50
        sun.center = CGPoint(x: right < bounds.width - 14 ? right : focusIndicator.center.x - 50,
                             y: focusIndicator.center.y - CGFloat(exposureBias) * 12)
    }
    private func scheduleHide() {
        hideIndicator?.cancel()
        guard !locked else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            UIView.animate(withDuration: 0.3) { self.focusIndicator.alpha = 0; self.sun.alpha = 0 }
        }
        hideIndicator = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        let location = pan.location(in: self)
        let velocity = pan.velocity(in: self)
        return focusIndicator.alpha > 0.1 && abs(location.x - focusIndicator.center.x) < 90 &&
            abs(location.y - focusIndicator.center.y) < 120 && abs(velocity.y) > abs(velocity.x)
    }
    @objc private func exposureDragged(_ gesture: UIPanGestureRecognizer) {
        if gesture.state == .began { dragBias = exposureBias; hideIndicator?.cancel() }
        let bias = min(exposureRange.upperBound, max(exposureRange.lowerBound,
            dragBias - Float(gesture.translation(in: self).y / 90)))
        exposureBias = bias; positionSun()
        let finished = gesture.state == .ended || gesture.state == .cancelled
        if Date().timeIntervalSince(lastExposureAt) > 0.05 || finished {
            onExposure?(bias); lastExposureAt = Date()
        }
        if finished { scheduleHide() }
    }
}
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let angle: CGFloat
    let front: Bool
    let options: CameraOptions?
    let onFocus: (CGPoint, Bool) -> Bool
    let onExposure: (Float) -> Void
    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView(); view.backgroundColor = .black
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.onFocus = onFocus; view.onExposure = onExposure
        return view
    }
    func updateUIView(_ view: PreviewUIView, context: Context) {
        view.onFocus = onFocus; view.onExposure = onExposure
        if let options { view.updateMetering(options) }
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
