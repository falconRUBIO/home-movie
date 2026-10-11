import SwiftUI
import AVFoundation
import UIKit

enum CameraState: Equatable { case preparing, ready, starting, recording, finalizing, denied, interrupted, failed }

@MainActor final class CameraModel: ObservableObject {
    let service = CaptureService()
    @Published var state: CameraState = .preparing
    @Published var options: CameraOptions?
    @Published var elapsed = CMTime.zero
    @Published var message: String?
    @Published var savedScene = false
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
    func prepare() async {
        guard !busy else { return }
        let requestID = UUID(); preparationID = requestID
        active = true; state = .preparing; message = nil; interruption = nil
        let granted = await CaptureService.permissions()
        guard active, preparationID == requestID else { return }
        guard granted else { state = .denied; return }
        service.prepare(front: rememberedFront)
    }
    func record(movieID: UUID) {
        guard state == .ready, active, let app else { return }
        state = .starting; savedScene = false; message = nil; startCancelled = false
        operation = Task {
            var pendingTicket: CaptureTicket?
            defer { operation = nil }
            do {
                let ticket = try await app.store.begin(movieID: movieID)
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
                service.record(ticket: ticket, url: path)
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
    func focus(at point: CGPoint, locked: Bool = false) -> Bool {
        guard active, [.ready, .recording].contains(state), options?.canMeter == true else { return false }
        guard !locked || options?.canLock == true else { return false }
        service.focus(at: point, locked: locked)
        return true
    }
    func exposure(_ bias: Float) { if active, [.ready, .recording].contains(state) { service.exposure(bias) } }
    func toggleTorch() { if active, [.ready, .recording].contains(state) { service.toggleTorch() } }
    func flip() { guard active, state == .ready else { return }; state = .preparing; service.flip() }
    private func receive(_ event: CaptureEvent) async {
        switch event {
        case .ready(let options):
            self.options = options; rememberedFront = options.isFront
            if !busy && active && interruption == nil { state = .ready }
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
            } catch { state = .failed; message = "\(error.localizedDescription) Any recording file has been preserved for recovery." }
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
