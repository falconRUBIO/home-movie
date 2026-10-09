import SwiftUI
import AVFoundation

struct CameraView: View {
    @ObservedObject var app: AppModel
    @StateObject private var camera: CameraModel
    @State private var movieID: UUID
    @State private var picking = false
    @State private var watching = false
    @State private var initialReviewID: UUID?
    @State private var layoutLandscape = false
    @State private var pinchBase: CGFloat?
    @State private var lastZoomAt = Date.distantPast
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("lastMovieID") private var lastMovieID = ""
    init(app: AppModel, movieID: UUID) {
        self.app = app; _movieID = State(initialValue: movieID)
        _camera = StateObject(wrappedValue: CameraModel(app: app))
    }
    private var movie: Movie? { app.movie(movieID) }
    private var correctOrientation: Bool { movie?.format == (layoutLandscape ? .landscape : .portrait) }
    var body: some View {
        GeometryReader { geometry in
            let landscape = geometry.size.width > geometry.size.height
            if let movie {
                VStack(spacing: landscape ? 8 : 14) {
                    HStack {
                        Button { dismiss() } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                            .accessibilityLabel("Back to Movies").disabled(camera.busy)
                        Spacer(minLength: 8)
                        Button { picking = true } label: {
                            HStack(spacing: 7) { Text(movie.name).font(.subheadline.weight(.medium)).lineLimit(1); Image(systemName: "chevron.down").font(.caption2) }
                                .padding(.horizontal, 15).frame(minHeight: 40).homeGlass()
                        }.disabled(camera.busy).accessibilityLabel("Recording into \(movie.name). Change movie")
                        Spacer(minLength: 8)
                        Color.clear.frame(width: 44, height: 44)
                    }.padding(.horizontal, 12)
                    if landscape {
                        HStack(spacing: 16) {
                            preview(movie: movie).frame(maxWidth: .infinity, maxHeight: .infinity)
                            controls(movie: movie, compact: true).frame(width: 110)
                        }.padding(.horizontal, 16)
                    } else {
                        preview(movie: movie).frame(maxWidth: .infinity, maxHeight: .infinity)
                        controls(movie: movie, compact: false).padding(.bottom, 10)
                    }
                }
                .onAppear { layoutLandscape = landscape }
                .onChange(of: landscape) { _, value in layoutLandscape = value }
            } else { ContentUnavailableView("Movie unavailable", systemImage: "film") }
        }
        .background(.black).foregroundStyle(.white)
        .toolbar(.hidden, for: .navigationBar).navigationBarBackButtonHidden()
        .preferredColorScheme(.dark)
        .task { await camera.prepare() }
        .onDisappear { camera.suspend() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { camera.suspend() }
            else if !watching && !camera.busy { Task { await camera.prepare() } }
        }
        .sheet(isPresented: $picking) {
            NavigationStack {
                List(app.activeMovies) { movie in
                    Button {
                        movieID = movie.id; lastMovieID = movie.id.uuidString; picking = false
                    } label: {
                        HStack { Text(movie.name); Spacer(); if movie.id == movieID { Image(systemName: "checkmark") } }
                    }
                }.navigationTitle("Record into").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { picking = false } } }
            }.presentationDetents([.medium, .large])
        }
        .fullScreenCover(isPresented: $watching, onDismiss: { Task { await camera.prepare() } }) {
            WatchMovieView(movieID: movieID, initialSceneID: initialReviewID).environmentObject(app)
        }
    }
    @ViewBuilder private func preview(movie: Movie) -> some View {
        VStack(spacing: 10) {
            ZStack {
                CameraPreview(session: camera.service.session, angle: camera.options?.angle ?? 90, front: camera.options?.isFront ?? false)
                    .aspectRatio(movie.format.aspect, contentMode: .fit)
                    .gesture(MagnificationGesture().onChanged { value in
                        guard camera.state == .ready || camera.state == .recording, let options = camera.options else { return }
                        if pinchBase == nil { pinchBase = options.zoom }
                        if Date().timeIntervalSince(lastZoomAt) > 0.05 {
                            camera.zoom((pinchBase ?? options.zoom) * value); lastZoomAt = Date()
                        }
                    }.onEnded { _ in pinchBase = nil })
                VStack {
                    Text(camera.state == .recording ? "● \(durationLabel(camera.elapsed))" : "\(durationLabel(movie.duration)) total")
                        .font(.caption.monospacedDigit()).padding(.horizontal, 10).padding(.vertical, 5)
                        .background(camera.state == .recording ? Color.red : Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 5))
                        .padding(.top, 10)
                    Spacer()
                    if let options = camera.options, options.lenses.count > 1 {
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
                        }.padding(4).homeGlass().padding(.bottom, 10)
                    }
                }
                if camera.state == .preparing { ProgressView("Preparing camera…").padding().background(.black.opacity(0.8), in: Capsule()) }
                if camera.state == .denied {
                    VStack(spacing: 12) {
                        Text("Camera and microphone access are needed to record.").multilineTextAlignment(.center)
                        Button("Open Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
                    }.padding(20).background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 14))
                }
            }.aspectRatio(movie.format.aspect, contentMode: .fit)
            if !correctOrientation && !camera.busy {
                Text("Rotate your iPhone to record in \(movie.format.label).").font(.footnote).foregroundStyle(.white.opacity(0.8)).multilineTextAlignment(.center)
            }
            if let message = camera.message {
                Text(message).font(.footnote).foregroundStyle(.white.opacity(0.9)).multilineTextAlignment(.center)
            }
            if camera.state == .failed || camera.state == .interrupted {
                Button("Resume Camera") { Task { await camera.prepare() } }.buttonStyle(.bordered)
            }
        }.padding(.horizontal, layoutLandscape ? 0 : 14)
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
            .disabled(camera.state != .recording && (camera.state != .ready || !correctOrientation))
            .opacity(camera.state != .recording && (camera.state != .ready || !correctOrientation) ? 0.4 : 1)
            .accessibilityLabel(camera.state == .recording ? "Stop recording" : "Record next scene")
        let recent = Button { openWatch(sceneID: movie.activeScenes.last?.id) } label: {
            SceneThumbnail(scene: movie.activeScenes.last, root: app.store.root)
                .frame(width: 46, height: 46).clipShape(RoundedRectangle(cornerRadius: 8))
        }.accessibilityLabel("Review recent scene").disabled(camera.busy || movie.activeScenes.isEmpty)
        let flip = Button { camera.flip() } label: {
            Image(systemName: "arrow.triangle.2.circlepath.camera").font(.title2)
                .frame(width: 46, height: 46).background(.white.opacity(0.15), in: Circle())
        }.accessibilityLabel("Switch camera").disabled(camera.state != .ready)
        VStack(spacing: 15) {
            Text(camera.state == .finalizing ? "SAVING…" : "VIDEO").font(.caption.weight(.medium)).tracking(1).foregroundStyle(.yellow)
            if compact { recordButton; HStack { recent; flip } }
            else { HStack { recent; Spacer(); recordButton; Spacer(); flip }.padding(.horizontal, 30) }
            Button { openWatch() } label: {
                Label(camera.savedScene ? "Scene Saved · Watch" : "Watch Movie", systemImage: camera.savedScene ? "checkmark" : "play.fill")
                    .font(.footnote).frame(minHeight: 44)
            }.disabled(camera.busy || movie.activeScenes.isEmpty)
                .accessibilityLabel(camera.savedScene ? "Scene saved. Watch movie" : "Watch movie")
        }
    }
    private func openWatch(sceneID: UUID? = nil) {
        guard !camera.busy else { return }
        Task { await camera.pauseForPlayback(); initialReviewID = sceneID; watching = true }
    }
}
