import SwiftUI
import MetalKit
import CoreImage
import UIKit

struct PiPControl: View {
    let enabled: Bool
    let composition: PiPComposition
    let canEnable: Bool
    let disabled: Bool
    let recording: Bool
    let onSelect: (PiPQuickMode) -> Void
    let onSwap: () -> Void
    let onSettings: () -> Void
    private var selection: PiPQuickMode { PiPQuickMode(enabled: enabled, composition: composition) }
    var body: some View {
        Menu {
            Picker("Layout", selection: Binding(get: { selection }, set: onSelect)) {
                ForEach(PiPQuickMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.symbol).tag(mode)
                }
            }.pickerStyle(.inline).disabled(!canEnable)
            if enabled, composition != .inset {
                Button("Swap Cameras", systemImage: composition == .topAndBottom
                    ? "arrow.up.arrow.down" : "arrow.left.arrow.right", action: onSwap)
            }
            Divider()
            Button("PiP Settings…", systemImage: "slider.horizontal.3", action: onSettings)
                .disabled(recording)
        } label: {
            MovieControlIcon(systemName: enabled ? composition.symbol : "rectangle.on.rectangle")
                .foregroundStyle(enabled ? .yellow : .white)
                .background(enabled ? Color.white.opacity(0.15) : .clear, in: Circle())
        }
        .menuOrder(.fixed)
        .disabled(disabled)
        .accessibilityLabel("Picture in Picture")
        .accessibilityValue(selection.title)
        .accessibilityHint("Show layout choices. Choose Off to use one camera.")
    }
}

