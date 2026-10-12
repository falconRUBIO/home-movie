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
    @State private var preparedDollyStart: CGFloat?
    @State private var preparedDollyTarget: CGFloat?
    @State private var queuedDolly: (target: CGFloat, seconds: Int)?
    @State private var activeDolly: DollyZoomRoute?
    @State private var showingDollyHelp = false
    @State private var showingDollySettings = false
    @AppStorage("dollyGuidanceLearned") private var dollyGuidanceLearned = false
    @AppStorage("handsFreeStart") private var handsFreeStart = false
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
    private var countdown: Int? { recordingCountdown.remaining }
    private var movie: Movie? { app.movie(movieID) }
    private var establishedFormat: MovieFormat? { movie?.recordingFormat ?? (camera.busy ? camera.takeFormat : nil) }
    private var cameraSurface: some View {
        GeometryReader { geometry in
            let landscape = geometry.size.width > geometry.size.height
            if let movie {
                let footerHeight: CGFloat = dynamicTypeSize.isAccessibilitySize ? 100 : 64
                let railWidth: CGFloat = 112
                let ratio: CGFloat = landscape ? 16 / 9 : 9 / 16
                let availableWidth = max(1, geometry.size.width - (landscape ? railWidth : 0))
                let availableHeight = max(1, geometry.size.height - (landscape ? 0 : footerHeight))
                let previewWidth = min(availableWidth, availableHeight * ratio)
                let previewHeight = previewWidth / ratio
                if landscape {
                    HStack(spacing: 0) {
                        viewfinder(movie: movie, landscape: true)
                            .frame(width: previewWidth, height: previewHeight)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        reviewControls(movie: movie, landscape: true).disabled(countdown != nil)
                            .frame(width: railWidth).frame(maxHeight: .infinity).background(.black)
                    }
                } else {
                    VStack(spacing: 0) {
                        viewfinder(movie: movie, landscape: false)
                            .frame(width: previewWidth, height: previewHeight)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        reviewControls(movie: movie, landscape: false).disabled(countdown != nil)
                            .padding(.horizontal, 20).frame(height: footerHeight)
                            .frame(maxWidth: .infinity).background(.black)
                    }
                }
            } else { ContentUnavailableView("Movie unavailable", systemImage: "film") }
        }
        .background(MovieOrientation(format: establishedFormat).frame(width: 0, height: 0))
        .background(.black).foregroundStyle(.white)
        .toolbar(.hidden, for: .navigationBar).navigationBarBackButtonHidden()
        .preferredColorScheme(.dark)
    }
    private var configuredCamera: some View {
        cameraSurface
        .task(id: movieID) {
            liveOriginal = false
            updateZoomSettings()
            await camera.prepare(profile: movie?.captureProfile ?? .standard)
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
                await camera.prepare(profile: movie?.captureProfile ?? .standard)
            }
        }
        .onChange(of: handsFreeStart) { _, _ in
            cancelCountdown(); preparedDollyStart = nil; preparedDollyTarget = nil
        }
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
            if state == .recording, let move = queuedDolly {
                queuedDolly = nil
                preparedDollyStart = nil; preparedDollyTarget = nil
                beginDolly(to: move.target, seconds: move.seconds)
            }
            if state == .failed || state == .interrupted || state == .denied || state == .preparing {
                cancelCountdown()
            }
            zoomDragging = false
            if state != .ready && state != .recording { manualZoomTargetShown = false }
            if state != .ready && state != .recording && state != .starting {
                activeDolly = nil; preparedDollyStart = nil; preparedDollyTarget = nil
            }
            if smoothZoomOpen, state == .ready { camera.beginSmoothZoom() }
        }
        .onChange(of: camera.options?.isFront) { _, _ in
            cancelCountdown(); preparedDollyStart = nil; preparedDollyTarget = nil
            activeDolly = nil
        }
        .onChange(of: camera.options?.zoom) { _, _ in
            if !zoomDragging && !manualZoomTargetShown { syncSmoothPosition() }
        }
        .task(id: camera.options?.smoothMoving) { await finishDollyIfIdle() }
        .onDisappear { cancelCountdown(); activeDolly = nil; zoomDragging = false; camera.suspend() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { cancelCountdown(); activeDolly = nil; zoomDragging = false; camera.suspend() }
            else if !watching && !showingRecovery && !camera.busy { Task { await camera.prepare(profile: movie?.captureProfile ?? .standard) } }
        }
    }
    var body: some View {
        activeCamera
        .sheet(isPresented: $showingRecovery, onDismiss: {
            Task { await camera.prepare(profile: movie?.captureProfile ?? .standard) }
        }) { RecordingRecoveryView().environmentObject(app) }
        .sheet(isPresented: $showingDollyHelp) { dollyHelp }
        .sheet(isPresented: $showingDollySettings) { dollySettings }
        .alert("Recording Details", isPresented: $showingErrorDetails) {
            Button("OK", role: .cancel) { }
        } message: { Text(camera.message ?? "No additional details are available.") }
        .fullScreenCover(isPresented: $watching, onDismiss: { Task { await camera.prepare(profile: movie?.captureProfile ?? .standard) } }) {
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
                    Divider()
                }
                Toggle("Hands-Free Start", isOn: $handsFreeStart)
                    .disabled(camera.busy)
                if handsFreeStart { Text("Waits 3 seconds before recording") }
                Divider()
                Button("Dolly Settings", systemImage: "slider.horizontal.3") { showingDollySettings = true }
                    .disabled(camera.busy)
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
            .onPreferenceChange(CameraControlRegionsKey.self) { previewControlRegions = $0 }
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
            if handsFreeStart, countdown == nil, camera.state == .ready {
                Label("3s", systemImage: "timer").font(.caption2).foregroundStyle(.white.opacity(0.8))
                    .accessibilityLabel("Hands-free start, three-second countdown")
            }
            if camera.state == .recording {
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
                    dollyGuidance(options: options)
                    smoothZoomBar(options: options)
                }
                ViewThatFits(in: .horizontal) {
                    lensButtons(options: options)
                    ScrollView(.horizontal) { lensButtons(options: options) }
                        .scrollIndicators(.hidden).frame(height: dynamicTypeSize.isAccessibilitySize ? 64 : 44)
                }.padding(4)
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
                    else { syncSmoothPosition(); smoothZoomOpen = true; camera.beginSmoothZoom() }
                } label: {
                    MovieControlIcon(systemName: "waveform.path")
                        .foregroundStyle(smoothZoomOpen ? .yellow : .white)
                        .background(smoothZoomOpen ? Color.white.opacity(0.15) : .clear, in: Circle())
                }.accessibilityLabel("Dolly").accessibilityValue(smoothZoomOpen ? "Open" : "Closed")
                    .accessibilityAddTraits(smoothZoomOpen ? .isSelected : [])
                    .disabled(countdown != nil || !smoothZoomOpen && camera.state != .ready && camera.state != .recording)
            }
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
        let actualZoom = Double(camera.options?.zoom ?? 0)
        if let route = activeDolly, route.hasArrived(at: actualZoom) {
            dollyGuidanceLearned = true
            UIAccessibility.post(notification: .announcement, argument: "Dolly complete")
        }
        activeDolly = nil
    }
    private func lensButton(label: String, factor: CGFloat, options: CameraOptions) -> some View {
        let selected = abs(factor - options.zoom) < 0.06
        let route = displayedDolly
        let start = route?.start ?? preparedDollyStart.map { Double($0) }
        let isStart = start.map { abs($0 - Double(factor)) < 0.06 } ?? false
        let isDestination = route.map { abs($0.destination - Double(factor)) < 0.06 } ?? false
        let highlighted = isDestination || route == nil && selected
        let foreground: Color = highlighted ? .yellow : .white
        let background: Color = isDestination ? .yellow.opacity(0.2) : isStart || route == nil && selected ? .white.opacity(0.15) : .clear
        let border: Color = isDestination ? .yellow : isStart ? .white.opacity(0.5) : .clear
        let value = isDestination ? "Dolly destination" : isStart ? "Dolly start" : selected ? "Current lens" : ""
        let hint: String
        if !smoothZoomOpen { hint = "Switch to this lens." }
        else if handsFreeStart && camera.state == .ready { hint = "Choose the starting or destination lens, then tap Record." }
        else { hint = "Smoothly move to this lens using the selected duration." }
        return Button { selectLens(factor) } label: {
            Text(label).font(.caption.weight(.medium)).monospacedDigit()
                .foregroundStyle(foreground).frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
                .background(background, in: Circle())
                .overlay { Circle().strokeBorder(border, lineWidth: isDestination ? 1.5 : 1) }
        }.buttonStyle(DollyLensButtonStyle())
            .disabled(countdown != nil || camera.state != .ready && camera.state != .recording)
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
        manualZoomTargetShown = false
        guard smoothZoomOpen else { camera.zoom(factor); return }
        UISelectionFeedbackGenerator().selectionChanged()
        if handsFreeStart, camera.state == .ready {
            activeDolly = nil
            if preparedDollyStart == nil {
                preparedDollyStart = factor; preparedDollyTarget = nil
                camera.zoom(factor)
            } else if let start = preparedDollyStart, abs(start - factor) > 0.001 {
                preparedDollyTarget = factor
                UIAccessibility.post(notification: .announcement, argument: "Dolly ready. Tap Record to start the countdown.")
            } else { preparedDollyTarget = nil }
        } else {
            preparedDollyStart = nil; preparedDollyTarget = nil
            beginDolly(to: factor, seconds: dollySeconds)
        }
    }
    private func beginDolly(to target: CGFloat, seconds: Int) {
        guard let options = camera.options else { return }
        activeDolly = DollyZoomRoute(start: Double(options.zoom), destination: Double(target), seconds: seconds)
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
                        Text(countdown != nil ? "Starts after countdown" : "Ready · Tap Record to start")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                } else if handsFreeStart, camera.state == .ready, preparedDollyStart != nil {
                    Text("Choose the destination lens")
                        .font(.caption).foregroundStyle(.secondary)
                } else if zoomDragging || pinchBase != nil {
                    Text("Manual Dolly").font(.caption).foregroundStyle(.secondary)
                } else if !dollyGuidanceLearned {
                    Text(handsFreeStart && camera.state == .ready ? "Choose two lenses, then tap Record." : "Tap another lens to dolly from here.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Dolly").font(.caption).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if preparedDollyStart != nil, activeDolly == nil {
                Button {
                    preparedDollyStart = nil; preparedDollyTarget = nil; queuedDolly = nil
                    UIAccessibility.post(notification: .announcement, argument: "Dolly route cleared. Choose a starting lens.")
                } label: {
                    Image(systemName: "arrow.counterclockwise").frame(width: 44, height: 44)
                }.accessibilityLabel("Reset Dolly route").disabled(camera.busy || countdown != nil)
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
                    Toggle("Hands-Free Start", isOn: $handsFreeStart)
                } footer: {
                    Text("Choose a starting lens and a destination, then tap Record. Recording begins after a three-second countdown, followed by the Dolly move.")
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
                    Text("Your current zoom is the starting point. Tap another lens to move smoothly to it. The outlined lens is your destination, and the dot follows the camera’s actual zoom.")
                    Text("Tap a different lens during a move to change the destination. Drag the track or pinch the viewfinder to take manual control.")
                    Text("Opening or closing Dolly does not start or stop recording.")
                }
                Section("Automatic duration") {
                    Text("Choose the seconds in the Dolly bar to set how long the next lens-to-lens move takes, including its gentle start and finish.")
                }
                Section("Manual Dolly Response") {
                    Text("Drag faster or slower to control zoom. Slow gives a gentler response, Normal is balanced, and Fast responds more quickly. This setting does not change the automatic duration.")
                }
                Section("Hands-Free Start") {
                    Text("Choose a starting lens, then a destination. Tap another lens to change the destination, or Reset to choose a new starting point. Tap Record for the three-second countdown. The Dolly starts when recording begins.")
                }
                Section {
                    Button("Show Dolly Tips Again") { dollyGuidanceLearned = false; showingDollyHelp = false }
                }
            }.navigationTitle("Dolly").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingDollyHelp = false } } }
        }.preferredColorScheme(.dark).presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }
    private func smoothZoomBar(options: CameraOptions) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                dollyZoomValue(options: options)
                dollyTrack(options: options).frame(minWidth: 88)
                dollyDurationMenu
            }
            VStack(spacing: 0) {
                HStack {
                    dollyZoomValue(options: options)
                    Spacer(minLength: 8)
                    dollyDurationMenu
                }
                dollyTrack(options: options)
            }
        }.padding(.horizontal, 12).padding(.vertical, 5)
            .contentShape(Rectangle()).onTapGesture { }
            .frame(maxWidth: 360).disabled(camera.state != .ready && camera.state != .recording || options.maximum <= options.minimum || countdown != nil)
    }
    private func dollyZoomValue(options: CameraOptions) -> some View {
        Text(zoomLabel(options.zoom, multiplier: options.multiplier))
            .font(.caption.monospacedDigit()).frame(minWidth: 42)
    }
    private func dollyTrack(options: CameraOptions) -> some View {
            GeometryReader { geometry in
                let width = max(1, geometry.size.width - 16)
                let actualPosition = SmoothZoomFilter.position(Double(options.zoom), minimum: Double(options.minimum), maximum: Double(options.maximum))
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.3)).frame(height: 2).padding(.horizontal, 8)
                    if let route = displayedDolly {
                        let start = SmoothZoomFilter.position(route.start, minimum: Double(options.minimum), maximum: Double(options.maximum))
                        let end = SmoothZoomFilter.position(route.destination, minimum: Double(options.minimum), maximum: Double(options.maximum))
                        Capsule().fill(.yellow.opacity(0.25)).frame(width: max(2, CGFloat(abs(end - start)) * width), height: 3)
                            .offset(x: 8 + CGFloat(min(start, end)) * width)
                        if activeDolly != nil {
                            let reached = start + (end - start) * route.progress(at: Double(options.zoom))
                            Capsule().fill(.yellow).frame(width: max(2, CGFloat(abs(reached - start)) * width), height: 3)
                                .offset(x: 8 + CGFloat(min(start, reached)) * width)
                        }
                        Circle().strokeBorder(.yellow, lineWidth: 1.5).frame(width: 8, height: 8)
                            .offset(x: 4 + CGFloat(end) * width)
                    }
                    ForEach(options.lenses.filter { $0.factor >= options.minimum && $0.factor <= options.maximum }) { lens in
                        Rectangle().fill(.white.opacity(0.45)).frame(width: 1, height: 6)
                            .offset(x: 8 + CGFloat(SmoothZoomFilter.position(Double(lens.factor), minimum: Double(options.minimum), maximum: Double(options.maximum))) * width)
                    }
                    Circle().fill(activeDolly == nil ? .white : .yellow).frame(width: 14, height: 14)
                        .offset(x: 1 + CGFloat(actualPosition) * width)
                }.frame(height: 44).contentShape(Rectangle())
                    .animation(reduceMotion ? nil : .linear(duration: 0.05), value: actualPosition)
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        zoomDragging = true
                        setSmoothPosition(Double((value.location.x - 8) / width), options: options, inputTime: value.time.timeIntervalSinceReferenceDate)
                    }.onEnded { value in
                        setSmoothPosition(Double((value.location.x - 8) / width), options: options, inputTime: value.time.timeIntervalSinceReferenceDate, inputEnded: true)
                        zoomDragging = false
                    })
            }.frame(height: 44)
                .accessibilityElement(children: .ignore).accessibilityLabel("Zoom")
                .accessibilityValue(String(format: "%.1f times", Double(options.zoom * options.multiplier)))
                .accessibilityAdjustableAction { direction in
                    let factor = Double(options.zoom) * pow(2, direction == .increment ? 0.25 : -0.25)
                    setSmoothPosition(SmoothZoomFilter.position(factor, minimum: Double(options.minimum), maximum: Double(options.maximum)), options: options)
                }
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
        preparedDollyStart = nil; preparedDollyTarget = nil; activeDolly = nil
        smoothPosition = min(1, max(0, position))
        manualZoomTargetShown = true
        camera.smoothZoom(to: CGFloat(SmoothZoomFilter.factor(smoothPosition, minimum: Double(options.minimum), maximum: Double(options.maximum))), inputTime: inputTime, inputEnded: inputEnded)
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
        Button("Try Again") { Task { await camera.prepare(profile: movie.captureProfile) } }
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
                options: camera.options, protectedRegions: previewControlRegions, liveFrames: camera.service.liveFrames,
                liveCube: liveOriginal ? nil : liveCube,
                liveActive: movie?.captureProfile == .appleLog && camera.state.showsLiveLook,
                onLiveLookStatus: { status in
                    Task { @MainActor in liveLookStatus = status }
                },
                fixedFormat: establishedFormat,
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
                    if pinchBase == nil { pinchBase = options.zoom }
                    if Date().timeIntervalSince(lastZoomAt) > 0.05 {
                        let target = (pinchBase ?? options.zoom) * value
                        if smoothZoomOpen {
                            manualZoomTargetShown = false
                            preparedDollyStart = nil; preparedDollyTarget = nil; activeDolly = nil
                            camera.smoothZoom(to: target, inputTime: Date().timeIntervalSinceReferenceDate)
                        } else { camera.zoom(target) }
                        lastZoomAt = Date()
                    }
                }.onEnded { _ in pinchBase = nil; if smoothZoomOpen { camera.endSmoothInput() } })
            if let countdown {
                Text("\(countdown)").font(.system(size: 64, weight: .light, design: .rounded))
                    .foregroundStyle(.white).shadow(color: .black.opacity(0.5), radius: 8)
                    .contentTransition(.numericText()).allowsHitTesting(false)
                    .accessibilityLabel("Recording in \(countdown) seconds")
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
            if countdown != nil { cancelCountdown() }
            else if camera.state == .recording { camera.stop() }
            else { startRecording() }
        } label: {
            ZStack {
                Circle().fill(.black.opacity(0.25)).frame(width: 78, height: 78)
                Circle().strokeBorder(.white, lineWidth: 3).frame(width: 78, height: 78)
                if countdown != nil {
                    Image(systemName: "xmark").font(.system(size: 24, weight: .medium)).foregroundStyle(.white)
                } else {
                    RoundedRectangle(cornerRadius: camera.state == .recording ? 5 : 32)
                        .fill(.red).frame(width: camera.state == .recording ? 29 : 62, height: camera.state == .recording ? 29 : 62)
                }
            }
        }.buttonStyle(.plain)
            .disabled(undoingTake || camera.state != .recording && camera.state != .ready)
            .opacity(camera.state != .recording && camera.state != .ready ? 0.4 : 1)
            .accessibilityLabel(countdown != nil ? "Cancel countdown" : camera.state == .recording ? "Stop recording" : "Record next scene")
    }
    @ViewBuilder private func reviewControls(movie: Movie, landscape: Bool) -> some View {
        let recent = Button { openWatch(sceneID: movie.activeScenes.last?.id) } label: {
            SceneThumbnail(scene: movie.activeScenes.last, root: app.store.root, movie: movie)
                .frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 8))
        }.accessibilityLabel("Review recent scene").disabled(camera.busy || movie.activeScenes.isEmpty)
        let flip = Button { camera.flip() } label: {
            MovieControlIcon(systemName: "arrow.triangle.2.circlepath.camera")
                .background(.white.opacity(0.15), in: Circle())
        }.accessibilityLabel("Switch camera").disabled(camera.state != .ready || camera.options?.canFlip != true)
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
        guard camera.state == .ready, countdown == nil, scenePhase == .active else { return }
        guard handsFreeStart else { camera.record(movieID: movieID); return }
        if smoothZoomOpen, let start = preparedDollyStart, let target = preparedDollyTarget {
            camera.zoom(start)
            queuedDolly = (target, DollyZoomDuration.validated(dollySeconds))
        } else { camera.endSmoothZoom(); queuedDolly = nil }
        recordingCountdown.start(canStart: {
            camera.state == .ready && scenePhase == .active
        }, onStart: {
            camera.record(movieID: movieID)
            if camera.state != .starting { queuedDolly = nil }
        })
    }
    private func cancelCountdown() {
        recordingCountdown.cancel(); queuedDolly = nil
    }
    private func openWatch(sceneID: UUID? = nil) {
        guard !camera.busy else { return }
        Task { await camera.pauseForPlayback(); initialReviewID = sceneID; watching = true }
    }
}

