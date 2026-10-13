import AVFoundation
import Foundation

enum CameraVideoTuning {
    static func configureRecordingOutput(_ output: AVCaptureMovieFileOutput) {
        // Keep device selection consistent between preview and recording. A separate
        // MovieFileOutput policy must not override Dolly's camera selection at Record.
        output.isPrimaryConstituentDeviceSwitchingBehaviorForRecordingEnabled = false
    }
    // Caller owns the device configuration lock.
    static func configureFocus(_ camera: AVCaptureDevice) {
        if camera.isSmoothAutoFocusSupported { camera.isSmoothAutoFocusEnabled = true }
    }
}

enum CameraStabilization {
    // Let Apple negotiate recording stabilization for the actual device, format and
    // frame rate. Keep live interaction responsive with its dedicated preview mode.
    static func preferredMode(preview: Bool, supports: (AVCaptureVideoStabilizationMode) -> Bool) -> AVCaptureVideoStabilizationMode {
        guard preview else { return .auto }
        if supports(.previewOptimized) { return .previewOptimized }
        if supports(.standard) { return .standard }
        return .auto
    }
    static func configure(_ connection: AVCaptureConnection, format: AVCaptureDevice.Format?, preview: Bool) {
        guard connection.isVideoStabilizationSupported, let format else { return }
        let mode = preferredMode(preview: preview, supports: { format.isVideoStabilizationModeSupported($0) })
        // Avoid renegotiating the pipeline on every zoom/UI update.
        if connection.preferredVideoStabilizationMode != mode { connection.preferredVideoStabilizationMode = mode }
    }
}

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
enum LogRecordingCodec {
    // ProRes FourCCs avoid SDK spelling changes; each is checked against the output at runtime.
    static let proResLT = AVVideoCodecType(rawValue: "apcs")
    static let proRes422 = AVVideoCodecType(rawValue: "apcn")
    static func preferred(in available: [AVVideoCodecType]) -> AVVideoCodecType? {
        [.hevc, proResLT, proRes422].first { available.contains($0) }
    }
    static func label(_ codec: AVVideoCodecType?) -> String {
        codec == .hevc ? "Apple Log · HEVC" : "Apple Log · ProRes"
    }
}
enum CameraCompatibility {
    static let logPiPExplanation = "Switch to Standard to use PiP. Your Log movie stays unchanged."
    static let logRecordingFlipExplanation = "Camera flip is unavailable while recording in Log. Stop recording to change cameras, or use Standard."
    static let logCameraExplanation = "The other camera cannot record this Log format. Switch to Standard to use it."

    static func allowsFlip(profile: CaptureProfile, recording: Bool, otherCameraSupported: Bool,
                           continuousFlipSupported: Bool) -> Bool {
        otherCameraSupported && (profile != .appleLog || !recording || continuousFlipSupported)
    }
    static func allowsPiP(profile: CaptureProfile, deviceSupported: Bool) -> Bool {
        profile == .standard && deviceSupported
    }
    static func supportsLog(_ format: AVCaptureDevice.Format) -> Bool {
        let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        return format.supportedColorSpaces.contains(.appleLog) && size.width >= 1920 && size.height >= 1080 &&
            format.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }
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
    var recordingFormat: String
    var samplePreview = false
    var canFlipWhileRecording = false
    var canPreparePiP = false
    var piPAvailable = false
    var isPiPEnabled = false
    var dualCameraPrepared = false
    var piPCanvasFormat: MovieFormat? = nil
}
enum CaptureEvent {
    case ready(CameraOptions)
    case cameraChanged(CameraOptions)
    case started(UUID)
    case finished(CaptureTicket, Error?)
    case interrupted(String)
    case failed(String)
    case notice(String)
    case pipPresentation(PiPPresentation)
    case pipLayout(PiPLayout)
    case pipSetupFailed(String)
}

