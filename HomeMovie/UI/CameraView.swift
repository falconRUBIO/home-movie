import SwiftUI
import AVFoundation
import UIKit
import UniformTypeIdentifiers

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
    @State private var smoothPosition = 0.0
    @State private var zoomDragging = false
    @StateObject private var recordingCountdown = RecordingCountdown()
    @State private var preparedDollyStart: CGFloat?
    @State private var preparedDollyTarget: CGFloat?
    @State private var queuedDolly: (target: CGFloat, seconds: Int)?
    @AppStorage("handsFreeStart") private var handsFreeStart = false
    @AppStorage("dollyZoomSeconds") private var dollySeconds = 3
    @AppStorage("smoothZoomSpeed") private var zoomSpeed = SmoothZoomSpeed.normal.rawValue
    @AppStorage("smoothStayOnLens") private var stayOnLens = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    init(app: AppModel, movieID: UUID) {
        self.app = app; _movieID = State(initialValue: movieID)
        _camera = StateObject(wrappedValue: CameraModel(app: app))
    }
    private var countdown: Int? { recordingCountdown.remaining }
    private var movie: Movie? { app.movie(movieID) }
    private var establishedFormat: MovieFormat? { movie?.recordingFormat ?? (camera.busy ? camera.takeFormat : nil) }
    var body: some View {
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
        .onChange(of: camera.state) { _, state in
            if state == .starting { addedSceneID = nil }
            if state == .recording, let move = queuedDolly {
                queuedDolly = nil
                camera.dollyZoom(to: move.target, seconds: move.seconds)
            }
            if state == .failed || state == .interrupted || state == .denied || state == .preparing {
                cancelCountdown()
            }
            zoomDragging = false
            if state != .ready && state != .recording { manualZoomTargetShown = false }
            if smoothZoomOpen, state == .ready { camera.beginSmoothZoom() }
        }
        .onChange(of: camera.options?.isFront) { _, _ in
            cancelCountdown(); preparedDollyStart = nil; preparedDollyTarget = nil
        }
        .onChange(of: camera.options?.zoom) { _, _ in
            if !zoomDragging && !manualZoomTargetShown { syncSmoothPosition() }
        }
        .onChange(of: camera.options?.smoothMoving) { _, moving in
            if moving == false, !zoomDragging { manualZoomTargetShown = false; syncSmoothPosition() }
        }
        .onDisappear { cancelCountdown(); zoomDragging = false; camera.suspend() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { cancelCountdown(); zoomDragging = false; camera.suspend() }
            else if !watching && !showingRecovery && !camera.busy { Task { await camera.prepare(profile: movie?.captureProfile ?? .standard) } }
        }
        .sheet(isPresented: $showingRecovery, onDismiss: {
            Task { await camera.prepare(profile: movie?.captureProfile ?? .standard) }
        }) { RecordingRecoveryView().environmentObject(app) }
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
                if handsFreeStart { Text("3-second countdown. Choose two Dolly lenses, then tap Record.") }
                Divider()
                Picker("Smoothing Speed", selection: $zoomSpeed) {
                    ForEach(SmoothZoomSpeed.allCases) { speed in Text(speed.label).tag(speed.rawValue) }
                }
                Toggle("Stay on This Lens", isOn: $stayOnLens)
                    .disabled(camera.options?.canStayOnLens != true)
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
            preview()
            VStack(spacing: 4) {
                header(movie: movie).padding(.horizontal, 12).padding(.top, 8)
                captureIndicators(movie: movie)
                Spacer(minLength: 0)
                status(movie: movie).padding(.horizontal, landscape ? 100 : 20)
                    .padding(.bottom, landscape ? (smoothZoomOpen ? 108 : 64) : (smoothZoomOpen ? 216 : 172))
            }
        }.clipped()
            .overlay(alignment: .bottom) {
                lenses.padding(.horizontal, landscape ? 100 : 12)
                    .padding(.bottom, landscape ? 10 : 116)
            }
            .overlay(alignment: landscape ? .trailing : .bottom) {
                recordControl.padding(landscape ? .trailing : .bottom, 16)
            }
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
                if smoothZoomOpen { smoothZoomBar(options: options) }
                ViewThatFits(in: .horizontal) {
                    lensButtons(options: options)
                    ScrollView(.horizontal) { lensButtons(options: options) }
                        .scrollIndicators(.hidden).frame(height: 44)
                }.padding(4)
            }.homeGlass().frame(maxWidth: 360)
        }
    }
    private func lensButtons(options: CameraOptions) -> some View {
        HStack(spacing: 6) {
            ForEach(options.lenses) { lens in
                let selected = abs(lens.factor - options.zoom) < 0.06
                Button {
                    manualZoomTargetShown = false
                    if smoothZoomOpen, handsFreeStart, camera.state == .ready {
                        if preparedDollyStart == nil || preparedDollyTarget != nil {
                            preparedDollyStart = lens.factor; preparedDollyTarget = nil
                            camera.zoom(lens.factor)
                        } else if let start = preparedDollyStart, abs(start - lens.factor) > 0.001 {
                            preparedDollyTarget = lens.factor
                        } else { camera.zoom(lens.factor) }
                    } else if smoothZoomOpen { camera.dollyZoom(to: lens.factor, seconds: DollyZoomDuration.validated(dollySeconds)) }
                    else { camera.zoom(lens.factor) }
                } label: {
                    Text(lens.label).font(.caption.weight(.medium)).monospacedDigit()
                        .foregroundStyle(selected ? .yellow : .white)
                        .frame(minWidth: 44, minHeight: 44)
                        .background(selected ? Color.white.opacity(0.15) : .clear, in: Circle())
                }.disabled(countdown != nil || camera.state != .ready && camera.state != .recording)
                    .accessibilityLabel("\(lens.label) lens").accessibilityAddTraits(selected ? .isSelected : [])
            }
            if options.maximum > options.minimum || smoothZoomOpen {
                Button {
                    manualZoomTargetShown = false
                    preparedDollyStart = nil; preparedDollyTarget = nil
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
    private func smoothZoomBar(options: CameraOptions) -> some View {
        HStack(spacing: 12) {
            Group {
                if handsFreeStart, camera.state == .ready, let start = preparedDollyStart, let end = preparedDollyTarget {
                    Text("\(zoomLabel(start, multiplier: options.multiplier)) → \(zoomLabel(end, multiplier: options.multiplier))")
                        .foregroundStyle(.yellow).accessibilityLabel("Dolly from \(zoomLabel(start, multiplier: options.multiplier)) to \(zoomLabel(end, multiplier: options.multiplier))")
                } else { Text(zoomLabel(options.zoom, multiplier: options.multiplier)) }
            }.font(.caption.monospacedDigit()).frame(minWidth: 42)
            GeometryReader { geometry in
                let width = max(1, geometry.size.width - 16)
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.3)).frame(height: 2).padding(.horizontal, 8)
                    ForEach(options.lenses.filter { $0.factor >= options.minimum && $0.factor <= options.maximum }) { lens in
                        Rectangle().fill(.white.opacity(0.45)).frame(width: 1, height: 6)
                            .offset(x: 8 + CGFloat(SmoothZoomFilter.position(Double(lens.factor), minimum: Double(options.minimum), maximum: Double(options.maximum))) * width)
                    }
                    Circle().fill(.white).frame(width: 14, height: 14)
                        .offset(x: 1 + CGFloat(smoothPosition) * width)
                        .animation(zoomDragging ? nil : .linear(duration: 0.05), value: smoothPosition)
                }.frame(height: 34).contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        zoomDragging = true
                        setSmoothPosition(Double((value.location.x - 8) / width), options: options, inputTime: value.time.timeIntervalSinceReferenceDate)
                    }.onEnded { value in
                        setSmoothPosition(Double((value.location.x - 8) / width), options: options, inputTime: value.time.timeIntervalSinceReferenceDate, inputEnded: true)
                        zoomDragging = false
                    })
            }.frame(height: 34)
                .accessibilityElement(children: .ignore).accessibilityLabel("Zoom")
                .accessibilityValue(String(format: "%.1f times", Double(options.zoom * options.multiplier)))
                .accessibilityAdjustableAction { direction in
                    let factor = Double(options.zoom) * pow(2, direction == .increment ? 0.25 : -0.25)
                    setSmoothPosition(SmoothZoomFilter.position(factor, minimum: Double(options.minimum), maximum: Double(options.maximum)), options: options)
                }
            Menu {
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
        }.padding(.horizontal, 12).padding(.vertical, 5)
            .contentShape(Rectangle()).onTapGesture { }
            .frame(maxWidth: 360).disabled(camera.state != .ready && camera.state != .recording || options.maximum <= options.minimum || countdown != nil)
    }
    private func setSmoothPosition(_ position: Double, options: CameraOptions, inputTime: Double? = nil, inputEnded: Bool = false) {
        guard smoothZoomOpen, countdown == nil, position.isFinite else { return }
        preparedDollyStart = nil; preparedDollyTarget = nil
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
                options: camera.options, liveFrames: camera.service.liveFrames,
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
                            preparedDollyStart = nil; preparedDollyTarget = nil
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
