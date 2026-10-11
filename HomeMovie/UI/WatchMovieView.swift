import SwiftUI
import AVKit
import UniformTypeIdentifiers

struct WatchMovieView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    let movieID: UUID
    var initialSceneID: UUID? = nil
    @State private var presentedInitialReview = false
    @State private var player: AVPlayer?
    @State private var loading = false
    @State private var problem: String?
    @State private var review: Scene?
    @State private var exporting = false
    @State private var looks: [LUTReference] = []
    @State private var importingLook = false
    @State private var changingLook = false
    @State private var showOriginalLog = false
    private var movie: Movie? { app.movie(movieID) }
    var body: some View {
        NavigationStack {
            if let movie {
                VStack(spacing: 0) {
                    GeometryReader { geometry in
                        // Fit the whole movie inside the space left above the timeline.
                        // A portrait movie must not size the page beyond the screen.
                        let width = min(geometry.size.width, geometry.size.height * movie.format.aspect)
                        ZStack {
                            Color.black
                            if let player {
                                VideoPlayer(player: player)
                                    .frame(width: max(0, width), height: max(0, width / movie.format.aspect))
                            }
                            if loading { ProgressView().tint(.white) }
                            if let problem {
                                Text(problem).font(.footnote).foregroundStyle(.white)
                                    .multilineTextAlignment(.center).padding()
                            }
                        }.frame(width: geometry.size.width, height: geometry.size.height)
                    }.frame(minHeight: 0, maxHeight: .infinity).layoutPriority(-1)
                    Divider()
                    sceneTimeline(movie: movie)
                }
                .navigationTitle(movie.name).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if movie.captureProfile == .appleLog {
                        ToolbarItem(placement: .topBarTrailing) {
                            Menu {
                                Button { showOriginalLog.toggle() } label: {
                                    Label("Show Original", systemImage: showOriginalLog ? "checkmark" : "circle")
                                }
                                Divider()
                                Button { selectLook(nil) } label: {
                                    Label("Apple Standard", systemImage: movie.look == nil ? "checkmark" : "circle")
                                }
                                ForEach(looks, id: \.id) { look in
                                    Button { selectLook(look) } label: {
                                        Label(look.name, systemImage: movie.look?.id == look.id ? "checkmark" : "circle")
                                    }
                                }
                                Divider()
                                Button("Add Apple Log Look…", systemImage: "plus") { importingLook = true }
                            } label: { Image(systemName: "slider.horizontal.3") }
                                .accessibilityLabel("Look: \(showOriginalLog ? "Original Log" : movie.lookName)")
                                .disabled(changingLook)
                        }
                    }
                    ToolbarItem(placement: .cancellationAction) { Button("Done") { player?.pause(); dismiss() } }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Export", systemImage: "square.and.arrow.up") { player?.pause(); exporting = true }
                            .disabled(movie.activeScenes.isEmpty || loading || changingLook || problem != nil)
                    }
                }
                .fileImporter(isPresented: $importingLook, allowedContentTypes: [UTType(filenameExtension: "cube") ?? .data], allowsMultipleSelection: false) { result in
                    switch result {
                    case .success(let urls):
                        guard let url = urls.first else { return }
                        changingLook = true
                        Task {
                            defer { changingLook = false }
                            do {
                                let look = try await app.store.importLook(from: url)
                                try await app.store.setLook(movieID: movieID, look: look)
                                looks = await app.store.availableLooks(); showOriginalLog = false; await app.refresh()
                            } catch { app.error = error.localizedDescription }
                        }
                    case .failure(let error): app.error = error.localizedDescription
                    }
                }
                .task { looks = await app.store.availableLooks() }
                .task(id: "\(movie.revision)-\(showOriginalLog)") {
                    let position = player?.currentTime() ?? .zero
                    let wasPlaying = player?.rate != 0 && player != nil
                    player?.pause(); loading = true; problem = nil
                    defer { loading = false }
                    do {
                        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
                        try AVAudioSession.sharedInstance().setActive(true)
                        let bundle = try await app.assembler.build(movie: movie, root: app.store.root, showOriginalLog: showOriginalLog)
                        try Task.checkCancellation()
                        let item = AVPlayerItem(asset: bundle.asset); item.videoComposition = bundle.videoComposition
                        player = AVPlayer(playerItem: item)
                        if position.isNumeric, position.seconds > 0 {
                            _ = await player?.seek(to: CMTimeMinimum(position, bundle.duration), toleranceBefore: .zero, toleranceAfter: .zero)
                        }
                        guard !Task.isCancelled else { return }
                        if wasPlaying { player?.play() }
                        if !presentedInitialReview {
                            presentedInitialReview = true
                            if let initialSceneID { review = movie.activeScenes.first { $0.id == initialSceneID } }
                        }
                    } catch { if !Task.isCancelled { player = nil; problem = error.localizedDescription } }
                }
                .sheet(item: $review) { scene in SceneReviewView(movieID: movie.id, scene: scene).environmentObject(app) }
                .sheet(isPresented: $exporting) { ExportView(movie: movie).environmentObject(app) }
            } else { ContentUnavailableView("Movie unavailable", systemImage: "film") }
        }
        .onDisappear { player?.pause() }
        .alert("Look unavailable", isPresented: Binding(get: { app.error != nil }, set: { if !$0 { app.error = nil } })) {
            Button("OK") { app.error = nil }
        } message: { Text(app.error ?? "") }
    }

    private func selectLook(_ look: LUTReference?) {
        guard !changingLook else { return }
        changingLook = true; showOriginalLog = false
        Task {
            defer { changingLook = false }
            await app.run { try await app.store.setLook(movieID: movieID, look: look) }
        }
    }
    private func sceneTimeline(movie: Movie) -> some View {
        VStack(spacing: verticalSizeClass == .compact ? 8 : 12) {
            HStack {
                Text("Scenes").font(.headline); Spacer()
                Text("\(movie.activeScenes.count) · \(durationLabel(movie.duration))").font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 20).padding(.top, 12)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(Array(movie.activeScenes.enumerated()), id: \.element.id) { item in
                        Button { player?.pause(); review = item.element } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                SceneThumbnail(scene: item.element, root: app.store.root)
                                    .frame(width: 100, height: verticalSizeClass == .compact ? 44 : 67)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                Text("Scene \(item.offset + 1)").font(.caption)
                                Text(durationLabel(item.element.playableDuration)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }.buttonStyle(.plain).accessibilityLabel("Review scene \(item.offset + 1)")
                            .accessibilityHint("Opens playback and trimming controls")
                    }
                }.padding(.horizontal, 20)
            }.scrollIndicators(.visible).fixedSize(horizontal: false, vertical: true)
            Button { player?.pause(); dismiss() } label: { Label("Continue Recording", systemImage: "video").frame(minHeight: 44) }
                .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).padding(.bottom, 8)
        }.fixedSize(horizontal: false, vertical: true).background(.bar)
    }
}