// All capture mutation is confined to one serial queue. The preview observes the session only.
final class CaptureService: NSObject, AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
    private let singleSession = AVCaptureSession()
    private var seamless: SeamlessCapture?
    private let sessionLock = NSLock()
    private var selectedSession: AVCaptureSession?
    var session: AVCaptureSession {
        sessionLock.lock(); defer { sessionLock.unlock() }
        return selectedSession ?? singleSession
    }
    private func selectSession(_ session: AVCaptureSession) {
        sessionLock.lock(); selectedSession = session; sessionLock.unlock()
    }
    private let queue = DispatchQueue(label: "HomeMovie.Capture", qos: .userInitiated)
    private let output = AVCaptureMovieFileOutput()
    let liveFrames = LiveFrames()
    let pipRearFrames = LiveFrames()
    let pipPresenterFrames = LiveFrames()
    private let piPCapable = SeamlessCapture.canPreparePiP()
    private var dualCameraRequested = false
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
    private var smoothClock = SmoothZoomClock()
    private var smoothInput = SmoothZoomInput()
    private var smoothOpen = false
    private var smoothClosing = false
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
        observers.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: nil, queue: nil) { [weak self] notification in
            guard let self, notification.object as? AVCaptureSession === self.session else { return }
            self.queue.async {
                self.stopSmoothZoomOnQueue()
                self.requestStop()
                self.turnOffTorch()
                self.onEvent?(.interrupted("Camera interrupted. Your saved scenes are safe. Tap Resume Camera when ready."))
            }
        })
        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: nil, queue: nil) { [weak self] notification in
            guard let self, notification.object as? AVCaptureSession === self.session else { return }
            let text = (notification.userInfo?[AVCaptureSessionErrorKey] as? Error)?.localizedDescription ?? "Camera unavailable. Try resuming the camera."
            self.queue.async {
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
    func prepare(front: Bool, profile: CaptureProfile = .standard, dualCamera: Bool = false,
                 pipLayout: PiPLayout = PiPLayout(), canvasFormat: MovieFormat? = nil) {
        queue.async {
            guard !dualCamera || CameraCompatibility.allowsPiP(profile: profile, deviceSupported: self.piPCapable) else {
                self.onEvent?(.pipSetupFailed(profile == .appleLog ? CameraCompatibility.logPiPExplanation : "This iPhone cannot use Dual Camera."))
                return
            }
            let previousFront = self.isFront
            let previousZoom = self.videoInput?.device.videoZoomFactor
            do {
                if self.ticket != nil { return }
                if !self.configured || self.configuredProfile != profile || self.dualCameraRequested != dualCamera || dualCamera && self.seamless?.needsPiPReprepare == true {
                    self.configured = false
                    if self.session.isRunning { self.session.stopRunning() }
                    self.configuredProfile = profile
                    self.dualCameraRequested = dualCamera
                    try self.configure(front: dualCamera ? false : self.device(front: front) == nil ? false : front,
                        preparedForPiP: dualCamera, pipLayout: pipLayout, canvasFormat: canvasFormat)
                }
                self.seamless?.configurePiP(layout: pipLayout, canvasFormat: canvasFormat)
                try self.ensureLogCaptureReady(requireCodec: false)
                try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .videoRecording, options: [.defaultToSpeaker])
                try AVAudioSession.sharedInstance().setActive(true)
                if !self.session.isRunning { self.session.startRunning() }
                guard self.session.isRunning else { throw HomeMovieError.message("The camera could not start.") }
                guard !self.session.isInterrupted else { throw HomeMovieError.message("The camera is still interrupted. Try Resume Camera again when it is available.") }
                try self.ensureLogCaptureReady()
                self.onEvent?(.ready(try self.options()))
            } catch {
                self.configured = false
                if dualCamera {
                    self.dualCameraRequested = false
                    do {
                        try self.configure(front: previousFront)
                        try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .videoRecording, options: [.defaultToSpeaker])
                        try AVAudioSession.sharedInstance().setActive(true); self.session.startRunning()
                        if let previousZoom, let camera = self.videoInput?.device {
                            try camera.lockForConfiguration()
                            camera.videoZoomFactor = min(camera.maxAvailableVideoZoomFactor, max(camera.minAvailableVideoZoomFactor, previousZoom))
                            camera.unlockForConfiguration()
                        }
                        self.onEvent?(.ready(try self.options()))
                        self.onEvent?(.pipSetupFailed("Dual-camera recording could not be prepared. Your ordinary camera remains available. " + error.localizedDescription))
                    } catch { self.onEvent?(.failed(error.localizedDescription)) }
                } else { self.onEvent?(.failed(error.localizedDescription)) }
            }
        }
    }
    private func device(front: Bool) -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType] = front ? [.builtInTrueDepthCamera, .builtInWideAngleCamera] : [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: front ? .front : .back)
        return types.compactMap { type in discovery.devices.first {
            $0.deviceType == type && (configuredProfile == .standard || $0.formats.contains(where: CameraCompatibility.supportsLog))
        } }.first
    }
    private func configure(front: Bool, preparedForPiP: Bool = false, pipLayout: PiPLayout = PiPLayout(), canvasFormat: MovieFormat? = nil) throws {
        stopSmoothZoomOnQueue()
        liveFrames.clear()
        pipRearFrames.clear(); pipPresenterFrames.clear()
        focusLocked = false
        if session.isRunning { session.stopRunning() }
        seamless = nil
        selectSession(singleSession)
        singleSession.beginConfiguration()
        singleSession.inputs.forEach { singleSession.removeInput($0) }
        singleSession.outputs.forEach { singleSession.removeOutput($0) }
        singleSession.commitConfiguration()
        if (front || preparedForPiP), configuredProfile == .standard, let dual = SeamlessCapture(queue: queue, frames: liveFrames,
            rearFrames: pipRearFrames, presenterFrames: pipPresenterFrames, front: front, preparedForPiP: preparedForPiP,
            layout: pipLayout, canvasFormat: canvasFormat) {
            seamless = dual; videoInput = dual.activeInput; isFront = front
            selectSession(dual.session)
            dual.onStarted = { [weak self] id in self?.onEvent?(.started(id)) }
            dual.onFinished = { [weak self] ticket, error in
                guard let self else { return }
                self.ticket = nil; self.recordingURL = nil; self.stopRequested = false
                self.onEvent?(.finished(ticket, error))
                if let options = try? self.options() { self.onEvent?(.ready(options)) }
            }
            dual.onReady = { [weak self] in
                guard let self, let options = try? self.options() else { return }
                self.onEvent?(.ready(options))
            }
            dual.onSelectionChanged = { [weak self, weak dual] in
                guard let self, let dual else { return }
                self.stopSmoothZoomOnQueue(); self.turnOffTorch()
                self.videoInput = dual.activeInput; self.isFront = dual.front; self.focusLocked = false
                self.setCoordinator(dual.activeInput.device)
                if let options = try? self.options() { self.onEvent?(.cameraChanged(options)) }
            }
            dual.onPiPPresentation = { [weak self] in self?.onEvent?(.pipPresentation($0)) }
            dual.onPiPLayout = { [weak self] in self?.onEvent?(.pipLayout($0)) }
            dual.onNotice = { [weak self] in self?.onEvent?(.notice($0)) }
            setCoordinator(dual.activeInput.device); configured = true
            return
        }
        if preparedForPiP { throw HomeMovieError.message("This device cannot sustain the selected 1080p, 30 fps SDR front/rear camera combination.") }
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
        if configuredProfile == .appleLog {
            guard session.canAddOutput(liveOutput) else { throw HomeMovieError.message("Live Log preview is unavailable on this camera.") }
            session.addOutput(liveOutput)
            // This output is used only for the graded viewfinder, never recording.
            // Preview-sized buffers allow Apple's previewOptimized stabilization.
            liveOutput.automaticallyConfiguresOutputBufferDimensions = false
            liveOutput.deliversPreviewSizedOutputBuffers = true
            liveOutput.alwaysDiscardsLateVideoFrames = true
            liveOutput.setSampleBufferDelegate(liveFrames, queue: liveQueue)
        }
        try configureFormat(camera)
        CameraVideoTuning.configureRecordingOutput(output)
        setCoordinator(camera)
        configureVideoConnection()
        output.minFreeDiskSpaceLimit = 200_000_000
        configured = true
    }
    private func configureFormat(_ camera: AVCaptureDevice) throws {
        try camera.lockForConfiguration(); defer { camera.unlockForConfiguration() }
        if configuredProfile == .appleLog {
            let formats = camera.formats.filter {
                CameraCompatibility.supportsLog($0)
            }.sorted {
                let a = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
                let b = CMVideoFormatDescriptionGetDimensions($1.formatDescription)
                return Int64(a.width) * Int64(a.height) < Int64(b.width) * Int64(b.height)
            }
            guard let first = formats.first else { throw HomeMovieError.message("Apple Log is not available on this camera. Switch back to a supported rear camera.") }
            // A Log color space alone does not imply that MovieFileOutput can encode HEVC.
            // Probe each active format, preferring HEVC across all formats before ProRes.
            liveOutput.videoSettings = [:]
            var selected: AVCaptureDevice.Format?
            var proRes: AVCaptureDevice.Format?
            for format in formats {
                camera.activeFormat = format
                camera.automaticallyAdjustsVideoHDREnabled = false
                if format.isVideoHDRSupported { camera.isVideoHDREnabled = false }
                camera.activeColorSpace = .appleLog
                let codec = LogRecordingCodec.preferred(in: output.availableVideoCodecTypes)
                if codec == .hevc { selected = format; break }
                if codec != nil && proRes == nil { proRes = format }
            }
            // The fully committed/running graph is checked again before enabling Record.
            camera.activeFormat = selected ?? proRes ?? first
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
        CameraVideoTuning.configureFocus(camera)
        if camera.isExposureModeSupported(.continuousAutoExposure) { camera.exposureMode = .continuousAutoExposure }
        camera.isSubjectAreaChangeMonitoringEnabled = false
        camera.setExposureTargetBias(0, completionHandler: nil)
        focusLocked = false
        if camera.primaryConstituentDeviceSwitchingBehavior != .unsupported {
            camera.setPrimaryConstituentDeviceSwitchingBehavior(.auto, restrictedSwitchingBehaviorConditions: [])
        }
        // Select Log last: format, HDR and zoom configuration must not override it.
        if configuredProfile == .appleLog {
            camera.activeColorSpace = .appleLog
            let available = liveOutput.availableVideoPixelFormatTypes
            guard let pixelFormat = [kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange].first(where: { available.contains($0) }) else {
                throw HomeMovieError.message("A high-quality live Log preview is unavailable on this camera.")
            }
            liveOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat]
        }
    }
    private func ensureLogCaptureReady(requireCodec: Bool = true) throws {
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
        guard requireCodec else { return }
        if LogRecordingCodec.preferred(in: output.availableVideoCodecTypes) == nil {
            // Retry format negotiation after startRunning has completed, never during a take.
            guard ticket == nil else { throw HomeMovieError.message("The Log recording format is unavailable.") }
            try configureFormat(camera)
            configureVideoConnection()
            liveFrames.clear()
        }
        guard let connection = output.connection(with: .video),
              let codec = LogRecordingCodec.preferred(in: output.availableVideoCodecTypes) else {
            throw HomeMovieError.message("This camera could not provide a compatible Apple Log recording format. Tap Resume Camera to reconnect.")
        }
        output.setOutputSettings([AVVideoCodecKey: codec], for: connection)
        CameraStabilization.configure(connection, format: camera.activeFormat, preview: false)
        output.minFreeDiskSpaceLimit = codec == .hevc ? 200_000_000 : 500_000_000
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
        // Late metering/rotation/zoom callbacks must not revive failed preparation.
        guard configured, session.isRunning, !session.isInterrupted else {
            throw HomeMovieError.message("The camera is not ready.")
        }
        guard let camera = videoInput?.device else { throw HomeMovieError.message("Camera not configured.") }
        if configuredProfile == .appleLog {
            guard camera.activeColorSpace == .appleLog,
                  LogRecordingCodec.preferred(in: output.availableVideoCodecTypes) != nil else {
                throw HomeMovieError.message("The Log recording format is not ready.")
            }
        }
        let multiplier = camera.displayVideoZoomFactorMultiplier
        let switches = camera.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) }
        var secondary = camera.activeFormat.secondaryNativeResolutionZoomFactors
        if seamless != nil, !isFront { secondary += [2, 4, 8].map { CGFloat($0) / multiplier } }
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
            canFlip: device(front: !isFront) != nil && seamless?.preparedForPiP != true, hasTorch: camera.hasTorch, torchOn: camera.torchMode == .on,
            canStayOnLens: camera.isVirtualDevice && camera.activePrimaryConstituent != nil && camera.primaryConstituentDeviceSwitchingBehavior != .unsupported,
            smoothMoving: smoothTimer != nil,
            recordingFormat: configuredProfile == .appleLog ? LogRecordingCodec.label(LogRecordingCodec.preferred(in: output.availableVideoCodecTypes)) : "Standard · H.264",
            samplePreview: seamless != nil, canFlipWhileRecording: seamless?.readyToFlip == true,
            canPreparePiP: CameraCompatibility.allowsPiP(profile: configuredProfile, deviceSupported: piPCapable), piPAvailable: seamless?.supportsPiP == true && seamless?.preparedForPiP == true && configuredProfile == .standard,
            isPiPEnabled: seamless?.pipEnabled == true, dualCameraPrepared: seamless?.preparedForPiP == true,
            piPCanvasFormat: seamless?.canvasFormat)
    }
    func setPiPEnabled(_ enabled: Bool) {
        queue.async {
            guard CameraCompatibility.allowsPiP(profile: self.configuredProfile, deviceSupported: self.piPCapable) else {
                self.onEvent?(.notice(self.configuredProfile == .appleLog ? CameraCompatibility.logPiPExplanation : "This iPhone cannot use Dual Camera.")); return
            }
            guard self.session.isRunning, !self.session.isInterrupted, self.configuredProfile == .standard,
                  let dual = self.seamless, dual.preparedForPiP else { self.onEvent?(.notice("Prepare Dual Camera before recording to use PiP.")); return }
            dual.setPiPEnabled(enabled)
        }
    }
    func setPiPLayout(_ layout: PiPLayout, canvasFormat: MovieFormat? = nil) {
        queue.async { self.seamless?.configurePiP(layout: layout, canvasFormat: canvasFormat) }
    }
    func setPiPObstacles(_ rectangles: [CGRect]) { queue.async { self.seamless?.setPiPObstacles(rectangles) } }
    func dragPiP(to point: CGPoint, finished: Bool) { queue.async { self.seamless?.dragPiP(to: point, finished: finished) } }
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
            if self.smoothSpeed != speed { self.smoothInput.reset() }
            self.smoothSpeed = speed; self.stayOnLens = stayOnLens
            if changedLock, self.smoothOpen, !self.smoothClosing {
                var previous = self.smoothFilter
                self.stopSmoothZoomOnQueue()
                self.beginSmoothZoomOnQueue()
                if let camera = self.videoInput?.device,
                   previous?.reconfigure(current: Double(camera.videoZoomFactor), minimum: Double(camera.minAvailableVideoZoomFactor), maximum: Double(camera.maxAvailableVideoZoomFactor)) == true {
                    self.smoothFilter = previous
                    if previous?.isSettled == false { self.startSmoothTimerOnQueue() }
                }
            }
        }
    }
    func beginSmoothZoom() { queue.async { self.beginSmoothZoomOnQueue() } }
    private func beginSmoothZoomOnQueue(lockLens: Bool = true) {
        smoothClosing = false
        guard !smoothOpen, session.isRunning, !session.isInterrupted, let camera = videoInput?.device else { return }
        do {
            try camera.lockForConfiguration(); defer { camera.unlockForConfiguration() }
            camera.cancelVideoZoomRamp()
            // .locked holds the current primary camera and narrows its hardware zoom range.
            if lockLens, stayOnLens, camera.isVirtualDevice, camera.activePrimaryConstituent != nil,
               camera.primaryConstituentDeviceSwitchingBehavior != .unsupported {
                smoothUnlockedRange = camera.minAvailableVideoZoomFactor...camera.maxAvailableVideoZoomFactor
                camera.setPrimaryConstituentDeviceSwitchingBehavior(.locked, restrictedSwitchingBehaviorConditions: [])
                smoothLensLocked = true
            } else if camera.isVirtualDevice, camera.activePrimaryConstituent != nil,
                      camera.primaryConstituentDeviceSwitchingBehavior != .unsupported {
                // Let Apple consider light and focus, not just optical zoom boundaries.
                // Suppressing fallback can force a darker telephoto image during a Dolly.
                camera.setPrimaryConstituentDeviceSwitchingBehavior(.auto, restrictedSwitchingBehaviorConditions: [])
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
    func dollyZoom(to factor: CGFloat, seconds: Int) {
        guard factor.isFinite, factor > 0 else { return }
        queue.async {
            guard self.session.isRunning, !self.session.isInterrupted, let camera = self.videoInput?.device else { return }
            // Explicit lens buttons can leave the optional slider's current-lens lock.
            if self.smoothLensLocked,
               factor < camera.minAvailableVideoZoomFactor || factor > camera.maxAvailableVideoZoomFactor {
                var previous = self.smoothFilter
                self.stopSmoothZoomOnQueue()
                self.beginSmoothZoomOnQueue(lockLens: false)
                if previous?.reconfigure(current: Double(camera.videoZoomFactor), minimum: Double(camera.minAvailableVideoZoomFactor), maximum: Double(camera.maxAvailableVideoZoomFactor)) == true {
                    self.smoothFilter = previous
                }
            }
            self.setSmoothTargetOnQueue(factor, duration: Double(DollyZoomDuration.validated(seconds)))
        }
    }
    func adjustDollyDestination(to factor: CGFloat) {
        guard factor.isFinite, factor > 0 else { return }
        queue.async {
            guard self.session.isRunning, !self.session.isInterrupted,
                  self.smoothFilter?.isTimed == true else { return }
            self.smoothFilter?.adjustTimedDestination(to: Double(factor))
            self.startSmoothTimerOnQueue()
        }
    }
    func smoothZoom(to factor: CGFloat, inputTime: Double? = nil, inputEnded: Bool = false) {
        guard factor.isFinite, factor > 0 else { return }
        queue.async {
            if let time = inputTime { self.smoothInput.observe(factor: Double(factor), at: time) }
            else { self.smoothInput.reset() }
            self.setSmoothTargetOnQueue(factor)
            if inputEnded { self.smoothInput.end() }
        }
    }
    func endSmoothInput() { queue.async { self.smoothInput.end() } }
    private func setSmoothTargetOnQueue(_ factor: CGFloat, duration: Double? = nil) {
        smoothClosing = false
        if !smoothOpen { beginSmoothZoomOnQueue() }
        guard smoothOpen, smoothFilter != nil, session.isRunning, !session.isInterrupted else { return }
        if duration != nil { smoothInput.reset() }
        if (duration != nil || smoothFilter?.isTimed == true), let camera = videoInput?.device {
            // Rebase to actual zoom without throwing away incoming motion on a takeover.
            _ = smoothFilter?.reconfigure(current: Double(camera.videoZoomFactor),
                minimum: Double(camera.minAvailableVideoZoomFactor), maximum: Double(camera.maxAvailableVideoZoomFactor))
        }
        smoothFilter?.setTarget(Double(factor), duration: duration)
        startSmoothTimerOnQueue()
    }
    private func startSmoothTimerOnQueue() {
        guard smoothOpen, smoothFilter != nil, smoothTimer == nil else { return }
        smoothClock.reset(at: ProcessInfo.processInfo.systemUptime)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let generation = UUID(); smoothGeneration = generation
        timer.schedule(deadline: .now() + .nanoseconds(16_666_667), repeating: .nanoseconds(16_666_667), leeway: .milliseconds(1))
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
            guard filter.reconfigure(current: Double(camera.videoZoomFactor), minimum: Double(camera.minAvailableVideoZoomFactor), maximum: Double(camera.maxAvailableVideoZoomFactor)) else { stopSmoothZoomOnQueue(); return }
        }
        do {
            let now = ProcessInfo.processInfo.systemUptime
            let seconds = smoothClock.step(at: now)
            guard seconds > 0 else { return }
            let next = filter.advance(seconds: seconds, rate: smoothInput.rate(baseline: smoothSpeed.rate), response: smoothSpeed.responseTime); smoothFilter = filter
            try camera.lockForConfiguration()
            let target = min(camera.maxAvailableVideoZoomFactor, max(camera.minAvailableVideoZoomFactor, CGFloat(next)))
            // One trajectory owns zoom. Restarting native ramps on every sample caused stepping.
            if abs(log2(Double(target / camera.videoZoomFactor))) > 0.0000001 { camera.videoZoomFactor = target }
            camera.unlockForConfiguration()
            if filter.isSettled,
               abs(log2(Double(camera.videoZoomFactor) / filter.target)) < 0.001 {
                smoothTimer?.cancel(); smoothTimer = nil; smoothGeneration = UUID(); smoothClock.reset()
                smoothInput.reset()
                if smoothClosing { stopSmoothZoomOnQueue() }
                if let options = try? options() { onEvent?(.ready(options)) }
            }
        } catch {
            stopSmoothZoomOnQueue()
            onEvent?(.notice("Smooth Zoom paused. Your recording continues."))
        }
    }
    func endSmoothZoom() {
        queue.async {
            if self.smoothTimer != nil, var filter = self.smoothFilter, let camera = self.videoInput?.device,
               self.session.isRunning, !self.session.isInterrupted {
                // Preserve incoming velocity without a stop or spring-back on close.
                _ = filter.reconfigure(current: Double(camera.videoZoomFactor), minimum: Double(camera.minAvailableVideoZoomFactor), maximum: Double(camera.maxAvailableVideoZoomFactor))
                filter.finishMotion()
                self.smoothFilter = filter; self.smoothInput.end(); self.smoothClosing = true
            } else { self.stopSmoothZoomOnQueue() }
            if let options = try? self.options() { self.onEvent?(.ready(options)) }
        }
    }
    private func stopSmoothZoomOnQueue() {
        smoothTimer?.cancel(); smoothTimer = nil; smoothGeneration = UUID(); smoothClock.reset()
        smoothFilter = nil; smoothOpen = false
        smoothClosing = false
        smoothInput.reset()
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
        CameraStabilization.configure(connection, format: videoInput?.device.activeFormat, preview: false)
        if let live = liveOutput.connection(with: .video) {
            if live.isVideoRotationAngleSupported(0) { live.videoRotationAngle = 0 }
            live.automaticallyAdjustsVideoMirroring = false
            if live.isVideoMirroringSupported { live.isVideoMirrored = false }
            CameraStabilization.configure(live, format: videoInput?.device.activeFormat, preview: true)
        }
        if configuredProfile == .appleLog, let codec = LogRecordingCodec.preferred(in: output.availableVideoCodecTypes) {
            output.setOutputSettings([AVVideoCodecKey: codec], for: connection)
        }
        if configuredProfile == .standard && output.availableVideoCodecTypes.contains(.h264) {
            output.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.h264], for: connection)
        }
    }
    func flip() {
        queue.async {
            guard CameraCompatibility.allowsFlip(profile: self.configuredProfile, recording: self.ticket != nil,
                otherCameraSupported: self.device(front: !self.isFront) != nil,
                continuousFlipSupported: self.seamless?.readyToFlip == true) else {
                self.onEvent?(.notice(self.configuredProfile == .appleLog ?
                    (self.ticket != nil ? CameraCompatibility.logRecordingFlipExplanation : CameraCompatibility.logCameraExplanation) : "No other camera is available."))
                return
            }
            if let dual = self.seamless {
                guard self.ticket == nil || !self.stopRequested, dual.flip() else {
                    self.onEvent?(.notice("Both cameras are still preparing. Your recording continues."))
                    if let options = try? self.options() { self.onEvent?(.cameraChanged(options)) }
                    return
                }
                self.stopSmoothZoomOnQueue(); self.turnOffTorch()
                self.videoInput = dual.activeInput; self.isFront = dual.front; self.focusLocked = false
                self.setCoordinator(dual.activeInput.device)
                if let options = try? self.options() { self.onEvent?(.cameraChanged(options)) }
                return
            }
            guard self.ticket == nil, let old = self.videoInput else { return }
            if !self.isFront, self.configuredProfile == .standard, AVCaptureMultiCamSession.isMultiCamSupported {
                do {
                    try self.configure(front: true)
                    self.session.startRunning()
                    self.onEvent?(.cameraChanged(try self.options()))
                } catch { self.configured = false; self.onEvent?(.failed(error.localizedDescription)) }
                return
            }
            self.stopSmoothZoomOnQueue()
            self.liveFrames.clear()
            let oldFront = self.isFront
            do {
                guard let camera = self.device(front: !oldFront) else { throw HomeMovieError.message("No other camera is available.") }
                let next = try AVCaptureDeviceInput(device: camera)
                self.turnOffTorch()
                try self.replaceInput(old, with: next)
                self.videoInput = next; self.isFront = !oldFront
                do { try self.configureFormat(camera); try self.ensureLogCaptureReady() }
                catch {
                    try self.replaceInput(next, with: old)
                    self.videoInput = old; self.isFront = oldFront
                    try self.configureFormat(old.device)
                    try self.ensureLogCaptureReady()
                    self.setCoordinator(old.device); self.configureVideoConnection()
                    throw error
                }
                self.setCoordinator(camera); self.configureVideoConnection()
                self.onEvent?(.cameraChanged(try self.options()))
            } catch {
                if self.videoInput?.device.uniqueID == old.device.uniqueID,
                   self.session.inputs.contains(where: { $0 === old }), let options = try? self.options() {
                    self.setCoordinator(old.device); self.configureVideoConnection()
                    self.onEvent?(.notice("Camera could not be switched. The current camera is still available."))
                    self.onEvent?(.cameraChanged(options))
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
            if let dual = self.seamless {
                do {
                    try dual.record(ticket: ticket, url: url, angle: angle)
                    self.ticket = ticket; self.recordingURL = url.standardizedFileURL; self.stopRequested = false
                } catch { self.onEvent?(.finished(ticket, error)) }
                return
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
        if let seamless { seamless.stop(); return }
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

