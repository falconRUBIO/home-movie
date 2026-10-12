import SwiftUI
import AVFoundation
import UIKit
import UniformTypeIdentifiers
import MetalKit

struct LogLookBadge: View {
    let lookName: String
    var body: some View {
        Text("LOG · \(lookName)")
            .font(.caption2.weight(.medium))
            .foregroundStyle(.white.opacity(0.8))
            .shadow(color: .black.opacity(0.8), radius: 2)
            .accessibilityLabel("Apple Log, \(lookName) view")
            .allowsHitTesting(false)
    }
}

struct MovieControlIcon: View {
    let systemName: String
    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 18, weight: .medium))
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }
}

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
    func image(scene: Scene, root: URL, movie: Movie? = nil) async throws -> UIImage {
        let key = "\(root.path)-\(scene.id)-\(scene.trimStart.value)-\(scene.trimStart.scale)-\(movie?.revision ?? 0)-\(movie?.look?.id.uuidString ?? "standard")" as NSString
        if let image = cache.object(forKey: key) { return image }
        let generator: AVAssetImageGenerator
        let time: CMTime
        if (scene.profile ?? movie?.captureProfile ?? .standard) == .appleLog {
            var preview = movie ?? Movie(name: "Preview", format: scene.width > scene.height ? .landscape : .portrait)
            preview.scenes = [scene]
            preview.profile = .appleLog
            let bundle = try await MediaAssembler().build(movie: preview, root: root)
            generator = AVAssetImageGenerator(asset: bundle.asset)
            generator.videoComposition = bundle.videoComposition
            time = .zero
        } else {
            let asset = AVURLAsset(url: root.appendingPathComponent(scene.source))
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard let track = tracks.first else { throw HomeMovieError.message("No preview available.") }
            let range = try await track.load(.timeRange)
            generator = AVAssetImageGenerator(asset: asset)
            time = CMTimeAdd(range.start, scene.trimStart.cmTime)
        }
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 700, height: 700)
        let (cg, _) = try await generator.image(at: time)
        let image = UIImage(cgImage: cg)
        cache.setObject(image, forKey: key, cost: cg.bytesPerRow * cg.height); return image
    }
}

