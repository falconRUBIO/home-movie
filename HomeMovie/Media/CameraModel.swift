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
    @AppStorage("frontCamera") var rememberedFront = false
    var busy: Bool { [.starting, .recording, .finalizing].contains(state) }

    init(app: AppModel) {
        self.app = app
        service.onEvent = { [weak self] event in Task { @MainActor in await self?.receive(event) } }
    }
    func prepare() async {
        guard !busy else { return }
        active = true; state = .preparing; message = nil; interruption = nil
        guard await CaptureService.permissions() else { state = .denied; return }
        guard active else { return }
        service.prepare(front: rememberedFront)
    }
    func record(movieID: UUID) {
        guard state == .ready, active, let app else { return }
        state = .starting; savedScene = false; message = nil
        operation = Task {
            do {
                let ticket = try await app.store.begin(movieID: movieID)
                guard active else { state = .interrupted; endBackgroundTime(); return }
                let path = try await app.store.url(ticket.staging)
                service.record(ticket: ticket, url: path)
            } catch { state = .failed; message = error.localizedDescription }
        }
    }
    func stop() {
        guard state == .recording || state == .starting else { return }
        state = .finalizing; timer?.invalidate(); beginBackgroundTime(); service.stop()
    }
    func suspend() {
        active = false
        if busy { beginBackgroundTime(); state = .finalizing; timer?.invalidate() }
        service.suspend()
    }
    func pauseForPlayback() async {
        active = false
        await withCheckedContinuation { continuation in
            service.suspend { continuation.resume() }
        }
    }
    func zoom(_ factor: CGFloat) { if [.ready, .recording].contains(state) { service.zoom(factor) } }
    func focus(at point: CGPoint, locked: Bool = false) -> Bool {
        guard [.ready, .recording].contains(state), options?.canMeter == true else { return false }
        guard !locked || options?.canLock == true else { return false }
        service.focus(at: point, locked: locked)
        return true
    }
    func exposure(_ bias: Float) { if [.ready, .recording].contains(state) { service.exposure(bias) } }
    func toggleTorch() { if [.ready, .recording].contains(state) { service.toggleTorch() } }
    func flip() { guard state == .ready else { return }; state = .preparing; service.flip() }
    private func receive(_ event: CaptureEvent) async {
        switch event {
        case .ready(let options):
            self.options = options; rememberedFront = options.isFront
            if !busy && active && interruption == nil { state = .ready }
        case .started:
            guard active, state != .finalizing else { service.stop(); return }
            state = .recording; beganAt = ProcessInfo.processInfo.systemUptime; elapsed = .zero
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let date = self.beganAt else { return }
                    self.elapsed = CMTime(seconds: max(0, ProcessInfo.processInfo.systemUptime - date), preferredTimescale: 600)
                }
            }
        case .finished(let ticket, let error):
            guard !finishing else { return }; finishing = true
            timer?.invalidate(); state = .finalizing; beginBackgroundTime()
            defer { finishing = false; endBackgroundTime() }
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
            interruption = text; message = text
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
