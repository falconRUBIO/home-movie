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
        // Prefer the familiar displayed 1× anchor to a nearby internal switch point.
        let candidates = ([1 / multiplier, minimum] + switchFactors + secondaryFactors)
            .filter { $0.isFinite && $0 >= minimum && $0 <= maximum }
        var choices: [LensChoice] = []
        for factor in candidates {
            let displayed = (factor * multiplier * 10).rounded() / 10
            // Sub-1× switch boundaries (for example 0.9×) aren't separate lenses.
            guard displayed == 0.5 || displayed >= 1,
                  !choices.contains(where: { $0.displayed == displayed }) else { continue }
            choices.append(LensChoice(factor: factor, displayed: displayed))
        }
        choices.sort { $0.displayed < $1.displayed }
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
    var canStayOnLens: Bool
    var smoothMoving: Bool
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
    private var smoothFilter: SmoothZoomFilter?
    private var smoothTimer: DispatchSourceTimer?
    private var smoothGeneration = UUID()
    private var smoothOpen = false
    private var smoothRampTarget: CGFloat?
    private var smoothRampRate: Float?
    private var smoothSpeed = SmoothZoomSpeed.normal
    private var stayOnLens = false
    private var smoothLensLocked = false
    private var smoothUnlockedRange: ClosedRange<CGFloat>?
    private var zoomObservation: NSKeyValueObservation?
    private var zoomNotificationPending = false
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
                self.stopSmoothZoomOnQueue()
                self.requestStop()
                self.turnOffTorch()
                self.onEvent?(.interrupted("Camera interrupted. Your saved scenes are safe. Tap Resume Camera when ready."))
            }
        })
        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] notification in
            let text = (notification.userInfo?[AVCaptureSessionErrorKey] as? Error)?.localizedDescription ?? "Camera unavailable. Try resuming the camera."
            self?.queue.async {
                guard let self else { return }
                self.stopSmoothZoomOnQueue(); self.requestStop(); self.turnOffTorch(); self.configured = false
                self.onEvent?(.failed(text))
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] notification in
            guard let value = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  value == AVAudioSession.InterruptionType.began.rawValue else { return }
            self?.queue.async {
                guard let self else { return }
                self.stopSmoothZoomOnQueue()
                self.requestStop()
                self.turnOffTorch()
                self.onEvent?(.interrupted("Audio interrupted. Resume the camera before recording again."))
            }
        })
    }
    deinit { smoothTimer?.cancel(); observers.forEach(NotificationCenter.default.removeObserver) }

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
                try self.ensureLogCaptureReady()
                try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .videoRecording, options: [.defaultToSpeaker])
                try AVAudioSession.sharedInstance().setActive(true)
                if !self.session.isRunning { self.session.startRunning() }
                guard self.session.isRunning else { throw HomeMovieError.message("The camera could not start.") }
                guard !self.session.isInterrupted else { throw HomeMovieError.message("The camera is still interrupted. Try Resume Camera again when it is available.") }
                try self.ensureLogCaptureReady()
                self.onEvent?(.ready(try self.options()))
            } catch { self.configured = false; self.onEvent?(.failed(error.localizedDescription)) }
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
        stopSmoothZoomOnQueue()
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
            let available = liveOutput.availableVideoPixelFormatTypes
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
        if camera.primaryConstituentDeviceSwitchingBehavior != .unsupported {
            camera.setPrimaryConstituentDeviceSwitchingBehavior(.auto, restrictedSwitchingBehaviorConditions: [])
        }
        // Select Log last: format, HDR and zoom configuration must not override it.
        if configuredProfile == .appleLog { camera.activeColorSpace = .appleLog }
    }
    private func ensureLogCaptureReady() throws {
        guard configuredProfile == .appleLog else { return }
        guard let camera = videoInput?.device, camera.activeFormat.supportedColorSpaces.contains(.appleLog) else {
            throw HomeMovieError.message("The camera’s active format no longer supports Apple Log. Tap Resume Camera to reconnect.")
        }
        if camera.activeColorSpace != .appleLog {
            try camera.lockForConfiguration()
            camera.activeColorSpace = .appleLog
            camera.unlockForConfiguration()
            liveFrames.clear()
        }
        guard camera.activeColorSpace == .appleLog else {
            throw HomeMovieError.message("Apple Log could not stay enabled on this camera. Tap Resume Camera to reconnect.")
        }
        guard let connection = output.connection(with: .video), output.availableVideoCodecTypes.contains(.hevc) else {
            throw HomeMovieError.message("Apple Log is enabled, but this camera output does not offer HEVC recording.")
        }
        output.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.hevc], for: connection)
        guard camera.activeColorSpace == .appleLog else {
            throw HomeMovieError.message("The recording output changed the camera’s Apple Log mode. Tap Resume Camera to reconnect.")
        }
    }
    private func setCoordinator(_ camera: AVCaptureDevice) {
        zoomObservation = camera.observe(\.videoZoomFactor, options: [.new]) { [weak self] _, _ in
            self?.queue.async { [weak self] in
                guard let self, !self.zoomNotificationPending else { return }
                self.zoomNotificationPending = true
                self.queue.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    guard let self else { return }; self.zoomNotificationPending = false
                    if self.session.isRunning, let options = try? self.options() { self.onEvent?(.ready(options)) }
                }
            }
        }
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
        // Keep explicit lens choices available so a tap can leave a temporary Smooth Zoom lens lock.
        let lensRange = smoothLensLocked ? smoothUnlockedRange : nil
        let lenses = LensChoice.available(minimum: lensRange?.lowerBound ?? camera.minAvailableVideoZoomFactor, maximum: lensRange?.upperBound ?? camera.maxAvailableVideoZoomFactor,
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
            canFlip: device(front: !isFront) != nil, hasTorch: camera.hasTorch, torchOn: camera.torchMode == .on,
            canStayOnLens: camera.isVirtualDevice && camera.activePrimaryConstituent != nil && camera.primaryConstituentDeviceSwitchingBehavior != .unsupported,
            smoothMoving: smoothTimer != nil)
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
            self.stopSmoothZoomOnQueue()
            do {
                try camera.lockForConfiguration()
                camera.videoZoomFactor = min(max(factor, camera.minAvailableVideoZoomFactor), camera.maxAvailableVideoZoomFactor)
                camera.unlockForConfiguration()
                self.onEvent?(.ready(try self.options()))
            } catch { self.onEvent?(.notice("Zoom could not be adjusted. Try again.")) }
        }
    }
    func configureSmoothZoom(speed: SmoothZoomSpeed, stayOnLens: Bool) {
        queue.async {
            let changedLock = self.stayOnLens != stayOnLens
            self.smoothSpeed = speed; self.stayOnLens = stayOnLens
            if changedLock, self.smoothOpen {
                let target = self.smoothFilter?.target
                self.stopSmoothZoomOnQueue()
                self.beginSmoothZoomOnQueue()
                if let target { self.setSmoothTargetOnQueue(CGFloat(target)) }
            }
        }
    }
    func beginSmoothZoom() { queue.async { self.beginSmoothZoomOnQueue() } }
    private func beginSmoothZoomOnQueue() {
        guard !smoothOpen, session.isRunning, !session.isInterrupted, let camera = videoInput?.device else { return }
        do {
            try camera.lockForConfiguration(); defer { camera.unlockForConfiguration() }
            // .locked holds the current primary camera and narrows its hardware zoom range.
            if stayOnLens, camera.isVirtualDevice, camera.activePrimaryConstituent != nil,
               camera.primaryConstituentDeviceSwitchingBehavior != .unsupported {
                smoothUnlockedRange = camera.minAvailableVideoZoomFactor...camera.maxAvailableVideoZoomFactor
                camera.setPrimaryConstituentDeviceSwitchingBehavior(.locked, restrictedSwitchingBehaviorConditions: [])
                smoothLensLocked = true
            }
            smoothFilter = SmoothZoomFilter(current: Double(camera.videoZoomFactor), minimum: Double(camera.minAvailableVideoZoomFactor), maximum: Double(camera.maxAvailableVideoZoomFactor))
            smoothOpen = smoothFilter != nil
            if !smoothOpen, smoothLensLocked {
                camera.setPrimaryConstituentDeviceSwitchingBehavior(.auto, restrictedSwitchingBehaviorConditions: [])
                smoothLensLocked = false; smoothUnlockedRange = nil
            }
            if let options = try? options() { onEvent?(.ready(options)) }
        } catch { onEvent?(.notice("Smooth Zoom could not be enabled. Your recording continues.")) }
    }
    func smoothZoom(to factor: CGFloat) {
        guard factor.isFinite, factor > 0 else { return }
        queue.async { self.setSmoothTargetOnQueue(factor) }
    }
    private func setSmoothTargetOnQueue(_ factor: CGFloat) {
        if !smoothOpen { beginSmoothZoomOnQueue() }
        guard smoothOpen, smoothFilter != nil, session.isRunning, !session.isInterrupted else { return }
        smoothFilter?.setTarget(Double(factor))
        guard smoothTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let generation = UUID(); smoothGeneration = generation
        timer.schedule(deadline: .now(), repeating: .milliseconds(50), leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in
            guard let self, self.smoothGeneration == generation else { return }
            self.advanceSmoothZoom()
        }
        smoothTimer = timer; timer.resume()
        if let options = try? options() { onEvent?(.ready(options)) }
    }
    private func advanceSmoothZoom() {
        guard smoothOpen, session.isRunning, !session.isInterrupted, let camera = videoInput?.device,
              var filter = smoothFilter else { stopSmoothZoomOnQueue(); return }
        if filter.minimum != Double(camera.minAvailableVideoZoomFactor) || filter.maximum != Double(camera.maxAvailableVideoZoomFactor) {
            guard var updated = SmoothZoomFilter(current: Double(camera.videoZoomFactor), minimum: Double(camera.minAvailableVideoZoomFactor), maximum: Double(camera.maxAvailableVideoZoomFactor)) else { stopSmoothZoomOnQueue(); return }
            updated.setTarget(filter.target); filter = updated
        }
        do {
            let next = filter.advance(seconds: 0.05, rate: smoothSpeed.rate); smoothFilter = filter
            try camera.lockForConfiguration(); defer { camera.unlockForConfiguration() }
            let target = min(camera.maxAvailableVideoZoomFactor, max(camera.minAvailableVideoZoomFactor, CGFloat(next)))
            if smoothRampTarget != target || smoothRampRate != smoothSpeed.rate {
                camera.ramp(toVideoZoomFactor: target, withRate: smoothSpeed.rate)
                smoothRampTarget = target; smoothRampRate = smoothSpeed.rate
            }
            if abs(log2(filter.value / filter.target)) < 0.0002,
               abs(log2(Double(camera.videoZoomFactor) / filter.target)) < 0.001 {
                smoothTimer?.cancel(); smoothTimer = nil; smoothGeneration = UUID()
                if let options = try? options() { onEvent?(.ready(options)) }
            }
        } catch {
            stopSmoothZoomOnQueue()
            onEvent?(.notice("Smooth Zoom paused. Your recording continues."))
        }
    }
    func endSmoothZoom() { queue.async { self.stopSmoothZoomOnQueue(); if let options = try? self.options() { self.onEvent?(.ready(options)) } } }
    private func stopSmoothZoomOnQueue() {
        smoothTimer?.cancel(); smoothTimer = nil; smoothGeneration = UUID()
        smoothFilter = nil; smoothOpen = false; smoothRampTarget = nil; smoothRampRate = nil
        guard let camera = videoInput?.device else { return }
        do {
            try camera.lockForConfiguration(); defer { camera.unlockForConfiguration() }
            camera.cancelVideoZoomRamp()
            if smoothLensLocked, camera.primaryConstituentDeviceSwitchingBehavior != .unsupported {
                camera.setPrimaryConstituentDeviceSwitchingBehavior(.auto, restrictedSwitchingBehaviorConditions: [])
            }
            smoothLensLocked = false; smoothUnlockedRange = nil
        } catch { onEvent?(.notice("Zoom could not be paused. Try again.")) }
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
        // Inherit the device's automatic physical-camera selection while recording.
        output.isPrimaryConstituentDeviceSwitchingBehaviorForRecordingEnabled = false
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
        if configuredProfile == .appleLog, output.availableVideoCodecTypes.contains(.hevc) {
            output.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.hevc], for: connection)
        }
        if configuredProfile == .standard && output.availableVideoCodecTypes.contains(.h264) {
            output.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.h264], for: connection)
        }
    }
    func flip() {
        queue.async {
            guard self.ticket == nil, let old = self.videoInput else { return }
            self.stopSmoothZoomOnQueue()
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
                do { try self.ensureLogCaptureReady() }
                catch { self.configured = false; self.onEvent?(.finished(ticket, error)); return }
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
            self.stopSmoothZoomOnQueue()
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