struct SceneReviewView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    let movieID: UUID
    let scene: Scene
    @State private var player: AVPlayer?
    @State private var start: Double
    @State private var end: Double
    @State private var originalStart = CMTime.zero
    @State private var saving = false
    @State private var confirmRemove = false
    @State private var error: String?
    init(movieID: UUID, scene: Scene) {
        self.movieID = movieID; self.scene = scene
        _start = State(initialValue: scene.trimStart.seconds); _end = State(initialValue: scene.trimEnd.seconds)
    }
    var body: some View {
        NavigationStack {
            ScrollView {
            VStack(spacing: 20) {
                if let player { VideoPlayer(player: player).frame(height: 260) }
                TrimRangeControl(scene: scene, root: app.store.root, start: $start, end: $end)
                    .frame(height: 64).padding(.horizontal, 22)
                HStack {
                    Text(durationLabel(CMTime(seconds: start, preferredTimescale: 600)))
                    Spacer(); Text(durationLabel(CMTime(seconds: end, preferredTimescale: 600)))
                }.font(.caption.monospacedDigit()).foregroundStyle(.secondary).padding(.horizontal, 24)
                Text("Drag either edge to trim. Your original recording stays intact.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 25)
                Button("Reset to Original") { start = 0; end = scene.sourceDuration.seconds }
                if let error { Text(error).font(.footnote).foregroundStyle(.red).padding(.horizontal) }
                Button("Remove Scene", role: .destructive) { confirmRemove = true }.frame(minHeight: 44).disabled(saving)
            }
            }
            .navigationTitle("Review Scene").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { player?.pause(); dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saving = true
                        Task {
                            do {
                                try await app.store.trim(movieID: movieID, sceneID: scene.id,
                                    start: CMTime(seconds: start, preferredTimescale: 600), end: CMTime(seconds: end, preferredTimescale: 600))
                                await app.refresh(); player?.pause(); dismiss()
                            } catch { self.error = error.localizedDescription; saving = false }
                        }
                    }.disabled(saving)
                }
            }
            .confirmationDialog("Remove this scene?", isPresented: $confirmRemove, titleVisibility: .visible) {
                Button("Move to Recently Deleted", role: .destructive) {
                    saving = true
                    Task {
                        do { try await app.store.setSceneDeleted(movieID: movieID, sceneID: scene.id, deleted: true); await app.refresh(); player?.pause(); dismiss() }
                        catch { self.error = error.localizedDescription; saving = false }
                    }
                }
            } message: { Text("Restore it later from Settings. Its original file will be kept.") }
            .task {
                if var movie = app.movie(movieID), movie.captureProfile == .appleLog {
                    do {
                        var fullScene = scene; fullScene.trimStart = MediaTime(.zero); fullScene.trimEnd = fullScene.sourceDuration
                        movie.scenes = [fullScene]
                        let bundle = try await app.assembler.build(movie: movie, root: app.store.root)
                        guard !Task.isCancelled else { return }
                        let item = AVPlayerItem(asset: bundle.asset); item.videoComposition = bundle.videoComposition
                        item.forwardPlaybackEndTime = scene.trimEnd.cmTime
                        originalStart = .zero; player = AVPlayer(playerItem: item)
                        _ = await player?.seek(to: scene.trimStart.cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
                    } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
                    return
                }
                let asset = AVURLAsset(url: app.store.root.appendingPathComponent(scene.source))
                if let tracks = try? await asset.loadTracks(withMediaType: .video), let track = tracks.first,
                   let range = try? await track.load(.timeRange) { originalStart = range.start }
                guard !Task.isCancelled else { return }
                let item = AVPlayerItem(asset: asset)
                item.forwardPlaybackEndTime = CMTimeAdd(originalStart, scene.trimEnd.cmTime)
                player = AVPlayer(playerItem: item)
                _ = await player?.seek(to: CMTimeAdd(originalStart, scene.trimStart.cmTime), toleranceBefore: .zero, toleranceAfter: .zero)
            }
            .onChange(of: start) { _, value in player?.pause(); player?.seek(to: CMTimeAdd(originalStart, CMTime(seconds: value, preferredTimescale: 600)), toleranceBefore: .zero, toleranceAfter: .zero, completionHandler: { _ in }) }
            .onChange(of: end) { _, value in player?.pause(); player?.currentItem?.forwardPlaybackEndTime = CMTimeAdd(originalStart, CMTime(seconds: value, preferredTimescale: 600)); player?.seek(to: CMTimeAdd(originalStart, CMTime(seconds: max(start, value - 1 / 30), preferredTimescale: 600)), toleranceBefore: .zero, toleranceAfter: .zero, completionHandler: { _ in }) }
        }.interactiveDismissDisabled(saving).onDisappear { player?.pause() }
    }
}

