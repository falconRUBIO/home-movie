import SwiftUI
import AVFoundation
import UIKit

enum CameraState: Equatable {
    case preparing, ready, starting, recording, finalizing, denied, interrupted, failed
    var canStopTake: Bool { self == .starting || self == .recording }
    var ownsTakeOrientation: Bool { [.starting, .recording, .finalizing].contains(self) }
    var showsLiveLook: Bool { [.ready, .starting, .recording, .finalizing].contains(self) }
}

// One foreground request can wait for a saving clip. A later departure or a
// real failure cancels it; state updates alone never create a resume request.
struct CameraForegroundResume {
    private(set) var pending = false
    mutating func request() { pending = true }
    mutating func cancel() { pending = false }
    mutating func consumeIfReady(state: CameraState, busy: Bool, foreground: Bool,
                                cameraVisible: Bool, recoverableTake: Bool) -> Bool {
        guard pending else { return false }
        guard foreground, cameraVisible, state != .failed, !recoverableTake else {
            pending = false
            return false
        }
        guard !busy else { return false }
        pending = false
        return true
    }
}

enum DollyStartDelay {
    static let choices = [0, 3, 5, 7]
    static func validated(_ seconds: Int) -> Int { choices.contains(seconds) ? seconds : 3 }
    static func effective(_ seconds: Int, dollyOpen: Bool) -> Int { dollyOpen ? validated(seconds) : 0 }
}

struct RecordingFlipHandoff {
    enum Phase: Equatable { case saving, switching }
    let movieID: UUID
    let elapsed: CMTime
    private(set) var phase = Phase.saving
    mutating func footageSaved() { phase = .switching }
    func mayResume(active: Bool, interrupted: Bool) -> Bool { phase == .switching && active && !interrupted }
}

@MainActor final class RecordingCountdown: ObservableObject {
    @Published private(set) var remaining: Int?
    private var task: Task<Void, Never>?
    private var requestID = UUID()
    private let tick: Duration
    init(tick: Duration = .seconds(1)) { self.tick = tick }

    func start(seconds: Int = 3, canStart: @escaping @MainActor () -> Bool, onStart: @escaping @MainActor () -> Void) {
        guard remaining == nil, canStart() else { return }
        let duration = DollyStartDelay.validated(seconds)
        if duration == 0 { onStart(); return }
        let request = UUID(); requestID = request; remaining = duration
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.requestID == request { self.remaining = nil; self.task = nil }
            }
            for number in stride(from: duration, through: 1, by: -1) {
                guard !Task.isCancelled, self.requestID == request, canStart() else { return }
                self.remaining = number
                do { try await Task.sleep(for: self.tick) } catch { return }
            }
            guard !Task.isCancelled, self.requestID == request, canStart() else { return }
            self.remaining = nil; self.task = nil
            onStart()
        }
    }
    func cancel() {
        requestID = UUID(); task?.cancel(); task = nil; remaining = nil
    }
}

@MainActor final class CameraModel: ObservableObject {
    let service: CaptureService
    private let applyPiPEnabled: (Bool) -> Void
    @Published var state: CameraState = .preparing
    @Published private(set) var switchingCamera = false
    @Published private(set) var switchingFormat: MovieFormat?
    @Published var options: CameraOptions?
    @Published var elapsed = CMTime.zero
    @Published var message: String?
    @Published var savedScene = false
    @Published private(set) var hasRecoverableTake = false
    @Published var takeFormat: MovieFormat?
    @Published private(set) var pipPresentation = PiPPresentation()
    @Published private(set) var pipLayout = PiPLayout()
    @Published private(set) var pipSetupFailed = false
    @Published private(set) var pendingPiPEnabled: Bool?
    private var preferencesMovieID: UUID?
    private var enablePiPWhenReady = false
    @Published private(set) var recordingFlip: RecordingFlipHandoff?
    private var timer: Timer?
    private var beganAt: TimeInterval?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private weak var app: AppModel?
    private var active = true
    private var finishing = false
    private var interruption: String?
    private var operation: Task<Void, Never>?
    private var startCancelled = false
    private var activeSceneID: UUID?
    private var activeMovieID: UUID?
    private var elapsedBeforeSegment = CMTime.zero
    private var continuingRecording = false
    private var preparationID = UUID()
    // Async preference writes must not revive a camera page that has since closed.
    var lifecycleID: UUID { preparationID }
    @AppStorage("frontCamera") var rememberedFront = false
    var busy: Bool { switchingCamera || recordingFlip != nil || [.starting, .recording, .finalizing].contains(state) }
    var recordingSessionActive: Bool { state.canStopTake || recordingFlip != nil }
    var activeTakeOrientation: MovieFormat? {
        state.ownsTakeOrientation || recordingFlip != nil ? takeFormat : nil
    }
    var canFlipCamera: Bool {
        guard active, !switchingCamera, pendingPiPEnabled == nil, recordingFlip == nil, state == .ready || state == .recording,
              let options, !options.isPiPEnabled,
              !options.dualCameraPrepared || pipPresentation.opacity <= 0.01,
              state != .recording || options.canFlipWhileRecording else { return false }
        return CameraCompatibility.allowsFlip(profile: options.profile, recording: state == .recording,
            otherCameraSupported: options.canFlip, continuousFlipSupported: options.canFlipWhileRecording)
    }

