import SwiftUI
import AVKit
import UIKit

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
            let bundle = try await app.assembler.build(movie: snapshot, root: app.store.root, filmEffects: movie.exportEffects, forFilmEffectsPreview: true)
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
    func update(adjustments: SceneAdjustments, filmEffects: FilmEffectsSettings) async {
        guard !Task.isCancelled, let template, let player, let item = player.currentItem,
              let composition = template.mutableCopy() as? AVMutableVideoComposition else { return }
        composition.instructions = template.instructions.map { instruction in
            guard let source = instruction as? ColorInstruction else { return instruction }
            return ColorInstruction(range: source.timeRange, trackID: source.trackID, transform: source.transform,
                cube: source.cube, filmEffects: filmEffects, adjustments: adjustments)
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
    case light = "Light", color = "Color", fx = "FX", trim = "Trim"
    var symbol: String {
        switch self {
        case .light: "sun.max"
        case .color: "circle.lefthalf.filled"
        case .fx: "sparkles"
        case .trim: "crop.rotate"
        }
    }
    var id: String { rawValue }
}
private enum SceneLightControl: String, CaseIterable, Identifiable {
    case exposure = "Exposure", brightness = "Brightness", brilliance = "Brilliance", pushPull = "Push/Pull", shadows = "Shadows", highlights = "Highlights", warmth = "Warmth", tint = "Tint", contrast = "Contrast", blackPoint = "Black Point", whitePoint = "White Point", saturation = "Saturation", vibrance = "Vibrance"
    var id: String { rawValue }
    var keyPath: WritableKeyPath<SceneAdjustments, Double> {
        switch self {
        case .contrast: \.contrast
        case .blackPoint: \.blackPoint
        case .whitePoint: \.whitePoint
        case .saturation: \.saturation
        case .vibrance: \.vibrance
        case .exposure: \.exposure
        case .shadows: \.shadows
        case .highlights: \.highlights
        case .brightness: \.brightness
        case .brilliance: \.brilliance
        case .pushPull: \.pushPull
        case .warmth: \.warmth
        case .tint: \.tint
        }
    }
    var symbol: String {
        switch self {
        case .contrast: "circle.lefthalf.filled"
        case .blackPoint: "circle.fill"
        case .whitePoint: "circle"
        case .saturation: "paintpalette"
        case .vibrance: "camera.filters"
        case .exposure: "sun.max"
        case .brightness: "sun.min"
        case .brilliance: "sun.max.circle"
        case .pushPull: "circle.lefthalf.filled"
        case .shadows: "moon"
        case .highlights: "sun.max.fill"
        case .warmth: "thermometer.medium"
        case .tint: "circle.lefthalf.filled"
        }
    }
    var endpoints: (String, String)? {
        switch self {
        case .warmth: ("Blue", "Yellow")
        case .tint: ("Green", "Magenta")
        case .pushPull: ("Pull · Softer", "Push · Denser")
        default: nil
        }
    }
    var detail: String {
        switch self {
        case .contrast: "Separates dark and bright tones around the midtones."
        case .blackPoint: "Deepens blacks to the right; lifts them for a faded look to the left."
        case .whitePoint: "Sets the brightest white level."
        case .saturation: "Adjusts all color intensity. Minus 100 makes black and white."
        case .vibrance: "Boosts muted colors with less effect on already vivid colors and warm skin tones."
        case .exposure: "Adjusts the entire image by up to two stops in either direction."
        case .brightness: "Brightens or darkens the midtones."
        case .brilliance: "Balances darker areas and bright highlights."
        case .pushPull: "Softens contrast or adds density. Does not change recording exposure."
        case .shadows: "Adjusts detail in darker areas."
        case .highlights: "Adjusts the brightest areas."
        case .warmth: "Balances cool blue and warm yellow."
        case .tint: "Balances green and magenta."
        }
    }
}

private struct SceneReviewRecipe: Equatable {
    let adjustments: SceneAdjustments
    let effects: FilmEffectsSettings
}

struct SceneReviewView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let movieID: UUID
    let scene: Scene
    @StateObject private var preview = SceneReviewPreviewModel()
    @StateObject private var export = ExportModel()
    @State private var start: Double
    @State private var end: Double
    @State private var adjustments: SceneAdjustments
    @State private var savedScene: Scene
    @State private var effects = FilmEffectsSettings.off
    @State private var originalEffects = FilmEffectsSettings.off
    @State private var loadedEffects = false
    @State private var comparing = false
    @State private var tool = SceneReviewTool.light
    @State private var draggingControl: SceneLightControl?
    @State private var saving = false
    @State private var savingPhotos = false
    @State private var waitingForExport = false
    @State private var confirmRemove = false
    @State private var confirmDiscard = false
    @State private var error: String?
    @State private var notice: String?
    init(movieID: UUID, scene: Scene) {
        self.movieID = movieID; self.scene = scene
        _start = State(initialValue: scene.trimStart.seconds)
        _end = State(initialValue: scene.trimEnd.seconds)
        _adjustments = State(initialValue: scene.lightAdjustments)
        _savedScene = State(initialValue: scene)
    }
    private var movie: Movie? { app.movie(movieID) }
    private var reviewAspect: CGFloat { movie?.format.aspect ?? (scene.width > scene.height ? 16 / 9 : 9 / 16) }
    private var busy: Bool { saving || export.running || savingPhotos || waitingForExport }
    private var hasUnsavedEdits: Bool {
        editedScene.trimStart != savedScene.trimStart || editedScene.trimEnd != savedScene.trimEnd
            || adjustments != savedScene.lightAdjustments || effects != originalEffects
    }
    private var shownRecipe: SceneReviewRecipe {
        SceneReviewRecipe(adjustments: comparing ? .neutral : adjustments, effects: comparing ? .off : effects)
    }
    private var pendingEffects: FilmEffectsSettings? { effects != originalEffects ? effects : nil }
    private var visibleLightControls: [SceneLightControl] {
        let color: [SceneLightControl] = [.warmth, .tint, .saturation, .vibrance]
        return SceneLightControl.allCases.filter { tool == .color ? color.contains($0) : !color.contains($0) }
    }
    private var canReset: Bool {
        tool == .fx ? effects != .off : visibleLightControls.contains { adjustments[keyPath: $0.keyPath] != 0 }
    }
    private func resetTool() {
        UISelectionFeedbackGenerator().selectionChanged()
        if tool == .fx { effects = .off }
        else { for control in visibleLightControls { adjustments[keyPath: control.keyPath] = 0 } }
        comparing = false
    }
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
                        previewPanel.frame(width: geometry.size.width * 0.64, height: geometry.size.height)
                            .background(.black)
                        editingPanel.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    VStack(spacing: 0) {
                        previewPanel.frame(maxWidth: .infinity)
                            .frame(height: max(120, min(geometry.size.height * (dynamicTypeSize.isAccessibilitySize ? 0.46 : 0.70), geometry.size.width / reviewAspect)))
                            .background(.black)
                        editingPanel.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { photosFooter }
            .saveStatusToast($export.saveFeedback)
            .navigationTitle("Review Scene").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if hasUnsavedEdits { preview.player?.pause(); confirmDiscard = true }
                        else { preview.stop(); dismiss() }
                    }.disabled(busy)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Save to Photos", systemImage: "square.and.arrow.down") { saveClip() }
                            .disabled(preview.loading || preview.error != nil)
                        Button("Duplicate", systemImage: "plus.square.on.square") { duplicateScene() }
                        Divider()
                        Button("Delete Scene", systemImage: "trash", role: .destructive) { confirmRemove = true }
                    } label: { Image(systemName: "ellipsis.circle").frame(minWidth: 44, minHeight: 44) }
                        .accessibilityLabel("Scene actions").disabled(busy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveEditsAndClose() }.disabled(busy || preview.loading)
                }
            }
            .confirmationDialog("Discard changes?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Discard Changes", role: .destructive) { preview.stop(); dismiss() }
                Button("Keep Editing", role: .cancel) { }
            }
            .alert("Delete this scene?", isPresented: $confirmRemove) {
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
                if !loadedEffects {
                    effects = movie.exportEffects; originalEffects = effects; loadedEffects = true
                }
                await preview.prepare(movie: movie, scene: scene, app: app)
                if !Task.isCancelled {
                    await preview.update(adjustments: shownRecipe.adjustments, filmEffects: shownRecipe.effects)
                    if scenePhase == .active, preview.error == nil { preview.player?.play() }
                }
            }
            .task(id: shownRecipe) {
                // Coalesce slider changes and abandon obsolete paused-frame seeks.
                do { try await Task.sleep(for: .milliseconds(40)) } catch { return }
                await preview.update(adjustments: shownRecipe.adjustments, filmEffects: shownRecipe.effects)
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
            .onChange(of: effects) { _, _ in invalidateExport() }
            .onChange(of: tool) { _, _ in comparing = false; UISelectionFeedbackGenerator().selectionChanged() }
            .onChange(of: export.running) { _, running in
                guard !running, waitingForExport else { return }
                waitingForExport = false
                if export.exportedURL != nil { writeClipToPhotos() }
                else if let error = export.error { export.saveFeedback = SaveToast(kind: .failure, message: error) }
                else { export.saveFeedback = nil }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { comparing = false; preview.player?.pause() }
            }
            .onChange(of: busy) { _, value in if value { comparing = false } }
        }
        .interactiveDismissDisabled(busy || hasUnsavedEdits)
        .onDisappear { preview.stop(); export.cancel() }
    }
    private var reviewToolPicker: some View {
        HStack(spacing: 0) {
            ForEach(SceneReviewTool.allCases) { item in
                Button { tool = item } label: {
                    VStack(spacing: 4) {
                        Image(systemName: item.symbol).font(.title3)
                        Text(item.rawValue).font(.caption.weight(.semibold))
                    }.frame(maxWidth: .infinity, minHeight: 52)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(tool == item ? Color.orange : Color.secondary)
                .background(tool == item ? Color.orange.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                .accessibilityLabel(item.rawValue)
                .accessibilityAddTraits(tool == item ? [.isSelected] : [])
            }
        }.padding(.horizontal, 12).padding(.vertical, 4).disabled(busy)
    }
    private var editingPanel: some View {
        VStack(spacing: 0) {
            if tool != .trim {
                ViewThatFits(in: .horizontal) {
                    HStack {
                        toolScopeLabel
                        Spacer(minLength: 8)
                        lightComparisonControls
                    }
                    VStack(spacing: 0) { toolScopeLabel; lightComparisonControls }
                }.padding(.horizontal, 16)
            }
            if tool == .fx {
                Form { FilmEffectsControlSections(settings: $effects) }
                    .listStyle(.plain).listSectionSpacing(.compact)
                    .disabled(busy || comparing || preview.loading || preview.error != nil)
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        if tool == .trim { trimControls } else { lightControls }
                    }.padding(.bottom, 8)
                }.id(tool)
            }
            if let message = error ?? preview.error ?? export.error {
                Text(message).font(.footnote).foregroundStyle(.red).padding(.horizontal)
            }
            if let message = notice ?? export.notice {
                Text(message).font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
            }
        }
    }
    private var toolScopeLabel: some View {
        Text(tool == .fx ? "All scenes · FX" : "This scene · \(tool.rawValue)")
            .font(.caption).foregroundStyle(.secondary)
    }
    private var previewPanel: some View {
        ZStack {
            Color.black
            if let player = preview.player { VideoPlayer(player: player) }
            if preview.loading { ProgressView().tint(.white) }
        }
        .aspectRatio(reviewAspect, contentMode: .fit)
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
            Text("Duration · \(String(format: "%.1f", max(0, end - start)))s")
                .font(.subheadline.monospacedDigit())
                .accessibilityLabel("Trimmed duration")
                .accessibilityValue("\(String(format: "%.1f", max(0, end - start))) seconds")
            Text("Drag either edge to trim. Your original recording stays intact.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 25)
            Button("Reset Trim") { start = 0; end = scene.sourceDuration.seconds }.frame(minHeight: 44).disabled(busy)
        }
    }
    private var lightComparisonControls: some View {
        HStack(spacing: 12) {
            Text(comparing ? "Before Edits" : "Hold to Compare")
                .foregroundStyle(comparing ? .primary : .secondary)
                .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                .onLongPressGesture(minimumDuration: 0, pressing: { pressing in
                    if !busy || !pressing { comparing = pressing }
                }, perform: {})
                .accessibilityElement().accessibilityAddTraits(.isButton)
                .accessibilityLabel(comparing ? "Show adjusted" : "Compare before edits")
                .accessibilityAction { if !busy { comparing.toggle() } }
                .accessibilityHint("Hold to compare without Light, Color, or FX edits; the selected look stays applied")
            Button("Reset") { resetTool() }
                .frame(minWidth: 44, minHeight: 44).disabled(!canReset || busy || preview.loading)
                .accessibilityLabel("Reset \(tool.rawValue)")
        }.font(.subheadline).fixedSize(horizontal: true, vertical: false)
    }
    private var lightControls: some View {
        LazyVStack(spacing: 4) {
            ForEach(visibleLightControls) { control in
                lightRuler(control)
            }
        }.padding(.horizontal, 16).disabled(preview.loading || preview.error != nil)
    }
    private func lightRuler(_ control: SceneLightControl) -> some View {
        let value = Binding(get: { adjustments[keyPath: control.keyPath] },
            set: { adjustments[keyPath: control.keyPath] = $0 })
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: control.symbol).frame(width: 20).accessibilityHidden(true)
                Text(control.rawValue).fontWeight(.semibold)
                Spacer(minLength: 8)
                Text(abs(value.wrappedValue) < 0.005 ? "0" : String(format: "%+.0f", value.wrappedValue * 100))
                    .monospacedDigit().fontWeight(.semibold)
                    .frame(minWidth: 44, minHeight: 24).contentShape(Rectangle())
                    .onTapGesture(count: 2) { if !busy && !comparing { UISelectionFeedbackGenerator().selectionChanged(); value.wrappedValue = 0 } }
                    .accessibilityLabel("\(control.rawValue) value")
                    .accessibilityAction(named: "Reset to Zero") { if !busy && !comparing { value.wrappedValue = 0 } }
            }.font(.subheadline).frame(minHeight: 24).accessibilityHidden(true)
            SceneAdjustmentRuler(value: value, onEditingChanged: { draggingControl = $0 ? control : nil })
                .frame(height: 44).disabled(busy || comparing)
                .overlay {
                    Canvas { context, size in
                        let center = size.width / 2
                        let marker = CGRect(x: center - 1.5, y: 1, width: 3, height: 16)
                        context.fill(Path(roundedRect: marker, cornerRadius: 1.5), with: .color(.orange))
                        var pointer = Path()
                        pointer.move(to: CGPoint(x: center, y: 20))
                        pointer.addLine(to: CGPoint(x: center - 3, y: 25))
                        pointer.addLine(to: CGPoint(x: center + 3, y: 25))
                        pointer.closeSubpath()
                        context.fill(pointer, with: .color(.primary))
                    }.allowsHitTesting(false).accessibilityHidden(true)
                }
                .adjustmentGlass(active: draggingControl == control)
                .padding(.vertical, -4)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(control.rawValue)
                .accessibilityValue(Text(value.wrappedValue * 100, format: .number.precision(.fractionLength(0))))
                .accessibilityHint(control.detail)
                .accessibilityAdjustableAction { direction in
                    guard !busy && !comparing else { return }
                    UISelectionFeedbackGenerator().selectionChanged()
                    switch direction {
                    case .increment: value.wrappedValue = min(1, value.wrappedValue + 0.01)
                    case .decrement: value.wrappedValue = max(-1, value.wrappedValue - 0.01)
                    @unknown default: break
                    }
                }
                .accessibilityAction(named: "Reset to Zero") { if !busy && !comparing { value.wrappedValue = 0 } }
        }
    }
    private var photosFooter: some View {
        VStack(spacing: 6) {
            reviewToolPicker
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
                Text("This scene only · Current look, Light, Color, and FX")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.horizontal, 20).padding(.vertical, 6).background(.bar)
    }
    private func invalidateExport() { export.invalidate(); notice = nil; error = nil }
    private func persistEdits() async throws {
        try await app.store.editScene(movieID: movieID, sceneID: scene.id,
            start: editedScene.trimStart.cmTime, end: editedScene.trimEnd.cmTime, adjustments: adjustments, filmEffects: pendingEffects)
        await app.refresh()
        savedScene = editedScene; originalEffects = effects
    }
    private func duplicateScene() {
        guard !busy else { return }
        saving = true; error = nil; comparing = false
        preview.player?.pause()
        Task {
            do {
                try await app.store.duplicateScene(movieID: movieID, sceneID: scene.id,
                    start: editedScene.trimStart.cmTime, end: editedScene.trimEnd.cmTime, adjustments: adjustments, filmEffects: pendingEffects)
                await app.refresh()
                preview.stop(); dismiss()
            } catch { self.error = error.localizedDescription; saving = false }
        }
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
        export.saveFeedback = SaveToast(kind: .saving, message: "Preparing scene…")
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
                    else if let error = export.error { export.saveFeedback = SaveToast(kind: .failure, message: error) }
                    else { export.saveFeedback = nil }
                }
            } catch {
                self.error = error.localizedDescription; saving = false
                export.saveFeedback = SaveToast(kind: .failure, message: "Couldn’t prepare the scene. Please try again.")
            }
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

