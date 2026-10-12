import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

struct CameraView: View {
    @ObservedObject var app: AppModel
    @StateObject private var camera: CameraModel
    @State private var movieID: UUID
    @State private var watching = false
    @State private var initialReviewID: UUID?
    @State private var pinchBase: CGFloat?
    @State private var lastZoomAt = Date.distantPast
    @State private var liveCube: ColorCube?
    @State private var liveOriginal = false
    @State private var looks: [LUTReference] = []
    @State private var addingLook = false
    @State private var changingLook = false
    @State private var smoothZoomOpen = false
    @State private var smoothPosition = 0.0
    @State private var zoomDragging = false
    @AppStorage("smoothZoomSpeed") private var zoomSpeed = SmoothZoomSpeed.normal.rawValue
    @AppStorage("smoothStayOnLens") private var stayOnLens = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    init(app: AppModel, movieID: UUID) {
        self.app = app; _movieID = State(initialValue: movieID)
        _camera = StateObject(wrappedValue: CameraModel(app: app))
    }
    private var movie: Movie? { app.movie(movieID) }
    private var establishedFormat: MovieFormat? { movie?.recordingFormat ?? (camera.busy ? camera.takeFormat : nil) }
    var body: some View {
        GeometryReader { geometry in
            let landscape = geometry.size.width > geometry.size.height
            if let movie {
                VStack(spacing: 0) {
                    header(movie: movie)
                        .padding(.horizontal, 12).padding(.vertical, 8).background(.black)
                    if landscape {
                        HStack(spacing: 0) {
                            VStack(spacing: 0) {
                                viewfinder(movie: movie)
                                lenses.padding(.vertical, 8).frame(maxWidth: .infinity).background(.black)
                            }
                            controls(movie: movie, compact: true)
                                .frame(width: 132).frame(maxHeight: .infinity)
                                .padding(.horizontal, 8).background(.black)
                        }
                    } else {
                        viewfinder(movie: movie)
                        VStack(spacing: 10) {
                            lenses
                            controls(movie: movie, compact: false)
                        }.padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 8)
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
            liveCube = nil
            let reference = movie?.look, root = app.store.root
            do {
                let loaded = try await Task.detached(priority: .userInitiated) {
                    if let reference { return try ColorCube.load(reference, root: root) }
                    return try ColorCube.appleStandard.get()
                }.value
                guard !Task.isCancelled else { return }; liveCube = loaded
            } catch { if !Task.isCancelled { liveCube = nil; camera.message = "This look could not be loaded. Choose Apple Standard." } }
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
        .onChange(of: zoomSpeed) { _, _ in updateZoomSettings() }
        .onChange(of: stayOnLens) { _, _ in updateZoomSettings() }
        .onChange(of: camera.options?.minimum) { _, _ in if !zoomDragging { syncSmoothPosition() } }
        .onChange(of: camera.options?.maximum) { _, _ in if !zoomDragging { syncSmoothPosition() } }
        .onChange(of: camera.state) { _, state in
            zoomDragging = false
            if smoothZoomOpen, state == .ready { camera.beginSmoothZoom() }
        }
        .onChange(of: camera.options?.zoom) { _, _ in
            if !zoomDragging, camera.options?.smoothMoving != true { syncSmoothPosition() }
        }
        .onDisappear { zoomDragging = false; camera.suspend() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { zoomDragging = false; camera.suspend() }
            else if !watching && !camera.busy { Task { await camera.prepare(profile: movie?.captureProfile ?? .standard) } }
        }
        .fullScreenCover(isPresented: $watching, onDismiss: { Task { await camera.prepare(profile: movie?.captureProfile ?? .standard) } }) {
            WatchMovieView(movieID: movieID, initialSceneID: initialReviewID).environmentObject(app)
        }
    }
    private func header(movie: Movie) -> some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left").frame(width: 44, height: 44).homeGlass()
            }.accessibilityLabel("Back to Movies").disabled(camera.busy)
            Spacer(minLength: 8)
            if movie.captureProfile == .appleLog {
                Menu {
                    Button { liveOriginal.toggle() } label: { Label("Show Original", systemImage: liveOriginal ? "checkmark" : "circle") }
                    Divider()
                    Button { changeLiveLook(nil) } label: { Label("Apple Standard", systemImage: movie.look == nil ? "checkmark" : "circle") }
                    ForEach(looks, id: \.id) { look in
                        Button { changeLiveLook(look) } label: { Label(look.name, systemImage: movie.look?.id == look.id ? "checkmark" : "circle") }
                    }
                    Divider()
                    Button("Add Apple Log Look…", systemImage: "plus") { addingLook = true }.disabled(camera.busy)
                } label: { Image(systemName: "slider.horizontal.3").frame(width: 44, height: 44).homeGlass() }
                    .accessibilityLabel("Live look: \(liveOriginal ? "Original Log" : movie.lookName)")
                    .disabled(changingLook)
            }
            Menu {
                Picker("Smoothing Speed", selection: $zoomSpeed) {
                    ForEach(SmoothZoomSpeed.allCases) { speed in Text(speed.label).tag(speed.rawValue) }
                }
                Toggle("Stay on This Lens", isOn: $stayOnLens)
                    .disabled(camera.options?.canStayOnLens != true)
            } label: { Image(systemName: "gearshape").frame(width: 44, height: 44).homeGlass() }
                .accessibilityLabel("Camera settings")
            if let options = camera.options, options.hasTorch {
                Button { camera.toggleTorch() } label: {
                    Image(systemName: options.torchOn ? "bolt.fill" : "bolt.slash")
                        .foregroundStyle(options.torchOn ? .yellow : .white)
                        .frame(width: 44, height: 44).homeGlass()
                }.accessibilityLabel(options.torchOn ? "Turn torch off" : "Turn torch on")
                    .disabled(camera.state != .ready && camera.state != .recording)
            } else { Color.clear.frame(width: 44, height: 44) }
        }
    }
    private func viewfinder(movie: Movie) -> some View {
        ZStack {
            preview()
            VStack {
                timer(movie: movie).padding(.top, 8)
                Spacer(minLength: 12)
                status(movie: movie).padding(.horizontal, 20).padding(.bottom, smoothZoomOpen ? 64 : 12)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
            .overlay(alignment: .bottom) {
                if smoothZoomOpen, let options = camera.options {
                    smoothZoomBar(options: options).padding(.horizontal, 12).padding(.bottom, 2)
                }
            }
    }
    private func timer(movie: Movie) -> some View {
        VStack(spacing: 6) {
            if movie.captureProfile == .appleLog { Text("LOG").font(.caption2.weight(.medium)).foregroundStyle(.secondary) }
            if camera.options?.focusLocked == true {
                Text("AE/AF LOCK").font(.caption2.weight(.semibold)).foregroundStyle(.black)
                    .padding(.horizontal, 8).padding(.vertical, 4).background(.yellow, in: RoundedRectangle(cornerRadius: 3))
            }
        Text(camera.state == .recording ? "● \(durationLabel(camera.elapsed))" : "\(durationLabel(movie.duration)) total")
            .font(.caption.monospacedDigit()).padding(.horizontal, 10).padding(.vertical, 5)
            .background(camera.state == .recording ? Color.red : Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 5))
        }
    }
    @ViewBuilder private var lenses: some View {
        if let options = camera.options, !options.lenses.isEmpty {
            VStack(spacing: 0) {
                ViewThatFits(in: .horizontal) {
                    lensButtons(options: options)
                    ScrollView(.horizontal) { lensButtons(options: options) }
                        .scrollIndicators(.hidden).frame(height: 44)
                }.padding(4).homeGlass()
            }
        }
    }
    private func lensButtons(options: CameraOptions) -> some View {
        HStack(spacing: 6) {
            ForEach(options.lenses) { lens in
                let selected = abs(lens.factor - options.zoom) < 0.06
                Button { camera.zoom(lens.factor) } label: {
                    Text(lens.label).font(.caption.weight(.medium)).monospacedDigit()
                        .foregroundStyle(selected ? .yellow : .white)
                        .frame(minWidth: 44, minHeight: 44)
                        .background(selected ? Color.white.opacity(0.15) : .clear, in: Circle())
                }.disabled(camera.state != .ready && camera.state != .recording)
                    .accessibilityLabel("\(lens.label) lens").accessibilityAddTraits(selected ? .isSelected : [])
            }
            if options.maximum > options.minimum || smoothZoomOpen {
                Button {
                    if smoothZoomOpen { camera.endSmoothZoom(); smoothZoomOpen = false }
                    else { syncSmoothPosition(); smoothZoomOpen = true; camera.beginSmoothZoom() }
                } label: {
                    Image(systemName: "waveform.path").font(.caption.weight(.medium))
                        .foregroundStyle(smoothZoomOpen ? .yellow : .white)
                        .frame(width: 44, height: 44)
                        .background(smoothZoomOpen ? Color.white.opacity(0.15) : .clear, in: Circle())
                }.accessibilityLabel("Smooth Zoom").accessibilityValue(smoothZoomOpen ? "Open" : "Closed")
                    .accessibilityAddTraits(smoothZoomOpen ? .isSelected : [])
                    .disabled(!smoothZoomOpen && camera.state != .ready && camera.state != .recording)
            }
        }
    }
    private func smoothZoomBar(options: CameraOptions) -> some View {
        HStack(spacing: 12) {
            Text(String(format: "%g×", Double((options.zoom * options.multiplier * 10).rounded() / 10)))
                .font(.caption.monospacedDigit()).frame(minWidth: 42)
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
                }.frame(height: 34).contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        zoomDragging = true
                        setSmoothPosition(Double((value.location.x - 8) / width), options: options)
                    }.onEnded { value in
                        setSmoothPosition(Double((value.location.x - 8) / width), options: options)
                        zoomDragging = false
                    })
            }.frame(height: 34)
                .accessibilityElement(children: .ignore).accessibilityLabel("Zoom")
                .accessibilityValue(String(format: "%.1f times", Double(options.zoom * options.multiplier)))
                .accessibilityAdjustableAction { direction in
                    let factor = Double(options.zoom) * pow(2, direction == .increment ? 0.25 : -0.25)
                    setSmoothPosition(SmoothZoomFilter.position(factor, minimum: Double(options.minimum), maximum: Double(options.maximum)), options: options)
                }
        }.padding(.horizontal, 12).padding(.vertical, 5).homeGlass(interactive: false)
            .contentShape(Rectangle()).onTapGesture { }
            .frame(maxWidth: 360).disabled(camera.state != .ready && camera.state != .recording || options.maximum <= options.minimum)
    }
    private func setSmoothPosition(_ position: Double, options: CameraOptions) {
        guard smoothZoomOpen, position.isFinite else { return }
        smoothPosition = min(1, max(0, position))
        camera.smoothZoom(to: CGFloat(SmoothZoomFilter.factor(smoothPosition, minimum: Double(options.minimum), maximum: Double(options.maximum))))
    }
    private func syncSmoothPosition() {
        guard let options = camera.options else { return }
        smoothPosition = SmoothZoomFilter.position(Double(options.zoom), minimum: Double(options.minimum), maximum: Double(options.maximum))
    }
    private func updateZoomSettings() {
        camera.configureSmoothZoom(speed: SmoothZoomSpeed(rawValue: zoomSpeed) ?? .normal, stayOnLens: stayOnLens)
    }
    @ViewBuilder private func status(movie: Movie) -> some View {
        VStack(spacing: 8) {
            if camera.state == .finalizing { ProgressView("Saving scene…").tint(.white) }
            if let message = camera.message { Text(message) }
            if camera.state == .failed || camera.state == .interrupted {
                Button("Resume Camera") { Task { await camera.prepare(profile: movie.captureProfile) } }.buttonStyle(.bordered)
            }
        }.font(.footnote).multilineTextAlignment(.center)
            .shadow(color: .black.opacity(0.8), radius: 3)
    }
    private func preview() -> some View {
        ZStack {
            CameraPreview(session: camera.service.session, angle: camera.options?.angle ?? 90, front: camera.options?.isFront ?? false,
                options: camera.options, liveFrames: camera.service.liveFrames,
                liveCube: liveOriginal ? nil : liveCube,
                liveActive: movie?.captureProfile == .appleLog && [.ready, .starting, .recording].contains(camera.state),
                fixedFormat: establishedFormat,
                onFocus: { camera.focus(at: $0, locked: $1) }, onExposure: { camera.exposure($0) })
                .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                .accessibilityLabel("Camera viewfinder")
                .accessibilityAction(named: "Focus at center") { _ = camera.focus(at: CGPoint(x: 0.5, y: 0.5)) }
                .accessibilityAction(named: "Lock focus and exposure at center") { _ = camera.focus(at: CGPoint(x: 0.5, y: 0.5), locked: true) }
                .accessibilityAction(named: "Increase brightness") { camera.exposure((camera.options?.exposureBias ?? 0) + 0.5) }
                .accessibilityAction(named: "Decrease brightness") { camera.exposure((camera.options?.exposureBias ?? 0) - 0.5) }
                .gesture(MagnificationGesture().onChanged { value in
                    guard camera.state == .ready || camera.state == .recording, let options = camera.options else { return }
                    if pinchBase == nil { pinchBase = options.zoom }
                    if Date().timeIntervalSince(lastZoomAt) > 0.05 {
                        camera.zoom((pinchBase ?? options.zoom) * value); lastZoomAt = Date()
                    }
                }.onEnded { _ in pinchBase = nil })
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
    @ViewBuilder private func controls(movie: Movie, compact: Bool) -> some View {
        let recordButton = Button {
            if camera.state == .recording { camera.stop() } else { camera.record(movieID: movieID) }
        } label: {
            ZStack {
                Circle().strokeBorder(.white, lineWidth: 3).frame(width: 78, height: 78)
                RoundedRectangle(cornerRadius: camera.state == .recording ? 5 : 32)
                    .fill(.red).frame(width: camera.state == .recording ? 29 : 62, height: camera.state == .recording ? 29 : 62)
            }
        }.buttonStyle(.plain)
            .disabled(camera.state != .recording && (camera.state != .ready))
            .opacity(camera.state != .recording && (camera.state != .ready) ? 0.4 : 1)
            .accessibilityLabel(camera.state == .recording ? "Stop recording" : "Record next scene")
        let recent = Button { openWatch(sceneID: movie.activeScenes.last?.id) } label: {
            SceneThumbnail(scene: movie.activeScenes.last, root: app.store.root)
                .frame(width: 46, height: 46).clipShape(RoundedRectangle(cornerRadius: 8))
        }.accessibilityLabel("Review recent scene").disabled(camera.busy || movie.activeScenes.isEmpty)
        let flip = Button { camera.flip() } label: {
            Image(systemName: "arrow.triangle.2.circlepath.camera").font(.title2)
                .frame(width: 46, height: 46).background(.white.opacity(0.15), in: Circle())
        }.accessibilityLabel("Switch camera").disabled(camera.state != .ready || camera.options?.canFlip != true)
        VStack(spacing: 15) {
            if compact { recordButton; HStack { recent; flip } }
            else { HStack { recent; Spacer(); recordButton; Spacer(); flip }.padding(.horizontal, 30) }
            Button { openWatch() } label: {
                Label(camera.savedScene ? "Scene Saved · Watch" : "Watch Movie", systemImage: camera.savedScene ? "checkmark" : "play.fill")
                    .font(.footnote).frame(minHeight: 44)
            }.disabled(camera.busy || movie.activeScenes.isEmpty)
                .accessibilityLabel(camera.savedScene ? "Scene saved. Watch movie" : "Watch movie")
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
    private func openWatch(sceneID: UUID? = nil) {
        guard !camera.busy else { return }
        Task { await camera.pauseForPlayback(); initialReviewID = sceneID; watching = true }
    }
}
