import SwiftUI
import AVFoundation
import UIKit

enum CameraState: Equatable {
    case preparing, ready, starting, recording, finalizing, denied, interrupted, failed
    var canStopTake: Bool { self == .starting || self == .recording }
    var showsLiveLook: Bool { [.ready, .starting, .recording, .finalizing].contains(self) }
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
    let service = CaptureService()
    @Published var state: CameraState = .preparing
    @Published private(set) var switchingCamera = false
    @Published var options: CameraOptions?
    @Published var elapsed = CMTime.zero
    @Published var message: String?
    @Published var savedScene = false
    @Published private(set) var hasRecoverableTake = false
    @Published var takeFormat: MovieFormat?
    @Published private(set) var pipPresentation = PiPPresentation()
    @Published private(set) var pipLayout = PiPLayout()
    @Published private(set) var pipSetupFailed = false
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
    @AppStorage("frontCamera") var rememberedFront = false
    var busy: Bool { switchingCamera || recordingFlip != nil || [.starting, .recording, .finalizing].contains(state) }
    var recordingSessionActive: Bool { state.canStopTake || recordingFlip != nil }

    init(app: AppModel) {
        self.app = app
        service.onEvent = { [weak self] event in Task { @MainActor in await self?.receive(event) } }
    }
    func prepare(profile: CaptureProfile = .standard, movieID: UUID? = nil, dualCamera: Bool = false,
                 layout: PiPLayout = PiPLayout(), canvasFormat: MovieFormat? = nil, enablePiP: Bool = false) async {
        guard !busy else { return }
        let requestID = UUID(); preparationID = requestID
        if preferencesMovieID != movieID { pipPresentation = PiPPresentation() }
        preferencesMovieID = movieID; pipLayout = layout; pipSetupFailed = false; enablePiPWhenReady = enablePiP
        active = true; state = .preparing; message = nil; interruption = nil; hasRecoverableTake = false
        let granted = await CaptureService.permissions()
        guard active, preparationID == requestID else { return }
        guard granted else { state = .denied; return }
        service.prepare(front: rememberedFront, profile: profile, dualCamera: dualCamera, pipLayout: layout, canvasFormat: canvasFormat)
    }
    func record(movieID: UUID, continuingAt elapsed: CMTime? = nil) {
        guard state == .ready, !switchingCamera, active, let app else { return }
        guard let observed = options?.angle, let automatic = MovieFormat.captureFormat(angle: observed),
              let movie = app.movie(movieID), options?.profile == movie.captureProfile else { return }
        let format = movie.recordingFormat ?? automatic
        let recordingFormat = options?.dualCameraPrepared == true ? format : automatic
        let angle = recordingFormat.recordingAngle(observed: observed)
        // Keep the camera controls oriented to the phone; PiP's movie canvas is independent.
        takeFormat = automatic
        activeMovieID = movieID; elapsedBeforeSegment = elapsed ?? .zero
        self.elapsed = elapsedBeforeSegment; beganAt = nil
        continuingRecording = elapsed != nil
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
        switchingCamera = false
        recordingFlip = nil
        active = false; startCancelled = true; preparationID = UUID()
        if busy { beginBackgroundTime(); state = .finalizing; timer?.invalidate() }
        service.suspend()
    }
    func pauseForPlayback() async {
        active = false; startCancelled = true; preparationID = UUID()
        await withCheckedContinuation { continuation in
            service.suspend { continuation.resume() }
        }
    }
    func zoom(_ factor: CGFloat) { if active, !switchingCamera, [.ready, .recording].contains(state) { service.zoom(factor) } }
    func configureSmoothZoom(speed: SmoothZoomSpeed, stayOnLens: Bool) { service.configureSmoothZoom(speed: speed, stayOnLens: stayOnLens) }
    func beginSmoothZoom() { if active, !switchingCamera, [.ready, .recording].contains(state) { service.beginSmoothZoom() } }
    func smoothZoom(to factor: CGFloat, inputTime: Double? = nil, inputEnded: Bool = false) {
        if active, !switchingCamera, [.ready, .recording].contains(state) { service.smoothZoom(to: factor, inputTime: inputTime, inputEnded: inputEnded) }
    }
    func endSmoothInput() { service.endSmoothInput() }
    func adjustDollyDestination(to factor: CGFloat) {
        if active, !switchingCamera, [.ready, .recording].contains(state) { service.adjustDollyDestination(to: factor) }
    }
    func dollyZoom(to factor: CGFloat, seconds: Int) { if active, !switchingCamera, [.ready, .recording].contains(state) { service.dollyZoom(to: factor, seconds: seconds) } }
    func endSmoothZoom() { service.endSmoothZoom() }
    func focus(at point: CGPoint, locked: Bool = false) -> Bool {
        guard active, !switchingCamera, [.ready, .recording].contains(state), options?.canMeter == true else { return false }
        guard !locked || options?.canLock == true else { return false }
        service.focus(at: point, locked: locked)
        return true
    }
    func exposure(_ bias: Float) { if active, !switchingCamera, [.ready, .recording].contains(state) { service.exposure(bias) } }
    func toggleTorch() { if active, !switchingCamera, [.ready, .recording].contains(state) { service.toggleTorch() } }
    func flip() {
        guard active, !switchingCamera, recordingFlip == nil, let options, options.isPiPEnabled != true, pipPresentation.opacity == 0 else { return }
        guard CameraCompatibility.allowsFlip(profile: options.profile, recording: state == .recording,
            otherCameraSupported: options.canFlip, continuousFlipSupported: options.canFlipWhileRecording) else {
            if options.profile == .appleLog {
                message = state == .recording ? CameraCompatibility.logRecordingFlipExplanation : CameraCompatibility.logCameraExplanation
            }
            return
        }
        if state == .recording, options.canFlipWhileRecording == true { service.flip(); return }
        if state == .recording, let movieID = activeMovieID {
            let current = beganAt.map { CMTimeAdd(elapsedBeforeSegment, CMTime(seconds: max(0, ProcessInfo.processInfo.systemUptime - $0), preferredTimescale: 600)) } ?? elapsed
            elapsed = current
            recordingFlip = RecordingFlipHandoff(movieID: movieID, elapsed: current)
            state = .finalizing; timer?.invalidate(); beginBackgroundTime(); service.stop()
        } else if state == .ready { switchingCamera = true; service.flip() }
    }
    func togglePiP() {
        guard active, !switchingCamera, state == .ready || state == .recording, options?.piPAvailable == true else { return }
        service.setPiPEnabled(options?.isPiPEnabled != true)
    }
    func updatePiPLayout(_ layout: PiPLayout, movieID: UUID) {
        guard !busy, let app else { return }
        pipLayout = layout; service.setPiPLayout(layout, canvasFormat: app.movie(movieID)?.recordingFormat)
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
            self.options = options; rememberedFront = options.isFront
            if (state == .preparing || state == .ready), recordingFlip == nil, active, interruption == nil { state = .ready }
            if enablePiPWhenReady, options.piPAvailable, active, state == .ready {
                enablePiPWhenReady = false; service.setPiPEnabled(true)
            }
        case .cameraChanged(let options):
            let wasSwitching = switchingCamera; switchingCamera = false
            self.options = options; rememberedFront = options.isFront
            guard active, interruption == nil else { recordingFlip = nil; state = .interrupted; return }
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
                hasRecoverableTake = hasFile
                if !hasFile { try? await app?.store.abandonUnstarted(ticket) }
                message = error.localizedDescription
            }
        case .interrupted(let text):
            switchingCamera = false
            recordingFlip = nil
            interruption = text; message = text; startCancelled = true
            if busy { state = .finalizing; beginBackgroundTime() } else { state = .interrupted }
        case .failed(let text):
            switchingCamera = false
            recordingFlip = nil
            message = text
            if busy { interruption = text; stop() } else { state = .failed }
        case .notice(let text):
            message = text
        case .pipPresentation(let presentation):
            pipPresentation = presentation
        case .pipLayout(let layout):
            pipLayout = layout
            if let app, let movieID = preferencesMovieID {
                do { try await app.store.setPiPLayout(movieID: movieID, layout: layout); await app.refresh() }
                catch { message = "The inset moved for this take, but its default position could not be saved." }
            }
        case .pipSetupFailed(let text):
            pipSetupFailed = true; enablePiPWhenReady = false; message = text
            if let app, let movieID = preferencesMovieID {
                try? await app.store.setDualCameraCapture(movieID: movieID, enabled: false); await app.refresh()
            }
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

