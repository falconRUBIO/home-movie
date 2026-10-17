import SwiftUI
import AVKit

@MainActor final class FilmEffectsPreviewModel: ObservableObject {
    @Published var player: AVPlayer?
    @Published var loading = false
    @Published var error: String?
    private var preparedMovieID: UUID?
    private var template: AVMutableVideoComposition?
    private var statusObservation: NSKeyValueObservation?
    private var requestID = UUID()
    private var updateID = UUID()
    func prepare(movie: Movie, app: AppModel, settings: FilmEffectsSettings) async {
        // Fullscreen presentation can restart the parent task. Keep its player/timeline.
        if preparedMovieID == movie.id, player != nil, error == nil { return }
        let id = UUID(); requestID = id; loading = true; error = nil
        defer { if requestID == id { loading = false } }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
            let bundle = try await app.assembler.build(movie: movie, root: app.store.root, filmEffects: settings, forFilmEffectsPreview: true)
            try Task.checkCancellation()
            guard requestID == id else { return }
            template = bundle.videoComposition; preparedMovieID = movie.id
            let item = AVPlayerItem(asset: bundle.asset)
            item.videoComposition = bundle.videoComposition; item.audioMix = bundle.audioMix
            player = AVPlayer(playerItem: item)
            statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                guard item.status == .failed else { return }
                let message = item.error?.localizedDescription ?? "This preview could not render. Your original recordings are safe."
                Task { @MainActor in self?.error = message; self?.player?.pause() }
            }
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
    func update(settings: FilmEffectsSettings) async {
        guard let template, let player, let item = player.currentItem,
              let composition = template.mutableCopy() as? AVMutableVideoComposition else { return }
        let id = UUID(); updateID = id
        let position = player.currentTime()
        let playing = player.timeControlStatus != .paused
        composition.instructions = template.instructions.map { instruction in
            guard let source = instruction as? ColorInstruction else { return instruction }
            return ColorInstruction(range: source.timeRange, trackID: source.trackID, transform: source.transform,
                                    cube: source.cube, filmEffects: settings, adjustments: source.adjustments)
        }
        item.videoComposition = composition
        // Running playback picks up the new recipe without pausing or replacing its item.
        // A paused frame needs an exact seek to redraw; timeline-seeded grain stays fixed.
        if !playing, position.isNumeric { _ = await player.seek(to: position, toleranceBefore: .zero, toleranceAfter: .zero) }
        guard updateID == id, !Task.isCancelled else { return }
    }
    func stop() { requestID = UUID(); updateID = UUID(); loading = false; player?.pause() }
    func release() {
        stop()
        // A dismissed preview must not keep a second decoder/compositor alive during export.
        statusObservation = nil
        player?.replaceCurrentItem(with: nil)
        player = nil; template = nil; preparedMovieID = nil
    }
}

