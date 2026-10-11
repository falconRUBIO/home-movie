import AVFoundation
import Foundation

struct LensChoice: Identifiable, Equatable, Sendable {
    var id: CGFloat { factor }
    let factor: CGFloat
    let displayed: CGFloat
    var label: String { String(format: "%g×", Double(displayed)) }
    static func available(minimum: CGFloat, maximum: CGFloat, multiplier: CGFloat,
                          switchFactors: [CGFloat], secondaryFactors: [CGFloat]) -> [LensChoice] {
        guard multiplier.isFinite, multiplier > 0 else { return [] }
        let candidates = ([minimum, 1 / multiplier] + switchFactors + secondaryFactors)
            .filter { $0.isFinite && $0 >= minimum && $0 <= maximum }.sorted()
        var choices: [LensChoice] = []
        for factor in candidates {
            guard !choices.contains(where: { abs($0.factor - factor) < 0.001 }) else { continue }
            choices.append(LensChoice(factor: factor, displayed: (factor * multiplier * 10).rounded() / 10))
        }
        return choices
    }
}
struct CameraOptions: Sendable {
    var lenses: [LensChoice]
    var zoom: CGFloat
    var minimum: CGFloat
    var maximum: CGFloat
    var multiplier: CGFloat
    var isFront: Bool
    var angle: CGFloat
    var canMeter: Bool
}
enum CaptureEvent {
    case ready(CameraOptions)
    case started
    case finished(CaptureTicket, Error?)
    case interrupted(String)
    case failed(String)
    case notice(String)
}

