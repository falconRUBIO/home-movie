import SwiftUI
import AVKit
import UniformTypeIdentifiers

struct WatchMovieView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    let movieID: UUID
    var initialSceneID: UUID? = nil
    var playbackOnly = false
    var autoplay = false
    @State private var initialPlaybackStarted = false
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
    @State private var reordering = false
    @State private var dropTargetID: UUID?
    @State private var playbackRequestID = UUID()
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
                            .overlay(alignment: .topLeading) {
                                if movie.captureProfile == .appleLog, player != nil, !loading, problem == nil {
                                    LogLookBadge(lookName: showOriginalLog ? "Original" : movie.lookName)
                                        .padding(12)
                                }
                            }
                    }.frame(minHeight: 0, maxHeight: .infinity).layoutPriority(-1)
                    if !playbackOnly {
                        Divider()
                        sceneTimeline(movie: movie)
                    }
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
                                        Label(look.displayName, systemImage: movie.look?.id == look.id ? "checkmark" : "circle")
                                    }
                                }
                                Divider()
                                Button("Add Apple Log Look…", systemImage: "plus") { importingLook = true }
                            } label: { MovieControlIcon(systemName: "slider.horizontal.3") }
                                .accessibilityLabel("Look: \(showOriginalLog ? "Original Log" : movie.lookName)")
                                .disabled(changingLook)
                        }
                    }
                    ToolbarItem(placement: .cancellationAction) { Button("Done") { player?.pause(); dismiss() } }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { player?.pause(); exporting = true } label: { MovieControlIcon(systemName: "square.and.arrow.up") }
                            .accessibilityLabel("Export Movie").disabled(movie.activeScenes.isEmpty || loading || changingLook || problem != nil)
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
                    let requestID = UUID(); playbackRequestID = requestID
                    let position = player?.currentTime() ?? .zero
                    let wasPlaying = player.map { $0.timeControlStatus != .paused } ?? false
                    player?.pause(); loading = true; problem = nil
                    defer { if playbackRequestID == requestID { loading = false } }
                    do {
                        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
                        try AVAudioSession.sharedInstance().setActive(true)
                        let bundle = try await app.assembler.build(movie: movie, root: app.store.root, showOriginalLog: showOriginalLog)
                        try Task.checkCancellation()
                        let item = AVPlayerItem(asset: bundle.asset); item.videoComposition = bundle.videoComposition; item.audioMix = bundle.audioMix
                        player = AVPlayer(playerItem: item)
                        if position.isNumeric, position.seconds > 0 {
                            _ = await player?.seek(to: CMTimeMinimum(position, bundle.duration), toleranceBefore: .zero, toleranceAfter: .zero)
                        }
                        guard !Task.isCancelled else { return }
                        if scenePhase == .active, wasPlaying || (autoplay && !initialPlaybackStarted) {
                            player?.play(); initialPlaybackStarted = true
                        }
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
        .background(MovieOrientation(format: .portrait).frame(width: 0, height: 0))
        .preferredColorScheme(playbackOnly ? .dark : nil)
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { player?.pause() }
            else if autoplay, !initialPlaybackStarted, !loading, player != nil {
                player?.play(); initialPlaybackStarted = true
            }
        }
        .onDisappear { player?.pause() }
        .alert("Unable to Update Movie", isPresented: Binding(get: { app.error != nil }, set: { if !$0 { app.error = nil } })) {
            Button("OK") { app.error = nil }
        } message: { Text(app.error ?? "") }
    }

    private func moveScene(_ sceneID: UUID, to targetID: UUID) {
        guard !reordering else { return }
        reordering = true
        dropTargetID = nil
        player?.pause()
        Task {
            defer { reordering = false }
            await app.run {
                try await app.store.moveScene(movieID: movieID, sceneID: sceneID, to: targetID)
            }
        }
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
                                SceneThumbnail(scene: item.element, root: app.store.root, movie: movie)
                                    .frame(width: 100, height: verticalSizeClass == .compact ? 44 : 67)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                Text("Scene \(item.offset + 1)").font(.caption)
                                Text(durationLabel(item.element.playableDuration)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }.buttonStyle(.plain).accessibilityLabel("Review scene \(item.offset + 1)")
                             .accessibilityHint("Tap to review. Touch and hold, then drag onto another scene to reorder.")
                            .overlay {
                                RoundedRectangle(cornerRadius: 10)
                                    .strokeBorder(dropTargetID == item.element.id ? Color.accentColor : .clear, lineWidth: 3)
                                    .allowsHitTesting(false)
                            }
                            .draggable("\(movieID.uuidString):\(item.element.id.uuidString)")
                            .dropDestination(for: String.self) { values, _ in
                                guard !reordering, values.count == 1,
                                      let value = values.first else { return false }
                                let parts = value.split(separator: ":")
                                guard parts.count == 2, String(parts[0]) == movieID.uuidString,
                                      let sourceID = UUID(uuidString: String(parts[1])),
                                      movie.activeScenes.contains(where: { $0.id == sourceID }),
                                      sourceID != item.element.id else { return false }
                                moveScene(sourceID, to: item.element.id)
                                return true
                            } isTargeted: { targeted in
                                if targeted { dropTargetID = item.element.id }
                                else if dropTargetID == item.element.id { dropTargetID = nil }
                            }
                            .accessibilityAction(named: "Move Earlier") {
                                guard item.offset > 0 else { return }
                                moveScene(item.element.id, to: movie.activeScenes[item.offset - 1].id)
                            }
                            .accessibilityAction(named: "Move Later") {
                                guard item.offset + 1 < movie.activeScenes.count else { return }
                                moveScene(item.element.id, to: movie.activeScenes[item.offset + 1].id)
                            }
                    }
                }.padding(.horizontal, 20)
            }.scrollIndicators(.visible).fixedSize(horizontal: false, vertical: true)
            Button { player?.pause(); dismiss() } label: { Label("Continue Recording", systemImage: "video").frame(minHeight: 44) }
                .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).padding(.bottom, 8)
        }.fixedSize(horizontal: false, vertical: true).background(.bar)
    }
}

struct TrimRangeControl: View {
    let scene: Scene
    let root: URL
    @Binding var start: Double
    @Binding var end: Double
    var movie: Movie? = nil
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
                        SceneThumbnail(scene: thumbnailScene(at: i), root: root, movie: movie)
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
        sample.trimEnd = sample.sourceDuration
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
