import SwiftUI
import AVKit

@MainActor final class SceneReviewPreviewModel: ObservableObject {
    @Published var player: AVPlayer?
    @Published var loading = false
    @Published var error: String?
    private var template: AVMutableVideoComposition?
    private var statusObservation: NSKeyValueObservation?
    private var requestID = UUID()
    func prepare(movie: Movie, scene: Scene, app: AppModel) async {
        let request = UUID(); requestID = request; loading = true; error = nil
        defer { if requestID == request { loading = false } }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
            var fullScene = scene
            fullScene.trimStart = MediaTime(.zero); fullScene.trimEnd = scene.sourceDuration
            var snapshot = movie; snapshot.scenes = [fullScene]
            let bundle = try await app.assembler.build(movie: snapshot, root: app.store.root, forFilmEffectsPreview: true)
            try Task.checkCancellation()
            guard requestID == request else { return }
            template = bundle.videoComposition
            let item = AVPlayerItem(asset: bundle.asset)
            item.videoComposition = bundle.videoComposition; item.audioMix = bundle.audioMix
            item.forwardPlaybackEndTime = scene.trimEnd.cmTime
            player = AVPlayer(playerItem: item)
            statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                guard item.status == .failed else { return }
                let message = item.error?.localizedDescription ?? "This scene could not be played."
                Task { @MainActor in
                    guard let self, self.requestID == request else { return }
                    self.error = message; self.player?.pause()
                }
            }
            _ = await player?.seek(to: scene.trimStart.cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
        } catch { if !Task.isCancelled, requestID == request { self.error = error.localizedDescription } }
    }
    func update(adjustments: SceneAdjustments) async {
        guard !Task.isCancelled, let template, let player, let item = player.currentItem,
              let composition = template.mutableCopy() as? AVMutableVideoComposition else { return }
        composition.instructions = template.instructions.map { instruction in
            guard let source = instruction as? ColorInstruction else { return instruction }
            return ColorInstruction(range: source.timeRange, trackID: source.trackID, transform: source.transform,
                cube: source.cube, filmEffects: source.filmEffects, adjustments: adjustments)
        }
        item.videoComposition = composition
        if player.timeControlStatus == .paused, player.currentTime().isNumeric {
            _ = await player.seek(to: player.currentTime(), toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }
    func stop() {
        requestID = UUID(); player?.pause(); statusObservation = nil
        player = nil; template = nil; loading = false
    }
}

private enum SceneReviewTool: String, CaseIterable, Identifiable {
    case light = "Light", trim = "Trim"
    var id: String { rawValue }
}
private enum SceneLightControl: String, CaseIterable, Identifiable {
    case exposure = "Exposure", shadows = "Shadows", highlights = "Highlights"
    var id: String { rawValue }
    var keyPath: WritableKeyPath<SceneAdjustments, Double> {
        switch self {
        case .exposure: \.exposure
        case .shadows: \.shadows
        case .highlights: \.highlights
        }
    }
}

struct SceneReviewView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let movieID: UUID
    let scene: Scene
    @StateObject private var preview = SceneReviewPreviewModel()
    @StateObject private var export = ExportModel()
    @State private var start: Double
    @State private var end: Double
    @State private var adjustments: SceneAdjustments
    @State private var comparing = false
    @State private var tool = SceneReviewTool.light
    @State private var lightControl = SceneLightControl.exposure
    @State private var saving = false
    @State private var savingPhotos = false
    @State private var waitingForExport = false
    @State private var confirmRemove = false
    @State private var error: String?
    @State private var notice: String?
    init(movieID: UUID, scene: Scene) {
        self.movieID = movieID; self.scene = scene
        _start = State(initialValue: scene.trimStart.seconds)
        _end = State(initialValue: scene.trimEnd.seconds)
        _adjustments = State(initialValue: scene.lightAdjustments)
    }
    private var movie: Movie? { app.movie(movieID) }
    private var reviewAspect: CGFloat { movie?.format.aspect ?? (scene.width > scene.height ? 16 / 9 : 9 / 16) }
    private var busy: Bool { saving || export.running || savingPhotos || waitingForExport }
    private var shownAdjustments: SceneAdjustments { comparing ? .neutral : adjustments }
    private var editedScene: Scene {
        var edited = scene
        edited.trimStart = MediaTime(seconds: start); edited.trimEnd = MediaTime(seconds: end)
        edited.adjustments = adjustments.isActive ? adjustments : nil
        return edited
    }
    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                if geometry.size.width > geometry.size.height {
                    HStack(spacing: 0) {
                        previewPanel.frame(width: geometry.size.width * 0.58, height: geometry.size.height)
                            .background(.black)
                        editingPanel.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    VStack(spacing: 0) {
                        previewPanel.frame(maxWidth: .infinity)
                            .frame(height: min(320, max(140, min(geometry.size.height * 0.48, geometry.size.width / reviewAspect))))
                            .background(.black)
                        editingPanel.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { photosFooter }
            .navigationTitle("Review Scene").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { preview.stop(); dismiss() }.disabled(busy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveEditsAndClose() }.disabled(busy || preview.loading)
                }
            }
            .alert("Remove this scene?", isPresented: $confirmRemove) {
                Button("Cancel", role: .cancel) { }
                Button("Move to Recently Deleted", role: .destructive) {
                    saving = true
                    Task {
                        do {
                            try await app.store.setSceneDeleted(movieID: movieID, sceneID: scene.id, deleted: true)
                            await app.refresh(); preview.stop(); dismiss()
                        } catch { self.error = error.localizedDescription; saving = false }
                    }
                }
            } message: { Text("Restore it later from Settings. Its original file will be kept.") }
            .task {
                guard let movie else { error = "This movie is unavailable."; return }
                await preview.prepare(movie: movie, scene: scene, app: app)
                if !Task.isCancelled { await preview.update(adjustments: shownAdjustments) }
            }
            .task(id: shownAdjustments) {
                // Coalesce slider changes and abandon obsolete paused-frame seeks.
                do { try await Task.sleep(for: .milliseconds(40)) } catch { return }
                await preview.update(adjustments: shownAdjustments)
            }
            .onChange(of: start) { _, value in
                invalidateExport(); preview.player?.pause()
                preview.player?.seek(to: CMTime(seconds: value, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            }
            .onChange(of: end) { _, value in
                invalidateExport(); preview.player?.pause()
                preview.player?.currentItem?.forwardPlaybackEndTime = CMTime(seconds: value, preferredTimescale: 600)
                preview.player?.seek(to: CMTime(seconds: max(start, value - 1 / 30), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            }
            .onChange(of: adjustments) { _, _ in invalidateExport() }
            .onChange(of: export.running) { _, running in
                guard !running, waitingForExport else { return }
                waitingForExport = false
                if export.exportedURL != nil { writeClipToPhotos() }
            }
            .onChange(of: scenePhase) { _, phase in if phase != .active { preview.player?.pause() } }
        }
        .interactiveDismissDisabled(busy)
        .onDisappear { preview.stop(); export.cancel() }
    }
    private var editingPanel: some View {
        VStack(spacing: 0) {
            Picker("Editing tool", selection: $tool) {
                ForEach(SceneReviewTool.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).padding(.horizontal, 20).padding(.vertical, 12).disabled(busy)
            ScrollView {
                VStack(spacing: 12) {
                    if tool == .light { lightControls } else { trimControls }
                    if let message = error ?? preview.error ?? export.error {
                        Text(message).font(.footnote).foregroundStyle(.red).padding(.horizontal)
                    }
                    if let message = notice ?? export.notice {
                        Text(message).font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
                    }
                    if tool == .trim {
                        Button("Remove Scene", role: .destructive) { confirmRemove = true }
                            .frame(minHeight: 44).disabled(busy)
                    }
                }.padding(.bottom, 16)
            }
        }
    }
    private var previewPanel: some View {
        ZStack {
            Color.black
            if let player = preview.player { VideoPlayer(player: player) }
            if preview.loading { ProgressView().tint(.white) }
        }
        .aspectRatio(reviewAspect, contentMode: .fit)
        .frame(maxHeight: 360)
        .overlay(alignment: .topLeading) {
            if (scene.profile ?? movie?.captureProfile) == .appleLog {
                LogLookBadge(lookName: movie?.lookName ?? "Apple Standard").padding(12)
            }
        }
    }
    private var trimControls: some View {
        VStack(spacing: 12) {
            TrimRangeControl(scene: scene, root: app.store.root, start: $start, end: $end, movie: movie)
                .frame(height: 64).padding(.horizontal, 22).disabled(busy)
            HStack {
                Text(durationLabel(CMTime(seconds: start, preferredTimescale: 600)))
                Spacer(); Text(durationLabel(CMTime(seconds: end, preferredTimescale: 600)))
            }.font(.caption.monospacedDigit()).foregroundStyle(.secondary).padding(.horizontal, 24)
            Text("Drag either edge to trim. Your original recording stays intact.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 25)
            Button("Reset Trim") { start = 0; end = scene.sourceDuration.seconds }.frame(minHeight: 44).disabled(busy)
        }
    }
    private var lightComparisonControls: some View {
        HStack(spacing: 12) {
            Button(comparing ? "Show Adjusted" : "Before") { comparing.toggle() }
                .frame(minWidth: 44, minHeight: 44).disabled(!adjustments.isActive || busy)
                .accessibilityHint("Compare against the selected look before light adjustments")
            Button("Reset") { adjustments = .neutral; comparing = false }
                .frame(minWidth: 44, minHeight: 44).disabled(!adjustments.isActive || busy)
        }
    }
    private var selectedLightValue: Binding<Double> {
        let keyPath = lightControl.keyPath
        return Binding(get: { adjustments[keyPath: keyPath] }, set: { adjustments[keyPath: keyPath] = $0 })
    }
    private var lightControls: some View {
        VStack(spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack { Text("Light").font(.headline); Spacer(); lightComparisonControls }
                VStack(alignment: .leading, spacing: 4) { Text("Light").font(.headline); lightComparisonControls }
            }
            Picker("Light adjustment", selection: $lightControl) {
                ForEach(SceneLightControl.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).disabled(busy)
            lightSlider(lightControl.rawValue, value: selectedLightValue)
            Text("Adjust this scene while watching the preview. Save remembers its light settings for playback and export.")
                .font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.horizontal, 20).disabled(preview.loading || preview.error != nil)
    }
    private func lightSlider(_ title: String, value: Binding<Double>) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(title); Spacer()
                Text(value.wrappedValue * 100, format: .number.precision(.fractionLength(0)))
                    .monospacedDigit().foregroundStyle(.secondary)
            }.font(.subheadline)
            Slider(value: value, in: -1...1, step: 0.01)
                .frame(minHeight: 44).disabled(busy || comparing)
                .accessibilityLabel(title)
                .accessibilityValue(Text(value.wrappedValue * 100, format: .number.precision(.fractionLength(0))))
        }
    }
    private var photosFooter: some View {
        VStack(spacing: 6) {
            if export.running {
                ProgressView(value: export.progress) { Text("Preparing Scene…") }
                Button("Cancel") { export.cancel() }.frame(minHeight: 44)
            } else {
                Button { saveClip() } label: {
                    HStack {
                        if savingPhotos || waitingForExport { ProgressView() }
                        Label(savingPhotos ? "Saving…" : "Save to Photos", systemImage: "square.and.arrow.down")
                    }.frame(maxWidth: .infinity, minHeight: 44)
                }.buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                    .disabled(busy || preview.loading || preview.error != nil || movie == nil)
                Text("This scene only · Current look and light adjustments")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.horizontal, 20).padding(.vertical, 10).background(.bar)
    }
    private func invalidateExport() { export.invalidate(); notice = nil; error = nil }
    private func persistEdits() async throws {
        try await app.store.editScene(movieID: movieID, sceneID: scene.id,
            start: editedScene.trimStart.cmTime, end: editedScene.trimEnd.cmTime, adjustments: adjustments)
        await app.refresh()
    }
    private func saveEditsAndClose() {
        saving = true; error = nil
        Task {
            do { try await persistEdits(); preview.stop(); dismiss() }
            catch { self.error = error.localizedDescription; saving = false }
        }
    }
    private func saveClip() {
        guard !busy else { return }
        saving = true; error = nil; notice = nil; comparing = false; preview.player?.pause()
        Task {
            do {
                try await persistEdits()
                guard let movie, let currentScene = movie.activeScenes.first(where: { $0.id == scene.id }) else {
                    throw HomeMovieError.message("This scene is unavailable.")
                }
                let clip = try ExportModel.singleSceneMovie(movie: movie, scene: currentScene)
                waitingForExport = true; saving = false
                export.start(movie: clip, app: app)
                // Cached exports can finish without a running-state transition.
                if !export.running, waitingForExport {
                    waitingForExport = false
                    if export.exportedURL != nil { writeClipToPhotos() }
                }
            } catch { self.error = error.localizedDescription; saving = false }
        }
    }
    private func writeClipToPhotos() {
        guard !savingPhotos else { return }
        savingPhotos = true
        Task {
            await export.saveToPhotos()
            if export.error == nil { notice = "Scene saved to Photos." }
            savingPhotos = false
        }
    }
}
