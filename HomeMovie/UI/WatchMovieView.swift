import SwiftUI
import AVKit
import UIKit
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
    @State private var undoOrder: [UUID]?
    @State private var reorderedOrder: [UUID]?
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

    private func saveOrder(_ order: [UUID], expected: [UUID], undo: Bool = false) {
        guard !reordering else { return }
        reordering = true
        player?.pause()
        Task {
            defer { reordering = false }
            do {
                try await app.store.reorderScenes(movieID: movieID, order: order, expected: expected)
                undoOrder = undo ? nil : expected
                reorderedOrder = undo ? nil : order
                await app.refresh()
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } catch {
                app.error = error.localizedDescription
                await app.refresh()
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
            ReorderableSceneStrip(movie: movie, root: app.store.root,
                compact: verticalSizeClass == .compact, saving: reordering,
                beginReorder: { player?.pause() },
                review: { scene in player?.pause(); review = scene },
                reorder: { order, previous in saveOrder(order, expected: previous) })
                .frame(height: verticalSizeClass == .compact ? 94 : 117)
            if let undoOrder, let reorderedOrder, movie.activeScenes.map(\.id) == reorderedOrder {
                HStack {
                    Text("Scenes reordered").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Undo") { saveOrder(undoOrder, expected: reorderedOrder, undo: true) }
                        .disabled(reordering)
                }.padding(.horizontal, 20)
            }
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

// UIKit's interactive movement supplies live gap animation, edge autoscroll,
// and cancellation without writing intermediate positions to the project.
private struct ReorderableSceneStrip: UIViewRepresentable {
    let movie: Movie
    let root: URL
    let compact: Bool
    let saving: Bool
    let beginReorder: () -> Void
    let review: (Scene) -> Void
    let reorder: ([UUID], [UUID]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UICollectionView {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = 12
        layout.sectionInset = UIEdgeInsets(top: 0, left: 20, bottom: 0, right: 20)
        let view = UICollectionView(frame: .zero, collectionViewLayout: layout)
        view.backgroundColor = .clear
        view.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "scene")
        view.dataSource = context.coordinator
        view.delegate = context.coordinator
        view.addGestureRecognizer(UILongPressGestureRecognizer(target: context.coordinator,
                                                               action: #selector(Coordinator.hold(_:))))
        return view
    }
    func updateUIView(_ view: UICollectionView, context: Context) {
        let coordinator = context.coordinator
        let previous = coordinator.parent
        coordinator.parent = self
        view.isUserInteractionEnabled = !saving
        guard !coordinator.moving else { return }
        let contentChanged = coordinator.scenes != movie.activeScenes
            || previous.movie.revision != movie.revision || previous.compact != compact
        coordinator.scenes = movie.activeScenes
        // Saving-state and playback updates must not recreate every thumbnail.
        if contentChanged {
            view.reloadData()
            view.collectionViewLayout.invalidateLayout()
        }
    }
    static func dismantleUIView(_ view: UICollectionView, coordinator: Coordinator) {
        view.cancelInteractiveMovement()
        coordinator.moving = false
    }

    final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
        var parent: ReorderableSceneStrip
        var scenes: [Scene]
        var moving = false
        init(_ parent: ReorderableSceneStrip) {
            self.parent = parent
            self.scenes = parent.movie.activeScenes
        }
        func collectionView(_ view: UICollectionView, numberOfItemsInSection section: Int) -> Int { scenes.count }
        func collectionView(_ view: UICollectionView, layout: UICollectionViewLayout,
                            sizeForItemAt indexPath: IndexPath) -> CGSize {
            CGSize(width: 100, height: parent.compact ? 94 : 117)
        }
        func collectionView(_ view: UICollectionView, cellForItemAt path: IndexPath) -> UICollectionViewCell {
            let cell = view.dequeueReusableCell(withReuseIdentifier: "scene", for: path)
            let scene = scenes[path.item]
            let parent = parent
            cell.contentConfiguration = UIHostingConfiguration {
                VStack(alignment: .leading, spacing: 6) {
                    SceneThumbnail(scene: scene, root: parent.root, movie: parent.movie)
                        .frame(width: 100, height: parent.compact ? 44 : 67)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    Text("Scene \(path.item + 1)").font(.caption)
                    Text(durationLabel(scene.playableDuration))
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }.frame(width: 100, alignment: .topLeading)
            }.margins(.all, 0)
            cell.isAccessibilityElement = true
            cell.accessibilityLabel = "Review scene \(path.item + 1)"
            cell.accessibilityHint = "Tap to review. Touch and hold, then drag to reorder."
            cell.accessibilityTraits = .button
            cell.accessibilityCustomActions = [
                UIAccessibilityCustomAction(name: "Move Earlier") { [weak self] _ in
                    self?.accessibleMove(scene.id, delta: -1) ?? false
                },
                UIAccessibilityCustomAction(name: "Move Later") { [weak self] _ in
                    self?.accessibleMove(scene.id, delta: 1) ?? false
                }
            ]
            return cell
        }
        func accessibleMove(_ id: UUID, delta: Int) -> Bool {
            guard !parent.saving, !moving, let index = scenes.firstIndex(where: { $0.id == id }),
                  scenes.indices.contains(index + delta) else { return false }
            let previous = scenes.map(\.id)
            var order = previous
            order.swapAt(index, index + delta)
            parent.reorder(order, previous)
            return true
        }
        func collectionView(_ view: UICollectionView, didSelectItemAt path: IndexPath) {
            guard !moving, !parent.saving else { return }
            parent.review(scenes[path.item])
        }
        func collectionView(_ view: UICollectionView, canMoveItemAt path: IndexPath) -> Bool {
            !parent.saving && scenes.count > 1
        }
        func collectionView(_ view: UICollectionView, moveItemAt source: IndexPath, to destination: IndexPath) {
            let previous = scenes.map(\.id)
            let scene = scenes.remove(at: source.item)
            scenes.insert(scene, at: destination.item)
            guard source != destination else { return }
            parent.reorder(scenes.map(\.id), previous)
        }
        @objc func hold(_ gesture: UILongPressGestureRecognizer) {
            guard let view = gesture.view as? UICollectionView else { return }
            let point = gesture.location(in: view)
            switch gesture.state {
            case .began:
                guard !parent.saving, let path = view.indexPathForItem(at: point) else { return }
                moving = view.beginInteractiveMovementForItem(at: path)
                if moving {
                    parent.beginReorder()
                    UISelectionFeedbackGenerator().selectionChanged()
                }
            case .changed:
                if moving { view.updateInteractiveMovementTargetPosition(point) }
            case .ended:
                guard moving else { return }
                view.endInteractiveMovement()
                moving = false
                // Renumber captions after UIKit has finished its movement transaction.
                DispatchQueue.main.async { view.reloadData() }
            default:
                guard moving else { return }
                view.cancelInteractiveMovement()
                moving = false
                scenes = parent.movie.activeScenes
                view.reloadData()
            }
        }
    }
}
