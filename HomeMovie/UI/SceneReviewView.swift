import SwiftUI
import AVKit
import UIKit

@MainActor final class SceneReviewPreviewModel: ObservableObject {
    @Published var player: AVPlayer?
    @Published var histogram: ReviewHistogram?
    private let histogramAnalyzer = ReviewHistogramAnalyzer()
    private var histogramOutput: AVPlayerItemVideoOutput?
    private weak var histogramItem: AVPlayerItem?
    private var histogramRequest = UUID()
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
        histogram = nil
        item.videoComposition = composition
        if player.timeControlStatus == .paused, player.currentTime().isNumeric {
            _ = await player.seek(to: player.currentTime(), toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }
    // One sampled frame at a time, at most four times a second. The output
    // belongs to the displayed composition, including looks, HSL and effects.
    func monitorHistogram(enabled: Bool) async {
        let token = UUID(); histogramRequest = token
        removeHistogramOutput()
        guard enabled else { return }
        defer { if histogramRequest == token { removeHistogramOutput() } }
        while !Task.isCancelled, histogramRequest == token {
            if let item = player?.currentItem {
                if histogramItem !== item {
                    removeHistogramOutput()
                    let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
                    item.add(output); histogramOutput = output; histogramItem = item
                    if let player, player.timeControlStatus == .paused, player.currentTime().isNumeric {
                        // A newly attached output needs a rendered frame even
                        // when the user returns to Light with playback paused.
                        _ = await player.seek(to: player.currentTime(), toleranceBefore: .zero, toleranceAfter: .zero)
                    }
                }
                // A tab/lifecycle change can replace the output while a paused
                // seek is suspended. An obsolete task must not acquire the new
                // output's only paused frame and then discard it.
                guard !Task.isCancelled, histogramRequest == token else { return }
                let time = player?.currentTime() ?? .invalid
                if time.isNumeric, let output = histogramOutput,
                   output.hasNewPixelBuffer(forItemTime: time),
                   let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
                    let result = await histogramAnalyzer.measure(HistogramFrame(buffer))
                    if !Task.isCancelled, histogramRequest == token, histogramOutput === output { histogram = result }
                }
            }
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
        }
    }
    private func removeHistogramOutput() {
        if let histogramItem, let histogramOutput { histogramItem.remove(histogramOutput) }
        histogramOutput = nil; histogramItem = nil; histogram = nil
    }
    func stop() {
        histogramRequest = UUID(); removeHistogramOutput()
        requestID = UUID(); player?.pause(); statusObservation = nil
        player = nil; template = nil; loading = false
    }
}