// All capture mutation is confined to one serial queue. The preview observes the session only.
final class CaptureService: NSObject, AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "HomeMovie.Capture", qos: .userInitiated)
    private let output = AVCaptureMovieFileOutput()
    private var videoInput: AVCaptureDeviceInput?
    private var coordinator: AVCaptureDevice.RotationCoordinator?
    private var ticket: CaptureTicket?
    private var captureAngle: CGFloat?
    private var observers: [NSObjectProtocol] = []
    private var rotationObservation: NSKeyValueObservation?
    private var configured = false
    private var isFront = false
    var onEvent: (@Sendable (CaptureEvent) -> Void)?

    override init() {
        super.init()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVCaptureDevice.subjectAreaDidChangeNotification, object: nil, queue: nil) { [weak self] notification in
            let deviceID = (notification.object as? AVCaptureDevice)?.uniqueID
            self?.queue.async {
                guard let self, let camera = self.videoInput?.device, camera.uniqueID == deviceID else { return }
                try? self.applyFocus(at: CGPoint(x: 0.5, y: 0.5), camera: camera, monitor: false)
            }
        })
        observers.append(center.addObserver(forName: .AVCaptureSessionWasInterrupted, object: session, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                if self.output.isRecording { self.output.stopRecording() }
                self.onEvent?(.interrupted("Camera interrupted. Your saved scenes are safe. Tap Resume Camera when ready."))
            }
        })
        observers.append(center.addObserver(forName: .AVCaptureSessionRuntimeError, object: session, queue: nil) { [weak self] notification in
            let text = (notification.userInfo?[AVCaptureSessionErrorKey] as? Error)?.localizedDescription ?? "Camera unavailable. Try resuming the camera."
            self?.queue.async { self?.onEvent?(.failed(text)) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] notification in
            guard let value = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  value == AVAudioSession.InterruptionType.began.rawValue else { return }
            self?.queue.async {
                guard let self else { return }
                if self.output.isRecording { self.output.stopRecording() }
                self.onEvent?(.interrupted("Audio interrupted. Resume the camera before recording again."))
            }
        })
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    static func permissions() async -> Bool {
        let camera = AVCaptureDevice.authorizationStatus(for: .video) == .authorized ? true : await AVCaptureDevice.requestAccess(for: .video)
        let microphone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized ? true : await AVCaptureDevice.requestAccess(for: .audio)
        return camera && microphone
    }
    func prepare(front: Bool) {
        queue.async {
            do {
                if self.ticket != nil { return }
                if !self.configured { try self.configure(front: front) }
                try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .videoRecording, options: [.defaultToSpeaker])
                try AVAudioSession.sharedInstance().setActive(true)
                if !self.session.isRunning { self.session.startRunning() }
                guard self.session.isRunning else { throw HomeMovieError.message("The camera could not start.") }
                self.onEvent?(.ready(try self.options()))
            } catch { self.onEvent?(.failed(error.localizedDescription)) }
        }
    }
    private func device(front: Bool) -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType] = front ? [.builtInTrueDepthCamera, .builtInWideAngleCamera] : [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: front ? .front : .back)
        return types.compactMap { type in discovery.devices.first { $0.deviceType == type } }.first
    }
    private func configure(front: Bool) throws {
        session.beginConfiguration(); defer { session.commitConfiguration() }
        guard session.canSetSessionPreset(.hd1920x1080) else { throw HomeMovieError.message("1080p recording is not available on this device.") }
        session.inputs.forEach { session.removeInput($0) }; session.outputs.forEach { session.removeOutput($0) }
        session.sessionPreset = .hd1920x1080
        session.automaticallyConfiguresApplicationAudioSession = false
        guard let camera = device(front: front) else { throw HomeMovieError.message("No supported camera found.") }
        let input = try AVCaptureDeviceInput(device: camera)
        guard session.canAddInput(input) else { throw HomeMovieError.message("The camera input could not be added.") }
        session.addInput(input); videoInput = input; isFront = front
        guard let mic = AVCaptureDevice.default(for: .audio) else { throw HomeMovieError.message("No microphone is available.") }
        let audio = try AVCaptureDeviceInput(device: mic)
        guard session.canAddInput(audio), session.canAddOutput(output) else { throw HomeMovieError.message("Recording could not be configured.") }
        session.addInput(audio); session.addOutput(output)
        try configureFormat(camera)
        setCoordinator(camera)
        if let connection = output.connection(with: .video) {
            connection.automaticallyAdjustsVideoMirroring = false
            if connection.isVideoMirroringSupported { connection.isVideoMirrored = false }
            if connection.isVideoStabilizationSupported { connection.preferredVideoStabilizationMode = .off }
        }
        if let videoConnection = output.connection(with: .video), output.availableVideoCodecTypes.contains(.h264) {
            output.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.h264], for: videoConnection)
        }
        output.minFreeDiskSpaceLimit = 200_000_000
        configured = true
    }
    private func configureFormat(_ camera: AVCaptureDevice) throws {
        try camera.lockForConfiguration(); defer { camera.unlockForConfiguration() }
        if camera.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }) {
            camera.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
            camera.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
        }
        let normal = 1 / camera.displayVideoZoomFactorMultiplier
        camera.videoZoomFactor = min(camera.maxAvailableVideoZoomFactor, max(camera.minAvailableVideoZoomFactor, normal))
        camera.automaticallyAdjustsVideoHDREnabled = false
        if camera.activeFormat.isVideoHDRSupported { camera.isVideoHDREnabled = false }
        if camera.isFocusModeSupported(.continuousAutoFocus) { camera.focusMode = .continuousAutoFocus }
        if camera.isExposureModeSupported(.continuousAutoExposure) { camera.exposureMode = .continuousAutoExposure }
        camera.isSubjectAreaChangeMonitoringEnabled = false
    }
    private func setCoordinator(_ camera: AVCaptureDevice) {
        coordinator = AVCaptureDevice.RotationCoordinator(device: camera, previewLayer: nil)
        rotationObservation = coordinator?.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.new]) { [weak self] _, _ in
            self?.queue.async {
                guard let self, self.ticket == nil else { return }
                if let options = try? self.options() { self.onEvent?(.ready(options)) }
            }
        }
    }
    private func options() throws -> CameraOptions {
        guard let camera = videoInput?.device else { throw HomeMovieError.message("Camera not configured.") }
        let multiplier = camera.displayVideoZoomFactorMultiplier
        let switches = camera.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) }
        var secondary = camera.activeFormat.secondaryNativeResolutionZoomFactors
        // Constituent formats report zoom relative to their own physical camera.
        // Convert those factors into the virtual device's zoom coordinates.
        for (index, constituent) in camera.constituentDevices.enumerated() {
            let base = index == 0 ? CGFloat(1) : switches.indices.contains(index - 1) ? switches[index - 1] : CGFloat(1)
            secondary += constituent.activeFormat.secondaryNativeResolutionZoomFactors.map { $0 * base }
        }
        let lenses = LensChoice.available(minimum: camera.minAvailableVideoZoomFactor, maximum: camera.maxAvailableVideoZoomFactor,
            multiplier: multiplier, switchFactors: switches, secondaryFactors: secondary)
        return CameraOptions(lenses: lenses,
            zoom: camera.videoZoomFactor, minimum: camera.minAvailableVideoZoomFactor, maximum: camera.maxAvailableVideoZoomFactor,
            multiplier: multiplier, isFront: isFront, angle: captureAngle ?? coordinator?.videoRotationAngleForHorizonLevelCapture ?? 90,
            canMeter: (camera.isFocusPointOfInterestSupported && camera.isFocusModeSupported(.continuousAutoFocus)) ||
                (camera.isExposurePointOfInterestSupported && camera.isExposureModeSupported(.continuousAutoExposure)))
    }
    func focus(at point: CGPoint) {
        guard point.x.isFinite, point.y.isFinite, (0...1).contains(point.x), (0...1).contains(point.y) else { return }
        queue.async {
            guard self.session.isRunning, let camera = self.videoInput?.device else { return }
            do { try self.applyFocus(at: point, camera: camera, monitor: true) }
            catch { self.onEvent?(.notice("Focus could not be adjusted. Try tapping again.")) }
        }
    }
    private func applyFocus(at point: CGPoint, camera: AVCaptureDevice, monitor: Bool) throws {
        try camera.lockForConfiguration(); defer { camera.unlockForConfiguration() }
        if camera.isFocusPointOfInterestSupported, camera.isFocusModeSupported(.continuousAutoFocus) {
            camera.focusPointOfInterest = point
            camera.focusMode = .continuousAutoFocus
        }
        if camera.isExposurePointOfInterestSupported, camera.isExposureModeSupported(.continuousAutoExposure) {
            camera.exposurePointOfInterest = point
            camera.exposureMode = .continuousAutoExposure
        }
        camera.isSubjectAreaChangeMonitoringEnabled = monitor
    }
    func zoom(_ factor: CGFloat) {
        queue.async {
            guard let camera = self.videoInput?.device else { return }
            do {
                try camera.lockForConfiguration()
                camera.videoZoomFactor = min(max(factor, camera.minAvailableVideoZoomFactor), camera.maxAvailableVideoZoomFactor)
                camera.unlockForConfiguration()
                self.onEvent?(.ready(try self.options()))
            } catch { self.onEvent?(.failed(error.localizedDescription)) }
        }
    }
    func flip() {
        queue.async {
            guard self.ticket == nil, let old = self.videoInput, let camera = self.device(front: !self.isFront) else { return }
            do {
                let next = try AVCaptureDeviceInput(device: camera)
                self.session.beginConfiguration(); self.session.removeInput(old)
                guard self.session.canAddInput(next) else {
                    self.session.addInput(old); self.session.commitConfiguration()
                    throw HomeMovieError.message("This camera is unavailable.")
                }
                self.session.addInput(next); self.session.commitConfiguration()
                self.videoInput = next; self.isFront.toggle()
                try self.configureFormat(camera)
                self.setCoordinator(camera)
                if let c = self.output.connection(with: .video) {
                    c.automaticallyAdjustsVideoMirroring = false
                    if c.isVideoMirroringSupported { c.isVideoMirrored = false }
                }
                self.onEvent?(.ready(try self.options()))
            } catch { self.onEvent?(.failed(error.localizedDescription)) }
        }
    }
    func record(ticket: CaptureTicket, url: URL) {
        queue.async {
            guard self.ticket == nil, self.session.isRunning, !self.session.isInterrupted else {
                self.onEvent?(.finished(ticket, HomeMovieError.message("The camera is not ready."))); return
            }
            guard let connection = self.output.connection(with: .video), let coordinator = self.coordinator else {
                self.onEvent?(.finished(ticket, HomeMovieError.message("The camera connection is unavailable."))); return
            }
            let angle = coordinator.videoRotationAngleForHorizonLevelCapture
            guard connection.isVideoRotationAngleSupported(angle) else {
                self.onEvent?(.finished(ticket, HomeMovieError.message("This camera rotation is unsupported."))); return
            }
            connection.videoRotationAngle = angle
            self.captureAngle = angle
            self.ticket = ticket
            self.output.startRecording(to: url, recordingDelegate: self)
        }
    }
    func stop() { queue.async { if self.output.isRecording { self.output.stopRecording() } } }
    func suspend(completion: (@Sendable () -> Void)? = nil) {
        queue.async {
            if self.output.isRecording { self.output.stopRecording() }
            if self.session.isRunning { self.session.stopRunning() }
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            completion?()
        }
    }
    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        onEvent?(.started)
    }
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo fileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        queue.async {
            guard let ticket = self.ticket else { return }; self.ticket = nil; self.captureAngle = nil
            let success = error == nil || ((error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool == true)
            self.onEvent?(.finished(ticket, success ? nil : error))
            if self.session.isRunning, let options = try? self.options() { self.onEvent?(.ready(options)) }
        }
    }
}
