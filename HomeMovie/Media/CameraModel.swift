import SwiftUI
import AVFoundation
import UIKit

enum CameraState: Equatable {
    case preparing, ready, starting, recording, finalizing, denied, interrupted, failed
    var showsLiveLook: Bool { [.ready, .starting, .recording, .finalizing].contains(self) }
}

@MainActor final class RecordingCountdown: ObservableObject {
    @Published private(set) var remaining: Int?
    private var task: Task<Void, Never>?
    private var requestID = UUID()
    private let tick: Duration
    init(tick: Duration = .seconds(1)) { self.tick = tick }

    func start(canStart: @escaping @MainActor () -> Bool, onStart: @escaping @MainActor () -> Void) {
        guard remaining == nil, canStart() else { return }
        let request = UUID(); requestID = request; remaining = 3
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.requestID == request { self.remaining = nil; self.task = nil }
            }
            for number in stride(from: 3, through: 1, by: -1) {
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
    @Published var options: CameraOptions?
    @Published var elapsed = CMTime.zero
    @Published var message: String?
    @Published var savedScene = false
    @Published private(set) var hasRecoverableTake = false
    @Published var takeFormat: MovieFormat?
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
    private var preparationID = UUID()
    @AppStorage("frontCamera") var rememberedFront = false
    var busy: Bool { [.starting, .recording, .finalizing].contains(state) }

    init(app: AppModel) {
        self.app = app
        service.onEvent = { [weak self] event in Task { @MainActor in await self?.receive(event) } }
    }
    func prepare(profile: CaptureProfile = .standard) async {
        guard !busy else { return }
        let requestID = UUID(); preparationID = requestID
        active = true; state = .preparing; message = nil; interruption = nil; hasRecoverableTake = false
        let granted = await CaptureService.permissions()
        guard active, preparationID == requestID else { return }
        guard granted else { state = .denied; return }
        service.prepare(front: rememberedFront, profile: profile)
    }
    func record(movieID: UUID) {
        guard state == .ready, active, let app else { return }
        guard let observed = options?.angle, let automatic = MovieFormat.captureFormat(angle: observed),
              let movie = app.movie(movieID), options?.profile == movie.captureProfile else { return }
        let format = movie.recordingFormat ?? automatic
        let angle = movie.recordingFormat == nil ? format.recordingAngle(observed: observed) : OrientationPolicy.shared.captureAngle(format: format, observed: observed)
        takeFormat = format
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
        guard state == .recording || state == .starting else { return }
        startCancelled = true
        state = .finalizing; timer?.invalidate(); beginBackgroundTime(); service.stop()
    }
    func suspend() {
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
    func zoom(_ factor: CGFloat) { if active, [.ready, .recording].contains(state) { service.zoom(factor) } }
    func configureSmoothZoom(speed: SmoothZoomSpeed, stayOnLens: Bool) { service.configureSmoothZoom(speed: speed, stayOnLens: stayOnLens) }
    func beginSmoothZoom() { if active, [.ready, .recording].contains(state) { service.beginSmoothZoom() } }
    func smoothZoom(to factor: CGFloat) { if active, [.ready, .recording].contains(state) { service.smoothZoom(to: factor) } }
    func dollyZoom(to factor: CGFloat, seconds: Int) { if active, [.ready, .recording].contains(state) { service.dollyZoom(to: factor, seconds: seconds) } }
    func endSmoothZoom() { service.endSmoothZoom() }
    func focus(at point: CGPoint, locked: Bool = false) -> Bool {
        guard active, [.ready, .recording].contains(state), options?.canMeter == true else { return false }
        guard !locked || options?.canLock == true else { return false }
        service.focus(at: point, locked: locked)
        return true
    }
    func exposure(_ bias: Float) { if active, [.ready, .recording].contains(state) { service.exposure(bias) } }
    func toggleTorch() { if active, [.ready, .recording].contains(state) { service.toggleTorch() } }
    func flip() { guard active, state == .ready else { return }; state = .preparing; service.flip() }
    func receive(_ event: CaptureEvent) async {
        switch event {
        case .ready(let options):
            self.options = options; rememberedFront = options.isFront
            if (state == .preparing || state == .ready), active, interruption == nil { state = .ready }
        case .started(let sceneID):
            guard activeSceneID == sceneID else { return }
            if state == .recording { return }
            guard active, !startCancelled, state == .starting, interruption == nil else { service.stop(); return }
            state = .recording; beganAt = ProcessInfo.processInfo.systemUptime; elapsed = .zero
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let date = self.beganAt else { return }
                    self.elapsed = CMTime(seconds: max(0, ProcessInfo.processInfo.systemUptime - date), preferredTimescale: 600)
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
                savedScene = true
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                state = active && interruption == nil ? .ready : .interrupted
                message = interruption
            } catch {
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
            interruption = text; message = text; startCancelled = true
            if busy { state = .finalizing; beginBackgroundTime() } else { state = .interrupted }
        case .failed(let text):
            message = text
            if busy { interruption = text; stop() } else { state = .failed }
        case .notice(let text):
            message = text
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
