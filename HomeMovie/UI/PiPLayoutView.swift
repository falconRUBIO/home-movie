import SwiftUI
import MetalKit
import CoreImage

struct PiPControl: View {
    let enabled: Bool
    var unavailableReason: String? = nil
    let disabled: Bool
    let onToggle: () -> Void
    let onLayout: () -> Void
    var body: some View {
        MovieControlIcon(systemName: "rectangle.on.rectangle")
            .foregroundStyle(enabled ? .yellow : .white)
            .background(enabled ? Color.white.opacity(0.15) : .clear, in: Circle())
            .opacity(disabled || unavailableReason != nil ? 0.4 : 1).contentShape(Rectangle())
            .gesture(LongPressGesture(minimumDuration: 0.45).exclusively(before: TapGesture()).onEnded { value in
                guard !disabled else { return }
                switch value { case .first: onLayout(); case .second: onToggle() }
            })
            .accessibilityElement(children: .ignore).accessibilityAddTraits(.isButton)
            .accessibilityLabel("Picture-in-Picture").accessibilityValue(enabled ? "On" : "Off")
            .accessibilityHint(unavailableReason ?? (disabled ? "Prepare a compatible Dual Camera configuration before the next take." : "Tap to toggle. Hold for PiP Layout while idle."))
            .accessibilityAction { if !disabled { onToggle() } }
            .accessibilityAction(named: "PiP Layout") { if !disabled { onLayout() } }
    }
}

