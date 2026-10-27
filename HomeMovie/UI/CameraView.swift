import SwiftUI
import AVFoundation
import UIKit

private struct DollyLensButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
private struct CameraControlRegionsKey: PreferenceKey {
    static var defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) { value.append(contentsOf: nextValue()) }
}
extension View {
    func cameraControlRegion(visibleHeight: CGFloat? = nil) -> some View {
        background {
            GeometryReader { geometry in
                let frame = geometry.frame(in: .named("cameraViewfinder"))
                let height = min(frame.height, visibleHeight ?? frame.height)
                Color.clear.preference(key: CameraControlRegionsKey.self,
                    value: [CGRect(x: frame.minX, y: frame.maxY - height, width: frame.width, height: height)])
            }
        }
    }
}
private struct DollyControlHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 52
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
private extension View {
    @ViewBuilder func dollyControlGlass() -> some View {
        let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
        if #available(iOS 26.0, *) { self.glassEffect(.regular.interactive(), in: shape) }
        else { self.background(.regularMaterial, in: shape) }
    }
}

struct CameraView: View {
    @ObservedObject var app: AppModel
    @StateObject private var camera: CameraModel
    @State private var movieID: UUID
    @State private var watching = false
    @State private var showingRecovery = false
    @State private var showingErrorDetails = false
    @State private var initialReviewID: UUID?
    @State private var pinchBase: CGFloat?
    @State private var lastZoomAt = Date.distantPast
    @State private var liveCube: ColorCube?
    @AppStorage(FalseColorPreview.preferenceKey) private var falseColorEnabled = false
    private var showsFalseColor: Bool { falseColorEnabled && movie?.captureProfile == .appleLog }
    @AppStorage(CameraPreviewMode.originalLogPreferenceKey) private var liveOriginal = false
    @State private var liveLookStatus = LiveLookStatus.inactive
    @State private var manualZoomTargetShown = false
    @State private var showingLookPreview = false
    @State private var showingFalseColorGuide = false
    private var previewMode: Binding<CameraPreviewMode> {
        Binding(get: { CameraPreviewMode(originalLog: liveOriginal, falseColor: falseColorEnabled) }, set: { mode in
            liveOriginal = mode.usesOriginalLog
            falseColorEnabled = mode.usesFalseColor
        })
    }
    @State private var addedSceneID: UUID?
    @State private var undoingTake = false
    @State private var smoothZoomOpen = false
    @State private var dollyCollapsed = false
    @State private var lensControlHeight: CGFloat = 52
    @State private var manualDialExpanded = false
    @State private var previewControlRegions: [CGRect] = []
    @State private var smoothPosition = 0.0
    @State private var zoomDragging = false
    @StateObject private var recordingCountdown = RecordingCountdown()
    @StateObject private var dollyCountdown = RecordingCountdown()
    @GestureState private var dollyEndpointTouching = false
    @State private var draggingDollyStart: Bool?
    @State private var dollyEditor = DollyEndpointEditor()
    @State private var dollyEndpointMoved = false
    @State private var dollyHapticTick: Int?
    @State private var awaitingDollyHold = false
    private var preparedDollyStart: CGFloat? {
        get { dollyEditor.start.map { CGFloat($0) } }
        nonmutating set { dollyEditor.start = newValue.map { Double($0) } }
    }
    private var preparedDollyTarget: CGFloat? {
        get { dollyEditor.end.map { CGFloat($0) } }
        nonmutating set { dollyEditor.end = newValue.map { Double($0) } }
    }
    @State private var activeDolly: DollyZoomRoute?
    @State private var showingDollyHelp = false
    @State private var showingDollySettings = false
    @State private var showingMovieSettings = false
    @State private var showingPiPLayout = false
    @State private var preparedPiPForSettings = false
    @State private var viewfinderSize = CGSize.zero
    @State private var foregroundResume = CameraForegroundResume()
    @State private var interfaceFormat = MovieFormat.portrait
    @State private var interfaceOrientation = UIInterfaceOrientation.portrait
    private var landscapeControlsOnLeading: Bool { interfaceOrientation == .landscapeLeft }
    private var landscapeBleedEdges: Edge.Set {
        guard interfaceFormat == .landscape else { return [] }
        return landscapeControlsOnLeading ? [.top, .bottom, .leading] : [.top, .bottom, .trailing]
    }
    @State private var pipConfiguring = false
    @State private var enablePiPAfterPreparation = false
    @AppStorage("dollyGuidanceLearned") private var dollyGuidanceLearned = false
    @AppStorage("handsFreeStart") private var handsFreeStart = false
    @AppStorage("dollyStartDelaySeconds") private var dollyStartDelaySeconds = 3
    @AppStorage("dollyZoomSeconds") private var dollySeconds = 3
    @AppStorage("smoothZoomSpeed") private var zoomSpeed = SmoothZoomSpeed.normal.rawValue
    @AppStorage("smoothStayOnLens") private var stayOnLens = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    init(app: AppModel, movieID: UUID) {
        self.app = app; _movieID = State(initialValue: movieID)
        _camera = StateObject(wrappedValue: app.camera)
    }
    private var countdown: Int? { recordingCountdown.remaining ?? dollyCountdown.remaining }
    private var startDelay: Int { DollyStartDelay.effective(handsFreeStart ? dollyStartDelaySeconds : 0, dollyOpen: smoothZoomOpen) }
    private var dollyDelayedStart: Bool { startDelay > 0 }
    private var movie: Movie? { app.movie(movieID) }
    private var pipCanvasFormat: MovieFormat { movie?.recordingFormat ?? activeTakeFormat ?? interfaceFormat }
    private var activeTakeFormat: MovieFormat? { camera.activeTakeOrientation }
    private var cameraSurface: some View {
        GeometryReader { geometry in
            let landscape = geometry.size.width > geometry.size.height
            if let movie {
                let footerHeight: CGFloat = dynamicTypeSize.isAccessibilitySize ? 100 : 64
                let canvasFormat: MovieFormat? = camera.options?.dualCameraPrepared == true ? pipCanvasFormat : nil
                let layout = CameraViewportLayout(size: geometry.size, landscape: landscape,
                    controlsOnLeading: landscapeControlsOnLeading, portraitFooter: footerHeight, canvasAspect: canvasFormat?.aspect)
                // Keep one viewfinder/UIViewRepresentable identity across rotation.
                // Switching between HStack/VStack branches destroys and reattaches the
                // native preview connection (and the Cinema Metal surface).
                ZStack(alignment: .topLeading) {
                    viewfinder(movie: movie, landscape: landscape, controlsOnLeading: landscapeControlsOnLeading)
                        .frame(width: layout.preview.width, height: layout.preview.height)
                        .position(x: layout.preview.midX, y: layout.preview.midY)
                    reviewControls(movie: movie, landscape: landscape).disabled(countdown != nil)
                        .padding(.horizontal, landscape ? 0 : 20)
                        .frame(width: layout.controls.width, height: layout.controls.height)
                        .background(.black)
                        .position(x: layout.controls.midX, y: layout.controls.midY)
                }.frame(width: geometry.size.width, height: geometry.size.height)

            } else { ContentUnavailableView("Movie unavailable", systemImage: "film") }
        }
        .onGeometryChange(for: MovieFormat.self) { geometry in
            geometry.size.width > geometry.size.height ? .landscape : .portrait
        } action: { format in
            interfaceFormat = format
            syncPiPCanvas()
        }
        .ignoresSafeArea(.container, edges: landscapeBleedEdges)
        .background(MovieOrientation(format: activeTakeFormat ?? camera.switchingFormat,
            onInterfaceChange: { interfaceOrientation = $0 }).frame(width: 0, height: 0))
        .background(.black).foregroundStyle(.white)
        .toolbar(.hidden, for: .navigationBar).navigationBarBackButtonHidden()
        .preferredColorScheme(.dark)
    }
    private var configuredCamera: some View {
        cameraSurface
        .task(id: movieID) {
            updateZoomSettings()
            await prepareCamera()
        }
        .task(id: "\(movieID)-\(movie?.captureProfile.rawValue ?? "standard")-\(movie?.look?.id.uuidString ?? "standard")") {
            guard movie?.captureProfile == .appleLog else { liveCube = nil; return }
            liveCube = nil; liveLookStatus = .preparing
            let reference = movie?.look, root = app.store.root
            do {
                let loaded = try await Task.detached(priority: .userInitiated) {
                    if let reference { return try ColorCube.load(reference, root: root) }
                    return try ColorCube.appleStandard.get()
                }.value
                guard !Task.isCancelled else { return }; liveCube = loaded
            } catch { if !Task.isCancelled { liveCube = nil; liveLookStatus = .unavailable; camera.message = "This look could not be loaded. Choose Natural in Look & Preview." } }
        }
        .onChange(of: handsFreeStart) { _, _ in
            cancelCountdown()
        }
        .onChange(of: dollyStartDelaySeconds) { _, _ in cancelCountdown() }
        .onChange(of: falseColorEnabled) { _, enabled in
            if enabled, movie?.captureProfile == .appleLog { liveLookStatus = .preparing }
        }
        .onChange(of: liveLookStatus) { _, status in
            if showsFalseColor, status == .unavailable {
                falseColorEnabled = false
                camera.message = "False Color is unavailable. Your normal preview has been restored; recording is unaffected."
            }
        }
        .onChange(of: zoomSpeed) { _, _ in updateZoomSettings() }
        .onChange(of: stayOnLens) { _, _ in updateZoomSettings() }
        .onChange(of: camera.options?.minimum) { _, _ in if !zoomDragging { syncSmoothPosition() } }
        .onChange(of: camera.options?.maximum) { _, _ in if !zoomDragging { syncSmoothPosition() } }
        .onChange(of: camera.savedScene) { _, saved in
            if saved {
                addedSceneID = movie?.latestTake?.id
                UIAccessibility.post(notification: .announcement, argument: "Clip saved")
            }
        }
        .task(id: addedSceneID) {
            guard let id = addedSceneID else { return }
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled, addedSceneID == id else { return }
            addedSceneID = nil
        }
    }
    private var activeCamera: some View {
        configuredCamera
        .onChange(of: camera.state) { _, state in
            if state == .starting { addedSceneID = nil }
            if state != .ready && state != .recording && state != .starting { dollyCountdown.cancel() }
            if state == .failed || state == .interrupted || state == .denied || state == .preparing {
                cancelCountdown()
            }
            zoomDragging = false
            if state != .ready && state != .recording { manualZoomTargetShown = false }
            if state != .ready && state != .recording && state != .starting && countdown == nil {
                activeDolly = nil; preparedDollyStart = nil; preparedDollyTarget = nil
            }
            if smoothZoomOpen, state == .ready {
                if preparedDollyStart == nil { preparedDollyStart = camera.options?.zoom }
                camera.beginSmoothZoom()
            }
            resumeCameraIfRequested()
        }
        .onChange(of: camera.options?.isFront) { _, _ in
            cancelCountdown(); preparedDollyStart = nil; preparedDollyTarget = nil
            activeDolly = nil
        }
        .onChange(of: camera.options?.zoom) { _, _ in
            if !zoomDragging && !manualZoomTargetShown { syncSmoothPosition() }
            if smoothZoomOpen, preparedDollyTarget == nil, activeDolly == nil,
               camera.state == .ready, countdown == nil {
                preparedDollyStart = camera.options?.zoom
            }
        }
        .onChange(of: dollyEndpointTouching) { _, touching in
            if !touching { finishDollyEndpointInteraction() }
        }
        .onChange(of: smoothZoomOpen) { _, open in
            if !open { finishDollyEndpointInteraction(); dollyCollapsed = false }
        }
        .task(id: camera.options?.smoothMoving) { await finishDollyIfIdle() }
        .onChange(of: camera.options?.isPiPEnabled) { _, enabled in
            if enabled == true { enablePiPAfterPreparation = false }
        }
        .onChange(of: camera.pipSetupFailed) { _, failed in if failed { enablePiPAfterPreparation = false } }
        .onChange(of: movie?.recordingFormat) { _, _ in syncPiPCanvas() }
        .onChange(of: camera.options?.dualCameraPrepared) { _, _ in syncPiPCanvas() }
        .onDisappear { foregroundResume.cancel(); finishDollyEndpointInteraction(); app.cancelCameraWarmup(); cancelCountdown(); activeDolly = nil; zoomDragging = false; camera.suspend() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { foregroundResume.cancel(); finishDollyEndpointInteraction(); cancelCountdown(); activeDolly = nil; zoomDragging = false; camera.suspend() }
            else if !watching && !showingRecovery {
                foregroundResume.request()
                resumeCameraIfRequested()
            }
        }
    }
    var body: some View {
        activeCamera
        .sheet(isPresented: $showingRecovery, onDismiss: {
            Task { await prepareCamera() }
        }) { RecordingRecoveryView().environmentObject(app) }
        .sheet(isPresented: $showingFalseColorGuide) { FalseColorGuideView() }
        .sheet(isPresented: $showingLookPreview) {
            LookPreviewSheet(app: app, movieID: movieID, previewMode: previewMode, canChangeLook: !camera.busy)
        }
        .sheet(isPresented: $showingDollyHelp) { dollyHelp }
        .sheet(isPresented: $showingDollySettings) { dollySettings }
        .sheet(isPresented: $showingMovieSettings, onDismiss: { Task { await prepareCamera() } }) {
            if let movie { MovieSettingsView(movie: movie).environmentObject(app) }
        }
        .sheet(isPresented: $showingPiPLayout, onDismiss: {
            if preparedPiPForSettings {
                preparedPiPForSettings = false
                Task { await prepareCamera() }
            }
        }) {
            PiPLayoutView(layout: Binding(get: { camera.pipLayout }, set: { camera.updatePiPLayout($0, movieID: movieID, canvasFormat: pipCanvasFormat) }),
                format: pipCanvasFormat,
                rearFrames: camera.service.pipRearFrames, frontFrames: camera.service.pipPresenterFrames,
                ready: camera.options?.piPAvailable == true, canPrepare: camera.options?.canPreparePiP == true,
                enabled: camera.options?.isPiPEnabled == true,
                requestedEnabled: camera.pendingPiPEnabled,
                configuring: pipConfiguring || camera.pendingPiPEnabled != nil || camera.state == .preparing,
                setupFailed: camera.pipSetupFailed || camera.state == .failed,
                onEnabledChange: { enabled in
                    if enabled { enableDualCamera() } else { disableDualCamera() }
                },
                logMode: movie?.captureProfile == .appleLog, logCube: liveOriginal ? nil : liveCube, obstacles: [],
                onPrepare: { preparePiPSettingsPreview() }, liveFrames: camera.service.liveFrames,
                frontMetering: camera.options?.frontMetering, rearMetering: camera.options?.rearMetering,
                onFocus: { point, locked, front in camera.focus(at: point, locked: locked, front: front) },
                onExposure: { bias, front in camera.exposure(bias, front: front) },
                onMove: { point, finished in camera.dragPiP(to: point, finished: finished) })
        }
        .alert("Recording Details", isPresented: $showingErrorDetails) {
            Button("OK", role: .cancel) { }
        } message: { Text(camera.message ?? "No additional details are available.") }
        .fullScreenCover(isPresented: $watching, onDismiss: { Task { await prepareCamera() } }) {
            WatchMovieView(movieID: movieID, initialSceneID: initialReviewID, autoplay: initialReviewID == nil).environmentObject(app)
        }
    }
    private func header(movie: Movie) -> some View {
        HStack {
            Button { dismiss() } label: {
                MovieControlIcon(systemName: "chevron.left").homeGlass()
            }.accessibilityLabel("Back to Movies").disabled(camera.busy)
            Spacer(minLength: 8)
            if movie.captureProfile == .appleLog {
                Button { showingLookPreview = true } label: {
                    MovieControlIcon(systemName: "camera.filters").homeGlass()
                }
                .accessibilityLabel("Look and Preview")
                .accessibilityValue("Movie look: \(movie.lookName). Viewfinder: \(previewMode.wrappedValue.title)")
            }
            Menu {
                if let options = camera.options {
                    Text(options.recordingFormat)
                    Divider()
                }
                Button("Recording Settings", systemImage: "record.circle") { showingMovieSettings = true }
                    .disabled(camera.busy)
                Button("Dolly Settings", systemImage: "slider.horizontal.3") { showingDollySettings = true }
                    .disabled(camera.busy)
            } label: { MovieControlIcon(systemName: "gearshape").homeGlass() }
                .accessibilityLabel("Camera settings")
            if let options = camera.options, options.hasTorch {
                Button { camera.toggleTorch() } label: {
                    MovieControlIcon(systemName: options.torchOn ? "bolt.fill" : "bolt.slash")
                        .foregroundStyle(options.torchOn ? .yellow : .white).homeGlass()
                }.accessibilityLabel(options.torchOn ? "Turn torch off" : "Turn torch on")
                    .disabled(camera.state != .ready && camera.state != .recording)
            } else { Color.clear.frame(width: 44, height: 44) }
        }.disabled(countdown != nil)
    }
    private func viewfinder(movie: Movie, landscape: Bool, controlsOnLeading: Bool) -> some View {
        ZStack {
            preview().zIndex(0)
            VStack(spacing: 4) {
                header(movie: movie).cameraControlRegion().padding(.horizontal, 12).padding(.top, 8)
                captureIndicators(movie: movie)
                Spacer(minLength: 0)
                status(movie: movie).cameraControlRegion().padding(.horizontal, landscape ? 100 : 20)
                    .padding(.bottom, lensControlHeight + (landscape ? 18 : 124))
            }
        }.clipped()
            .overlay { pipInteraction }
            .overlay(alignment: .bottom) {
                lenses.cameraControlRegion(visibleHeight: smoothZoomOpen ? nil : (manualDialExpanded ? 104 : 52)).zIndex(2).background {
                    GeometryReader { proxy in
                        Color.clear.preference(key: DollyControlHeightKey.self, value: proxy.size.height)
                    }
                }.onPreferenceChange(DollyControlHeightKey.self) { lensControlHeight = $0 }
                    .padding(.leading, landscape && (smoothZoomOpen || controlsOnLeading) ? 100 : 12)
                    .padding(.trailing, landscape && (smoothZoomOpen || !controlsOnLeading) ? 100 : 12)
                    .padding(.bottom, landscape ? 10 : 116)
            }
            .overlay(alignment: landscape ? (controlsOnLeading ? .leading : .trailing) : .bottom) {
                recordControl.cameraControlRegion().zIndex(3)
                    .padding(landscape ? (controlsOnLeading ? .leading : .trailing) : .bottom, 16)
            }
            .coordinateSpace(name: "cameraViewfinder")
            .onPreferenceChange(CameraControlRegionsKey.self) { previewControlRegions = $0; updatePiPObstacles() }
    }
    private func captureIndicators(movie: Movie) -> some View {
        VStack(spacing: 6) {
            if showsFalseColor {
                FalseColorIndicator(status: liveLookStatus) { showingFalseColorGuide = true }
                    .cameraControlRegion()
            } else if movie.captureProfile == .appleLog {
                let wantsLook = !liveOriginal && camera.state.showsLiveLook
                LogLookBadge(lookName: wantsLook ? (liveLookStatus == .ready ? movie.lookName : liveLookStatus == .unavailable ? "Preview unavailable" : "Loading look…") : "Original")
            }
            if camera.options?.focusLocked == true {
                Text("AE/AF LOCK").font(.caption2.weight(.semibold)).foregroundStyle(.black)
                    .padding(.horizontal, 8).padding(.vertical, 4).background(.yellow, in: RoundedRectangle(cornerRadius: 3))
            }
            if camera.recordingSessionActive {
                Text("● \(durationLabel(camera.elapsed))")
                    .font(.caption.monospacedDigit()).padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.red, in: RoundedRectangle(cornerRadius: 5))
            }
        }
    }
    @ViewBuilder private var lenses: some View {
        if let options = camera.options, !options.lenses.isEmpty {
            if smoothZoomOpen {
                VStack(spacing: 0) {
                    if dollyCollapsed, let route = displayedDolly {
                        compactDollyBar(options: options, route: route)
                    } else {
                        smoothZoomBar(options: options)
                    }
                    ViewThatFits(in: .horizontal) {
                        lensButtons(options: options)
                        ScrollView(.horizontal) { lensButtons(options: options) }
                            .scrollIndicators(.hidden).frame(height: dynamicTypeSize.isAccessibilitySize ? 64 : 44)
                    }.padding(4)
                }.dollyControlGlass().frame(maxWidth: 360)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: dollyCollapsed)
            } else {
                // No scrolling container, conditional overlay, or layout change during a scrub.
                ZStack(alignment: .bottomTrailing) {
                    ManualZoomControl(options: options,
                        enabled: !camera.switchingCamera && countdown == nil &&
                            (camera.state == .ready || camera.state == .recording),
                        reservedTrailingWidth: options.maximum > options.minimum ? 100 : 50,
                        onLens: { selectLens($0) }, onBegin: { camera.beginManualZoom(id: $0) },
                        onZoom: { factor, time, id in camera.manualZoom(to: factor, inputTime: time, id: id) },
                        onEnd: { camera.endManualZoom(id: $0) },
                        onVisibilityChanged: { manualDialExpanded = $0 })
                        .id(options.isFront)
                    HStack(spacing: 6) { lensActions(options: options) }.padding(4)
                }.frame(maxWidth: 360).frame(height: ZoomDialControlView.height)
                    .background(alignment: .bottom) {
                        Color.clear.frame(height: 52).dollyControlGlass().allowsHitTesting(false)
                    }
            }
        }
    }
    private func lensButtons(options: CameraOptions) -> some View {
        HStack(spacing: 6) {
            ForEach(options.lenses) { lens in
                lensButton(label: lens.label, factor: lens.factor, options: options)
            }
            lensActions(options: options)
        }
    }
    @ViewBuilder private func lensActions(options: CameraOptions) -> some View {
        if options.maximum > options.minimum || smoothZoomOpen {
            Button {
                manualZoomTargetShown = false
                preparedDollyStart = nil; preparedDollyTarget = nil; activeDolly = nil
                if smoothZoomOpen { camera.endSmoothZoom(); smoothZoomOpen = false }
                else {
                    dollyEditor.selected = .end
                    syncSmoothPosition(); smoothZoomOpen = true
                    preparedDollyStart = options.zoom
                    preparedDollyTarget = options.zoom < options.maximum ? min(options.maximum, options.zoom * 2) : options.minimum
                    camera.beginSmoothZoom()
                    UISelectionFeedbackGenerator().selectionChanged()
                }
            } label: {
                MovieControlIcon(systemName: "waveform.path")
                    .foregroundStyle(smoothZoomOpen ? .yellow : .white)
                    .background(smoothZoomOpen ? Color.white.opacity(0.15) : .clear, in: Circle())
            }.accessibilityLabel("Dolly").accessibilityValue(smoothZoomOpen ? "Open" : "Closed")
                .accessibilityAddTraits(smoothZoomOpen ? .isSelected : [])
                .disabled(countdown != nil || !smoothZoomOpen && camera.state != .ready && camera.state != .recording)
        }
        PiPControl(enabled: options.isPiPEnabled, composition: camera.pipLayout.composition,
            size: Binding(get: { camera.pipLayout.size }, set: { size in
                updatePiPInset { $0.size = size }
            }),
            orientation: Binding(get: { camera.pipLayout.orientation }, set: { orientation in
                updatePiPInset { $0.orientation = orientation }
            }),
            canEnable: options.piPAvailable || options.canPreparePiP,
            disabled: countdown != nil || pipConfiguring || camera.pendingPiPEnabled != nil || camera.state != .ready && camera.state != .recording || camera.state == .recording && !options.piPAvailable,
            recording: camera.state == .recording,
            onSelect: { selectPiPMode($0) }, onSwap: { swapPiPCameras() },
            onSettings: { showingPiPLayout = true })
    }
    private func updatePiPInset(_ edit: (inout PiPLayout) -> Void) {
        guard countdown == nil, !pipConfiguring, camera.pendingPiPEnabled == nil,
              !camera.switchingCamera, camera.state == .ready || camera.state == .recording,
              camera.options?.isPiPEnabled == true, camera.pipLayout.composition == .inset else { return }
        var layout = camera.pipLayout
        edit(&layout)
        guard layout != camera.pipLayout else { return }
        camera.updatePiPLayout(layout, movieID: movieID, canvasFormat: pipCanvasFormat)
        UISelectionFeedbackGenerator().selectionChanged()
    }
    private func selectPiPMode(_ mode: PiPQuickMode) {
        guard countdown == nil, !pipConfiguring, camera.pendingPiPEnabled == nil,
              !camera.switchingCamera, camera.state == .ready || camera.state == .recording,
              let options = camera.options else { return }
        let current = PiPQuickMode(enabled: options.isPiPEnabled, composition: camera.pipLayout.composition)
        guard current != mode else { return }
        if let composition = mode.composition {
            guard options.piPAvailable || camera.state == .ready && options.canPreparePiP else { return }
            var layout = camera.pipLayout
            layout.composition = composition
            camera.updatePiPLayout(layout, movieID: movieID, canvasFormat: pipCanvasFormat)
            if !options.isPiPEnabled {
                if camera.state == .recording { camera.setPiPEnabled(true) }
                else { enableDualCamera() }
            }
        } else if camera.state == .recording {
            camera.setPiPEnabled(false)
        } else { disableDualCamera() }
        UISelectionFeedbackGenerator().selectionChanged()
    }
    private func swapPiPCameras() {
        guard countdown == nil, !pipConfiguring, camera.pendingPiPEnabled == nil,
              camera.options?.isPiPEnabled == true, camera.pipLayout.composition != .inset else { return }
        var layout = camera.pipLayout
        layout.splitSwapped.toggle()
        camera.updatePiPLayout(layout, movieID: movieID, canvasFormat: pipCanvasFormat)
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func finishDollyIfIdle() async {
        guard camera.options?.smoothMoving == false else { return }
        let observedRouteID = activeDolly?.id
        // A lens unlock can briefly publish idle before the new move begins.
        try? await Task.sleep(for: .milliseconds(80))
        guard !Task.isCancelled, camera.options?.smoothMoving == false, !zoomDragging,
              activeDolly?.id == observedRouteID else { return }
        manualZoomTargetShown = false; syncSmoothPosition()
        if smoothZoomOpen, preparedDollyTarget == nil, activeDolly == nil {
            preparedDollyStart = camera.options?.zoom
        }
        let actualZoom = Double(camera.options?.zoom ?? 0)
        if let route = activeDolly, route.hasArrived(at: actualZoom) {
            dollyGuidanceLearned = true
            UIAccessibility.post(notification: .announcement, argument: "Dolly complete")
        }
        activeDolly = nil
        // Keep both endpoints available for reversing or repeating the move.
    }
    private func lensButton(label: String, factor: CGFloat, options: CameraOptions) -> some View {
        let editingEndpoint = smoothZoomOpen && !dollyCollapsed && activeDolly == nil
        let value: CGFloat? = editingEndpoint ? (dollyEditor.selected == .start ? preparedDollyStart : preparedDollyTarget) : options.zoom
        let selected = value.map { abs(factor - $0) < 0.06 } ?? false
        return Button { selectLens(factor) } label: {
            Text(label).font(.caption.weight(.medium)).monospacedDigit()
                .foregroundStyle(selected ? .yellow : .white).frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
                .background(selected ? Color.yellow.opacity(0.15) : .clear, in: Circle())
        }.buttonStyle(DollyLensButtonStyle())
            .disabled(camera.switchingCamera || countdown != nil || smoothZoomOpen && (activeDolly != nil || awaitingDollyHold) || camera.state != .ready && camera.state != .recording)
            .accessibilityLabel("\(label) lens")
            .accessibilityValue(selected ? (editingEndpoint ? "\(dollyEditor.selected.title) lens" : "Current lens") : "")
            .accessibilityHint(smoothZoomOpen ? "Set the selected \(dollyEditor.selected.title.lowercased()) point" : "Switch to this lens")
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
    private var displayedDolly: DollyZoomRoute? {
        if let activeDolly { return activeDolly }
        if let start = preparedDollyStart, let target = preparedDollyTarget {
            return DollyZoomRoute(start: Double(start), destination: Double(target), seconds: dollySeconds)
        }
        return nil
    }
    private func selectLens(_ factor: CGFloat) {
        guard countdown == nil, !camera.switchingCamera,
              camera.state == .ready || camera.state == .recording else { return }
        manualZoomTargetShown = false
        guard smoothZoomOpen else { camera.zoom(factor); return }
        guard activeDolly == nil, !awaitingDollyHold else { return }
        dollyCollapsed = false
        if let options = camera.options { chooseDollyLens(factor, options: options) }
    }
    private func toggleDollyPlayback() {
        if dollyCountdown.remaining != nil { dollyCountdown.cancel(); return }
        guard countdown == nil, !camera.switchingCamera, !awaitingDollyHold,
              camera.state == .ready || camera.state == .recording else { return }
        if activeDolly != nil {
            awaitingDollyHold = true
            let heldMovie = movieID, heldFront = camera.options?.isFront
            camera.pauseSmoothZoom { factor in
                if movieID == heldMovie, camera.options?.isFront == heldFront, smoothZoomOpen, let factor { preparedDollyStart = factor }
                awaitingDollyHold = false
            }
            activeDolly = nil; preparedDollyStart = camera.options?.zoom
            dollyEditor.selected = .end
            manualZoomTargetShown = false
            UIAccessibility.post(notification: .announcement, argument: "Dolly stopped")
        } else if let target = preparedDollyTarget {
            let seconds = DollyZoomDuration.validated(dollySeconds)
            if let start = preparedDollyStart { camera.zoom(start); camera.beginSmoothZoom() }
            dollyCountdown.start(seconds: startDelay, canStart: {
                smoothZoomOpen && scenePhase == .active && !camera.switchingCamera &&
                    (camera.state == .ready || camera.state == .starting || camera.state == .recording) &&
                    preparedDollyTarget == target
            }, onStart: {
                beginDolly(to: target, seconds: seconds)
            })
        }
    }
    private var dollyPlaybackButton: some View {
        Button(action: toggleDollyPlayback) {
            HStack(spacing: 6) {
                Image(systemName: dollyCountdown.remaining != nil ? "xmark" : activeDolly == nil ? "play.fill" : "stop.fill")
                Text(dollyCountdown.remaining != nil ? "Cancel" : activeDolly == nil ? "Go" : "Stop")
            }.font(.caption.weight(.semibold)).foregroundStyle(.yellow)
                .frame(minWidth: 44, minHeight: 44)
                .padding(.horizontal, 8)
                .background(.white.opacity(0.1), in: Capsule())
        }.buttonStyle(DollyLensButtonStyle())
            .disabled(recordingCountdown.remaining != nil || camera.switchingCamera ||
                awaitingDollyHold ||
                camera.state != .ready && camera.state != .recording ||
                activeDolly == nil && (preparedDollyTarget == nil || abs((preparedDollyTarget ?? 0) - (preparedDollyStart ?? 0)) < 0.001))
            .accessibilityLabel(dollyCountdown.remaining != nil ? "Cancel Dolly countdown" : activeDolly == nil ? "Go, Start Dolly" : "Stop Dolly")
            .accessibilityHint("Controls the zoom move. Recording is controlled separately.")
    }
    private func beginDolly(to target: CGFloat, seconds: Int) {
        guard let options = camera.options else { return }
        activeDolly = DollyZoomRoute(start: Double(preparedDollyStart ?? options.zoom), destination: Double(target), seconds: seconds)
        dollyCollapsed = activeDolly != nil
        camera.dollyZoom(to: target, seconds: seconds)
        if activeDolly != nil {
            UIAccessibility.post(notification: .announcement, argument: "Dolly to \(zoomLabel(target, multiplier: options.multiplier)), \(DollyZoomDuration.validated(seconds)) seconds")
        }
    }
    private func dollyGuidance(options: CameraOptions) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                if let route = displayedDolly {
                    Text("\(zoomLabel(CGFloat(route.start), multiplier: options.multiplier)) → \(zoomLabel(CGFloat(route.destination), multiplier: options.multiplier)) · \(route.seconds)s")
                        .font(.caption.weight(.medium)).monospacedDigit().foregroundStyle(.yellow)
                    if activeDolly == nil {
                        Text(dollyCountdown.remaining != nil ? "Dolly starts after countdown" : recordingCountdown.remaining != nil ? "Recording countdown" : "Ready · Tap Go")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                } else if preparedDollyStart != nil {
                    Text("Select End, choose a lens, then Go")
                        .font(.caption).foregroundStyle(.secondary)
                } else if zoomDragging || pinchBase != nil {
                    Text("Manual Dolly").font(.caption).foregroundStyle(.secondary)
                } else if !dollyGuidanceLearned {
                    Text("Select End, choose a lens, then Go")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Dolly").font(.caption).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if preparedDollyTarget != nil, activeDolly == nil {
                Button {
                    preparedDollyStart = options.zoom; preparedDollyTarget = nil
                    dollyEditor.selected = .end
                    UIAccessibility.post(notification: .announcement, argument: "Dolly destination cleared. Your current zoom is the start.")
                } label: {
                    Image(systemName: "arrow.counterclockwise").frame(width: 44, height: 44)
                }.accessibilityLabel("Clear Dolly destination").disabled(countdown != nil || camera.state != .ready && camera.state != .recording)
            }
            Button { showingDollyHelp = true } label: {
                Image(systemName: "questionmark.circle").font(.body)
                    .foregroundStyle(.white.opacity(0.7)).frame(width: 44, height: 44)
            }.accessibilityLabel("How to use Dolly").disabled(camera.busy || countdown != nil)
        }.padding(.leading, 14).padding(.trailing, 4).frame(minHeight: 44)
            .accessibilityElement(children: .contain)
    }
    private var dollySettings: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Response", selection: $zoomSpeed.withSelectionFeedback()) {
                        ForEach(SmoothZoomSpeed.allCases) { speed in Text(speed.label).tag(speed.rawValue) }
                    }
                } header: { Text("Manual Dolly Response") } footer: {
                    Text("\((SmoothZoomSpeed(rawValue: zoomSpeed) ?? .normal).responseDescription) Drag faster or slower to control zoom. This does not change automatic duration.")
                }
                Section {
                    Picker("Duration", selection: $dollySeconds.withSelectionFeedback()) {
                        ForEach(DollyZoomDuration.choices, id: \.self) { seconds in Text("\(seconds) seconds").tag(seconds) }
                    }
                } header: { Text("Automatic Dolly") } footer: {
                    Text("Time for the next move between lenses, including the gentle start and finish. You can also change this in the Dolly bar.")
                }
                Section {
                    Toggle("Stay on This Lens", isOn: $stayOnLens.withSelectionFeedback())
                        .disabled(camera.options?.canStayOnLens != true)
                } footer: {
                    Text("Keeps manual zoom on the current physical camera when supported. Tapping another lens can switch cameras for an automatic Dolly.")
                }
                Section {
                    NavigationLink("How to Use Dolly", destination: dollyHelpContent)
                }
            }.navigationTitle("Dolly Settings").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingDollySettings = false } } }
        }.preferredColorScheme(.dark).presentationDetents([.large]).presentationDragIndicator(.visible)
    }
    private var dollyHelp: some View {
        NavigationStack {
            dollyHelpContent
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingDollyHelp = false } } }
        }.preferredColorScheme(.dark).presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }
    private var dollyHelpContent: some View {
        List {
            Section("Move between lenses") {
                Text("Tap Start or End, then choose a lens. Yellow shows the point you’re editing. Tap a point on the track to select it, or drag to adjust it. Go runs the move; the moving dot shows actual zoom.")
                Text("Go becomes Stop during a move. Stop holds the current view and keeps End ready for another move. Reverse Direction swaps Start and End and previews the new start.")
                Text("Changing Start previews that framing. Changing End sets the destination and keeps the camera still until Go. Selecting a point alone never changes the view. Pinching the video takes over manual zoom.")
                Text("Record controls recording; Go controls the zoom move. Delay waits only before the move, without delaying recording. Tap Cancel to cancel a pending move; use the red record control to stop recording.")
                Text("Tap the video to focus, including during a Dolly move. Lens and Dolly controls adjust zoom without changing focus.")
            }
            Section("Automatic duration") {
                Text("Choose the seconds in the Dolly bar to set how long the next lens-to-lens move takes, including its gentle start and finish.")
            }
            Section("Manual Dolly Response") {
                Text("Drag faster or slower to control zoom. Slow gives a gentler response, Normal is balanced, and Fast responds more quickly. This setting does not change the automatic duration.")
            }
            Section("Start Delay") {
                Text("Delay sets an optional 3, 5 or 7 second wait before the Dolly move. Duration controls the move itself. Record starts immediately, including during a Dolly countdown. Tap Cancel to cancel the pending move without stopping recording.")
            }
            Section {
                Button("Show Dolly Tips Again") { dollyGuidanceLearned = false; showingDollyHelp = false; showingDollySettings = false }
            }
        }.navigationTitle("Dolly").navigationBarTitleDisplayMode(.inline)
    }
    private func dollyMinimum(_ options: CameraOptions) -> CGFloat {
        min(options.minimum, options.lenses.map(\.factor).min() ?? options.minimum)
    }
    private func dollyMaximum(_ options: CameraOptions) -> CGFloat {
        max(options.maximum, options.lenses.map(\.factor).max() ?? options.maximum)
    }
    private func compactDollyBar(options: CameraOptions, route: DollyZoomRoute) -> some View {
        HStack(spacing: 10) {
            Text(zoomLabel(options.zoom, multiplier: options.multiplier))
                .font(.caption.monospacedDigit().weight(.medium))
                .foregroundStyle(.yellow)
                .frame(minWidth: 44)
                .accessibilityLabel("Current zoom")
            ProgressView(value: route.progress(at: Double(options.zoom)))
                .progressViewStyle(.linear).tint(.yellow)
                .accessibilityLabel("Dolly progress")
            dollyPlaybackButton
            if activeDolly == nil {
                Button {
                    dollyCollapsed = false
                    UISelectionFeedbackGenerator().selectionChanged()
                } label: {
                    Image(systemName: "chevron.up").frame(width: 44, height: 44)
                }.buttonStyle(DollyLensButtonStyle())
                    .accessibilityLabel("Expand Dolly controls")
                    .accessibilityHint("Edit Start and End points")
            }
        }.padding(.horizontal, 12).padding(.top, 4)
            .contentShape(Rectangle()).onTapGesture { }
    }
    private func smoothZoomBar(options: CameraOptions) -> some View {
        VStack(spacing: 4) {
            dollyEndpointSelector(options: options)
            dollyTrack(options: options)
                .disabled(countdown != nil || activeDolly != nil || awaitingDollyHold)
            HStack(spacing: 4) {
                dollyStartDelayMenu
                dollyDurationMenu.disabled(countdown != nil || activeDolly != nil)
                if dollyMaximum(options) * options.multiplier > 8 {
                    dollyExtendedMenu(options: options).disabled(countdown != nil || activeDolly != nil || awaitingDollyHold)
                }
                Spacer(minLength: 0)
                Button {
                    guard let start = preparedDollyStart, let end = preparedDollyTarget else { return }
                    preparedDollyStart = end; preparedDollyTarget = start
                    camera.zoom(end); camera.beginSmoothZoom()
                    UISelectionFeedbackGenerator().selectionChanged()
                } label: {
                    Image(systemName: (preparedDollyTarget ?? options.zoom) >= (preparedDollyStart ?? options.zoom) ? "arrow.right" : "arrow.left")
                        .frame(width: 44, height: 44).background(.white.opacity(0.1), in: Circle())
                }.accessibilityLabel("Reverse Dolly direction")
                    .disabled(countdown != nil || activeDolly != nil || awaitingDollyHold)
                dollyPlaybackButton
                Button {
                    cancelCountdown(); camera.endSmoothZoom(); activeDolly = nil; smoothZoomOpen = false
                } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                .accessibilityLabel("Close Dolly")
            }.font(.caption)
        }.padding(.horizontal, 8).padding(.vertical, 4)
            .contentShape(Rectangle()).onTapGesture { }
            .disabled(camera.state != .ready && camera.state != .recording || dollyMaximum(options) <= dollyMinimum(options))
    }
    private func dollyLensStops(options: CameraOptions) -> [CGFloat] {
        // Familiar displayed zoom values, including digital stops beyond the lens range.
        // Keep the hardware ceiling in More rather than presenting it as a native lens.
        let displayed: [CGFloat] = [0.5, 1, 2, 4, 8]
        return displayed.map { $0 / options.multiplier }
            .filter { $0 >= dollyMinimum(options) && $0 <= dollyMaximum(options) }
    }
    private func chooseDollyLens(_ factor: CGFloat, options: CameraOptions) {
        guard countdown == nil, activeDolly == nil, !awaitingDollyHold else { return }
        setDollyEndpoint(factor, start: dollyEditor.selected == .start)
        UISelectionFeedbackGenerator().selectionChanged()
    }
    private func selectDollyEndpoint(_ endpoint: DollyEndpoint) {
        guard countdown == nil, activeDolly == nil, !awaitingDollyHold else { return }
        if dollyEditor.selected != endpoint { UISelectionFeedbackGenerator().selectionChanged() }
        dollyEditor.selected = endpoint
    }
    private func setDollyEndpoint(_ factor: CGFloat, start: Bool) {
        guard activeDolly == nil, countdown == nil, !awaitingDollyHold, let options = camera.options else { return }
        if let preview = dollyEditor.edit(Double(factor), endpoint: start ? .start : .end,
            minimum: Double(dollyMinimum(options)), maximum: Double(dollyMaximum(options)),
            isScrubbing: draggingDollyStart != nil && dollyEndpointMoved) {
            camera.zoom(CGFloat(preview)); camera.beginSmoothZoom()
        }
    }
    private func finishDollyEndpointInteraction() {
        if let start = dollyEditor.finishScrubbing(), activeDolly == nil, countdown == nil {
            camera.zoom(CGFloat(start)); camera.beginSmoothZoom()
        }
        draggingDollyStart = nil; dollyEndpointMoved = false; dollyHapticTick = nil
    }
    private func dollyEndpointSelector(options: CameraOptions) -> some View {
        HStack(spacing: 8) {
            ForEach(DollyEndpoint.allCases) { endpoint in
                let value = endpoint == .start ? preparedDollyStart ?? options.zoom : preparedDollyTarget ?? options.zoom
                let selected = dollyEditor.selected == endpoint
                Button { selectDollyEndpoint(endpoint) } label: {
                    Text("\(endpoint.title) \(zoomLabel(value, multiplier: options.multiplier))")
                        .font(.caption.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(selected ? .yellow : .white)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(selected ? Color.yellow.opacity(0.12) : .clear, in: Capsule())
                        .homeGlass(interactive: true)
                }.buttonStyle(DollyLensButtonStyle())
                    .accessibilityLabel("\(endpoint.title) point")
                    .accessibilityValue(zoomLabel(value, multiplier: options.multiplier))
                    .accessibilityHint("Select to edit with the lens buttons or track")
                    .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }.disabled(countdown != nil || activeDolly != nil || awaitingDollyHold)
    }
    @ViewBuilder private func dollyTrack(options: CameraOptions) -> some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width - 44)
            let start = preparedDollyStart ?? options.zoom
            let end = preparedDollyTarget ?? dollyMaximum(options)
            let a = CGFloat(SmoothZoomFilter.position(Double(start), minimum: Double(dollyMinimum(options)), maximum: Double(dollyMaximum(options))))
            let b = CGFloat(SmoothZoomFilter.position(Double(end), minimum: Double(dollyMinimum(options)), maximum: Double(dollyMaximum(options))))
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.3)).frame(height: 3).padding(.horizontal, 22)
                Capsule().fill(.yellow).frame(width: max(2, abs(b - a) * width), height: 3)
                    .offset(x: 22 + min(a, b) * width)
                ForEach(dollyLensStops(options: options), id: \.self) { factor in
                    Rectangle().fill(.white.opacity(0.5)).frame(width: 1, height: 8)
                        .offset(x: 22 + CGFloat(SmoothZoomFilter.position(Double(factor), minimum: Double(dollyMinimum(options)), maximum: Double(dollyMaximum(options)))) * width)
                }
                ForEach([true, false], id: \.self) { isStart in
                    Circle().fill((isStart ? DollyEndpoint.start : .end) == dollyEditor.selected ? Color.yellow : .white).frame(width: 22, height: 22)
                        .overlay(Text(isStart ? "S" : "E").font(.system(size: 10, weight: .bold)).foregroundStyle(.black))
                        .zIndex((isStart ? DollyEndpoint.start : .end) == dollyEditor.selected ? 1 : 0)
                        .offset(x: 11 + (isStart ? a : b) * width)
                        .accessibilityElement().accessibilityLabel(isStart ? "Start zoom" : "End zoom")
                        .accessibilityValue(zoomLabel(isStart ? start : end, multiplier: options.multiplier))
                        .accessibilityAddTraits((isStart ? DollyEndpoint.start : .end) == dollyEditor.selected ? [.isSelected] : [])
                        .accessibilityAction { selectDollyEndpoint(isStart ? .start : .end) }
                        .accessibilityAdjustableAction { direction in
                            let value = (isStart ? start : end) * CGFloat(pow(2, direction == .increment ? 0.1 : -0.1))
                            selectDollyEndpoint(isStart ? .start : .end)
                            setDollyEndpoint(min(dollyMaximum(options), max(dollyMinimum(options), value)), start: isStart)
                        }
                }
                if let editingStart = draggingDollyStart {
                    Text(zoomLabel(editingStart ? start : end, multiplier: options.multiplier))
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.yellow)
                        .offset(x: min(width - 14, max(0, (editingStart ? a : b) * width)), y: -18)
                }
                if activeDolly != nil {
                    Circle().fill(.yellow).frame(width: 6, height: 6)
                        .offset(x: 19 + CGFloat(SmoothZoomFilter.position(Double(options.zoom), minimum: Double(dollyMinimum(options)), maximum: Double(dollyMaximum(options)))) * width, y: -16)
                }
            }.frame(height: 44).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .updating($dollyEndpointTouching) { _, touching, _ in touching = true }
                    .onChanged { value in
                    if draggingDollyStart == nil {
                        let touched = min(1, max(0, Double((value.startLocation.x - 22) / width)))
                        let previous = dollyEditor.selected
                        dollyEditor.selectNearest(position: touched, startPosition: Double(a), endPosition: Double(b))
                        draggingDollyStart = dollyEditor.selected == .start
                        dollyEndpointMoved = false
                        if previous != dollyEditor.selected { UISelectionFeedbackGenerator().selectionChanged() }
                        if preparedDollyStart == nil { preparedDollyStart = options.zoom }
                    }
                    // A tap selects only. Require intentional horizontal movement before editing.
                    if abs(value.translation.width) >= 6 { dollyEndpointMoved = true }
                    guard dollyEndpointMoved else { return }
                    let position = min(1, max(0, (value.location.x - 22) / width))
                    let factor = dollyMinimum(options) * CGFloat(pow(Double(dollyMaximum(options) / dollyMinimum(options)), Double(position)))
                    setDollyEndpoint(factor, start: draggingDollyStart == true)
                    let stops = dollyLensStops(options: options)
                    let tick = stops.firstIndex { abs(log2(Double(factor / $0))) < 0.035 }
                    if tick != dollyHapticTick {
                        dollyHapticTick = tick
                        if tick != nil { UISelectionFeedbackGenerator().selectionChanged() }
                    }
                }.onEnded { _ in finishDollyEndpointInteraction() })
        }.frame(height: 44)
    }

    private func dollyExtendedMenu(options: CameraOptions) -> some View {
            Menu {
                ForEach(ExtendedZoomTargets.available(minimum: dollyMinimum(options), maximum: dollyMaximum(options),
                    multiplier: options.multiplier), id: \.self) { factor in
                    Button(zoomLabel(factor, multiplier: options.multiplier)) { chooseDollyLens(factor, options: options) }
                }
            } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                .accessibilityLabel("More zoom values")
    }
    private var dollyStartDelayMenu: some View {
        Menu {
            Picker("Start delay", selection: Binding(get: {
                handsFreeStart ? DollyStartDelay.validated(dollyStartDelaySeconds) : 0
            }, set: { seconds in
                UISelectionFeedbackGenerator().selectionChanged()
                handsFreeStart = seconds > 0
                if seconds > 0 { dollyStartDelaySeconds = DollyStartDelay.validated(seconds) }
            })) {
                ForEach(DollyStartDelay.choices, id: \.self) { seconds in
                    Text(seconds == 0 ? "Off" : "\(seconds) seconds").tag(seconds)
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "timer")
                Text(startDelay == 0 ? "Off" : "\(startDelay)s").monospacedDigit()
            }.font(.caption.weight(.medium)).foregroundStyle(dollyDelayedStart ? .yellow : .white)
                .frame(minWidth: 44, minHeight: 44)
        }.accessibilityLabel("Start delay")
            .accessibilityValue(startDelay == 0 ? "Off" : "\(startDelay) seconds")
            .accessibilityHint("Wait before the Dolly move starts. Recording always starts immediately.")
            .disabled(camera.state != .ready && camera.state != .recording || countdown != nil)
    }
    private var dollyDurationMenu: some View {
            Menu {
                Text("Time to move between lenses")
                Picker("Dolly duration", selection: $dollySeconds.withSelectionFeedback()) {
                    ForEach(DollyZoomDuration.choices, id: \.self) { seconds in
                        Text("\(seconds) seconds").tag(seconds)
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Text("\(DollyZoomDuration.validated(dollySeconds))s").monospacedDigit()
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                }.font(.caption.weight(.medium)).frame(minWidth: 44, minHeight: 44)
            }.accessibilityLabel("Dolly duration")
                .accessibilityValue("\(DollyZoomDuration.validated(dollySeconds)) seconds")
                .accessibilityHint("Time for the next automatic move between lenses. Does not change manual dragging.")
    }
    private func setSmoothPosition(_ position: Double, options: CameraOptions, inputTime: Double? = nil, inputEnded: Bool = false) {
        guard smoothZoomOpen, countdown == nil, position.isFinite else { return }
        smoothPosition = min(1, max(0, position))
        let factor = CGFloat(SmoothZoomFilter.factor(smoothPosition, minimum: Double(options.minimum), maximum: Double(options.maximum)))
        if activeDolly != nil {
            camera.endSmoothZoom(); camera.beginSmoothZoom()
        }
        activeDolly = nil; preparedDollyTarget = nil
        preparedDollyStart = factor
        dollyEditor.selected = .end
        manualZoomTargetShown = true
        camera.smoothZoom(to: factor, inputTime: inputTime, inputEnded: inputEnded)
    }
    private func syncSmoothPosition() {
        guard let options = camera.options else { return }
        smoothPosition = SmoothZoomFilter.position(Double(options.zoom), minimum: Double(options.minimum), maximum: Double(options.maximum))
    }
    private func updateZoomSettings() {
        camera.configureSmoothZoom(speed: SmoothZoomSpeed(rawValue: zoomSpeed) ?? .normal, stayOnLens: stayOnLens)
    }
    @ViewBuilder private func status(movie: Movie) -> some View {
        if camera.state == .failed || camera.state == .interrupted {
            VStack(spacing: 8) {
                Text(camera.hasRecoverableTake ? "Clip couldn’t be added" : "Camera paused")
                    .font(.footnote.weight(.semibold))
                Text(camera.hasRecoverableTake ? "The recording file was kept for recovery." : (camera.message ?? "Try again to reconnect the camera."))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { recoveryActions(movie: movie) }
                    VStack(spacing: 4) { recoveryActions(movie: movie) }
                }
            }.padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                .multilineTextAlignment(.center)
        } else if let message = camera.message {
            HStack(spacing: 8) {
                Text(message).font(.caption).lineLimit(2)
                Button { showingErrorDetails = true } label: { MovieControlIcon(systemName: "info.circle") }
                    .accessibilityLabel("Read camera notice").accessibilityHint(message)
            }.padding(.horizontal, 10).homeGlass(interactive: false)
        }
    }
    @ViewBuilder private func recoveryActions(movie: Movie) -> some View {
        Button("Try Again") { Task { await prepareCamera() } }
            .frame(minHeight: 44).buttonStyle(.borderedProminent)
        if camera.hasRecoverableTake {
            Button("Recover Clip") {
                Task { await camera.pauseForPlayback(); showingRecovery = true }
            }.frame(minHeight: 44).buttonStyle(.bordered)
        }
        Button { showingErrorDetails = true } label: { MovieControlIcon(systemName: "info.circle") }
            .accessibilityLabel("Recording error details")
    }
    private func preview() -> some View {
        ZStack {
            CameraPreview(session: camera.service.session, angle: camera.options?.angle ?? 90, front: camera.options?.isFront ?? false,
                options: camera.options, protectedRegions: previewControlRegions + pipProtectedRegion, liveFrames: camera.service.liveFrames,
                liveCube: liveOriginal ? nil : liveCube,
                liveActive: movie?.captureProfile == .appleLog && camera.state.showsLiveLook,
                samplePreview: camera.options?.samplePreview == true,
                displayPaused: showingPiPLayout || camera.options?.dualCameraPrepared == true,
                falseColor: showsFalseColor,
                onLiveLookStatus: { status in
                    guard camera.options?.dualCameraPrepared != true else { return }
                    Task { @MainActor in liveLookStatus = status }
                },
                fixedFormat: activeTakeFormat,
                onFocus: { camera.focus(at: $0, locked: $1) }, onExposure: { camera.exposure($0) })
                .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                .allowsHitTesting(countdown == nil).accessibilityHidden(countdown != nil)
                .accessibilityLabel("Camera viewfinder")
                .accessibilityAction(named: "Focus at center") { _ = camera.focus(at: CGPoint(x: 0.5, y: 0.5)) }
                .accessibilityAction(named: "Lock focus and exposure at center") { _ = camera.focus(at: CGPoint(x: 0.5, y: 0.5), locked: true) }
                .accessibilityAction(named: "Increase brightness") { camera.exposure((camera.options?.exposureBias ?? 0) + 0.5) }
                .accessibilityAction(named: "Decrease brightness") { camera.exposure((camera.options?.exposureBias ?? 0) - 0.5) }
                .gesture(MagnificationGesture().onChanged { value in
                    guard countdown == nil, camera.state == .ready || camera.state == .recording, let options = camera.options else { return }
                    if pinchBase == nil { pinchBase = smoothZoomOpen ? options.zoom : options.zoom }
                    if Date().timeIntervalSince(lastZoomAt) > 0.05 {
                        let target = (pinchBase ?? options.zoom) * value
                        if smoothZoomOpen {
                            setSmoothPosition(SmoothZoomFilter.position(Double(target), minimum: Double(options.minimum), maximum: Double(options.maximum)), options: options, inputTime: Date().timeIntervalSinceReferenceDate)
                        } else { camera.zoom(target) }
                        lastZoomAt = Date()
                    }
                }.onEnded { _ in pinchBase = nil; if smoothZoomOpen { camera.endSmoothInput() } })
            if camera.options?.dualCameraPrepared == true {
                PiPCompositionPreview(rearFrames: camera.service.pipRearFrames,
                    frontFrames: camera.service.pipPresenterFrames, layout: camera.pipLayout,
                    format: pipCanvasFormat,
                    liveFrames: camera.service.liveFrames, paused: showingPiPLayout,
                    sourceFront: camera.options?.isFront == true, falseColor: showsFalseColor,
                    profile: movie?.captureProfile ?? .standard, cube: liveOriginal ? nil : liveCube,
                    onStatus: { status in if liveLookStatus != status { liveLookStatus = status } })
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            if let countdown {
                VStack(spacing: 6) {
                    Text(dollyCountdown.remaining != nil ? "Dolly starts in…" : "Recording starts in…")
                        .font(.subheadline.weight(.medium))
                    Text("\(countdown)").font(.system(size: 64, weight: .light, design: .rounded))
                        .contentTransition(.numericText())
                }.foregroundStyle(.white).shadow(color: .black.opacity(0.5), radius: 8)
                    .allowsHitTesting(false)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(dollyCountdown.remaining != nil ? "Dolly" : "Recording") in \(countdown) seconds")
            }
            if camera.state == .denied {
                VStack(spacing: 12) {
                    Text("Camera and microphone access are needed to record.").multilineTextAlignment(.center)
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }.padding(20).background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 14))
                    .padding(24)
            }
        }
    }
    private var recordControl: some View {
        Button {
            if camera.recordingSessionActive { cancelCountdown(); camera.stop() }
            else if recordingCountdown.remaining != nil { recordingCountdown.cancel() }
            else { startRecording() }
        } label: {
            ZStack {
                Circle().fill(.black.opacity(0.25)).frame(width: 78, height: 78)
                Circle().strokeBorder(.white, lineWidth: 3).frame(width: 78, height: 78)
                if camera.state == .starting || camera.state == .finalizing {
                    ProgressView().tint(.white)
                } else if recordingCountdown.remaining != nil {
                    Image(systemName: "xmark").font(.system(size: 24, weight: .medium)).foregroundStyle(.white)
                } else {
                    RoundedRectangle(cornerRadius: camera.recordingSessionActive ? 5 : 32)
                        .fill(.red).frame(width: camera.recordingSessionActive ? 29 : 62, height: camera.recordingSessionActive ? 29 : 62)
                }
            }
        }.buttonStyle(.plain)
            .disabled(!camera.recordingSessionActive && (camera.switchingCamera || pipConfiguring ||
                camera.pendingPiPEnabled != nil || undoingTake || camera.state != .ready))
            .opacity(!camera.recordingSessionActive && camera.state != .ready ? 0.4 : 1)
            .accessibilityLabel(recordingCountdown.remaining != nil ? "Cancel recording countdown" : camera.state == .starting ? "Cancel starting recording" : camera.state == .finalizing ? "Saving recording" : camera.recordingSessionActive ? "Stop recording" : "Record next clip")
    }
    @ViewBuilder private func reviewControls(movie: Movie, landscape: Bool) -> some View {
        let recent = Button { openWatch(sceneID: movie.activeScenes.last?.id) } label: {
            SceneThumbnail(scene: movie.activeScenes.last, root: app.store.root, movie: movie)
                .frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 8))
        }.accessibilityLabel("Review recent clip").disabled(camera.busy || movie.activeScenes.isEmpty)
            .contextMenu {
                if let last = movie.latestTake {
                    Button("Undo Last Clip", systemImage: "arrow.uturn.backward") { undoLastTake(last.id) }
                        .disabled(camera.busy || undoingTake)
                }
            }
            .accessibilityHint("Opens the latest clip. Touch and hold for Undo Last Clip.")
        let flip = Button { camera.flip() } label: {
            ZStack {
                MovieControlIcon(systemName: "arrow.triangle.2.circlepath.camera")
                    .opacity(!camera.switchingCamera && camera.recordingFlip == nil ? 1 : 0)
                if camera.switchingCamera || camera.recordingFlip != nil { ProgressView().tint(.white) }
            }.background(.white.opacity(0.15), in: Circle())
        }.accessibilityLabel(camera.switchingCamera || camera.recordingFlip != nil ? "Switching camera" : "Switch camera")
            .accessibilityHint(movie.captureProfile == .appleLog ?
                (camera.options?.canFlipWhileRecording == true ? "Switch cameras while keeping this Log clip and microphone recording continuous." : camera.state == .recording ? CameraCompatibility.logRecordingFlipExplanation : camera.options?.canFlip == true ? "Switch cameras before recording." : CameraCompatibility.logCameraExplanation) : "Switch between the front and rear cameras.")
            .disabled(!camera.canFlipCamera)
        let watch = VStack(spacing: 0) {
            Button { openWatch() } label: {
                Label("Watch Movie", systemImage: "play.fill")
                    .font(.footnote).frame(minHeight: 44)
            }.disabled(camera.busy || movie.activeScenes.isEmpty)
                .accessibilityLabel("Watch movie")
            Text("\(durationLabel(movie.duration)) total")
                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                .accessibilityLabel("Total movie runtime, \(durationLabel(movie.duration))")
        }
        if landscape {
            VStack(spacing: 8) {
                flip
                Spacer(minLength: 8)
                Button { openWatch() } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "play.fill").font(.system(size: 18, weight: .semibold))
                            .frame(width: 44, height: 44).background(.white.opacity(0.12), in: Circle())
                        Text("Movie").font(.caption.weight(.medium)).lineLimit(1)
                        Text(durationLabel(movie.duration)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity)
                }.buttonStyle(.plain).disabled(camera.busy || movie.activeScenes.isEmpty)
                    .accessibilityLabel("Watch movie")
                    .accessibilityValue("Total runtime, \(durationLabel(movie.duration))")
                Spacer(minLength: 8)
                recent
                    .overlay(alignment: .top) {
                        recentTakeFeedback(movie: movie).fixedSize().offset(y: -64)
                    }
            }.padding(.horizontal, 8).padding(.vertical, 28)
        } else {
            HStack(spacing: 8) {
                HStack(spacing: 4) { recent; recentTakeFeedback(movie: movie) }
                Spacer(minLength: 0)
                watch
                Spacer(minLength: 0)
                flip
            }
        }
    }
    @ViewBuilder private func recentTakeFeedback(movie: Movie) -> some View {
        VStack(spacing: 0) {
            if camera.state == .finalizing {
                VStack(spacing: 4) {
                    ProgressView().controlSize(.small).tint(.white)
                    Text("Saving…").font(.caption2)
                }.frame(minWidth: 44, minHeight: 44)
                    .accessibilityElement(children: .ignore).accessibilityLabel("Saving clip")
                    .transition(.opacity)
            } else if let id = addedSceneID, movie.latestTake?.id == id, !camera.busy {
                VStack(spacing: 0) {
                    Label("Saved", systemImage: "checkmark").font(.caption2).foregroundStyle(.secondary)
                    Button("Undo") { undoLastTake(id) }
                        .font(.caption.weight(.medium)).frame(minWidth: 44, minHeight: 44)
                        .disabled(undoingTake).accessibilityLabel("Undo last clip")
                        .accessibilityHint("Moves the latest clip to Recently Deleted. You can restore it in Settings.")
                }.transition(.opacity)
            }
        }.animation(.easeInOut(duration: 0.2), value: camera.state == .finalizing)
            .animation(.easeInOut(duration: 0.2), value: addedSceneID)
    }
    private func undoLastTake(_ sceneID: UUID) {
        guard !camera.busy, !undoingTake else { return }
        undoingTake = true
        let destination = movieID
        Task {
            defer { undoingTake = false }
            do {
                try await app.store.undoLastTake(movieID: destination, expectedSceneID: sceneID)
                await app.refresh()
                addedSceneID = nil; camera.savedScene = false
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch { camera.message = error.localizedDescription }
        }
    }
    private func zoomLabel(_ factor: CGFloat, multiplier: CGFloat) -> String {
        String(format: "%g×", Double((factor * multiplier * 10).rounded() / 10))
    }
    private func startRecording() {
        guard !pipConfiguring, camera.pendingPiPEnabled == nil, camera.state == .ready, recordingCountdown.remaining == nil, scenePhase == .active else { return }
        camera.record(movieID: movieID)
    }
    private func cancelCountdown() {
        recordingCountdown.cancel(); dollyCountdown.cancel()
    }
    private func openWatch(sceneID: UUID? = nil) {
        guard !camera.busy else { return }
        Task { await camera.pauseForPlayback(); initialReviewID = sceneID; watching = true }
    }
    private func prepareCamera() async {
        let plan = CameraCompatibility.preparationPlan(profile: movie?.captureProfile ?? .standard,
            storedPreference: movie?.dualCameraCapture == true, requested: enablePiPAfterPreparation,
            currentlyEnabled: camera.options?.isPiPEnabled == true,
            settingsPreview: showingPiPLayout, previewSupported: camera.options?.canPreparePiP == true)
        if showingPiPLayout, plan.dualCamera, !plan.enablePiP { preparedPiPForSettings = true }
        await camera.prepare(profile: movie?.captureProfile ?? .standard, movieID: movieID,
            dualCamera: plan.dualCamera, layout: movie?.preferredPiPLayout ?? PiPLayout(),
            canvasFormat: pipCanvasFormat, enablePiP: plan.enablePiP)
    }
    private func resumeCameraIfRequested() {
        guard foregroundResume.consumeIfReady(state: camera.state, busy: camera.busy,
            foreground: scenePhase == .active, cameraVisible: !watching && !showingRecovery,
            recoverableTake: camera.hasRecoverableTake) else { return }
        let lifecycle = camera.lifecycleID
        Task { @MainActor in
            guard scenePhase == .active, !watching, !showingRecovery,
                  camera.lifecycleID == lifecycle, !camera.busy,
                  camera.state != .failed, !camera.hasRecoverableTake else { return }
            await prepareCamera()
        }
    }
    private func syncPiPCanvas() {
        guard !camera.busy, camera.options?.dualCameraPrepared == true else { return }
        camera.service.setPiPLayout(camera.pipLayout, canvasFormat: pipCanvasFormat)
    }
    private var normalizedPiPObstacles: [CGRect] {
        guard viewfinderSize.width > 0, viewfinderSize.height > 0 else { return [] }
        return previewControlRegions.map {
            CGRect(x: $0.minX / viewfinderSize.width, y: $0.minY / viewfinderSize.height,
                width: $0.width / viewfinderSize.width, height: $0.height / viewfinderSize.height)
        }.filter { !$0.isEmpty }
    }
    private func updatePiPObstacles() { camera.service.setPiPObstacles([]) }
    private var pipProtectedRegion: [CGRect] {
        guard camera.pipPresentation.opacity > 0, viewfinderSize.width > 0 else { return [] }
        let r = camera.pipPresentation.rect
        return [CGRect(x: r.minX * viewfinderSize.width, y: r.minY * viewfinderSize.height,
            width: r.width * viewfinderSize.width, height: r.height * viewfinderSize.height)]
    }
    private var pipInteraction: some View {
        GeometryReader { geometry in
            if camera.options?.dualCameraPrepared == true, camera.pipPresentation.opacity > 0.001 {
                PiPMeteringView(frames: camera.service.liveFrames, presentation: camera.pipPresentation,
                    front: camera.options?.frontMetering, rear: camera.options?.rearMetering,
                    protectedRegions: previewControlRegions,
                    onFocus: { point, locked, front in camera.focus(at: point, locked: locked, front: front) },
                    onExposure: { bias, front in camera.exposure(bias, front: front) },
                    onMove: { point, finished in camera.dragPiP(to: point, finished: finished) })
                    .accessibilityLabel("Dual camera viewfinder")
                    .accessibilityHint("Tap either camera to focus and expose. Drag the sun vertically to adjust its brightness. Drag the inset to move it. Release to snap to a corner.")
                    .accessibilityAction(named: "Focus Presenter") { _ = camera.focus(at: CGPoint(x: 0.5, y: 0.5), front: true) }
                    .accessibilityAction(named: "Move to Top Left") { movePiP(to: .topLeft) }
                    .accessibilityAction(named: "Move to Top Right") { movePiP(to: .topRight) }
                    .accessibilityAction(named: "Move to Bottom Left") { movePiP(to: .bottomLeft) }
                    .accessibilityAction(named: "Move to Bottom Right") { movePiP(to: .bottomRight) }
            } else { Color.clear.allowsHitTesting(false) }
        }.onGeometryChange(for: CGSize.self) { $0.size } action: { size in viewfinderSize = size; updatePiPObstacles() }
    }
    private func movePiP(to corner: PiPCorner) {
        let format = pipCanvasFormat
        let center = PiPGeometry.desiredCenter(corner: corner, canvas: format.canvas, size: camera.pipLayout.size, orientation: camera.pipLayout.orientation)
        camera.dragPiP(to: center, finished: true)
    }
    private func preparePiPSettingsPreview() {
        guard !camera.busy, !pipConfiguring, let movie,
              camera.options?.canPreparePiP == true, camera.options?.piPAvailable != true else { return }
        pipConfiguring = true
        preparedPiPForSettings = true
        Task {
            defer { pipConfiguring = false }
            guard showingPiPLayout, scenePhase == .active else { return }
            // Settings needs both live feeds even when PiP is off in the viewfinder.
            // Do not dismiss the sheet, enable the inset or persist a Dual Camera choice.
            await camera.prepare(profile: movie.captureProfile, movieID: movieID, dualCamera: true,
                layout: camera.pipLayout,
                canvasFormat: pipCanvasFormat,
                enablePiP: false)
        }
    }
    private func enableDualCamera() {
        guard !camera.busy, !pipConfiguring, camera.pendingPiPEnabled == nil,
              countdown == nil, let movie, camera.options?.canPreparePiP == true else { return }
        pipConfiguring = true
        camera.beginPiPChange(to: true)
        enablePiPAfterPreparation = true
        let lifecycle = camera.lifecycleID
        Task {
            defer { pipConfiguring = false }
            do {
                let destination = movie.id
                try await app.store.setDualCameraCapture(movieID: destination, enabled: true)
                await app.refresh()
                guard camera.lifecycleID == lifecycle else { return }
                movieID = destination
                preparedPiPForSettings = false
                if scenePhase == .active {
                    if camera.options?.piPAvailable == true { camera.setPiPEnabled(true) }
                    else {
                        await camera.prepare(profile: movie.captureProfile, movieID: destination, dualCamera: true,
                            layout: camera.pipLayout, canvasFormat: pipCanvasFormat, enablePiP: true)
                    }
                } else { camera.cancelPiPChange() }
            } catch {
                guard camera.lifecycleID == lifecycle else { return }
                camera.cancelPiPChange(); enablePiPAfterPreparation = false; camera.message = error.localizedDescription
            }
        }
    }
    private func disableDualCamera() {
        guard !camera.busy, !pipConfiguring, camera.pendingPiPEnabled == nil, countdown == nil else { return }
        pipConfiguring = true; enablePiPAfterPreparation = false
        camera.beginPiPChange(to: false)
        let lifecycle = camera.lifecycleID
        Task {
            defer { pipConfiguring = false }
            do {
                try await app.store.setDualCameraCapture(movieID: movieID, enabled: false)
                await app.refresh()
                guard camera.lifecycleID == lifecycle else { return }
                // Keep both live feeds available while choosing a layout with PiP off.
                // Dismissal restores the ordinary camera without persisting preview preparation.
                preparedPiPForSettings = showingPiPLayout
                camera.setPiPEnabled(false)
                if !showingPiPLayout, scenePhase == .active { await prepareCamera() }
            }
            catch {
                guard camera.lifecycleID == lifecycle else { return }
                camera.cancelPiPChange(); camera.message = error.localizedDescription
            }
        }
    }
}