struct PiPLayoutView: View {
    @Binding var layout: PiPLayout
    let format: MovieFormat
    let rearFrames: LiveFrames
    let frontFrames: LiveFrames
    let ready: Bool
    let canPrepare: Bool
    let enabled: Bool
    var requestedEnabled: Bool? = nil
    let configuring: Bool
    let setupFailed: Bool
    let onEnabledChange: (Bool) -> Void
    let logMode: Bool
    var logCube: ColorCube? = nil
    var obstacles: [CGRect] = []
    let onPrepare: () -> Void
    var liveFrames: LiveFrames? = nil
    var frontMetering: CameraMetering? = nil
    var rearMetering: CameraMetering? = nil
    var onFocus: ((CGPoint, Bool, Bool) -> Bool)? = nil
    var onExposure: ((Float, Bool) -> Void)? = nil
    var onMove: ((CGPoint, Bool) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var expandedComposition: PiPComposition?
    @State private var checkingLogSupport = false
    @State private var logSupportReport: String?
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
                    .frame(height: geometry.size.height * (dynamicTypeSize.isAccessibilitySize ? 0.30 : (format == .portrait ? 0.49 : 0.38)))
                    .background(Color.black)
                    ScrollViewReader { scroll in
                        Form {
                            Section {
                                Toggle("Picture in Picture", isOn: Binding(
                                    get: { requestedEnabled ?? enabled }, set: onEnabledChange))
                                    .disabled(configuring || !enabled && !canPrepare && !ready)
                                if configuring {
                                    HStack(spacing: 10) {
                                        ProgressView()
                                        Text(ready ? "Updating Picture in Picture…" : "Preparing cameras…").foregroundStyle(.secondary)
                                    }
                                }
                            } footer: {
                                Text(logMode ? "1080p · 30 fps · Apple Log · 10-bit. Your movie stays in Log." : "1080p · 30 fps · Standard. Uses the rear wide camera and front camera.")
                            }
                            ForEach(PiPComposition.allCases) { composition in
                                Section {
                                    compositionButton(composition)
                                        .id(composition)
                                    if expandedComposition == composition {
                                        compositionSettings.disabled(configuring)
                                    }
                                }
                            }
                            if !ready, !configuring, setupFailed || !canPrepare {
                                Section {
                                    if logMode {
                                        Text(canPrepare ? "The live preview could not start. Retry or check this iPhone’s Log support." : "Picture in Picture is unavailable for this iPhone’s Log camera formats.")
                                        Button {
                                            guard !checkingLogSupport else { return }
                                            checkingLogSupport = true
                                            Task {
                                                var report = await Task.detached(priority: .userInitiated) {
                                                    CaptureService.logPiPCompatibilityReport()
                                                }.value
                                                if canPrepare {
                                                    do {
                                                        try await LogPiPValidation.shared.check()
                                                        report += "\n\nEncoder check passed: saved Apple Log metadata, 10-bit HEVC components, and 10-bit decoding verified. Live dual-camera recording still needs device testing."
                                                    } catch {
                                                        report += "\n\nEncoder check did not pass: " + error.localizedDescription
                                                    }
                                                }
                                                checkingLogSupport = false
                                                logSupportReport = report
                                            }
                                        } label: {
                                            HStack {
                                                Text("Check Log + PiP Support")
                                                if checkingLogSupport { ProgressView() }
                                            }
                                        }.disabled(checkingLogSupport)
                                        if canPrepare { Button("Retry Live Preview", action: onPrepare) }
                                    }
                                    else { Button("Retry Live Preview", action: onPrepare).disabled(!canPrepare) }
                                } footer: {
                                    Text(logMode ? "Log PiP needs compatible 10-bit front/rear camera formats. No SDR fallback is recorded into a Log movie." : canPrepare ? "Turn on both cameras for a live preview. PiP records at 1080p, 30 fps." : "Dual Camera is unavailable on this iPhone.")
                                }
                            }
                        }
                        .listSectionSpacing(8)
                        .scrollIndicators(.visible)
                        .onChange(of: expandedComposition) { _, composition in
                            guard let composition else { return }
                            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                                scroll.scrollTo(composition, anchor: .top)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Picture in Picture").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(configuring) } }
        }.interactiveDismissDisabled(configuring)
            .presentationDetents([.large]).presentationDragIndicator(.visible)
            .sensoryFeedback(.selection, trigger: layout.composition)
            .task {
                if !ready, canPrepare { onPrepare() }
            }
            .alert("Log + PiP Compatibility", isPresented: Binding(
                get: { logSupportReport != nil }, set: { if !$0 { logSupportReport = nil } })) {
                Button("OK") { logSupportReport = nil }
            } message: { Text(logSupportReport ?? "") }
    }
    private func compositionButton(_ composition: PiPComposition) -> some View {
        let selected = layout.composition == composition
        let expanded = expandedComposition == composition
        return Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                layout.composition = composition
                expandedComposition = expanded ? nil : composition
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: composition.symbol)
                    .frame(width: 24).foregroundStyle(selected ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(composition.title).font(.body.weight(.medium)).foregroundStyle(.primary)
                    if !expanded { Text("Tap to adjust").font(.caption).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 8)
                if selected {
                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                }
                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary).rotationEffect(.degrees(expanded ? 90 : 0))
            }.frame(minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .disabled(configuring)
            .accessibilityLabel(composition.title)
            .accessibilityValue("\(selected ? "Selected, " : "")\(expanded ? "expanded" : "collapsed")")
            .accessibilityHint(expanded ? "Tap to collapse settings" : "Tap to select this layout and show settings beneath it")
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
    @ViewBuilder private var compositionSettings: some View {
        if layout.composition == .inset {
            VStack(alignment: .leading, spacing: 8) {
                Text("Orientation").font(.subheadline).foregroundStyle(.secondary)
                if dynamicTypeSize.isAccessibilitySize {
                    Picker("Orientation", selection: $layout.orientation.withSelectionFeedback()) {
                        ForEach(PiPOrientation.allCases) { orientation in
                            Text(orientation.title).tag(orientation)
                        }
                    }.pickerStyle(.menu)
                        .accessibilityLabel("Presenter orientation")
                } else {
                    Picker("Orientation", selection: $layout.orientation.withSelectionFeedback()) {
                        ForEach(PiPOrientation.allCases) { orientation in
                            Text(orientation.title).tag(orientation)
                        }
                    }.pickerStyle(.segmented)
                        .accessibilityLabel("Presenter orientation")
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Size").font(.subheadline).foregroundStyle(.secondary)
                if dynamicTypeSize.isAccessibilitySize {
                    Picker("Size", selection: $layout.size.withSelectionFeedback()) {
                        ForEach(PiPSize.allCases) { size in Text(size.title).tag(size) }
                    }.pickerStyle(.menu)
                        .accessibilityLabel("Presenter size")
                } else {
                    Picker("Size", selection: $layout.size.withSelectionFeedback()) {
                        ForEach(PiPSize.allCases) { size in Text(size.title).tag(size) }
                    }.pickerStyle(.segmented)
                        .accessibilityLabel("Presenter size")
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Position").font(.subheadline).foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: dynamicTypeSize.isAccessibilitySize ? 2 : 4), spacing: 12) {
                    ForEach(PiPCorner.allCases) { corner in
                        Button { layout.corner = corner; UISelectionFeedbackGenerator().selectionChanged() } label: {
                            ZStack(alignment: alignment(for: corner)) {
                                RoundedRectangle(cornerRadius: 5).strokeBorder(.secondary.opacity(0.5), lineWidth: 1)
                                RoundedRectangle(cornerRadius: 2).fill(layout.corner == corner ? Color.accentColor : Color.secondary)
                                    .frame(width: 16, height: 12).padding(5)
                            }.frame(width: 48, height: 36).frame(maxWidth: .infinity, minHeight: 44)
                                .background(layout.corner == corner ? Color.accentColor.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain).contentShape(Rectangle()).accessibilityLabel(corner.title)
                            .accessibilityAddTraits(layout.corner == corner ? .isSelected : [])
                    }
                }
            }
        } else {
            Button {
                layout.splitSwapped.toggle()
                UISelectionFeedbackGenerator().selectionChanged()
            } label: {
                Label("Swap Cameras", systemImage: layout.composition == .topAndBottom
                    ? "arrow.up.arrow.down" : "arrow.left.arrow.right")
                    .frame(minHeight: 44)
            }.accessibilityHint("Exchanges the front and rear views")
            Text(splitDescription).font(.subheadline).foregroundStyle(.secondary)
        }
        VStack(spacing: 12) {
            HStack {
                Text("Front Camera Zoom")
                Spacer()
                Text(String(format: "%.1f×", Double(layout.framingZoom)))
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            HapticGlassSlider(value: Binding(get: { Double(layout.zoom) }, set: { layout.zoom = CGFloat($0) }), range: 1...2, step: 0.05, neutral: 1)
                .accessibilityLabel("Presenter zoom")
                .accessibilityValue(String(format: "%.1f times", Double(layout.framingZoom)))
            HStack {
                Text("Wider")
                Spacer()
                Text("Closer")
            }.font(.caption).foregroundStyle(.secondary)
        }
    }
    private var splitDescription: String {
        if layout.composition == .topAndBottom {
            return layout.splitSwapped ? "Front camera above. Rear camera below." : "Rear camera above. Front camera below."
        }
        return layout.splitSwapped ? "Front camera on the left. Rear camera on the right." : "Rear camera on the left. Front camera on the right."
    }
    private func alignment(for corner: PiPCorner) -> Alignment {
        switch corner {
        case .topLeft: .topLeading
        case .topRight: .topTrailing
        case .bottomLeft: .bottomLeading
        case .bottomRight: .bottomTrailing
        }
    }
    private var preview: some View {
        ZStack {
            PiPCompositionPreview(rearFrames: rearFrames, frontFrames: frontFrames,
                layout: layout, format: format, enabled: enabled, obstacles: obstacles,
                liveFrames: liveFrames, profile: logMode ? .appleLog : .standard, cube: logCube)
            if ready, let liveFrames, let onFocus, let onExposure {
                PiPMeteringView(frames: liveFrames,
                    presentation: layout.previewPresentation(enabled: enabled, canvas: format.canvas, obstacles: obstacles),
                    front: frontMetering, rear: rearMetering, protectedRegions: [],
                    onFocus: onFocus, onExposure: onExposure, onMove: { point, finished in
                        // Use the same capture-queue drag/settle path as the viewfinder,
                        // so the live preview follows every drag sample, not only release.
                        if let onMove { onMove(point, finished) }
                        else if finished { layout.corner = PiPGeometry.nearestCorner(to: point, layout: layout, canvas: format.canvas, obstacles: obstacles) }
                    })
            }
            if !ready {
                GeometryReader { geometry in
                    let rect = layout.splitPresenterRect ?? PiPGeometry.rect(layout: layout, canvas: format.canvas, obstacles: obstacles) ?? .zero
                    ZStack {
                        Color(white: 0.12)
                        Image(systemName: format == .portrait ? "rectangle.portrait" : "rectangle")
                            .font(.largeTitle).foregroundStyle(.white.opacity(0.3))
                        if enabled {
                            RoundedRectangle(cornerRadius: layout.composition == .inset ? 6 : 0).fill(.white.opacity(0.2))
                                .overlay { Image(systemName: "person.fill").foregroundStyle(.white) }
                                .frame(width: rect.width * geometry.size.width, height: rect.height * geometry.size.height)
                                .position(x: rect.midX * geometry.size.width, y: rect.midY * geometry.size.height)
                        }
                    }
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel(!enabled ? "Picture in Picture off. Rear camera preview." : layout.composition == .inset
                ? "\(format == .portrait ? "Portrait" : "Landscape") video with \(layout.orientation.title.lowercased()) presenter inset at \(layout.corner.title.lowercased())"
                : "\(layout.composition.title) preview. \(splitDescription)")
    }

}

struct PiPCompositionPreview: UIViewRepresentable {
    let rearFrames: LiveFrames
    let frontFrames: LiveFrames
    let layout: PiPLayout
    let format: MovieFormat
    var enabled = true
    var obstacles: [CGRect] = []
    var liveFrames: LiveFrames? = nil
    var paused = false
    var sourceFront = false
    var falseColor = false
    var profile: CaptureProfile = .standard
    var cube: ColorCube? = nil
    var onStatus: ((LiveLookStatus) -> Void)? = nil
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
        context.coordinator?.previewEnabled = enabled
        context.coordinator?.live = liveFrames
        context.coordinator?.sourceFront = sourceFront
        context.coordinator?.falseColor = falseColor && profile == .appleLog
        context.coordinator?.profile = profile; context.coordinator?.cube = cube
        context.coordinator?.onStatus = onStatus
        (view.layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: profile == .appleLog && !falseColor ? CGColorSpace.itur_709 : CGColorSpace.sRGB)
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
    var previewEnabled = true
    var falseColor = false { didSet { if oldValue != falseColor { presentationID = UUID() } } }
    private var presentationID = UUID()
    var profile: CaptureProfile = .standard
    var cube: ColorCube?
    var onStatus: ((LiveLookStatus) -> Void)?
    private lazy var logContext = CIContext(mtlCommandQueue: queue, options: LogPiPColor.contextOptions())
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
            backgroundAngle: backgroundAngle, presenterAngle: presenterAngle, presentation: presentation, profile: profile)
    }
    func monitoringImage(background: CVPixelBuffer, presenter: CVPixelBuffer?, canvas: CGSize,
                         backgroundAngle: CGFloat, presenterAngle: CGFloat, presentation: PiPPresentation) throws -> CIImage {
        if falseColor && profile == .appleLog {
            return try FalseColorPreview.image(background: background, presenter: presenter, canvas: canvas,
                backgroundAngle: backgroundAngle, presenterAngle: presenterAngle, presentation: presentation)
        }
        let composed = image(background: background, presenter: presenter, canvas: canvas,
            backgroundAngle: backgroundAngle, presenterAngle: presenterAngle, presentation: presentation)
        return profile == .appleLog ? try LiveLookRenderer.viewingImage(composed, cube: cube) : composed
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
        do {
            var image = try monitoringImage(background: background.buffer, presenter: live != nil ? liveSource?.pip?.presenter : presenter?.buffer,
                canvas: canvas,
                backgroundAngle: liveSource?.pip?.backgroundAngle ?? (live != nil ? background.angle ?? 90 :
                    (MovieFormat.captureFormat(angle: background.angle ?? 90) ?? .portrait).recordingAngle(observed: background.angle ?? 90)),
                presenterAngle: liveSource?.pip?.presenterAngle ??
                    (MovieFormat.captureFormat(angle: presenter?.angle ?? 90) ?? .portrait).recordingAngle(observed: presenter?.angle ?? 90),
                presentation: live != nil ? (liveSource?.pip?.presentation ?? PiPPresentation()) :
                    layout.previewPresentation(enabled: previewEnabled, canvas: format.canvas, obstacles: obstacles))
            if live != nil, sourceFront, liveSource?.pip == nil {
                image = image.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: canvas.width, ty: 0))
            }
            let destination = CIRenderDestination(mtlTexture: drawable.texture, commandBuffer: command)
            destination.isFlipped = true; destination.colorSpace = profile == .appleLog ? nil : CGColorSpace(name: CGColorSpace.sRGB)
            _ = try (profile == .appleLog ? logContext : context).startTask(toRender: image, to: destination)
            rendering = true
            let presentationID = self.presentationID
            command.addCompletedHandler { [weak self, background, presenter, liveSource] buffer in
                withExtendedLifetime((background, presenter, liveSource)) { }
                Task { @MainActor in
                    self?.rendering = false
                    guard self?.presentationID == presentationID else { return }
                    self?.onStatus?(buffer.status == .completed ? .ready : .unavailable)
                }
            }
            command.present(drawable); command.commit()
        }
        catch { onStatus?(.unavailable) }
    }
}
