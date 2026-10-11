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
    var profile: CaptureProfile
    var canMeter: Bool
    var canLock: Bool
    var focusLocked: Bool
    var exposureBias: Float
    var minimumExposureBias: Float
    var maximumExposureBias: Float
    var canFlip: Bool
    var hasTorch: Bool
    var torchOn: Bool
}
enum CaptureEvent {
    case ready(CameraOptions)
    case started(UUID)
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
    let liveFrames = LiveFrames()
    private let liveOutput = AVCaptureVideoDataOutput()
    private let liveQueue = DispatchQueue(label: "HomeMovie.live-look", qos: .userInteractive)
    private var videoInput: AVCaptureDeviceInput?
    private var coordinator: AVCaptureDevice.RotationCoordinator?
    private var ticket: CaptureTicket?
    private var recordingURL: URL?
    private var stopRequested = false
    private var observers: [NSObjectProtocol] = []
    private var rotationObservation: NSKeyValueObservation?
    private var configuredProfile = CaptureProfile.standard
    private var configured = false
    private var isFront = false
    private var focusLocked = false
    var onEvent: (@Sendable (CaptureEvent) -> Void)?

    override init() {
        super.init()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVCaptureDevice.subjectAreaDidChangeNotification, object: nil, queue: nil) { [weak self] notification in
            let deviceID = (notification.object as? AVCaptureDevice)?.uniqueID
            self?.queue.async {
                guard let self, let camera = self.videoInput?.device, camera.uniqueID == deviceID, !self.focusLocked else { return }
                if (try? self.applyFocus(at: CGPoint(x: 0.5, y: 0.5), camera: camera, monitor: false)) != nil,
                   let options = try? self.options() { self.onEvent?(.ready(options)) }
            }
        })
        observers.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                self.requestStop()
                self.turnOffTorch()
                self.onEvent?(.interrupted("Camera interrupted. Your saved scenes are safe. Tap Resume Camera when ready."))
            }
        })
        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] notification in
            let text = (notification.userInfo?[AVCaptureSessionErrorKey] as? Error)?.localizedDescription ?? "Camera unavailable. Try resuming the camera."
            self?.queue.async {
                guard let self else { return }
                self.requestStop(); self.turnOffTorch(); self.configured = false
                self.onEvent?(.failed(text))
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] notification in
            guard let value = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  value == AVAudioSession.InterruptionType.began.rawValue else { return }
            self?.queue.async {
                guard let self else { return }
                self.requestStop()
                self.turnOffTorch()
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
    static func supportsAppleLog() -> Bool {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInTripleCamera, .builtInDualWideCamera, .builtInWideAngleCamera],
            mediaType: .video, position: .back).devices.contains { camera in
                camera.formats.contains { $0.supportedColorSpaces.contains(.appleLog) && $0.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 } }
            }
    }
    func prepare(front: Bool, profile: CaptureProfile = .standard) {
        queue.async {
            do {
                if self.ticket != nil { return }
                if !self.configured || self.configuredProfile != profile {
                    self.configured = false
                    if self.session.isRunning { self.session.stopRunning() }
                    self.configuredProfile = profile
                    try self.configure(front: self.device(front: front) == nil ? false : front)
                }
                try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .videoRecording, options: [.defaultToSpeaker])
                try AVAudioSession.sharedInstance().setActive(true)
                if !self.session.isRunning { self.session.startRunning() }
                guard self.session.isRunning else { throw HomeMovieError.message("The camera could not start.") }
                guard !self.session.isInterrupted else { throw HomeMovieError.message("The camera is still interrupted. Try Resume Camera again when it is available.") }
                self.onEvent?(.ready(try self.options()))
            } catch { self.onEvent?(.failed(error.localizedDescription)) }
        }
    }
    private func device(front: Bool) -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType] = front ? [.builtInTrueDepthCamera, .builtInWideAngleCamera] : [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: front ? .front : .back)
        return types.compactMap { type in discovery.devices.first {
            $0.deviceType == type && (configuredProfile == .standard || $0.formats.contains { $0.supportedColorSpaces.contains(.appleLog) && $0.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 } })
        } }.first
    }
    private func configure(front: Bool) throws {
        liveFrames.clear()
        session.beginConfiguration(); defer { session.commitConfiguration() }
        guard session.canSetSessionPreset(.hd1920x1080) else { throw HomeMovieError.message("1080p recording is not available on this device.") }
        session.inputs.forEach { session.removeInput($0) }; session.outputs.forEach { session.removeOutput($0) }
        session.sessionPreset = configuredProfile == .appleLog ? .inputPriority : .hd1920x1080
        session.automaticallyConfiguresCaptureDeviceForWideColor = false
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
        if configuredProfile == .appleLog {
            guard session.canAddOutput(liveOutput) else { throw HomeMovieError.message("Live Log preview is unavailable on this camera.") }
            session.addOutput(liveOutput)
            liveOutput.alwaysDiscardsLateVideoFrames = true
            let available = liveOutput.availableVideoCVPixelFormatTypes
            guard let pixelFormat = [kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange].first(where: { available.contains($0) }) else {
                throw HomeMovieError.message("A high-quality live Log preview is unavailable on this camera.")
            }
            liveOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat]
            liveOutput.setSampleBufferDelegate(liveFrames, queue: liveQueue)
            try configureFormat(camera)
        }
        setCoordinator(camera)
        configureVideoConnection()
        output.minFreeDiskSpaceLimit = 200_000_000
        configured = true
    }
    private func configureFormat(_ camera: AVCaptureDevice) throws {
        try camera.lockForConfiguration(); defer { camera.unlockForConfiguration() }
        if configuredProfile == .appleLog {
            let formats = camera.formats.filter {
                let size = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
                return $0.supportedColorSpaces.contains(.appleLog) && size.width >= 1920 && size.height >= 1080 &&
                    $0.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }
            }.sorted {
                let a = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
                let b = CMVideoFormatDescriptionGetDimensions($1.formatDescription)
                return Int64(a.width) * Int64(a.height) < Int64(b.width) * Int64(b.height)
            }
            guard let format = formats.first else { throw HomeMovieError.message("Apple Log is not available on this camera. Switch back to a supported rear camera.") }
            camera.activeFormat = format
            camera.activeColorSpace = .appleLog
        } else if camera.activeFormat.supportedColorSpaces.contains(.sRGB) { camera.activeColorSpace = .sRGB }
        if camera.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }) {
            camera.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
            camera.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
        }
        let normal = 1 / camera.displayVideoZoomFactorMultiplier
        camera.videoZoomFactor = min(camera.maxAvailableVideoZoomFactor, max(camera.minAvailableVideoZoomFactor, normal))
        camera.automaticallyAdjustsVideoHDREnabled = false
        if camera.activeFormat.isVideoHDRSupported { camera.isVideoHDREnabled = false }
        if camera.isFocusPointOfInterestSupported { camera.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5) }
        if camera.isExposurePointOfInterestSupported { camera.exposurePointOfInterest = CGPoint(x: 0.5, y: 0.5) }
        if camera.isFocusModeSupported(.continuousAutoFocus) { camera.focusMode = .continuousAutoFocus }
        if camera.isExposureModeSupported(.continuousAutoExposure) { camera.exposureMode = .continuousAutoExposure }
        camera.isSubjectAreaChangeMonitoringEnabled = false
        camera.setExposureTargetBias(0, completionHandler: nil)
        focusLocked = false
    }
    private func setCoordinator(_ camera: AVCaptureDevice) {
        coordinator = AVCaptureDevice.RotationCoordinator(device: camera, previewLayer: nil)
        rotationObservation = coordinator?.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.new]) { [weak self] _, _ in
            self?.queue.async {
                guard let self else { return }
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
            multiplier: multiplier, isFront: isFront, angle: coordinator?.videoRotationAngleForHorizonLevelCapture ?? 90, profile: configuredProfile,
            canMeter: (camera.isFocusPointOfInterestSupported && camera.isFocusModeSupported(.continuousAutoFocus)) ||
                (camera.isExposurePointOfInterestSupported && camera.isExposureModeSupported(.continuousAutoExposure)),
            canLock: camera.isExposurePointOfInterestSupported && camera.isExposureModeSupported(.autoExpose) &&
                (!camera.isFocusPointOfInterestSupported || camera.isFocusModeSupported(.autoFocus)),
            focusLocked: focusLocked, exposureBias: camera.exposureTargetBias,
            minimumExposureBias: camera.minExposureTargetBias, maximumExposureBias: camera.maxExposureTargetBias,
            canFlip: device(front: !isFront) != nil, hasTorch: camera.hasTorch, torchOn: camera.torchMode == .on)
    }
    func focus(at point: CGPoint, locked: Bool = false) {
        guard point.x.isFinite, point.y.isFinite, (0...1).contains(point.x), (0...1).contains(point.y) else { return }
        queue.async {
            guard self.session.isRunning, !self.session.isInterrupted, let camera = self.videoInput?.device else { return }
            do {
                try self.applyFocus(at: point, camera: camera, monitor: !locked, locked: locked)
                self.onEvent?(.ready(try self.options()))
            }
            catch {
                self.onEvent?(.notice("Focus could not be adjusted. Try tapping again."))
                if let options = try? self.options() { self.onEvent?(.ready(options)) }
            }
        }
    }
    private func applyFocus(at point: CGPoint, camera: AVCaptureDevice, monitor: Bool, locked: Bool = false) throws {
        try camera.lockForConfiguration(); defer { camera.unlockForConfiguration() }
        let focusMode: AVCaptureDevice.FocusMode = locked ? .autoFocus : .continuousAutoFocus
        let exposureMode: AVCaptureDevice.ExposureMode = locked ? .autoExpose : .continuousAutoExposure
        if camera.isFocusPointOfInterestSupported, camera.isFocusModeSupported(focusMode) {
            camera.focusPointOfInterest = point
            camera.focusMode = focusMode
        }
        if camera.isExposurePointOfInterestSupported, camera.isExposureModeSupported(exposureMode) {
            camera.exposurePointOfInterest = point
            camera.exposureMode = exposureMode
        }
        // One-shot autofocus/autoexposure settle and hold, unlike continuous metering.
        focusLocked = locked
        camera.isSubjectAreaChangeMonitoringEnabled = monitor
        if !locked { camera.setExposureTargetBias(0, completionHandler: nil) }
    }
    func exposure(_ bias: Float) {
        guard bias.isFinite else { return }
        queue.async {
            guard self.session.isRunning, !self.session.isInterrupted, let camera = self.videoInput?.device else { return }
            do {
                try camera.lockForConfiguration()
                camera.setExposureTargetBias(min(camera.maxExposureTargetBias, max(camera.minExposureTargetBias, bias)), completionHandler: nil)
                camera.unlockForConfiguration()
                self.onEvent?(.ready(try self.options()))
            } catch { self.onEvent?(.notice("Brightness could not be adjusted.")) }
        }
    }
    func toggleTorch() {
        queue.async {
            guard self.session.isRunning, !self.session.isInterrupted, let camera = self.videoInput?.device, camera.hasTorch else { return }
            do {
                try camera.lockForConfiguration(); defer { camera.unlockForConfiguration() }
                if camera.torchMode == .on { camera.torchMode = .off }
                else {
                    guard camera.isTorchAvailable else { throw HomeMovieError.message("The torch is temporarily unavailable.") }
                    try camera.setTorchModeOn(level: AVCaptureDevice.maxAvailableTorchLevel)
                }
                self.onEvent?(.ready(try self.options()))
            } catch { self.onEvent?(.notice(error.localizedDescription)) }
        }
    }
    private func turnOffTorch() {
        guard let camera = videoInput?.device, camera.hasTorch else { return }
        do {
            try camera.lockForConfiguration(); defer { camera.unlockForConfiguration() }
            camera.torchMode = .off
        } catch { }
    }
    func zoom(_ factor: CGFloat) {
        guard factor.isFinite, factor > 0 else { return }
        queue.async {
            guard self.session.isRunning, !self.session.isInterrupted, let camera = self.videoInput?.device else { return }
            do {
                try camera.lockForConfiguration()
                camera.videoZoomFactor = min(max(factor, camera.minAvailableVideoZoomFactor), camera.maxAvailableVideoZoomFactor)
                camera.unlockForConfiguration()
                self.onEvent?(.ready(try self.options()))
            } catch { self.onEvent?(.notice("Zoom could not be adjusted. Try again.")) }
        }
    }
    private func replaceInput(_ old: AVCaptureDeviceInput, with next: AVCaptureDeviceInput) throws {
        session.beginConfiguration(); defer { session.commitConfiguration() }
        session.removeInput(old)
        guard session.canAddInput(next) else {
            if session.canAddInput(old) { session.addInput(old) }
            throw HomeMovieError.message("This camera is unavailable.")
        }
        session.addInput(next)
    }
    private func configureVideoConnection() {
        guard let connection = output.connection(with: .video) else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        if connection.isVideoMirroringSupported { connection.isVideoMirrored = false }
        if connection.isVideoStabilizationSupported { connection.preferredVideoStabilizationMode = .off }
        if let live = liveOutput.connection(with: .video) {
            if live.isVideoRotationAngleSupported(0) { live.videoRotationAngle = 0 }
            live.automaticallyAdjustsVideoMirroring = false
            if live.isVideoMirroringSupported { live.isVideoMirrored = false }
            if live.isVideoStabilizationSupported { live.preferredVideoStabilizationMode = .off }
        }
        if configuredProfile == .standard && output.availableVideoCodecTypes.contains(.h264) {
            output.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.h264], for: connection)
        }
    }
    func flip() {
        queue.async {
            guard self.ticket == nil, let old = self.videoInput else { return }
            self.liveFrames.clear()
            let oldFront = self.isFront
            do {
                guard let camera = self.device(front: !oldFront) else { throw HomeMovieError.message("No other camera is available.") }
                let next = try AVCaptureDeviceInput(device: camera)
                self.turnOffTorch()
                try self.replaceInput(old, with: next)
                self.videoInput = next; self.isFront = !oldFront
                do { try self.configureFormat(camera) }
                catch {
                    try self.replaceInput(next, with: old)
                    self.videoInput = old; self.isFront = oldFront
                    try self.configureFormat(old.device)
                    self.setCoordinator(old.device); self.configureVideoConnection()
                    throw error
                }
                self.setCoordinator(camera); self.configureVideoConnection()
                self.onEvent?(.ready(try self.options()))
            } catch {
                if self.videoInput?.device.uniqueID == old.device.uniqueID,
                   self.session.inputs.contains(where: { $0 === old }), let options = try? self.options() {
                    self.setCoordinator(old.device); self.configureVideoConnection()
                    self.onEvent?(.notice("Camera could not be switched. The current camera is still available."))
                    self.onEvent?(.ready(options))
                } else {
                    self.configured = false
                    self.onEvent?(.failed("Camera could not be switched. Tap Resume Camera to reconnect."))
                }
            }
        }
    }
    func record(ticket: CaptureTicket, url: URL, angle: CGFloat) {
        queue.async {
            guard self.ticket == nil, self.session.isRunning, !self.session.isInterrupted else {
                self.onEvent?(.finished(ticket, HomeMovieError.message("The camera is not ready."))); return
            }
            guard let connection = self.output.connection(with: .video) else {
                self.onEvent?(.finished(ticket, HomeMovieError.message("The camera connection is unavailable."))); return
            }
            guard connection.isVideoRotationAngleSupported(angle) else {
                self.onEvent?(.finished(ticket, HomeMovieError.message("This camera rotation is unsupported."))); return
            }
            if self.configuredProfile == .appleLog {
                guard self.videoInput?.device.activeColorSpace == .appleLog, self.output.availableVideoCodecTypes.contains(.hevc) else {
                    self.onEvent?(.finished(ticket, HomeMovieError.message("Apple Log recording is unavailable. Your movie was not recorded in Standard mode."))); return
                }
                self.output.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.hevc], for: connection)
            }
            connection.videoRotationAngle = angle
            self.ticket = ticket; self.recordingURL = url.standardizedFileURL; self.stopRequested = false
            self.output.startRecording(to: url, recordingDelegate: self)
        }
    }
    private func requestStop() {
        if ticket != nil { stopRequested = true }
        if output.isRecording { output.stopRecording() }
    }
    func stop() { queue.async { self.requestStop() } }
    func suspend(completion: (@Sendable () -> Void)? = nil) {
        queue.async {
            self.requestStop()
            self.liveFrames.clear()
            self.turnOffTorch()
            if self.session.isRunning { self.session.stopRunning() }
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            completion?()
        }
    }
    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        queue.async {
            guard let ticket = self.ticket, self.recordingURL == fileURL.standardizedFileURL else { return }
            if self.stopRequested { self.output.stopRecording() }
            self.onEvent?(.started(ticket.sceneID))
        }
    }
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo fileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        queue.async {
            guard let ticket = self.ticket, self.recordingURL == fileURL.standardizedFileURL else { return }
            self.ticket = nil; self.recordingURL = nil; self.stopRequested = false
            let success = error == nil || ((error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool == true)
            self.onEvent?(.finished(ticket, success ? nil : error))
            if self.session.isRunning, let options = try? self.options() { self.onEvent?(.ready(options)) }
        }
    }
}