struct FilmEffectsView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    let movie: Movie
    @State private var settings: FilmEffectsSettings
    @StateObject private var preview = FilmEffectsPreviewModel()
    @State private var comparing = false
    @State private var fullscreen = false
    @State private var saving = false
    @State private var saveError: String?
    @State private var showGrainDetails = false
    @State private var showHalationDetails = false
    @State private var showBloomDetails = false
    init(movie: Movie) { self.movie = movie; _settings = State(initialValue: movie.exportEffects) }
    private var shownSettings: FilmEffectsSettings { comparing ? .off : settings }
    var body: some View {
        Group {
            if verticalSizeClass == .compact {
                HStack(spacing: 0) { previewPanel.frame(maxWidth: .infinity); controls.frame(maxWidth: .infinity) }
            } else {
                VStack(spacing: 0) { previewPanel.frame(height: 240); controls }
            }
        }
        .navigationTitle("Film Effects").navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button { saveAndClose() } label: { Label("Export", systemImage: "chevron.left") }
                    .disabled(saving)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { saveAndClose() }.disabled(saving)
            }
        }
        .task {
            await preview.prepare(movie: movie, app: app, settings: settings)
            if !Task.isCancelled { await preview.update(settings: shownSettings) }
        }
        .task(id: shownSettings) {
            do {
                try Task.checkCancellation()
                await preview.update(settings: shownSettings)
            } catch { }
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { comparing = false; preview.stop() } }
        .onDisappear { if !fullscreen { preview.release() } }
        .fullScreenCover(isPresented: $fullscreen) {
            FilmEffectsFullscreen(preview: preview, aspect: movie.format.aspect, comparing: $comparing, settings: settings)
        }
        .alert("Settings could not be saved", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("OK") { saveError = nil }
        } message: { Text(saveError ?? "") }
    }
    private var previewPanel: some View {
        VStack(spacing: 8) {
            GeometryReader { geometry in
                ZStack {
                    Color.black
                    if let player = preview.player {
                        let width = min(geometry.size.width, geometry.size.height * movie.format.aspect)
                        VideoPlayer(player: player)
                            .frame(width: width, height: width / movie.format.aspect)
                    }
                    if preview.loading { ProgressView().tint(.white) }
                    if let error = preview.error { Text(error).font(.footnote).foregroundStyle(.white).padding() }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .topLeading) {
                        Text(comparing ? "Without Effects" : "Export Preview")
                            .font(.caption).padding(6).background(.ultraThinMaterial, in: Capsule()).padding(8)
                    }
                    .overlay(alignment: .topTrailing) {
                        Button { fullscreen = true } label: { Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 44, height: 44) }
                            .background(.ultraThinMaterial, in: Circle()).padding(8)
                            .accessibilityLabel("Inspect export preview fullscreen").disabled(preview.player == nil)
                    }
            }
            FilmEffectsCompareButton(comparing: $comparing).disabled(preview.player == nil)
        }.padding(.bottom, 8).background(Color.black.opacity(0.04))
    }
    private var controls: some View {
        Form {
            softnessControls
            rolloffControls
            grainControls
            halationControls
            bloomControls
            Section {
                Button("Reset All") { settings = .off; comparing = false }
            } footer: { Text("These effects appear in this preview and your exported copy. Original recordings and your selected color look are preserved.") }
        }.disabled(saving)
    }
    private var softnessControls: some View {
        Section {
            Toggle("Optical Softness", isOn: $settings.softnessEnabled)
            if settings.softnessEnabled {
                amountSlider("Amount", value: $settings.softnessAmount)
            }
        } footer: { Text("Gently softens fine detail for a less digital texture. Faces stay clear.") }
    }
    private var rolloffControls: some View {
        Section {
            Toggle("Highlight Roll-Off", isOn: $settings.rolloffEnabled)
            if settings.rolloffEnabled {
                amountSlider("Amount", value: $settings.rolloffAmount)
            }
        } footer: { Text("Smooths bright tones toward white. Lower amounts keep highlights brighter.") }
    }
    private var grainControls: some View {
        Section {
            Toggle("Grain", isOn: $settings.grainEnabled)
            if settings.grainEnabled {
                amountSlider("Amount", value: $settings.grainAmount)
                DisclosureGroup("Adjustments", isExpanded: $showGrainDetails) {
                    Picker("Texture", selection: $settings.grainTexture) {
                        ForEach(FilmGrainTexture.allCases) { texture in Text(texture.label).tag(texture) }
                    }
                    amountSlider("Size", value: $settings.grainSize, range: 0.5...2, percent: false)
                    Button("Reset Grain") { settings.grainAmount = 0.25; settings.grainSize = 1; settings.grainTexture = .fine35 }
                }
            }
        } footer: { Text("Adds fine, moving film texture. Pause to inspect the detail.") }
    }
    private var halationControls: some View {
        Section {
            Toggle("Halation", isOn: $settings.halationEnabled)
            if settings.halationEnabled {
                amountSlider("Amount", value: $settings.halationAmount)
                DisclosureGroup("Adjustments", isExpanded: $showHalationDetails) {
                    amountSlider("Spread", value: $settings.halationSpread)
                    amountSlider("Highlight Sensitivity", value: $settings.halationSensitivity)
                    Button("Reset Halation") { settings.halationAmount = 0.2; settings.halationSpread = 0.35; settings.halationSensitivity = 0.25 }
                }
            }
        } footer: { Text("Adds a warm halo around bright edges. Higher sensitivity includes more highlights.") }
    }
    private var bloomControls: some View {
        Section {
            Toggle("Bloom", isOn: $settings.bloomEnabled)
            if settings.bloomEnabled {
                amountSlider("Amount", value: $settings.bloomAmount)
                DisclosureGroup("Adjustments", isExpanded: $showBloomDetails) {
                    amountSlider("Spread", value: $settings.bloomSpread)
                    amountSlider("Highlight Sensitivity", value: $settings.bloomSensitivity)
                    Button("Reset Bloom") { settings.bloomAmount = 0.15; settings.bloomSpread = 0.35; settings.bloomSensitivity = 0.25 }
                }
            }
        } footer: { Text("Softens the glow around bright lights while keeping their color.") }
    }
    private func amountSlider(_ label: String, value: Binding<Double>, range: ClosedRange<Double> = 0...1, percent: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                Spacer()
                Text(percent ? "\(Int((value.wrappedValue * 100).rounded()))%" : String(format: "%.1f×", value.wrappedValue))
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: value, in: range).accessibilityLabel(label)
        }.padding(.vertical, 4)
    }
    private func saveAndClose() {
        guard !saving else { return }; saving = true; comparing = false; preview.player?.pause()
        Task {
            do {
                try await app.store.setFilmEffects(movieID: movie.id, settings: settings)
                await app.refresh(); dismiss()
            } catch { saveError = error.localizedDescription }
            saving = false
        }
    }
}

