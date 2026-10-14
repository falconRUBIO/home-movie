import SwiftUI
import AVFoundation
import UIKit
import UniformTypeIdentifiers

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
private extension View {
    func cameraControlRegion() -> some View {
        background {
            GeometryReader { geometry in
                Color.clear.preference(key: CameraControlRegionsKey.self,
                    value: [geometry.frame(in: .named("cameraViewfinder"))])
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
    @State private var liveOriginal = false
    @State private var liveLookStatus = LiveLookStatus.inactive
    @State private var manualZoomTargetShown = false
    @State private var looks: [LUTReference] = []
    @State private var addingLook = false
    @State private var changingLook = false
    @State private var addedSceneID: UUID?
    @State private var undoingTake = false
    @State private var smoothZoomOpen = false
    @State private var lensControlHeight: CGFloat = 52
    @State private var previewControlRegions: [CGRect] = []
    @State private var smoothPosition = 0.0
    @State private var zoomDragging = false
    @StateObject private var recordingCountdown = RecordingCountdown()
    @StateObject private var dollyCountdown = RecordingCountdown()
    @State private var draggingDollyStart: Bool?
    @State private var preparedDollyStart: CGFloat?
    @State private var preparedDollyTarget: CGFloat?
    @State private var activeDolly: DollyZoomRoute?
    @State private var showingDollyHelp = false
    @State private var showingDollySettings = false
    @State private var showingPiPLayout = false
    @State private var showingPiPCompatibility = false
    @State private var viewfinderSize = CGSize.zero
    @State private var pipDragStart: CGPoint?
    @State private var lastPiPDragPoint: CGPoint?
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
        _camera = StateObject(wrappedValue: CameraModel(app: app))
    }
    private var countdown: Int? { recordingCountdown.remaining ?? dollyCountdown.remaining }
    private var startDelay: Int { DollyStartDelay.effective(handsFreeStart ? dollyStartDelaySeconds : 0, dollyOpen: smoothZoomOpen) }
    private var dollyDelayedStart: Bool { startDelay > 0 }
    private var movie: Movie? { app.movie(movieID) }
    private var activeTakeFormat: MovieFormat? { camera.busy ? camera.takeFormat : nil }
    private var cameraSurface: some View {
        GeometryReader { geometry in
            let landscape = geometry.size.width > geometry.size.height
            if let movie {
                let footerHeight: CGFloat = dynamicTypeSize.isAccessibilitySize ? 100 : 64
                let railWidth: CGFloat = 112
                let phoneRatio: CGFloat = landscape ? 16.0 / 9.0 : 9.0 / 16.0
                let canvasFormat = movie.recordingFormat ?? activeTakeFormat
                let canvasRatio: CGFloat = canvasFormat?.aspect ?? phoneRatio
                let ratio: CGFloat = camera.options?.dualCameraPrepared == true ? canvasRatio : phoneRatio
                let availableWidth = max(1, geometry.size.width - (landscape ? railWidth : 0))
                let availableHeight = max(1, geometry.size.height - (landscape ? 0 : footerHeight))
                let previewWidth = min(availableWidth, availableHeight * ratio)
                let previewHeight = previewWidth / ratio
                // Keep one viewfinder/UIViewRepresentable identity across rotation.
                // Switching between HStack/VStack branches destroys and reattaches the
                // native preview connection (and the Cinema Metal surface).
                ZStack(alignment: .topLeading) {
                    viewfinder(movie: movie, landscape: landscape)
                        .frame(width: previewWidth, height: previewHeight)
                        .position(x: availableWidth / 2, y: availableHeight / 2)
                    reviewControls(movie: movie, landscape: landscape).disabled(countdown != nil)
                        .padding(.horizontal, landscape ? 0 : 20)
                        .frame(width: landscape ? railWidth : geometry.size.width,
                               height: landscape ? geometry.size.height : footerHeight)
                        .background(.black)
                        .position(x: landscape ? geometry.size.width - railWidth / 2 : geometry.size.width / 2,
                                  y: landscape ? geometry.size.height / 2 : geometry.size.height - footerHeight / 2)
                }.frame(width: geometry.size.width, height: geometry.size.height)

            } else { ContentUnavailableView("Movie unavailable", systemImage: "film") }
        }
        .background(MovieOrientation(format: activeTakeFormat).frame(width: 0, height: 0))
        .background(.black).foregroundStyle(.white)
        .toolbar(.hidden, for: .navigationBar).navigationBarBackButtonHidden()
        .preferredColorScheme(.dark)
    }
    private var configuredCamera: some View {
        cameraSurface
        .task(id: movieID) {
            liveOriginal = false
            updateZoomSettings()
            await prepareCamera()
            looks = await app.store.availableLooks()
        }
        .task(id: "\(movieID)-\(movie?.look?.id.uuidString ?? "standard")") {
            guard movie?.captureProfile == .appleLog else { liveCube = nil; return }
            liveCube = nil; liveLookStatus = .preparing
            let reference = movie?.look, root = app.store.root
            do {
                let loaded = try await Task.detached(priority: .userInitiated) {
                    if let reference { return try ColorCube.load(reference, root: root) }
                    return try ColorCube.appleStandard.get()
                }.value
                guard !Task.isCancelled else { return }; liveCube = loaded
            } catch { if !Task.isCancelled { liveCube = nil; liveLookStatus = .unavailable; camera.message = "This look could not be loaded. Choose Apple Standard." } }
        }
        .fileImporter(isPresented: $addingLook, allowedContentTypes: [UTType(filenameExtension: "cube") ?? .data], allowsMultipleSelection: false) { result in
            changingLook = true
            Task {
                defer { changingLook = false }
                do {
                    let urls = try result.get()
                    if let url = urls.first {
                        let look = try await app.store.importLook(from: url)
                        try await app.store.setLook(movieID: movieID, look: look)
                        liveOriginal = false; looks = await app.store.availableLooks(); await app.refresh()
                    }
                } catch { camera.message = error.localizedDescription }
                await prepareCamera()
            }
        }
        .onChange(of: handsFreeStart) { _, _ in
            cancelCountdown()
        }
        .onChange(of: dollyStartDelaySeconds) { _, _ in cancelCountdown() }
        .onChange(of: zoomSpeed) { _, _ in updateZoomSettings() }
        .onChange(of: stayOnLens) { _, _ in updateZoomSettings() }
        .onChange(of: camera.options?.minimum) { _, _ in if !zoomDragging { syncSmoothPosition() } }
        .onChange(of: camera.options?.maximum) { _, _ in if !zoomDragging { syncSmoothPosition() } }
        .onChange(of: camera.savedScene) { _, saved in
            if saved {
                addedSceneID = movie?.activeScenes.last?.id
                UIAccessibility.post(notification: .announcement, argument: "Scene saved")
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
        .task(id: camera.options?.smoothMoving) { await finishDollyIfIdle() }
        .onChange(of: camera.options?.isPiPEnabled) { _, enabled in
            if enabled == true { enablePiPAfterPreparation = false }
        }
        .onChange(of: camera.pipSetupFailed) { _, failed in if failed { enablePiPAfterPreparation = false } }
        .onChange(of: movie?.recordingFormat) { _, format in
            if camera.options?.dualCameraPrepared == true { camera.service.setPiPLayout(camera.pipLayout, canvasFormat: format) }
        }
        .onDisappear { cancelCountdown(); activeDolly = nil; zoomDragging = false; camera.suspend() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { cancelCountdown(); activeDolly = nil; zoomDragging = false; camera.suspend() }
            else if !watching && !showingRecovery && !camera.busy { Task { await prepareCamera() } }
        }
    }
    var body: some View {
        activeCamera
        .sheet(isPresented: $showingRecovery, onDismiss: {
            Task { await prepareCamera() }
        }) { RecordingRecoveryView().environmentObject(app) }
        .sheet(isPresented: $showingDollyHelp) { dollyHelp }
        .sheet(isPresented: $showingDollySettings) { dollySettings }
        .sheet(isPresented: $showingPiPLayout) {
            PiPLayoutView(layout: Binding(get: { camera.pipLayout }, set: { camera.updatePiPLayout($0, movieID: movieID) }),
                format: movie?.recordingFormat ?? MovieFormat.captureFormat(angle: camera.options?.angle ?? 90) ?? .portrait,
                rearFrames: camera.service.pipRearFrames, frontFrames: camera.service.pipPresenterFrames,
                ready: camera.options?.piPAvailable == true, canPrepare: camera.options?.canPreparePiP == true,
                logMode: movie?.captureProfile == .appleLog, obstacles: [],
                onPrepare: { enableDualCamera() })
        }
        .sheet(isPresented: $showingPiPCompatibility) { pipCompatibility }
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
                Menu {
                    Button { liveOriginal.toggle() } label: { Label("Show Original", systemImage: liveOriginal ? "checkmark" : "circle") }
                    Divider()
                    Button { changeLiveLook(nil) } label: { Label("Apple Standard", systemImage: movie.look == nil ? "checkmark" : "circle") }
                    ForEach(looks, id: \.id) { look in
                        Button { changeLiveLook(look) } label: { Label(look.displayName, systemImage: movie.look?.id == look.id ? "checkmark" : "circle") }
                    }
                    Divider()
                    Button("Add Apple Log Look…", systemImage: "plus") { addingLook = true }.disabled(camera.busy)
                } label: { MovieControlIcon(systemName: "slider.horizontal.3").homeGlass() }
                    .accessibilityLabel("Live look: \(liveOriginal ? "Original Log" : movie.lookName)")
                    .disabled(changingLook)
            }
            Menu {
                if let options = camera.options {
                    Text(options.recordingFormat)
                    if options.profile == .appleLog {
                        Text(CameraCompatibility.logPiPExplanation)
                        Text(camera.state == .recording ? CameraCompatibility.logRecordingFlipExplanation :
                            options.canFlip ? "Camera flip is available before recording. It is unavailable during a Log take." : CameraCompatibility.logCameraExplanation)
                    }
                    Divider()
                }
                Button("Dolly Settings", systemImage: "slider.horizontal.3") { showingDollySettings = true }
                    .disabled(camera.busy)
                Button("PiP Layout…", systemImage: "rectangle.on.rectangle") { showingPiPLayout = true }
                    .disabled(camera.busy)
                if camera.options?.dualCameraPrepared == true {
                    Button("Use Ordinary Camera", systemImage: "camera") { disableDualCamera() }.disabled(camera.busy)
                }
                Button("Dolly Help", systemImage: "questionmark.circle") { showingDollyHelp = true }
                    .disabled(camera.busy)
                if let last = movie.activeScenes.last {
                    Divider()
                    Button("Undo Last Take", systemImage: "arrow.uturn.backward") { undoLastTake(last.id) }
                        .disabled(camera.busy || undoingTake)
                }
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
    private func viewfinder(movie: Movie, landscape: Bool) -> some View {
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
                lenses.cameraControlRegion().zIndex(2).background {
                    GeometryReader { proxy in
                        Color.clear.preference(key: DollyControlHeightKey.self, value: proxy.size.height)
                    }
                }.onPreferenceChange(DollyControlHeightKey.self) { lensControlHeight = $0 }
                    .padding(.horizontal, landscape ? 100 : 12)
                    .padding(.bottom, landscape ? 10 : 116)
            }
            .overlay(alignment: landscape ? .trailing : .bottom) {
                recordControl.cameraControlRegion().zIndex(3).padding(landscape ? .trailing : .bottom, 16)
            }
            .coordinateSpace(name: "cameraViewfinder")
            .onPreferenceChange(CameraControlRegionsKey.self) { previewControlRegions = $0; updatePiPObstacles() }
    }
    private func captureIndicators(movie: Movie) -> some View {
        VStack(spacing: 6) {
            if movie.captureProfile == .appleLog {
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
            VStack(spacing: 0) {
                if smoothZoomOpen {
                    smoothZoomBar(options: options)
                }
                if !smoothZoomOpen {
                ViewThatFits(in: .horizontal) {
                    lensButtons(options: options)
                    ScrollView(.horizontal) { lensButtons(options: options) }
                        .scrollIndicators(.hidden).frame(height: dynamicTypeSize.isAccessibilitySize ? 64 : 44)
                }.padding(4)
                }
            }.dollyControlGlass().frame(maxWidth: 360)
        }
    }
    private func lensButtons(options: CameraOptions) -> some View {
        HStack(spacing: 6) {
            ForEach(options.lenses) { lens in
                lensButton(label: lens.label, factor: lens.factor, options: options)
            }
            if options.maximum > options.minimum || smoothZoomOpen {
                Button {
                    manualZoomTargetShown = false
                    preparedDollyStart = nil; preparedDollyTarget = nil; activeDolly = nil
                    if smoothZoomOpen { camera.endSmoothZoom(); smoothZoomOpen = false }
                    else {
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
            PiPControl(enabled: options.isPiPEnabled,
                unavailableReason: options.profile == .appleLog ? CameraCompatibility.logPiPExplanation : nil,
                disabled: countdown != nil || camera.state != .ready && camera.state != .recording || camera.state == .recording && !options.piPAvailable,
                onToggle: {
                    if options.piPAvailable { camera.togglePiP() }
                    else if !camera.busy { showingPiPCompatibility = true }
                }, onLayout: { if !camera.busy { showingPiPLayout = true } })
        }
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
        let selected = abs(factor - options.zoom) < 0.06
        let route = displayedDolly
        let start = route?.start ?? preparedDollyStart.map { Double($0) }
        let isStart = start.map { abs($0 - Double(factor)) < 0.06 } ?? false
        let isDestination = route.map { abs($0.destination - Double(factor)) < 0.06 } ?? false
        let highlighted = isDestination || route == nil && (isStart || selected)
        let foreground: Color = highlighted ? .yellow : .white
        let background: Color = isDestination ? .yellow.opacity(0.2) : isStart || route == nil && selected ? .white.opacity(0.15) : .clear
        let border: Color = isDestination ? .yellow : isStart ? .white.opacity(0.5) : .clear
        let value = isDestination ? "Dolly destination" : isStart ? "Dolly start" : selected ? "Current lens" : ""
        let hint: String
        if !smoothZoomOpen { hint = "Switch to this lens." }
        else { hint = "Choose this destination without moving. Tap Start Dolly to start." }
        return Button { selectLens(factor) } label: {
            Text(label).font(.caption.weight(.medium)).monospacedDigit()
                .foregroundStyle(foreground).frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
                .background(background, in: Circle())
                .overlay { Circle().strokeBorder(border, lineWidth: isDestination ? 1.5 : 1) }
        }.buttonStyle(DollyLensButtonStyle())
            .disabled(camera.switchingCamera || countdown != nil || camera.state != .ready && camera.state != .recording)
            .accessibilityLabel("\(label) lens").accessibilityValue(value).accessibilityHint(hint)
            .accessibilityAddTraits(highlighted ? .isSelected : [])
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
        // Selecting a destination never starts a move.
        if activeDolly != nil || camera.options?.smoothMoving == true {
            camera.endSmoothZoom(); camera.beginSmoothZoom()
        }
        activeDolly = nil
        preparedDollyStart = camera.options?.zoom
        if let start = preparedDollyStart, abs(start - factor) > 0.001 { preparedDollyTarget = factor }
        else { preparedDollyTarget = nil }
        UISelectionFeedbackGenerator().selectionChanged()
        if preparedDollyTarget != nil {
            UIAccessibility.post(notification: .announcement, argument: "Destination selected. Tap Start Dolly to move.")
        }
    }
    private func toggleDollyPlayback() {
        if dollyCountdown.remaining != nil { dollyCountdown.cancel(); return }
        guard countdown == nil, !camera.switchingCamera,
              camera.state == .ready || camera.state == .recording else { return }
        if activeDolly != nil {
            camera.endSmoothZoom(); camera.beginSmoothZoom()
            activeDolly = nil; preparedDollyTarget = nil; preparedDollyStart = camera.options?.zoom
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
                camera.state != .ready && camera.state != .recording ||
                activeDolly == nil && (preparedDollyTarget == nil || abs((preparedDollyTarget ?? 0) - (preparedDollyStart ?? 0)) < 0.001))
            .accessibilityLabel(dollyCountdown.remaining != nil ? "Cancel Dolly countdown" : activeDolly == nil ? "Start Dolly" : "Stop Dolly")
            .accessibilityHint("Controls the zoom move. Recording is controlled separately.")
    }
    private func beginDolly(to target: CGFloat, seconds: Int) {
        guard let options = camera.options else { return }
        activeDolly = DollyZoomRoute(start: Double(preparedDollyStart ?? options.zoom), destination: Double(target), seconds: seconds)
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
                        Text(dollyCountdown.remaining != nil ? "Dolly starts after countdown" : recordingCountdown.remaining != nil ? "Recording countdown" : "Ready · Tap Start Dolly")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                } else if preparedDollyStart != nil {
                    Text("Choose a destination, then Start Dolly")
                        .font(.caption).foregroundStyle(.secondary)
                } else if zoomDragging || pinchBase != nil {
                    Text("Manual Dolly").font(.caption).foregroundStyle(.secondary)
                } else if !dollyGuidanceLearned {
                    Text("Choose a destination, then Start Dolly")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Dolly").font(.caption).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if preparedDollyTarget != nil, activeDolly == nil {
                Button {
                    preparedDollyStart = options.zoom; preparedDollyTarget = nil
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
                    Picker("Response", selection: $zoomSpeed) {
                        ForEach(SmoothZoomSpeed.allCases) { speed in Text(speed.label).tag(speed.rawValue) }
                    }
                } header: { Text("Manual Dolly Response") } footer: {
                    Text("\((SmoothZoomSpeed(rawValue: zoomSpeed) ?? .normal).responseDescription) Drag faster or slower to control zoom. This does not change automatic duration.")
                }
                Section {
                    Picker("Duration", selection: $dollySeconds) {
                        ForEach(DollyZoomDuration.choices, id: \.self) { seconds in Text("\(seconds) seconds").tag(seconds) }
                    }
                } header: { Text("Automatic Dolly") } footer: {
                    Text("Time for the next move between lenses, including the gentle start and finish. You can also change this in the Dolly bar.")
                }
                Section {
                    Toggle("Stay on This Lens", isOn: $stayOnLens)
                        .disabled(camera.options?.canStayOnLens != true)
                } footer: {
                    Text("Keeps manual zoom on the current physical camera when supported. Tapping another lens can switch cameras for an automatic Dolly.")
                }
            }.navigationTitle("Dolly Settings").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingDollySettings = false } } }
        }.preferredColorScheme(.dark).presentationDetents([.large]).presentationDragIndicator(.visible)
    }
    private var dollyHelp: some View {
        NavigationStack {
            List {
                Section("Move between lenses") {
                    Text("Drag the Start and End handles on the full zoom scale. The preview shows Start. Tap the circular arrow to reverse direction, then tap Start Dolly. The small moving dot shows actual zoom.")
                    Text("Start Dolly becomes Stop Dolly during a move. Stop holds the current zoom. Reverse Direction swaps Start and End and shows the new starting frame.")
                    Text("Dragging Start changes the preview. Dragging End chooses the destination without moving the preview. Pinching the video takes over manual zoom.")
                    Text("Record controls recording; Start Dolly controls the zoom move. Delay waits only before the Dolly move; recording starts immediately. Duration sets the zoom duration. During a take, Start Dolly counts down without interrupting recording. Tap Cancel to cancel that countdown, or the red Stop button to end the take.")
                    Text("Tap the video to focus, including during a Dolly move. Lens and Dolly controls adjust zoom without changing focus.")
                }
                Section("Automatic duration") {
                    Text("Choose the seconds in the Dolly bar to set how long the next lens-to-lens move takes, including its gentle start and finish.")
                }
                Section("Manual Dolly Response") {
                    Text("Drag faster or slower to control zoom. Slow gives a gentler response, Normal is balanced, and Fast responds more quickly. This setting does not change the automatic duration.")
                }
                Section("Start Delay") {
                    Text("Delay sets an optional 3, 5 or 7 second wait before the Dolly move. Duration controls the move itself. Record starts immediately, including during a Dolly countdown. Tap Start Dolly again to cancel the pending move without stopping recording.")
                }
                Section {
                    Button("Show Dolly Tips Again") { dollyGuidanceLearned = false; showingDollyHelp = false }
                }
            }.navigationTitle("Dolly").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingDollyHelp = false } } }
        }.preferredColorScheme(.dark).presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }
    private func smoothZoomBar(options: CameraOptions) -> some View {
        VStack(spacing: 0) {
            dollyTrack(options: options)
                .disabled(countdown != nil || activeDolly != nil)
            HStack(spacing: 4) {
                dollyStartDelayMenu
                dollyDurationMenu.disabled(countdown != nil || activeDolly != nil)
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
                    .disabled(countdown != nil || activeDolly != nil)
                dollyPlaybackButton
                Button {
                    cancelCountdown(); camera.endSmoothZoom(); activeDolly = nil; smoothZoomOpen = false
                } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                .accessibilityLabel("Close Dolly")
            }.font(.caption)
        }.padding(.horizontal, 8).padding(.vertical, 4)
            .contentShape(Rectangle()).onTapGesture { }
            .disabled(camera.state != .ready && camera.state != .recording || options.maximum <= options.minimum)
    }
    private func dollyLensStops(options: CameraOptions) -> [CGFloat] {
        // Familiar displayed zoom values, including digital stops beyond the lens range.
        // Keep the hardware ceiling in More rather than presenting it as a native lens.
        let displayed: [CGFloat] = [0.5, 1, 2, 4, 8]
        return displayed.map { $0 / options.multiplier }
            .filter { $0 >= options.minimum && $0 <= options.maximum }
    }
    private func chooseDollyLens(_ factor: CGFloat, options: CameraOptions) {
        guard countdown == nil, activeDolly == nil else { return }
        // A lens tap immediately shows that lens and updates the starting handle.
        preparedDollyStart = factor
        if preparedDollyTarget == nil || abs((preparedDollyTarget ?? factor) - factor) < 0.001 {
            preparedDollyTarget = factor < options.maximum ? min(options.maximum, factor * 2) : options.minimum
        }
        camera.zoom(factor); camera.beginSmoothZoom()
        UISelectionFeedbackGenerator().selectionChanged()
    }
    private func setDollyEndpoint(_ factor: CGFloat, start: Bool) {
        guard activeDolly == nil, countdown == nil else { return }
        if start {
            preparedDollyStart = factor
            camera.zoom(factor); camera.beginSmoothZoom()
        } else { preparedDollyTarget = factor }
    }
    @ViewBuilder private func dollyTrack(options: CameraOptions) -> some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width - 44)
            let start = preparedDollyStart ?? options.zoom
            let end = preparedDollyTarget ?? options.maximum
            let a = CGFloat(SmoothZoomFilter.position(Double(start), minimum: Double(options.minimum), maximum: Double(options.maximum)))
            let b = CGFloat(SmoothZoomFilter.position(Double(end), minimum: Double(options.minimum), maximum: Double(options.maximum)))
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.3)).frame(height: 3).padding(.horizontal, 22)
                Capsule().fill(.yellow).frame(width: max(2, abs(b - a) * width), height: 3)
                    .offset(x: 22 + min(a, b) * width)
                ForEach(options.lenses.filter { $0.factor > options.minimum && $0.factor < options.maximum }) { lens in
                    Rectangle().fill(.white.opacity(0.5)).frame(width: 1, height: 8)
                        .offset(x: 22 + CGFloat(SmoothZoomFilter.position(Double(lens.factor), minimum: Double(options.minimum), maximum: Double(options.maximum))) * width)
                }
                ForEach([true, false], id: \.self) { isStart in
                    Circle().fill(isStart ? Color.white : Color.yellow).frame(width: 22, height: 22)
                        .overlay(Text(isStart ? "S" : "E").font(.system(size: 10, weight: .bold)).foregroundStyle(.black))
                        .offset(x: 11 + (isStart ? a : b) * width)
                        .accessibilityElement().accessibilityLabel(isStart ? "Start zoom" : "End zoom")
                        .accessibilityValue(zoomLabel(isStart ? start : end, multiplier: options.multiplier))
                        .accessibilityAdjustableAction { direction in
                            let value = (isStart ? start : end) * CGFloat(pow(2, direction == .increment ? 0.1 : -0.1))
                            setDollyEndpoint(min(options.maximum, max(options.minimum, value)), start: isStart)
                        }
                }
                if activeDolly != nil {
                    Circle().fill(.yellow).frame(width: 6, height: 6)
                        .offset(x: 19 + CGFloat(SmoothZoomFilter.position(Double(options.zoom), minimum: Double(options.minimum), maximum: Double(options.maximum))) * width, y: -16)
                }
            }.frame(height: 44).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    let position = min(1, max(0, (value.location.x - 22) / width))
                    if draggingDollyStart == nil { draggingDollyStart = abs(position - a) <= abs(position - b) }
                    let factor = options.minimum * CGFloat(pow(Double(options.maximum / options.minimum), Double(position)))
                    setDollyEndpoint(factor, start: draggingDollyStart == true)
                }.onEnded { _ in draggingDollyStart = nil })
        }.frame(height: 44)
        HStack(spacing: 0) {
            ForEach(dollyLensStops(options: options), id: \.self) { factor in
                Button { chooseDollyLens(factor, options: options) } label: {
                    Text(zoomLabel(factor, multiplier: options.multiplier))
                        .font(.caption.monospacedDigit().weight(.medium))
                        .foregroundStyle(abs(factor - options.zoom) < 0.06 ? .yellow : .white)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }.buttonStyle(DollyLensButtonStyle())
                    .accessibilityLabel("Set starting lens to \(zoomLabel(factor, multiplier: options.multiplier))")
            }
            Menu {
                ForEach(ExtendedZoomTargets.available(minimum: options.minimum, maximum: options.maximum,
                    multiplier: options.multiplier), id: \.self) { factor in
                    Button(zoomLabel(factor, multiplier: options.multiplier)) { chooseDollyLens(factor, options: options) }
                }
            } label: {
                Image(systemName: "ellipsis").frame(width: 44, height: 44)
            }.accessibilityLabel("More zoom values")
        }.disabled(countdown != nil || activeDolly != nil)
    }
    private var dollyStartDelayMenu: some View {
        Menu {
            Picker("Start delay", selection: Binding(get: {
                handsFreeStart ? DollyStartDelay.validated(dollyStartDelaySeconds) : 0
            }, set: { seconds in
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
                Picker("Dolly duration", selection: $dollySeconds) {
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
                Text(camera.hasRecoverableTake ? "Take couldn’t be added" : "Camera paused")
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
            Button("Recover Take") {
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
                onLiveLookStatus: { status in
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
                    format: movie?.recordingFormat ?? activeTakeFormat ??
                        MovieFormat.captureFormat(angle: camera.options?.angle ?? 90) ?? .portrait,
                    liveFrames: camera.service.liveFrames, paused: showingPiPLayout,
                    sourceFront: camera.options?.isFront == true)
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
            if camera.state == .preparing {
                ProgressView("Preparing camera…").padding().background(.black.opacity(0.8), in: Capsule())
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
            .disabled(camera.switchingCamera && !camera.recordingSessionActive || pipConfiguring || undoingTake ||
                !camera.recordingSessionActive && camera.state != .ready)
            .opacity(!camera.recordingSessionActive && camera.state != .ready ? 0.4 : 1)
            .accessibilityLabel(recordingCountdown.remaining != nil ? "Cancel recording countdown" : camera.state == .starting ? "Cancel starting recording" : camera.state == .finalizing ? "Saving recording" : camera.recordingSessionActive ? "Stop recording" : "Record next scene")
    }
    @ViewBuilder private func reviewControls(movie: Movie, landscape: Bool) -> some View {
        let recent = Button { openWatch(sceneID: movie.activeScenes.last?.id) } label: {
            SceneThumbnail(scene: movie.activeScenes.last, root: app.store.root, movie: movie)
                .frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 8))
        }.accessibilityLabel("Review recent scene").disabled(camera.busy || movie.activeScenes.isEmpty)
        let flip = Button { camera.flip() } label: {
            ZStack {
                MovieControlIcon(systemName: "arrow.triangle.2.circlepath.camera")
                    .opacity(camera.recordingFlip == nil ? 1 : 0)
                if camera.recordingFlip != nil { ProgressView().tint(.white) }
            }.background(.white.opacity(0.15), in: Circle())
        }.accessibilityLabel(camera.recordingFlip == nil ? "Switch camera" : "Switching camera")
            .accessibilityHint(movie.captureProfile == .appleLog ?
                (camera.state == .recording ? CameraCompatibility.logRecordingFlipExplanation : camera.options?.canFlip == true ? "Switch cameras before recording." : CameraCompatibility.logCameraExplanation) : "Switch between the front and rear cameras.")
            .disabled(camera.switchingCamera || camera.recordingFlip != nil || camera.state != .ready && camera.state != .recording || camera.options?.canFlip != true ||
                movie.captureProfile == .appleLog && camera.state == .recording && camera.options?.canFlipWhileRecording != true ||
                camera.options?.isPiPEnabled == true || camera.pipPresentation.opacity > 0)
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
            VStack(spacing: 12) {
                VStack(spacing: 0) { recent; recentTakeFeedback(movie: movie) }
                watch
                flip
            }.padding(.horizontal, 8)
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
                    .accessibilityElement(children: .ignore).accessibilityLabel("Saving scene")
                    .transition(.opacity)
            } else if let id = addedSceneID, movie.activeScenes.last?.id == id, !camera.busy {
                VStack(spacing: 0) {
                    Label("Saved", systemImage: "checkmark").font(.caption2).foregroundStyle(.secondary)
                    Button("Undo") { undoLastTake(id) }
                        .font(.caption.weight(.medium)).frame(minWidth: 44, minHeight: 44)
                        .disabled(undoingTake).accessibilityLabel("Undo last take")
                        .accessibilityHint("Moves the latest scene to Recently Deleted. You can restore it in Settings.")
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
    private func changeLiveLook(_ look: LUTReference?) {
        guard !changingLook else { return }
        changingLook = true; liveOriginal = false
        Task {
            defer { changingLook = false }
            await app.run { try await app.store.setLook(movieID: movieID, look: look) }
        }
    }
    private func zoomLabel(_ factor: CGFloat, multiplier: CGFloat) -> String {
        String(format: "%g×", Double((factor * multiplier * 10).rounded() / 10))
    }
    private func startRecording() {
        guard !pipConfiguring, camera.state == .ready, recordingCountdown.remaining == nil, scenePhase == .active else { return }
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
        let usePiP = CameraCompatibility.shouldPreparePiP(profile: movie?.captureProfile ?? .standard,
            storedPreference: movie?.dualCameraCapture == true, requested: enablePiPAfterPreparation,
            currentlyEnabled: camera.options?.isPiPEnabled == true)
        await camera.prepare(profile: movie?.captureProfile ?? .standard, movieID: movieID,
            dualCamera: usePiP, layout: movie?.preferredPiPLayout ?? PiPLayout(),
            canvasFormat: movie?.recordingFormat, enablePiP: usePiP)
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
            if camera.pipPresentation.opacity > 0.001 {
                let r = camera.pipPresentation.rect
                Color.clear.frame(width: r.width * geometry.size.width, height: r.height * geometry.size.height)
                    .contentShape(Rectangle()).onTapGesture { }
                    .gesture(pipDragGesture(size: geometry.size))
                    .position(x: r.midX * geometry.size.width, y: r.midY * geometry.size.height)
                    .accessibilityElement(children: .ignore).accessibilityLabel("Presenter inset")
                    .accessibilityHint("Hold briefly, then drag to another corner.")
                    .accessibilityAction(named: "Move to Top Left") { movePiP(to: .topLeft) }
                    .accessibilityAction(named: "Move to Top Right") { movePiP(to: .topRight) }
                    .accessibilityAction(named: "Move to Bottom Left") { movePiP(to: .bottomLeft) }
                    .accessibilityAction(named: "Move to Bottom Right") { movePiP(to: .bottomRight) }
            }
        }.onGeometryChange(for: CGSize.self) { $0.size } action: { size in viewfinderSize = size; updatePiPObstacles() }
    }
    private func pipDragGesture(size: CGSize) -> some Gesture {
        LongPressGesture(minimumDuration: 0.25).sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named("cameraViewfinder")))
            .onChanged { value in
                guard camera.options?.isPiPEnabled == true, size.width > 0, size.height > 0 else { return }
                switch value {
                case .first(true):
                    if pipDragStart == nil { pipDragStart = CGPoint(x: camera.pipPresentation.rect.midX, y: camera.pipPresentation.rect.midY) }
                case .second(true, let drag?):
                    let anchor = pipDragStart ?? CGPoint(x: camera.pipPresentation.rect.midX, y: camera.pipPresentation.rect.midY)
                    pipDragStart = anchor
                    let point = CGPoint(x: anchor.x + drag.translation.width / size.width, y: anchor.y + drag.translation.height / size.height)
                    lastPiPDragPoint = point; camera.dragPiP(to: point, finished: false)
                default: break
                }
            }.onEnded { _ in
                if let point = lastPiPDragPoint ?? pipDragStart { camera.dragPiP(to: point, finished: true) }
                lastPiPDragPoint = nil; pipDragStart = nil
            }
    }
    private func movePiP(to corner: PiPCorner) {
        let format = movie?.recordingFormat ?? activeTakeFormat ?? MovieFormat.captureFormat(angle: camera.options?.angle ?? 90) ?? .portrait
        let center = PiPGeometry.desiredCenter(corner: corner, canvas: format.canvas, size: camera.pipLayout.size, orientation: camera.pipLayout.orientation)
        camera.dragPiP(to: center, finished: true)
    }
    private var pipCompatibility: some View {
        NavigationStack {
            Form {
                Section("Dual Camera") {
                    Text(movie?.captureProfile == .appleLog ? CameraCompatibility.logPiPExplanation : "Prepare both cameras before a take so PiP can appear and disappear without restarting video or audio.")
                    Text("1080p · 30 fps · SDR · H.264\nRear 1× wide camera with digital zoom. One continuous microphone.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if movie?.captureProfile == .appleLog {
                        Text("Choose a Standard movie before recording with PiP.").foregroundStyle(.secondary)
                    } else if camera.options?.canPreparePiP == true {
                        Button("Use Dual Camera") { enableDualCamera() }
                    } else { Text("This iPhone cannot use the required front/rear camera combination.").foregroundStyle(.secondary) }
                }
            }.navigationTitle("Picture-in-Picture").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showingPiPCompatibility = false } } }
        }.presentationDetents([.medium]).presentationDragIndicator(.visible)
    }
    private func enableDualCamera() {
        guard !camera.busy, !pipConfiguring, countdown == nil, let movie, movie.captureProfile == .standard, camera.options?.canPreparePiP == true else { return }
        pipConfiguring = true; showingPiPLayout = false; showingPiPCompatibility = false
        enablePiPAfterPreparation = true
        Task {
            defer { pipConfiguring = false }
            do {
                let destination = movie.id
                try await app.store.setDualCameraCapture(movieID: destination, enabled: true)
                await app.refresh(); movieID = destination
                if scenePhase == .active { await prepareCamera() }
            } catch { enablePiPAfterPreparation = false; camera.message = error.localizedDescription }
        }
    }
    private func disableDualCamera() {
        guard !camera.busy, !pipConfiguring, countdown == nil else { return }
        pipConfiguring = true; enablePiPAfterPreparation = false
        Task {
            defer { pipConfiguring = false }
            do { try await app.store.setDualCameraCapture(movieID: movieID, enabled: false); await app.refresh(); await prepareCamera() }
            catch { camera.message = error.localizedDescription }
        }
    }
}