struct SceneThumbnail: View {
    let scene: Scene?
    let root: URL
    var movie: Movie? = nil
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
        .task(id: scene.map { "\($0.id)-\($0.trimStart.value)-\($0.trimStart.scale)-\(movie?.revision ?? 0)-\(movie?.look?.id.uuidString ?? "standard")" }) {
            image = nil
            guard let scene, !scene.missing else { return }
            let result = try? await ThumbnailService.shared.image(scene: scene, root: root, movie: movie)
            guard !Task.isCancelled else { return }
            image = result
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
    private var focusDevicePoint: CGPoint?
    var fixedFormat: MovieFormat?
    private var showingFront = false
    private var lookView: MTKView?
    private var lookRenderer: LiveLookRenderer?
    var onLiveLookStatus: ((LiveLookStatus) -> Void)?
    func configureLiveLook(frames: LiveFrames?, cube: ColorCube?, active: Bool) {
        if lookView == nil, active, cube != nil, let device = MTLCreateSystemDefaultDevice(), let renderer = LiveLookRenderer(device: device) {
            let view = MTKView(frame: bounds, device: device)
            view.isUserInteractionEnabled = false; view.framebufferOnly = false
            view.colorPixelFormat = .bgra8Unorm; (view.layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.itur_709)
            view.autoResizeDrawable = false; view.isPaused = true; view.enableSetNeedsDisplay = false
            view.preferredFramesPerSecond = 30; view.isOpaque = false; view.backgroundColor = .clear
            view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0); view.isHidden = true
            view.delegate = renderer; insertSubview(view, at: 0)
            renderer.onStatusChanged = { [weak self] status in self?.onLiveLookStatus?(status) }
            lookView = view; lookRenderer = renderer
        }
        // The Metal display loop reads only the latest frame. Keep its layer visible at full
        // opacity so drawable acquisition never depends on a first-render alpha handshake.
        lookRenderer?.frames?.setListener(nil)
        lookRenderer?.configure(frames: frames, cube: cube, active: active)
        lookRenderer?.front = showingFront
        resizeLookView()
        let enabled = active && cube != nil && frames != nil
        lookView?.alpha = 1; lookView?.isHidden = !enabled; lookView?.isPaused = !enabled
        if enabled, lookRenderer == nil { onLiveLookStatus?(.unavailable) }
    }
    private func resizeLookView() {
        lookView?.frame = bounds
        let scale = min(window?.screen.scale ?? 2, 1920 / max(1, max(bounds.width, bounds.height)))
        lookView?.drawableSize = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
    }
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    func updatePreviewRotation(fallback: CGFloat) {
        let device = previewLayer.session?.inputs.compactMap { $0 as? AVCaptureDeviceInput }
            .first { $0.device.hasMediaType(.video) }?.device
        if let device, rotationCoordinator?.device?.uniqueID != device.uniqueID {
            rotationObservation = nil
            let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
            rotationCoordinator = coordinator
            rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.applyPreviewRotation() }
            }
        }
        applyPreviewRotation(fallback: fallback)
    }
    private func applyPreviewRotation(fallback: CGFloat = 90) {
        guard let connection = previewLayer.connection else { return }
        let angle = fixedFormat.map { OrientationPolicy.shared.captureAngle(format: $0, observed: fallback) }
            ?? rotationCoordinator?.videoRotationAngleForHorizonLevelPreview ?? fallback
        if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
        lookRenderer?.angle = angle
        repositionIndicator()
    }
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
        focusDevicePoint = devicePoint
        self.locked = locked
        if !locked { exposureBias = 0 }
        hideIndicator?.cancel()
        focusIndicator.layer.removeAllAnimations()
        sun.layer.removeAllAnimations()
        repositionIndicator()
        focusIndicator.alpha = 1; sun.alpha = 1
        focusIndicator.transform = CGAffineTransform(scaleX: 1.2, y: 1.2)
        positionSun()
        UIView.animate(withDuration: 0.18) { self.focusIndicator.transform = .identity }
        if locked { UISelectionFeedbackGenerator().selectionChanged() }
        scheduleHide()
    }
    override func layoutSubviews() {
        super.layoutSubviews(); resizeLookView()
        applyPreviewRotation()
        repositionIndicator()
    }
    func setFront(_ front: Bool) {
        guard showingFront != front else { return }
        showingFront = front
        lookRenderer?.front = front; focusDevicePoint = nil; hideIndicator?.cancel()
        focusIndicator.layer.removeAllAnimations(); sun.layer.removeAllAnimations()
        focusIndicator.alpha = 0; sun.alpha = 0
    }
    func repositionIndicator() {
        guard let focusDevicePoint else { return }
        let point = previewLayer.layerPointConverted(fromCaptureDevicePoint: focusDevicePoint)
        guard point.x.isFinite, point.y.isFinite else { return }
        focusIndicator.center = CGPoint(x: min(max(36, point.x), max(36, bounds.width - 36)),
                                        y: min(max(36, point.y), max(36, bounds.height - 36)))
        positionSun()
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
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
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
    var liveFrames: LiveFrames? = nil
    var liveCube: ColorCube? = nil
    var liveActive = false
    var onLiveLookStatus: ((LiveLookStatus) -> Void)? = nil
    var fixedFormat: MovieFormat? = nil
    let onFocus: (CGPoint, Bool) -> Bool
    let onExposure: (Float) -> Void
    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView(); view.backgroundColor = .black
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.onFocus = onFocus; view.onExposure = onExposure
        return view
    }
    static func dismantleUIView(_ view: PreviewUIView, coordinator: ()) {
        view.configureLiveLook(frames: nil, cube: nil, active: false)
    }
    func updateUIView(_ view: PreviewUIView, context: Context) {
        view.onFocus = onFocus; view.onExposure = onExposure
        view.fixedFormat = fixedFormat
        view.onLiveLookStatus = onLiveLookStatus
        view.setFront(front)
        view.configureLiveLook(frames: liveFrames, cube: liveCube, active: liveActive)
        if let options { view.updateMetering(options) }
        guard let connection = view.previewLayer.connection else { return }
        view.updatePreviewRotation(fallback: angle)
        connection.automaticallyAdjustsVideoMirroring = false
        if connection.isVideoMirroringSupported { connection.isVideoMirrored = front }
        view.repositionIndicator()
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