struct FilmEffectsCompareButton: View {
    @Binding var comparing: Bool
    var body: some View {
        Text(comparing ? "Without Effects" : "Hold to Compare")
            .font(.subheadline.weight(.medium)).frame(minWidth: 150, minHeight: 44)
            .homeGlass()
            .gesture(DragGesture(minimumDistance: 0).onChanged { _ in comparing = true }.onEnded { _ in comparing = false })
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Compare without Film Effects")
            .accessibilityValue(comparing ? "Without effects" : "With effects")
            .accessibilityAction { comparing.toggle() }
            .onDisappear { comparing = false }
    }
}

private struct FilmEffectsFullscreen: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var preview: FilmEffectsPreviewModel
    private var player: AVPlayer? { preview.player }
    let aspect: CGFloat
    @Binding var comparing: Bool
    let settings: FilmEffectsSettings
    @State private var detail = false
    @State private var offset = CGSize.zero
    @State private var dragStart = CGSize.zero
    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                GeometryReader { geometry in
                    let width = min(geometry.size.width, geometry.size.height * aspect)
                    ZStack {
                        Color.black
                        if let player {
                            if detail {
                                FilmEffectsDetailPlayer(player: player).frame(width: width, height: width / aspect)
                                    .scaleEffect(2).offset(offset).allowsHitTesting(false)
                            } else {
                                VideoPlayer(player: player).frame(width: width, height: width / aspect)
                            }
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                        .gesture(DragGesture().onChanged { value in
                            guard detail else { return }
                            offset = CGSize(width: min(width / 2, max(-width / 2, dragStart.width + value.translation.width)),
                                            height: min(width / aspect / 2, max(-width / aspect / 2, dragStart.height + value.translation.height)))
                        }.onEnded { _ in dragStart = offset })
                }
                HStack {
                    Button(detail ? "Fit" : "Detail 2×") { player?.pause(); detail.toggle(); offset = .zero; dragStart = .zero }
                        .frame(minWidth: 80, minHeight: 44)
                    FilmEffectsCompareButton(comparing: $comparing)
                }.padding(.bottom)
            }.background(.black)
                .navigationTitle("Export Preview").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { comparing = false; dismiss() } } }
        }.preferredColorScheme(.dark)
            .task(id: comparing) { await preview.update(settings: comparing ? .off : settings) }
    }
}

private struct FilmEffectsDetailPlayer: UIViewRepresentable {
    let player: AVPlayer
    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
    }
    func makeUIView(context: Context) -> PlayerView { PlayerView() }
    func updateUIView(_ view: PlayerView, context: Context) {
        guard let layer = view.layer as? AVPlayerLayer else { return }
        layer.player = player; layer.videoGravity = .resizeAspect
    }
}