struct PiPLayoutView: View {
    @Binding var layout: PiPLayout
    let format: MovieFormat
    let rearFrames: LiveFrames
    let frontFrames: LiveFrames
    let ready: Bool
    let canPrepare: Bool
    let logMode: Bool
    var obstacles: [CGRect] = []
    let onPrepare: () -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    GeometryReader { area in
                        let size = PiPGeometry.fittedPreview(canvas: format.canvas,
                            available: CGSize(width: max(0, area.size.width - 32), height: max(0, area.size.height - 24)))
                        preview.frame(width: size.width, height: size.height)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .position(x: area.size.width / 2, y: area.size.height / 2)
                    }
                    .frame(height: geometry.size.height * (format == .portrait ? 0.49 : 0.38))
                    .background(Color.black)
                    Form {
                        Section {
                            Picker("Framing", selection: $layout.orientation) {
                                ForEach(PiPOrientation.allCases) { orientation in
                                    Text(orientation.title).tag(orientation)
                                }
                            }.pickerStyle(.segmented)
                            VStack(spacing: 12) {
                                HStack {
                                    Text("Zoom")
                                    Spacer()
                                    Text(String(format: "%.1f×", Double(layout.framingZoom)))
                                        .monospacedDigit().foregroundStyle(.secondary)
                                }
                                Slider(value: $layout.zoom, in: 1...2, step: 0.05)
                                    .accessibilityLabel("Presenter zoom")
                                    .accessibilityValue(String(format: "%.1f times", Double(layout.framingZoom)))
                                HStack {
                                    Text("Wider")
                                    Spacer()
                                    Text("Closer")
                                }.font(.caption).foregroundStyle(.secondary)
                            }
                        } header: { Text("Front Camera") } footer: {
                            Text("Frame yourself without turning your iPhone. The main video stays the same.")
                        }
                        Section("Inset") {
                            Picker("Size", selection: $layout.size) {
                                ForEach(PiPSize.allCases) { size in Text(size.title).tag(size) }
                            }.pickerStyle(.segmented)
                            Picker("Position", selection: $layout.corner) {
                                ForEach(PiPCorner.allCases) { corner in Text(corner.title).tag(corner) }
                            }
                        }
                        if !ready {
                            Section {
                                if logMode { Text(CameraCompatibility.logPiPExplanation) }
                                else { Button("Retry Live Preview", action: onPrepare).disabled(!canPrepare) }
                            } footer: {
                                Text(logMode ? "PiP is available in Standard movies." : canPrepare ? "Turn on both cameras for a live preview. PiP records at 1080p, 30 fps." : "Dual Camera is unavailable on this iPhone.")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Picture in Picture").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }.presentationDetents([.large]).presentationDragIndicator(.visible)
            .task {
                if !ready, canPrepare, !logMode { onPrepare() }
            }
    }
    private var preview: some View {
        ZStack {
            PiPCompositionPreview(rearFrames: rearFrames, frontFrames: frontFrames,
                layout: layout, format: format, obstacles: obstacles)
            if !ready {
                GeometryReader { geometry in
                    let rect = PiPGeometry.rect(layout: layout, canvas: format.canvas, obstacles: obstacles) ?? .zero
                    ZStack {
                        Color(white: 0.12)
                        Image(systemName: format == .portrait ? "rectangle.portrait" : "rectangle")
                            .font(.largeTitle).foregroundStyle(.white.opacity(0.3))
                        RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.2))
                            .overlay { Image(systemName: "person.fill").foregroundStyle(.white) }
                            .frame(width: rect.width * geometry.size.width, height: rect.height * geometry.size.height)
                            .position(x: rect.midX * geometry.size.width, y: rect.midY * geometry.size.height)
                    }
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel("\(format == .portrait ? "Portrait" : "Landscape") video with \(layout.orientation.title.lowercased()) presenter inset at \(layout.corner.title.lowercased())")
    }

}

struct PiPCompositionPreview: UIViewRepresentable {
    let rearFrames: LiveFrames
    let frontFrames: LiveFrames
    let layout: PiPLayout
    let format: MovieFormat
    var obstacles: [CGRect] = []
    var liveFrames: LiveFrames? = nil
    var paused = false
    var sourceFront = false
    func makeCoordinator() -> PiPLayoutRenderer? {
        MTLCreateSystemDefaultDevice().flatMap { PiPLayoutRenderer(device: $0) }
    }
    func makeUIView(context: Context) -> MTKView {
        let view = PiPMetalView(frame: .zero, device: context.coordinator?.device)
        view.framebufferOnly = false; view.colorPixelFormat = .bgra8Unorm
        view.isUserInteractionEnabled = false; view.preferredFramesPerSecond = 30
        view.autoResizeDrawable = false; view.enableSetNeedsDisplay = false
        view.isOpaque = true; view.backgroundColor = .black
        (view.layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        view.delegate = context.coordinator; return view
    }
    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator?.rear = rearFrames; context.coordinator?.front = frontFrames
        context.coordinator?.layout = layout; context.coordinator?.format = format
        context.coordinator?.obstacles = obstacles
        context.coordinator?.live = liveFrames
        context.coordinator?.sourceFront = sourceFront
        view.isPaused = paused
        (view as? PiPMetalView)?.resizeDrawable()
    }
    static func dismantleUIView(_ view: MTKView, coordinator: PiPLayoutRenderer?) { view.isPaused = true; view.delegate = nil }
}
// Size from view bounds before acquiring a drawable, never from last frame's texture.
final class PiPMetalView: MTKView {
    func resizeDrawable() {
        let scale = window?.screen.scale ?? 2
        let size = PiPFrameRenderer.previewCanvas(for: CGSize(width: bounds.width * scale, height: bounds.height * scale))
        if size != .zero, drawableSize != size { drawableSize = size }
    }
    override func layoutSubviews() { super.layoutSubviews(); resizeDrawable() }
    override func didMoveToWindow() { super.didMoveToWindow(); resizeDrawable() }
}
@MainActor final class PiPLayoutRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let context: CIContext
    private var rendering = false
    var sourceFront = false
    var live: LiveFrames?
    var rear: LiveFrames?
    var front: LiveFrames?
    var layout = PiPLayout()
    var format = MovieFormat.landscape
    var obstacles: [CGRect] = []
    init?(device: MTLDevice) {
        guard let queue = device.makeCommandQueue() else { return nil }
        self.device = device; self.queue = queue
        context = CIContext(mtlCommandQueue: queue, options: [.cacheIntermediates: false, .name: "HomeMovie.PiPLayout"]); super.init()
    }
    func image(background: CVPixelBuffer, presenter: CVPixelBuffer?, canvas: CGSize,
               backgroundAngle: CGFloat, presenterAngle: CGFloat, presentation: PiPPresentation) -> CIImage {
        PiPCompositor.image(background: background, presenter: presenter, canvas: canvas,
            backgroundAngle: backgroundAngle, presenterAngle: presenterAngle, presentation: presentation)
    }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { }
    func draw(in view: MTKView) {
        (view as? PiPMetalView)?.resizeDrawable()
        guard !rendering, !view.isPaused, view.bounds.width > 0, view.bounds.height > 0 else { return }
        let liveSource = live?.snapshot()
        guard let background = liveSource ?? rear?.snapshot(),
              let drawable = view.currentDrawable, let command = queue.makeCommandBuffer() else { return }
        let presenter = front?.snapshot()
        let canvas = CGSize(width: drawable.texture.width, height: drawable.texture.height)
        var image = image(background: background.buffer, presenter: live != nil ? liveSource?.pip?.presenter : presenter?.buffer,
            canvas: canvas,
            backgroundAngle: liveSource?.pip?.backgroundAngle ?? (live != nil ? background.angle ?? 90 :
                (MovieFormat.captureFormat(angle: background.angle ?? 90) ?? .portrait).recordingAngle(observed: background.angle ?? 90)),
            presenterAngle: liveSource?.pip?.presenterAngle ??
                (MovieFormat.captureFormat(angle: presenter?.angle ?? 90) ?? .portrait).recordingAngle(observed: presenter?.angle ?? 90),
            presentation: live != nil ? (liveSource?.pip?.presentation ?? PiPPresentation()) :
                PiPPresentation(rect: PiPGeometry.rect(layout: layout, canvas: format.canvas, obstacles: obstacles) ?? .zero,
                    opacity: 1, enabled: true, corner: layout.corner, zoom: layout.framingZoom))
        if live != nil, sourceFront, liveSource?.pip == nil {
            image = image.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: canvas.width, ty: 0))
        }
        let destination = CIRenderDestination(mtlTexture: drawable.texture, commandBuffer: command)
        destination.isFlipped = true; destination.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        do {
            _ = try context.startTask(toRender: image, to: destination)
            rendering = true
            command.addCompletedHandler { [weak self, background, presenter, liveSource] _ in
                withExtendedLifetime((background, presenter, liveSource)) { }
                Task { @MainActor in self?.rendering = false }
            }
            command.present(drawable); command.commit()
        }
        catch { }
    }
}