private enum SceneReviewTool: String, CaseIterable, Identifiable {
    case light = "Light", color = "Color", hsl = "HSL", fx = "FX", trim = "Trim"
    var symbol: String {
        switch self {
        case .light: "sun.max"
        case .color: "circle.lefthalf.filled"
        case .hsl: "slider.horizontal.3"
        case .fx: "sparkles"
        case .trim: "crop.rotate"
        }
    }
    var id: String { rawValue }
}
private enum SceneLightControl: String, CaseIterable, Identifiable {
    case exposure = "Exposure", brilliance = "Brilliance", highlights = "Highlights", shadows = "Shadows"
    case contrast = "Contrast", brightness = "Brightness", blackPoint = "Black Point", whitePoint = "White Point", pushPull = "Push/Pull"
    case fade = "Fade"
    case saturation = "Saturation", vibrance = "Vibrance", warmth = "Warmth", tint = "Tint"
    var id: String { rawValue }
    var isColor: Bool { self == .saturation || self == .vibrance || self == .warmth || self == .tint }
    var keyPath: WritableKeyPath<SceneAdjustments, Double> {
        switch self {
        case .fade: \.fade
        case .exposure: \.exposure
        case .shadows: \.shadows
        case .highlights: \.highlights
        case .brightness: \.brightness
        case .brilliance: \.brilliance
        case .pushPull: \.pushPull
        case .contrast: \.contrast
        case .blackPoint: \.blackPoint
        case .whitePoint: \.whitePoint
        case .saturation: \.saturation
        case .vibrance: \.vibrance
        case .warmth: \.warmth
        case .tint: \.tint
        }
    }
    var symbol: String {
        switch self {
        case .fade: "circle.dotted"
        case .exposure: "sun.max"
        case .brightness: "sun.min"
        case .brilliance: "sun.max.circle"
        case .pushPull: "circle.lefthalf.filled"
        case .contrast: "circle.lefthalf.filled"
        case .blackPoint: "circle.bottomhalf.filled"
        case .whitePoint: "circle.tophalf.filled"
        case .saturation: "drop.fill"
        case .vibrance: "rainbow"
        case .shadows: "moon"
        case .highlights: "sun.max.fill"
        case .warmth: "thermometer.medium"
        case .tint: "circle.lefthalf.filled"
        }
    }
    var endpoints: (String, String)? {
        switch self {
        case .fade: ("Off", "Lifted Blacks")
        case .warmth: ("Blue", "Yellow")
        case .tint: ("Green", "Magenta")
        case .pushPull: ("Pull · Softer", "Push · Denser")
        case .contrast: ("Softer", "Stronger")
        case .blackPoint: ("Lifted", "Deeper")
        case .whitePoint: ("Softer", "Brighter")
        case .saturation: ("Muted", "Rich")
        case .vibrance: ("Muted", "Vibrant")
        default: nil
        }
    }
    var detail: String {
        switch self {
        case .fade: "Lifts the finished black level for a softer, faded look. Zero is off."
        case .exposure: "Adjusts the overall light level."
        case .brightness: "Brightens or darkens the midtones."
        case .brilliance: "Balances darker areas and bright highlights."
        case .pushPull: "Softens contrast or adds density. Does not change recording exposure."
        case .contrast: "Softens or strengthens separation between light and dark tones."
        case .blackPoint: "Lifts the darkest tones or deepens them to black."
        case .whitePoint: "Lowers the white ceiling or brightens the lightest tones."
        case .saturation: "Adjusts all color intensity. Minus 100 is black and white."
        case .vibrance: "Adjusts quieter colors more, with less boost to strong colors and warm tones."
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

// Keep the sheet alive while replacing a deleted clip's editing session.
struct SceneReviewView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    let movieID: UUID
    @State private var selectedScene: Scene?

    init(movieID: UUID, scene: Scene) {
        self.movieID = movieID
        _selectedScene = State(initialValue: scene)
    }

    var body: some View {
        Group {
            if let scene = selectedScene {
                SceneReviewSession(movieID: movieID, scene: scene) { nextID in
                    selectedScene = app.movie(movieID)?.activeScenes.first { $0.id == nextID }
                }.id(scene.id)
            } else {
                NavigationStack {
                    ContentUnavailableView("No Clips", systemImage: "film",
                        description: Text("The clip was moved to Recently Deleted. You can restore it from Settings."))
                        .navigationTitle("Edit Scene")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { dismiss() }
                            }
                        }
                }
            }
        }
    }
}