    private let requestPermissions: () async -> Bool
    init(app: AppModel, service: CaptureService = CaptureService(), applyPiPEnabled: ((Bool) -> Void)? = nil,
         requestPermissions: @escaping () async -> Bool = { await CaptureService.permissions() }) {
        self.service = service
        self.applyPiPEnabled = applyPiPEnabled ?? service.setPiPEnabled
        self.app = app
        self.requestPermissions = requestPermissions
        service.onEvent = { [weak self] event in Task { @MainActor in await self?.receive(event) } }
    }
    private struct PreparationConfiguration: Equatable {
        let profile: CaptureProfile
        let movieID: UUID?
        let dualCamera: Bool
        let layout: PiPLayout
        let canvasFormat: MovieFormat?
        let enablePiP: Bool
    }
    private var preparationConfiguration: PreparationConfiguration?
    func prepare(profile: CaptureProfile = .standard, movieID: UUID? = nil, dualCamera: Bool = false,
                 layout: PiPLayout = PiPLayout(), canvasFormat: MovieFormat? = nil, enablePiP: Bool = false) async {
        guard !busy else { return }
        let configuration = PreparationConfiguration(profile: profile, movieID: movieID, dualCamera: dualCamera,
            layout: layout, canvasFormat: canvasFormat, enablePiP: enablePiP)
        // View presentation and foreground callbacks may request the same camera.
        // Keep an in-flight or ready session instead of showing Preparing again.
        if active, preparationConfiguration == configuration, state == .preparing { return }
        if active, state == .ready, options?.dualCameraPrepared == dualCamera, options?.profile == profile,
           preferencesMovieID == movieID {
            preparationConfiguration = configuration
            pipLayout = layout
            service.setPiPLayout(layout, canvasFormat: canvasFormat)
            // The stored configuration is only a request. Reconcile against the
            // observed switch, including when On -> Off -> On repeats that request.
            if dualCamera { setPiPEnabled(enablePiP) }
            return
        }
        ReliabilityDiagnostics.shared.record(.cameraRequested)
        preparationConfiguration = configuration
        let requestID = UUID(); preparationID = requestID
        if preferencesMovieID != movieID || !dualCamera { pipPresentation = PiPPresentation() }
        preferencesMovieID = movieID; pipLayout = layout; pipSetupFailed = false; enablePiPWhenReady = enablePiP
        active = true; state = .preparing; message = nil; interruption = nil; hasRecoverableTake = false
        let granted = await requestPermissions()
        guard active, preparationID == requestID else { return }
        guard granted else { state = .denied; cancelPiPChange(); return }
        if profile == .appleLog {
            do { try await LogPiPValidation.shared.check() }
            catch {
                guard active, preparationID == requestID else { return }
                ReliabilityDiagnostics.shared.record(.cameraFailed, error: error)
                state = .failed; cancelPiPChange(); message = error.localizedDescription; pipSetupFailed = dualCamera
                return
            }
            guard active, preparationID == requestID, !Task.isCancelled else { return }
        }
        service.prepare(front: rememberedFront, profile: profile, dualCamera: dualCamera, pipLayout: layout, canvasFormat: canvasFormat)
    }
    func record(movieID: UUID, continuingAt elapsed: CMTime? = nil) {
        guard state == .ready, !switchingCamera, pendingPiPEnabled == nil, active, let app else { return }
        guard let observed = options?.angle, MovieFormat.captureFormat(angle: observed) != nil,
              let movie = app.movie(movieID), options?.profile == movie.captureProfile else { return }
        let interfaceFormat = OrientationPolicy.shared.currentInterfaceFormat(observed: observed)
        let format = movie.recordingFormat ?? interfaceFormat
        let recordingFormat = options?.dualCameraPrepared == true ? format : interfaceFormat
        let angle = recordingFormat.recordingAngle(observed: observed, profile: movie.captureProfile,
            composited: options?.compositedCapture == true || options?.dualCameraPrepared == true)
        // Keep the camera controls oriented to the phone; PiP's movie canvas is independent.
        takeFormat = OrientationPolicy.shared.currentInterfaceFormat(observed: observed)
        activeMovieID = movieID; elapsedBeforeSegment = elapsed ?? .zero
        self.elapsed = elapsedBeforeSegment; beganAt = nil
        continuingRecording = elapsed != nil
        ReliabilityDiagnostics.shared.record(.recordingRequested, capture: .init(
            camera: options?.isFront == true ? .front : .rear, interface: interfaceFormat,
            canvas: recordingFormat, sensorAngle: Double(observed)))
        state = .starting; savedScene = false; hasRecoverableTake = false; message = nil; startCancelled = false
        operation = Task {
            var pendingTicket: CaptureTicket?
            defer { operation = nil }
            do {
                let ticket = try await app.store.begin(movieID: movieID, format: format, profile: movie.captureProfile)
                pendingTicket = ticket
                let path = try await app.store.url(ticket.staging)
                guard active, !startCancelled, state == .starting, interruption == nil else {
                    try await app.store.abandonUnstarted(ticket)
                    state = active && interruption == nil ? .ready : .interrupted
                    endBackgroundTime()
                    return
                }
                // No await between the final cancellation check and handing off ownership.
                activeSceneID = ticket.sceneID
                service.record(ticket: ticket, url: path, angle: angle)
                pendingTicket = nil
            } catch {
                ReliabilityDiagnostics.shared.record(.recordingFailed, error: error)
                if let pendingTicket { try? await app.store.abandonUnstarted(pendingTicket) }
                state = .failed; message = error.localizedDescription; endBackgroundTime()
            }
        }
    }
    func stop() {
        if recordingFlip != nil {
            recordingFlip = nil; startCancelled = true; timer?.invalidate()
            service.stop(); return
        }
        guard state == .recording || state == .starting else { return }
        startCancelled = true
        state = .finalizing; timer?.invalidate(); beginBackgroundTime(); service.stop()
    }
    func suspend() {
        switchingCamera = false; switchingFormat = nil
        recordingFlip = nil; cancelPiPChange()
        active = false; startCancelled = true; preparationID = UUID()
        if busy { beginBackgroundTime(); state = .finalizing; timer?.invalidate() }
        service.suspend()
    }
    func pauseForPlayback() async {
        cancelPiPChange()
        active = false; startCancelled = true; preparationID = UUID()
        await withCheckedContinuation { continuation in
            service.suspend { continuation.resume() }
        }
    }
    func zoom(_ factor: CGFloat) { if active, !switchingCamera, [.ready, .recording].contains(state) { service.zoom(factor) } }
    func configureSmoothZoom(speed: SmoothZoomSpeed, stayOnLens: Bool) { service.configureSmoothZoom(speed: speed, stayOnLens: stayOnLens) }
    func beginManualZoom(id: UUID) {
        if active, !switchingCamera, [.ready, .recording].contains(state) { service.beginManualZoom(id: id) }
    }
    func manualZoom(to factor: CGFloat, inputTime: Double, id: UUID) {
        if active, !switchingCamera, [.ready, .recording].contains(state) { service.manualZoom(to: factor, inputTime: inputTime, id: id) }
    }
    func endManualZoom(id: UUID) { service.endManualZoom(id: id) }
    func beginSmoothZoom() { if active, !switchingCamera, [.ready, .recording].contains(state) { service.beginSmoothZoom() } }
    func smoothZoom(to factor: CGFloat, inputTime: Double? = nil, inputEnded: Bool = false) {
        if active, !switchingCamera, [.ready, .recording].contains(state) { service.smoothZoom(to: factor, inputTime: inputTime, inputEnded: inputEnded) }
    }
    func endSmoothInput() { service.endSmoothInput() }
    func pauseSmoothZoom(completion: @escaping @MainActor @Sendable (CGFloat?) -> Void) {
        guard active, !switchingCamera, [.ready, .recording].contains(state) else { completion(nil); return }
        service.pauseSmoothZoom { factor in Task { @MainActor in completion(factor) } }
    }
    func adjustDollyDestination(to factor: CGFloat) {
        if active, !switchingCamera, [.ready, .recording].contains(state) { service.adjustDollyDestination(to: factor) }
    }
    func dollyZoom(to factor: CGFloat, seconds: Int) { if active, !switchingCamera, [.ready, .recording].contains(state) { service.dollyZoom(to: factor, seconds: seconds) } }
    func endSmoothZoom() { service.endSmoothZoom() }
    func focus(at point: CGPoint, locked: Bool = false, front: Bool? = nil) -> Bool {
        guard active, !switchingCamera, [.ready, .recording].contains(state) else { return false }
        let metering = front == true ? options?.frontMetering : options?.rearMetering
        guard (front == nil ? options?.canMeter : metering?.canMeter) == true,
              !locked || (front == nil ? options?.canLock : metering?.canLock) == true else { return false }
        service.focus(at: point, locked: locked, front: front)
        return true
    }
    func exposure(_ bias: Float, front: Bool? = nil) {
        if active, !switchingCamera, [.ready, .recording].contains(state) { service.exposure(bias, front: front) }
    }
    func toggleTorch() { if active, !switchingCamera, [.ready, .recording].contains(state) { service.toggleTorch() } }
    func flip() {
        guard canFlipCamera, let options else { return }
        // A switch is busy, but it is not a take. Preserve the current interface,
        // never the previous recording's stale portrait/landscape lock.
        let format = OrientationPolicy.shared.currentInterfaceFormat(observed: options.angle)
        switchingFormat = format; switchingCamera = true
        service.flip(previewFormat: format)
    }
    func beginPiPChange(to enabled: Bool) { pendingPiPEnabled = enabled }
    func cancelPiPChange() { pendingPiPEnabled = nil; enablePiPWhenReady = false }
    func setPiPEnabled(_ enabled: Bool) {
        guard active, !switchingCamera, state == .ready || state == .recording,
              options?.piPAvailable == true else { cancelPiPChange(); return }
        pendingPiPEnabled = enabled
        // An explicit Off must also cancel an earlier deferred On.
        enablePiPWhenReady = false
        applyPiPEnabled(enabled)
    }
    func togglePiP() {
        guard pendingPiPEnabled == nil else { return }
        setPiPEnabled(options?.isPiPEnabled != true)
    }
    func updatePiPLayout(_ layout: PiPLayout, movieID: UUID, canvasFormat: MovieFormat? = nil) {
        guard active, !switchingCamera, pendingPiPEnabled == nil,
              state == .ready || state == .recording, let app else { return }
        let canvas = app.movie(movieID)?.recordingFormat ?? canvasFormat
            ?? OrientationPolicy.shared.currentInterfaceFormat(observed: options?.angle ?? 90)
        pipLayout = layout; service.setPiPLayout(layout, canvasFormat: canvas)
        Task {
            do { try await app.store.setPiPLayout(movieID: movieID, layout: layout); await app.refresh() }
            catch { message = error.localizedDescription }
        }
    }
    func dragPiP(to center: CGPoint, finished: Bool) {
        guard active, !switchingCamera, state == .ready || state == .recording, options?.isPiPEnabled == true else { return }
        service.dragPiP(to: center, finished: finished)
    }
    func receive(_ event: CaptureEvent) async {
        switch event {
        case .ready(let options):
            if state == .preparing { ReliabilityDiagnostics.shared.record(.cameraReady) }
            self.options = options; rememberedFront = options.isFront
            if pendingPiPEnabled == options.isPiPEnabled { pendingPiPEnabled = nil }
            if !options.dualCameraPrepared { pipPresentation = PiPPresentation() }
            if (state == .preparing || state == .ready), recordingFlip == nil, active, interruption == nil { state = .ready }
            if enablePiPWhenReady, options.piPAvailable, active, state == .ready {
                setPiPEnabled(true)
            }
        case .cameraChanged(let options):
            let wasSwitching = switchingCamera; switchingCamera = false; switchingFormat = nil
            self.options = options; rememberedFront = options.isFront
            guard active, interruption == nil else { recordingFlip = nil; state = .interrupted; return }
            // A live input change must not reset the writer, timer or Record state.
            guard state != .recording && state != .finalizing && state != .starting else { return }
            guard state == .preparing || wasSwitching else { return }
            state = .ready
            if let handoff = recordingFlip, handoff.mayResume(active: active, interrupted: interruption != nil) {
                recordingFlip = nil
                record(movieID: handoff.movieID, continuingAt: handoff.elapsed)
            }
        case .started(let sceneID):
            guard activeSceneID == sceneID else { return }
            if state == .recording { return }
            guard active, !startCancelled, state == .starting, interruption == nil else { service.stop(); return }
            ReliabilityDiagnostics.shared.record(.recordingStarted)
            state = .recording; beganAt = ProcessInfo.processInfo.systemUptime; elapsed = elapsedBeforeSegment
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.state == .recording, let date = self.beganAt else { return }
                    self.elapsed = CMTimeAdd(self.elapsedBeforeSegment, CMTime(seconds: max(0, ProcessInfo.processInfo.systemUptime - date), preferredTimescale: 600))
                }
            }
        case .finished(let ticket, let error):
            guard activeSceneID == ticket.sceneID, !finishing else { return }; finishing = true
            timer?.invalidate(); state = .finalizing; beginBackgroundTime()
            defer { finishing = false; activeSceneID = nil; endBackgroundTime() }
            do {
                if let error { throw error }
                guard let app else { throw HomeMovieError.message("The project is unavailable.") }
                try await app.store.commit(ticket); await app.refresh()
                app.copySceneToPhotos(ticket.sceneID)
                if recordingFlip != nil, active, interruption == nil {
                    recordingFlip?.footageSaved()
                    state = .preparing; service.flip()
                    return
                }
                recordingFlip = nil
                ReliabilityDiagnostics.shared.record(.recordingFinished)
                savedScene = true
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                state = active && interruption == nil ? .ready : .interrupted
                message = interruption ?? message
            } catch {
                recordingFlip = nil
                state = .failed
                let hasFile = app.map {
                    FileManager.default.fileExists(atPath: $0.store.root.appendingPathComponent(ticket.staging).path) ||
                    FileManager.default.fileExists(atPath: $0.store.root.appendingPathComponent(ticket.source).path)
                } ?? false
                ReliabilityDiagnostics.shared.record(.recordingFailed, error: error)
                hasRecoverableTake = hasFile
                if !hasFile { try? await app?.store.abandonUnstarted(ticket) }
                message = error.localizedDescription
            }
        case .interrupted(let text):
            guard active else { return }
            cancelPiPChange()
            ReliabilityDiagnostics.shared.record(.cameraInterrupted)
            switchingCamera = false; switchingFormat = nil
            recordingFlip = nil
            interruption = text; message = text; startCancelled = true
            if busy { state = .finalizing; beginBackgroundTime() } else { state = .interrupted }
        case .interruptionEnded(let options):
            // A generic .ready can be a delayed metering/zoom callback. Only a
            // verified session recovery may dismiss an interruption notice.
            guard active, interruption != nil, state == .interrupted || state == .finalizing else { return }
            self.options = options; rememberedFront = options.isFront
            interruption = nil; message = nil
            if state == .interrupted { state = .ready }
        case .failed(let text):
            cancelPiPChange()
            ReliabilityDiagnostics.shared.record(.cameraFailed)
            switchingCamera = false; switchingFormat = nil
            recordingFlip = nil
            message = text
            if busy { interruption = text; stop() } else { state = .failed }
        case .notice(let text):
            cancelPiPChange()
            message = text
        case .pipPresentation(let presentation):
            pipPresentation = presentation
        case .pipLayout(let layout):
            pipLayout = layout
            if let app, let movieID = preferencesMovieID {
                do { try await app.store.setPiPLayout(movieID: movieID, layout: layout); await app.refresh() }
                catch { message = "The inset moved for this clip, but its default position could not be saved." }
            }
        case .pipSetupFailed(let text):
            guard active else { return }
            pipSetupFailed = true; cancelPiPChange(); message = text
            // A temporary hardware failure must not change the saved movie choice.
        }
    }
    private func beginBackgroundTime() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Save Scene") { [weak self] in
            Task { @MainActor in self?.endBackgroundTime() }
        }
    }
    private func endBackgroundTime() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask); backgroundTask = .invalid
    }
}