// A native horizontal scroll view preserves vertical scrolling between adjustment rows.
private struct SceneAdjustmentRuler: UIViewRepresentable {
    @Binding var value: Double
    var onEditingChanged: (Bool) -> Void
    @Environment(\.isEnabled) private var enabled
    func makeCoordinator() -> Coordinator { Coordinator(value: $value, onEditingChanged: onEditingChanged) }
    func makeUIView(context: Context) -> SceneRulerScrollView {
        let view = SceneRulerScrollView()
        view.delegate = context.coordinator
        return view
    }
    func updateUIView(_ view: SceneRulerScrollView, context: Context) {
        context.coordinator.value = $value
        context.coordinator.onEditingChanged = onEditingChanged
        view.isScrollEnabled = enabled
        view.apply(value)
    }
    static func dismantleUIView(_ view: SceneRulerScrollView, coordinator: Coordinator) {
        view.delegate = nil; view.isScrollEnabled = false
    }
    @MainActor final class Coordinator: NSObject, UIScrollViewDelegate {
        var value: Binding<Double>
        var onEditingChanged: (Bool) -> Void
        var snap = AdjustmentDetent()
        let feedback = AdjustmentFeedback()
        init(value: Binding<Double>, onEditingChanged: @escaping (Bool) -> Void) {
            self.value = value; self.onEditingChanged = onEditingChanged
        }
        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            snap = AdjustmentDetent(); feedback.begin(value: value.wrappedValue, step: 0.01)
            onEditingChanged(true)
        }
        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            onEditingChanged(false)
            if !decelerate { (scrollView as? SceneRulerScrollView)?.apply(value.wrappedValue) }
        }
        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            (scrollView as? SceneRulerScrollView)?.apply(value.wrappedValue)
        }
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard let view = scrollView as? SceneRulerScrollView, !view.applying,
                  view.readyForInput, view.isDragging || view.isDecelerating else { return }
            let next = snap.value(view.value(at: scrollView.contentOffset.x), neutral: 0, step: 0.01)
            feedback.changed(value: next, step: 0.01, neutral: 0)
            view.displayedValue = next
            if value.wrappedValue != next { value.wrappedValue = next }
        }
        func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                      targetContentOffset: UnsafeMutablePointer<CGPoint>) {
            guard let view = scrollView as? SceneRulerScrollView else { return }
            let projected = view.value(at: targetContentOffset.pointee.x)
            targetContentOffset.pointee.x = view.offset(for: abs(projected) <= 0.02 ? 0 : projected)
        }
    }
}
private final class SceneRulerScrollView: UIScrollView {
    private let ticks = SceneRulerTicks()
    private let tickSpacing: CGFloat = 6
    private var previousWidth: CGFloat = 0
    var displayedValue = 0.0
    var applying = false
    var readyForInput: Bool { previousWidth > 0 && previousWidth == bounds.width }
    init() {
        super.init(frame: .zero)
        showsHorizontalScrollIndicator = false; showsVerticalScrollIndicator = false
        bounces = false; isDirectionalLockEnabled = true; decelerationRate = .fast
        contentInsetAdjustmentBehavior = .never; semanticContentAttribute = .forceLeftToRight
        backgroundColor = .clear; isAccessibilityElement = false
        addSubview(ticks)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func value(at offset: CGFloat) -> Double {
        let raw = Double((offset + bounds.width / 2) / (100 * tickSpacing)) - 1
        return min(1, max(-1, (raw * 100).rounded() / 100))
    }
    func offset(for value: Double) -> CGFloat {
        CGFloat(min(1, max(-1, value)) + 1) * 100 * tickSpacing - bounds.width / 2
    }
    func apply(_ value: Double) {
        displayedValue = value
        guard !isDragging, bounds.width > 0 else { return }
        if isDecelerating, abs(self.value(at: contentOffset.x) - value) < 0.005 { return }
        applying = true
        setContentOffset(CGPoint(x: offset(for: value), y: 0), animated: false)
        applying = false
    }
    override func layoutSubviews() {
        let widthChanged = bounds.width != previousWidth
        let previouslyApplying = applying
        super.layoutSubviews()
        applying = true
        ticks.frame = CGRect(x: 0, y: 0, width: 200 * tickSpacing, height: bounds.height)
        if contentSize != ticks.bounds.size { contentSize = ticks.bounds.size }
        let half = bounds.width / 2
        if contentInset.left != half || contentInset.right != half {
            contentInset = UIEdgeInsets(top: 0, left: half, bottom: 0, right: half)
        }
        if widthChanged {
            previousWidth = bounds.width
            setContentOffset(CGPoint(x: offset(for: displayedValue), y: 0), animated: false)
        }
        applying = previouslyApplying
    }
}
private final class SceneRulerTicks: UIView {
    override init(frame: CGRect) { super.init(frame: frame); backgroundColor = .clear; isOpaque = false; isAccessibilityElement = false }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.setStrokeColor(UIColor.secondaryLabel.withAlphaComponent(0.55).cgColor)
        context.setLineWidth(1.5); context.setLineCap(.round)
        for index in 0...200 {
            let height: CGFloat = index == 100 ? 14 : (index % 10 == 0 ? 11 : 6)
            let x = CGFloat(index) * 6
            context.move(to: CGPoint(x: x, y: 15 - height))
            context.addLine(to: CGPoint(x: x, y: 15))
        }
        context.strokePath()
    }
}