private struct SceneReviewSession: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let movieID: UUID
    let scene: Scene
    let onDeleted: (UUID?) -> Void
    @StateObject private var preview = SceneReviewPreviewModel()
    @StateObject private var export = ExportModel()
    @State private var history: SceneEditHistory?
    @State private var showingCopyAdjustments = false
    @State private var showingFullscreenPreview = false
    @State private var start: Double
    @State private var end: Double
    @State private var adjustments: SceneAdjustments
    @State private var interactingControl: String?
    @State private var hslBand = HSLBand.red
    @State private var advancedLight = false
    @State private var pickingWhiteBalance = false
    @State private var samplingWhiteBalance = false
    @State private var savedScene: Scene
    @State private var effects = FilmEffectsSettings.off
    @State private var originalEffects = FilmEffectsSettings.off
    @State private var clipEffects: FilmEffectsTweaks?
    @State private var editingClipFX = false
    @State private var loadedEffects = false
    @State private var comparing = false
    @State private var tool = SceneReviewTool.light
    @State private var saving = false
    @State private var savingPhotos = false
    @State private var waitingForExport = false
    @State private var confirmRemove = false
    @State private var confirmDiscard = false
    @State private var error: String?
    @State private var notice: String?
    init(movieID: UUID, scene: Scene, onDeleted: @escaping (UUID?) -> Void) {
        self.onDeleted = onDeleted
        self.movieID = movieID; self.scene = scene
        _start = State(initialValue: scene.trimStart.seconds)
        _end = State(initialValue: scene.trimEnd.seconds)
        _adjustments = State(initialValue: scene.lightAdjustments)
        _savedScene = State(initialValue: scene)
        _clipEffects = State(initialValue: scene.filmEffectsTweaks?.normalized)
        _editingClipFX = State(initialValue: scene.filmEffectsTweaks?.normalized != nil)
        _advancedLight = State(initialValue: scene.lightAdjustments.pushPull != 0 || scene.lightAdjustments.fade != 0 || scene.lightAdjustments.curve.isActive)
    }
    private var movie: Movie? { app.movie(movieID) }
    private var reviewAspect: CGFloat { movie?.format.aspect ?? (scene.width > scene.height ? 16 / 9 : 9 / 16) }
    private var busy: Bool { samplingWhiteBalance || saving || export.running || savingPhotos || waitingForExport }
    private var hasUnsavedEdits: Bool {
        editedScene.trimStart != savedScene.trimStart || editedScene.trimEnd != savedScene.trimEnd
            || adjustments != savedScene.lightAdjustments || effects != originalEffects
            || clipEffects?.normalized != savedScene.filmEffectsTweaks?.normalized
    }
    private var resolvedEffects: FilmEffectsSettings { clipEffects?.applying(to: effects) ?? effects }
    private var scopedEffects: Binding<FilmEffectsSettings> {
        Binding(get: { editingClipFX ? resolvedEffects : effects }, set: { edited in
            if editingClipFX {
                clipEffects = (clipEffects ?? FilmEffectsTweaks()).updating(
                    from: resolvedEffects, to: edited, relativeTo: effects).normalized
            } else { effects = edited }
        })
    }
    private var shownRecipe: SceneReviewRecipe {
        SceneReviewRecipe(adjustments: comparing ? .neutral : adjustments, effects: comparing ? .off : resolvedEffects)
    }
    private var editState: SceneEditState {
        SceneEditState(start: start, end: end, adjustments: adjustments, effects: effects, clipEffects: clipEffects)
    }
    private func editingChanged(_ active: Bool) {
        if active { history?.begin(editState) } else { history?.end(editState) }
    }
    private func restoreEdit(_ state: SceneEditState) {
        pickingWhiteBalance = false; comparing = false; error = nil; notice = nil
        start = state.start; end = state.end
        adjustments = state.adjustments; effects = state.effects; clipEffects = state.clipEffects
        if adjustments.pushPull != 0 || adjustments.fade != 0 || adjustments.curve.isActive { advancedLight = true }
        UISelectionFeedbackGenerator().selectionChanged()
    }
    private func undoEdit() {
        history?.observe(editState)
        if let state = history?.undo() { restoreEdit(state) }
    }
    private func redoEdit() {
        history?.observe(editState)
        if let state = history?.redo() { restoreEdit(state) }
    }
    private func pasteAdjustments() {
        guard let clipboard = app.copiedSceneAdjustments, !busy else { return }
        do {
            let pasted = try clipboard.applying(to: adjustments)
            pickingWhiteBalance = false; comparing = false
            editingChanged(true); adjustments = pasted; editingChanged(false)
            if pasted.pushPull != 0 || pasted.fade != 0 || pasted.curve.isActive { advancedLight = true }
            UISelectionFeedbackGenerator().selectionChanged()
        } catch { self.error = error.localizedDescription }
    }
    private var pendingEffects: FilmEffectsSettings? { effects != originalEffects ? effects : nil }
    private var visibleLightControls: [SceneLightControl] {
        SceneLightControl.allCases.filter { tool == .color ? $0.isColor : !$0.isColor }
    }
    private var canReset: Bool {
        tool == .hsl ? adjustments.hsl.isActive : tool == .fx ? (editingClipFX ? clipEffects != nil : effects != .off) : (tool == .light && adjustments.curve.isActive) || visibleLightControls.contains { adjustments[keyPath: $0.keyPath] != 0 }
    }
    private func resetTool() {
        UISelectionFeedbackGenerator().selectionChanged()
        if tool == .hsl { adjustments.hsl = HSLAdjustments() }
        else if tool == .fx { if editingClipFX { clipEffects = nil } else { effects = .off } }
        else { for control in visibleLightControls { adjustments[keyPath: control.keyPath] = 0 } }
        if tool == .light { adjustments.curve = .neutral }
        if !adjustments.isActive { adjustments = .neutral }
        comparing = false
    }
    private var editedScene: Scene {
        var edited = scene
        edited.trimStart = MediaTime(seconds: start); edited.trimEnd = MediaTime(seconds: end)
        edited.adjustments = adjustments.isActive ? adjustments : nil
        edited.filmEffectsTweaks = clipEffects?.normalized
        return edited
    }
    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                if geometry.size.width > geometry.size.height {
                    HStack(spacing: 0) {
                        previewPanel.frame(width: geometry.size.width * 0.68, height: geometry.size.height)
                            .background(.black)
                        editingPanel.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    VStack(spacing: 0) {
                        previewPanel.frame(maxWidth: .infinity)
                            .frame(height: max(120, min(geometry.size.width / reviewAspect,
                                min(geometry.size.height * (dynamicTypeSize.isAccessibilitySize ? 0.52 : 0.68),
                                    geometry.size.height - (dynamicTypeSize.isAccessibilitySize ? 240 : 180)))))
                            .background(.black)
                        editingPanel.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { editorFooter }
            .saveStatusToast($export.saveFeedback)
            .navigationTitle("Edit Scene").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if hasUnsavedEdits { preview.player?.pause(); confirmDiscard = true }
                        else { preview.stop(); dismiss() }
                    }.disabled(busy)
                }
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button("Undo", systemImage: "arrow.uturn.backward", action: undoEdit)
                        .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                        .disabled(history?.canUndo != true || busy || preview.loading)
                    Button("Redo", systemImage: "arrow.uturn.forward", action: redoEdit)
                        .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                        .disabled(history?.canRedo != true || busy || preview.loading)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Copy Adjustments", systemImage: "doc.on.doc") { pickingWhiteBalance = false; preview.player?.pause(); showingCopyAdjustments = true }
                            .disabled(preview.loading)
                        Button("Paste Adjustments", systemImage: "doc.on.clipboard", action: pasteAdjustments)
                            .disabled(app.copiedSceneAdjustments == nil || preview.loading)
                        Divider()
                        Button("Save Edited Clip to Photos", systemImage: "square.and.arrow.down") { saveClip() }
                            .accessibilityHint("Saves only this trimmed clip with its current look and adjustments")
                            .disabled(preview.loading || preview.error != nil)
                        Button("Duplicate", systemImage: "plus.square.on.square") { duplicateScene() }
                        Divider()
                        Button("Delete Scene", systemImage: "trash", role: .destructive) { confirmRemove = true }
                    } label: { Image(systemName: "ellipsis.circle").frame(minWidth: 44, minHeight: 44) }
                        .accessibilityLabel("Scene actions").disabled(busy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { saveEditsAndClose() }.disabled(busy)
                }
            }
            .fullScreenCover(isPresented: $showingFullscreenPreview) {
                if let player = preview.player { SceneFullscreenPreview(player: player) }
            }
            .sheet(isPresented: $showingCopyAdjustments) {
                CopySceneAdjustmentsView(source: adjustments) { clipboard in
                    app.copiedSceneAdjustments = clipboard
                    notice = "Adjustments copied. Open another scene to paste."
                    UISelectionFeedbackGenerator().selectionChanged()
                }
            }
            .onChange(of: editState) { _, state in history?.observe(state) }
            .confirmationDialog("Discard changes?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Discard Changes", role: .destructive) { preview.stop(); dismiss() }
                Button("Keep Editing", role: .cancel) { }
            }
            .alert("Delete this scene?", isPresented: $confirmRemove) {
                Button("Cancel", role: .cancel) { }
                Button("Move to Recently Deleted", role: .destructive) {
                    deleteScene()
                }
            } message: { Text("Restore it later from Settings. Its original file will be kept.") }
            .task {
                // A fullscreen presentation can restart this task on return.
                // Keep the edited player and its current playback position.
                guard preview.player == nil else { return }
                guard let movie else { error = "This movie is unavailable."; return }
                if !loadedEffects {
                    effects = movie.exportEffects; originalEffects = effects; loadedEffects = true
                    history = SceneEditHistory(editState)
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
            .onChange(of: clipEffects) { _, _ in invalidateExport() }
            .onChange(of: editingClipFX) { _, _ in editingChanged(false); comparing = false }
            .onChange(of: tool) { _, _ in editingChanged(false); pickingWhiteBalance = false; comparing = false; interactingControl = nil; UISelectionFeedbackGenerator().selectionChanged() }
            .onChange(of: export.running) { _, running in
                guard !running, waitingForExport else { return }
                waitingForExport = false
                if export.exportedURL != nil { writeClipToPhotos() }
                else if let error = export.error { export.saveFeedback = SaveToast(kind: .failure, message: error) }
                else { export.saveFeedback = nil }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { editingChanged(false); comparing = false; interactingControl = nil; preview.player?.pause() }
            }
            .onChange(of: busy) { _, value in if value { editingChanged(false); pickingWhiteBalance = false; comparing = false; interactingControl = nil } }
        }
        .interactiveDismissDisabled(busy || hasUnsavedEdits)
        .onDisappear {
            if !showingFullscreenPreview { preview.stop(); export.cancel() }
        }
    }
    private var reviewToolPicker: some View {
        HStack(spacing: 0) {
            ForEach(SceneReviewTool.allCases) { item in
                Button { tool = item } label: {
                    VStack(spacing: 3) {
                        Image(systemName: item.symbol).font(.system(size: 18))
                        Text(item.rawValue).font(.caption.weight(.semibold))
                    }.frame(maxWidth: .infinity, minHeight: 44)
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
            if tool == .fx {
                Form {
                    Section {
                        Picker("Apply FX to", selection: $editingClipFX) {
                            Text("Movie").tag(false)
                            Text("This Clip").tag(true)
                        }.pickerStyle(.segmented)
                        if clipEffects != nil {
                            Label("Clip Adjusted", systemImage: "slider.horizontal.3")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if editingClipFX {
                            Button("Reset to Movie Look", systemImage: "arrow.counterclockwise") {
                                editingChanged(true); clipEffects = nil; editingChanged(false)
                                UISelectionFeedbackGenerator().selectionChanged()
                            }.disabled(clipEffects == nil)
                        }
                    } footer: {
                        Text(editingClipFX ? "Fine-tune this clip from the movie’s look." :
                            "Sets the look for all clips. Individual clip tweaks are kept.")
                    }
                    FilmEffectsControlSections(settings: scopedEffects, editingChanged: editingChanged, compact: true)
                }
                    .listStyle(.plain).listSectionSpacing(.compact)
                    .disabled(busy || comparing || preview.loading || preview.error != nil)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        if tool == .trim { trimControls } else if tool == .hsl { hslControls } else { lightControls }
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
    private var previewPanel: some View {
        ZStack {
            Color.black
            if let player = preview.player {
                SceneReviewPlayer(player: showingFullscreenPreview ? nil : player, showsControls: false)
                Button { showingFullscreenPreview = true } label: {
                    Color.clear
                        .contentShape(Rectangle())
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.white).frame(width: 44, height: 44)
                                .background(.black.opacity(0.45), in: Circle()).padding(8)
                        }
                }.buttonStyle(.plain)
                    .accessibilityLabel("Expand Video Preview")
                    .accessibilityHint("Opens fullscreen playback with native video controls. Close it to continue editing.")
                    .disabled(busy || preview.loading || preview.error != nil || pickingWhiteBalance)
            }
            if preview.loading { ProgressView().tint(.white) }
        }
        .aspectRatio(reviewAspect, contentMode: .fit)
        .overlay {
            if pickingWhiteBalance {
                GeometryReader { geometry in
                    Color.clear.contentShape(Rectangle())
                        .gesture(SpatialTapGesture().onEnded { tap in
                            sampleWhiteBalance(at: CGPoint(x: tap.location.x / geometry.size.width, y: tap.location.y / geometry.size.height))
                        })
                        .overlay(alignment: .bottom) {
                            Text("Tap a neutral gray area").font(.footnote.weight(.medium))
                                .padding(10).background(.regularMaterial, in: Capsule()).padding(12)
                                .allowsHitTesting(false)
                        }
                }
            }
        }
        .overlay(alignment: .topLeading) {
            if (scene.profile ?? movie?.captureProfile) == .appleLog {
                LogLookBadge(lookName: movie?.lookName ?? "Apple Standard").padding(12)
            }
        }
    }
    private var trimControls: some View {
        VStack(spacing: 12) {
            TrimRangeControl(scene: scene, root: app.store.root, start: $start, end: $end, movie: movie, editingChanged: editingChanged)
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
    private var hslControls: some View {
        VStack(spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 0) {
                    ForEach(HSLBand.allCases) { band in hslBandButton(band) }
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 4), spacing: 4) {
                    ForEach(HSLBand.allCases) { band in hslBandButton(band) }
                }
            }
            HStack {
                Text(hslBand.name).font(.subheadline.weight(.semibold))
                Spacer()
                Button("Reset Color", systemImage: "arrow.counterclockwise") {
                    adjustments.hsl[hslBand] = HSLValues()
                    UISelectionFeedbackGenerator().selectionChanged()
                }.font(.caption).frame(minHeight: 44)
                    .disabled(!adjustments.hsl[hslBand].isActive)
            }
            hslSlider("Hue", symbol: "paintpalette", path: \.hue, detail: "Shifts the selected color toward neighboring colors.")
            hslSlider("Saturation", symbol: "drop.fill", path: \.saturation, detail: "Mutes or enriches the selected color.")
            hslSlider("Lightness", symbol: "sun.max", path: \.lightness, detail: "Darkens or brightens the selected color.")
        }.padding(.horizontal, 16)
            .disabled(busy || comparing || preview.loading || preview.error != nil)
    }
    private func hslBandButton(_ band: HSLBand) -> some View {
        Button {
            hslBand = band; interactingControl = nil
            UISelectionFeedbackGenerator().selectionChanged()
        } label: {
            Circle().fill(Color(hue: band.degrees / 360, saturation: 0.8, brightness: 0.95))
                .frame(width: 26, height: 26)
                .overlay { if hslBand == band { Circle().stroke(.primary, lineWidth: 2).padding(-4) } }
                .overlay(alignment: .bottomTrailing) {
                    if adjustments.hsl[band].isActive {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 12, weight: .bold))
                            .symbolRenderingMode(.palette).foregroundStyle(.primary, .background)
                            .offset(x: 4, y: 4)
                    }
                }
                .frame(minWidth: 44, maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(band.name)
            .accessibilityValue(adjustments.hsl[band].isActive ? "Edited" : "Unchanged")
            .accessibilityAddTraits(hslBand == band ? [.isSelected] : [])
    }
    private func hslSlider(_ title: String, symbol: String, path: WritableKeyPath<HSLValues, Double>, detail: String) -> some View {
        let band = hslBand
        let value = Binding(get: { adjustments.hsl[band][keyPath: path] }, set: { value in
            adjustments.hsl[band][keyPath: path] = value
            if !adjustments.isActive { adjustments = .neutral }
        })
        return adjustmentSlider(title: title, symbol: symbol, detail: "\(band.name). \(detail)", value: value)
            .id("\(band.rawValue)-\(title)")
    }
    private var lightControls: some View {
        LazyVStack(spacing: 4) {
            if tool == .color {
                Button {
                    preview.player?.pause()
                    pickingWhiteBalance.toggle()
                    UISelectionFeedbackGenerator().selectionChanged()
                } label: {
                    Label(pickingWhiteBalance ? "Cancel White Balance" : "White Balance", systemImage: "eyedropper")
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }.disabled(busy || comparing || adjustments.pipelineVersion < 2)
                .accessibilityHint("Tap a neutral gray area in the preview to set Warmth and Tint before the look")
            }
            ForEach(visibleLightControls.filter { $0 != .pushPull && $0 != .fade }) { control in lightSlider(control) }
            if tool == .light {
                DisclosureGroup(isExpanded: $advancedLight.withSelectionFeedback()) {
                    lightSlider(.pushPull)
                    lightSlider(.fade)
                    LightCurveEditor(curve: $adjustments.curve, editingChanged: { active in
                        editingChanged(active)
                        interactingControl = active ? "Curve" : nil
                    }).disabled(busy || comparing)
                        .background { if interactingControl == "Curve" { Color.clear.homeGlass().allowsHitTesting(false) } }
                } label: {
                    Label("Advanced", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                        .font(.subheadline.weight(.semibold)).frame(minHeight: 44)
                }.tint(.primary).padding(.top, 8).disabled(busy || comparing)
            }
        }.padding(.horizontal, 16).disabled(preview.loading || preview.error != nil)
    }
    private func lightSlider(_ control: SceneLightControl) -> some View {
        let value = Binding(get: { adjustments[keyPath: control.keyPath] },
            set: {
                adjustments[keyPath: control.keyPath] = $0
                if !adjustments.isActive { adjustments = .neutral }
            })
        return adjustmentSlider(title: control.rawValue, symbol: control.symbol, detail: control.detail, value: value, range: control == .fade ? 0...1 : -1...1)
    }
    private func adjustmentSlider(title: String, symbol: String, detail: String, value: Binding<Double>, range: ClosedRange<Double> = -1...1) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: symbol).frame(width: 20).accessibilityHidden(true)
                Text(title).fontWeight(.semibold)
                Spacer(minLength: 8)
                Text(abs(value.wrappedValue) < 0.005 ? "0" : String(format: "%+.0f", value.wrappedValue * 100))
                    .monospacedDigit().foregroundStyle(.secondary)
                    .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        guard !busy && !comparing else { return }
                        value.wrappedValue = 0
                        UISelectionFeedbackGenerator().selectionChanged()
                    }
                    .accessibilityHidden(true)
            }.font(.subheadline)
            HapticGlassSlider(value: value, range: range, editingChanged: editingChanged)
                .frame(minHeight: 44)
                .accessibilityLabel(title)
                .accessibilityValue(Text(value.wrappedValue * 100, format: .number.precision(.fractionLength(0))))
                .accessibilityHint(detail)
                .accessibilityAction(named: "Reset to Zero") {
                    guard !busy && !comparing else { return }
                    value.wrappedValue = 0
                    UISelectionFeedbackGenerator().selectionChanged()
                }
        }.padding(.vertical, 2).disabled(busy || comparing)
    }
    private var editorFooter: some View {
        VStack(spacing: 4) {
            reviewToolPicker
            if export.running {
                ProgressView(value: export.progress) { Text("Preparing Edited Clip…") }
                Button("Cancel Export") { export.cancel() }.frame(minHeight: 44)
            }
        }.padding(.horizontal, 8).padding(.vertical, 4).background(.bar)
    }
    private func sampleWhiteBalance(at point: CGPoint) {
        guard pickingWhiteBalance, !busy, let movie else { return }
        pickingWhiteBalance = false; samplingWhiteBalance = true; error = nil
        let time = preview.player?.currentTime() ?? scene.trimStart.cmTime
        let url = app.store.root.appendingPathComponent(scene.source)
        Task {
            defer { samplingWhiteBalance = false }
            do {
                let result = try await WhiteBalanceSampler.sample(url: url, time: time, point: point,
                    canvas: movie.format.canvas, logEncoded: (scene.profile ?? movie.captureProfile) == .appleLog)
                editingChanged(true)
                adjustments.warmth = result.warmth; adjustments.tint = result.tint
                editingChanged(false)
                UISelectionFeedbackGenerator().selectionChanged()
                notice = "White balance set for this scene."
            } catch { self.error = error.localizedDescription }
        }
    }
    private func invalidateExport() { export.invalidate(); notice = nil; error = nil }
    private func persistEdits() async throws {
        try await app.store.editScene(movieID: movieID, sceneID: scene.id,
            start: editedScene.trimStart.cmTime, end: editedScene.trimEnd.cmTime, adjustments: adjustments, filmEffects: pendingEffects,
            clipEffects: clipEffects, updateClipEffects: true)
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
                    start: editedScene.trimStart.cmTime, end: editedScene.trimEnd.cmTime, adjustments: adjustments, filmEffects: pendingEffects,
                    clipEffects: clipEffects, updateClipEffects: true)
                await app.refresh()
                preview.stop(); dismiss()
            } catch { self.error = error.localizedDescription; saving = false }
        }
    }
    private func deleteScene() {
        guard !busy else { return }
        editingChanged(false)
        let nextID = SceneEditorSelection.afterDeleting(scene.id, from: movie?.activeScenes.map(\.id) ?? [])
        saving = true; error = nil
        preview.player?.pause()
        Task {
            do {
                try await app.store.setSceneDeleted(movieID: movieID, sceneID: scene.id, deleted: true)
                await app.refresh()
                preview.stop(); export.cancel()
                onDeleted(nextID)
            } catch { self.error = error.localizedDescription; saving = false }
        }
    }
    private func saveEditsAndClose() {
        guard !busy else { return }
        // UIKit can cancel a slider gesture without delivering its end callback.
        // Finish the transaction using the latest values; preview readiness is
        // unrelated to persisting edits and must never trap the user here.
        editingChanged(false)
        pickingWhiteBalance = false; comparing = false; interactingControl = nil
        if !loadedEffects, let movie {
            effects = movie.exportEffects; originalEffects = effects; loadedEffects = true
        }
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


// Share the exact edited player and playback position between both sizes.
// Detach the embedded surface while the fullscreen controller owns the player.
private struct SceneReviewPlayer: UIViewControllerRepresentable {
    let player: AVPlayer?
    let showsControls: Bool
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.videoGravity = .resizeAspect
        controller.showsPlaybackControls = showsControls
        controller.player = player
        return controller
    }
    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
        controller.showsPlaybackControls = showsControls
    }
}

private struct SceneFullscreenPreview: View {
    @Environment(\.dismiss) private var dismiss
    let player: AVPlayer
    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            SceneReviewPlayer(player: player, showsControls: true).ignoresSafeArea()
            Button("Done") { dismiss() }
                .font(.headline).foregroundStyle(.white)
                .padding(.horizontal, 18).frame(minHeight: 44)
                .background(.ultraThinMaterial, in: Capsule()).padding(16)
                .accessibilityLabel("Close Fullscreen Preview")
        }.preferredColorScheme(.dark)
    }
}
