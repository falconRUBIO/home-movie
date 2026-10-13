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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    preview
                        .frame(maxWidth: .infinity)
                        .frame(height: min(300, geometry.size.height * 0.43))
                        .background(.black)
                    Form {
                        Section {
                            Picker("Orientation", selection: $layout.orientation) {
                                ForEach(PiPOrientation.allCases) { orientation in
                                    Text(orientation.title).tag(orientation)
                                }
                            }.pickerStyle(.segmented)
                            Picker("Size", selection: $layout.size) {
                                ForEach(PiPSize.allCases) { size in Text(size.title).tag(size) }
                            }.pickerStyle(.segmented)
                        } header: { Text("Presenter") } footer: {
                            Text("The inset has its own shape, independent of the main video. Your presenter stays upright and unmirrored.")
                        }
                        Section("Position") {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: dynamicTypeSize.isAccessibilitySize ? 1 : 2), spacing: 8) {
                                ForEach(PiPCorner.allCases) { corner in
                                    Button { layout.corner = corner } label: {
                                        HStack {
                                            Image(systemName: layout.corner == corner ? "checkmark.circle.fill" : "circle")
                                            Text(corner.title).font(.subheadline)
                                            Spacer(minLength: 0)
                                        }.frame(minHeight: 44)
                                    }.buttonStyle(.plain).foregroundStyle(layout.corner == corner ? Color.accentColor : .primary)
                                        .accessibilityAddTraits(layout.corner == corner ? .isSelected : [])
                                }
                            }
                        }
                        if !ready {
                            Section {
                                if logMode { Text(CameraCompatibility.logPiPExplanation) }
                                else { Button("Use Dual Camera", action: onPrepare).disabled(!canPrepare) }
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
    }
    private var preview: some View {
        ZStack {
            PiPCompositionPreview(rearFrames: rearFrames, frontFrames: frontFrames,
                layout: layout, format: format, obstacles: obstacles)
            if !ready {
                GeometryReader { geometry in
                    let rect = PiPGeometry.rect(layout: layout, canvas: geometry.size, obstacles: obstacles) ?? .zero
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
        }.aspectRatio(format.aspect, contentMode: .fit)
            .accessibilityLabel("\(format == .portrait ? "Portrait" : "Landscape") video with \(layout.orientation.title.lowercased()) presenter inset at \(layout.corner.title.lowercased())")
    }

}

struct PiPCompositionPreview: UIViewRepresentable {
    let rearFrames: LiveFrames
    let frontFrames: LiveFrames
    let layout: PiPLayout
    let format: MovieFormat
    var obstacles: [CGRect] = []
    func makeCoordinator() -> PiPLayoutRenderer? {
        MTLCreateSystemDefaultDevice().flatMap { PiPLayoutRenderer(device: $0) }
    }
    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: context.coordinator?.device)
        view.framebufferOnly = false; view.colorPixelFormat = .bgra8Unorm
        view.isUserInteractionEnabled = false; view.preferredFramesPerSecond = 30
        view.delegate = context.coordinator; return view
    }
    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator?.rear = rearFrames; context.coordinator?.front = frontFrames
        context.coordinator?.layout = layout; context.coordinator?.format = format
        context.coordinator?.obstacles = obstacles
    }
    static func dismantleUIView(_ view: MTKView, coordinator: PiPLayoutRenderer?) { view.isPaused = true; view.delegate = nil }
}
@MainActor final class PiPLayoutRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let context: CIContext
    private var rendering = false
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
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { }
    func draw(in view: MTKView) {
        let previewSize = PiPFrameRenderer.previewCanvas(for: view.drawableSize)
        if previewSize != .zero, view.drawableSize != previewSize { view.drawableSize = previewSize }
        guard !rendering, let rear = rear?.snapshot(), let drawable = view.currentDrawable, let command = queue.makeCommandBuffer() else { return }
        let front = front?.snapshot(), canvas = CGSize(width: drawable.texture.width, height: drawable.texture.height)
        let presentation = PiPPresentation(rect: PiPGeometry.rect(layout: layout, canvas: canvas, obstacles: obstacles) ?? .zero, opacity: 1, enabled: true, corner: layout.corner)
        let image = PiPCompositor.image(background: rear.buffer, presenter: front?.buffer, canvas: canvas,
            backgroundAngle: (MovieFormat.captureFormat(angle: rear.angle ?? 90) ?? .portrait).recordingAngle(observed: rear.angle ?? 90),
            presenterAngle: (MovieFormat.captureFormat(angle: front?.angle ?? 90) ?? .portrait).recordingAngle(observed: front?.angle ?? 90), presentation: presentation)
        let destination = CIRenderDestination(mtlTexture: drawable.texture, commandBuffer: command)
        destination.isFlipped = true; destination.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        do {
            _ = try context.startTask(toRender: image, to: destination)
            rendering = true
            command.addCompletedHandler { [weak self] _ in Task { @MainActor in self?.rendering = false } }
            command.present(drawable); command.commit()
        }
        catch { }
    }
}