struct TrimRangeControl: View {
    let scene: Scene
    let root: URL
    @Binding var start: Double
    @Binding var end: Double
    private var duration: Double { max(scene.sourceDuration.seconds, 1 / 600) }
    private var minimum: Double { min(1 / 30, duration) }
    var body: some View {
        GeometryReader { proxy in
            let width = max(1, proxy.size.width - 28)
            let x1 = CGFloat(start / duration) * width + 14
            let x2 = CGFloat(end / duration) * width + 14
            ZStack(alignment: .leading) {
                HStack(spacing: 1) {
                    ForEach(0..<6) { i in
                        SceneThumbnail(scene: thumbnailScene(at: i), root: root)
                    }
                }.clipShape(RoundedRectangle(cornerRadius: 8)).padding(.horizontal, 14)
                Color.black.opacity(0.55).frame(width: max(0, x1 - 14)).padding(.leading, 14).allowsHitTesting(false)
                Color.black.opacity(0.55).frame(width: max(0, width + 14 - x2)).offset(x: x2).allowsHitTesting(false)
                RoundedRectangle(cornerRadius: 8).strokeBorder(.yellow, lineWidth: 3)
                    .frame(width: max(14, x2 - x1 + 16)).offset(x: x1 - 8).allowsHitTesting(false)
                handle("Trim start", x: x1, width: width, isStart: true)
                handle("Trim end", x: x2, width: width, isStart: false)
            }.coordinateSpace(name: "trim")
        }
    }
    private func thumbnailScene(at index: Int) -> Scene {
        var sample = scene
        sample.trimStart = MediaTime(seconds: Double(index) / 6 * duration)
        return sample
    }
    private func handle(_ label: String, x: CGFloat, width: CGFloat, isStart: Bool) -> some View {
        RoundedRectangle(cornerRadius: 7).fill(.yellow).frame(width: 15)
            .overlay { Capsule().fill(.black.opacity(0.6)).frame(width: 3, height: 20) }
            .frame(width: 44).contentShape(Rectangle()).offset(x: x - 22)
            .gesture(DragGesture(coordinateSpace: .named("trim")).onChanged { value in
                let seconds = max(0, min(duration, Double((value.location.x - 14) / width) * duration))
                if isStart { start = min(seconds, end - minimum) } else { end = max(seconds, start + minimum) }
            })
            .accessibilityElement().accessibilityLabel(label)
            .accessibilityValue(durationLabel(CMTime(seconds: isStart ? start : end, preferredTimescale: 600)))
            .accessibilityAdjustableAction { direction in
                let change: Double = direction == .increment ? 1 : -1
                if isStart { start = max(0, min(end - minimum, start + change)) }
                else { end = min(duration, max(start + minimum, end + change)) }
            }
    }
}
