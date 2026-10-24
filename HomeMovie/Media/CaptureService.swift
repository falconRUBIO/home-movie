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
    static func preferredMode(preview: Bool, front: Bool = false, supports: (AVCaptureVideoStabilizationMode) -> Bool) -> AVCaptureVideoStabilizationMode {
        guard preview else {
            if front, #available(iOS 26.0, *), supports(.lowLatency) { return .lowLatency }
            return .auto
        }
        if supports(.previewOptimized) { return .previewOptimized }
        if supports(.standard) { return .standard }
        return .auto
    }
    static func dualCameraMode(front: Bool, supports: (AVCaptureVideoStabilizationMode) -> Bool) -> AVCaptureVideoStabilizationMode {
        // Both streams feed preview AND recording. Never select preview-only or
        // automatic cinematic buffering here; stabilize the presenter as well.
        if #available(iOS 26.0, *), supports(.lowLatency) { return .lowLatency }
        return supports(.standard) ? .standard : .off
    }
    static func configure(_ connection: AVCaptureConnection, format: AVCaptureDevice.Format?, preview: Bool, front: Bool = false, sharedStream: Bool = false) {
        guard connection.isVideoStabilizationSupported, let format else { return }
        let mode = sharedStream ? dualCameraMode(front: front, supports: { format.isVideoStabilizationModeSupported($0) }) :
            preferredMode(preview: preview, front: front, supports: { format.isVideoStabilizationModeSupported($0) })
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
enum ExtendedZoomTargets {
    static func available(minimum: CGFloat, maximum: CGFloat, multiplier: CGFloat) -> [CGFloat] {
        guard minimum.isFinite, maximum.isFinite, maximum > minimum,
              multiplier.isFinite, multiplier > 0 else { return [] }
        let stops: [CGFloat] = [10, 15, 20, 24, 30, 40, 60]
        var factors = stops.map { $0 / multiplier }.filter { $0 >= minimum && $0 <= maximum }
        if !factors.contains(where: { abs($0 - maximum) < 0.001 }) { factors.append(maximum) }
        return factors.sorted()
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
    static let logPiPExplanation = "Log PiP requires compatible front and rear 10-bit Log capture formats. Your movie’s recording profile is preserved."
    static let logRecordingFlipExplanation = "The camera is not ready for a continuous Log flip. Your current recording continues."
    static let logCameraExplanation = "The other camera cannot record this Log format. Switch to Standard to use it."

    static func allowsFlip(profile: CaptureProfile, recording: Bool, otherCameraSupported: Bool,
                           continuousFlipSupported: Bool) -> Bool {
        otherCameraSupported && (profile != .appleLog || !recording || continuousFlipSupported)
    }
    static func shouldPreparePiP(profile: CaptureProfile, storedPreference: Bool, requested: Bool, currentlyEnabled: Bool) -> Bool {
        storedPreference && (requested || currentlyEnabled)
    }
    static func allowsPiP(profile: CaptureProfile, deviceSupported: Bool) -> Bool {
        deviceSupported
    }
    static func logPiPFormatSummary(frontLog: Bool, rearLog: Bool, compatiblePair: Bool) -> String {
        if compatiblePair {
            return "Compatible front and rear Log capture formats are advertised. Log PiP uses a 10-bit recording pipeline; simultaneous streaming and saved-file validation must also pass."
        }
        if frontLog && rearLog {
            return "Both cameras advertise Log individually, but no supported front/rear pair advertises MultiCam Log at 1080p / 30 fps."
        }
        return "No supported front/rear pair advertises MultiCam Log at 1080p / 30 fps. Front-camera Log: \(frontLog ? "available" : "not advertised"). Rear-camera Log: \(rearLog ? "available" : "not advertised")."
    }
    static func supportsLog(_ format: AVCaptureDevice.Format) -> Bool {
        let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        return format.supportedColorSpaces.contains(.appleLog) && isHD(width: size.width, height: size.height) &&
            format.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }
    }
    static func isHD(width: Int32, height: Int32) -> Bool {
        max(width, height) >= 1920 && min(width, height) >= 1080
    }
}
struct CameraMetering: Sendable {
    let canMeter: Bool
    let canLock: Bool
    let bias: Float
    let range: ClosedRange<Float>
    let locked: Bool
    init(_ camera: AVCaptureDevice, locked: Bool) {
        canMeter = camera.isExposureModeSupported(.continuousAutoExposure) ||
            (camera.isFocusPointOfInterestSupported && camera.isFocusModeSupported(.continuousAutoFocus))
        canLock = camera.isExposureModeSupported(.autoExpose)
        bias = camera.exposureTargetBias; range = camera.minExposureTargetBias...camera.maxExposureTargetBias
        self.locked = locked
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
    var compositedCapture = false
    var canFlipWhileRecording = false
    var canPreparePiP = false
    var piPAvailable = false
    var isPiPEnabled = false
    var dualCameraPrepared = false
    var piPCanvasFormat: MovieFormat? = nil
    var frontMetering: CameraMetering? = nil
    var rearMetering: CameraMetering? = nil
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
final class CaptureService: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
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
    // Construct capture outputs and enumerate MultiCam formats on the capture queue,
    // rather than blocking SwiftUI while the camera model is created.
    private lazy var continuousVideo = AVCaptureVideoDataOutput()
    private lazy var continuousAudio = AVCaptureAudioDataOutput()
    private let continuousCopies = CaptureFrameCopy()
    private var previewHandoff: CameraPreviewHandoff?
    private var previewHandoffAnnounced = true
    private var validatedLogFormats: [String: AVCaptureDevice.Format] = [:]
    private var knownDevices: [String: AVCaptureDevice] = [:]
    private var knownVideoInputs: [String: AVCaptureDeviceInput] = [:]
    private var continuousTake: ContinuousTakePipeline?
    private var continuousAngle: CGFloat = 90
    private var continuousSourceAngles: [Bool: CGFloat] = [:]
    private var continuousStarted = false
    private var continuousStorageCheckPending = false
    private var continuousLastStorageCheck: Double = 0
    let liveFrames = LiveFrames()
    let pipRearFrames = LiveFrames()
    let pipPresenterFrames = LiveFrames()
    private lazy var piPCapable = SeamlessCapture.canPreparePiP()
    private lazy var logPiPCapable = SeamlessCapture.canPreparePiP(profile: .appleLog)
    private func piPCapable(for profile: CaptureProfile) -> Bool { profile == .appleLog ? logPiPCapable : piPCapable }
    private var dualCameraRequested = false
    private var videoInput: AVCaptureDeviceInput?
    private var coordinator: AVCaptureDevice.RotationCoordinator?
    private var ticket: CaptureTicket?
    private var recordingURL: URL?
    private var stopRequested = false
    private var observers: [NSObjectProtocol] = []
    private var pressureObservation: NSKeyValueObservation?
    private var pressureStopReported = false
    private var rotationObservation: NSKeyValueObservation?
    private var configuredProfile = CaptureProfile.standard
    private var configured = false
    private var isFront = false
    private var focusLocked = false
    private var meteringLocks: [String: Bool] = [:]
    private var smoothFilter: SmoothZoomFilter?
    private var smoothTimer: DispatchSourceTimer?
    private var smoothGeneration = UUID()
    private var smoothClock = SmoothZoomClock()
    private var smoothInput = SmoothZoomInput()
    private var smoothOpen = false
    private var manualZoomSession = ManualZoomSession()
    private var smoothClosing = false
    private var smoothSpeed = SmoothZoomSpeed.normal
    private var stayOnLens = false
    private var smoothLensLocked = false
    private var smoothUnlockedRange: ClosedRange<CGFloat>?
    private var smoothPreviousSwitching: (behavior: AVCaptureDevice.PrimaryConstituentDeviceSwitchingBehavior,
        conditions: AVCaptureDevice.PrimaryConstituentDeviceRestrictedSwitchingBehaviorConditions)?
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
            ReliabilityDiagnostics.shared.record(.cameraFailed, error: notification.userInfo?[AVCaptureSessionErrorKey] as? Error)
            let text = (notification.userInfo?[AVCaptureSessionErrorKey] as? Error)?.localizedDescription ?? "Camera unavailable. Try resuming the camera."
            self.queue.async {
                self.stopSmoothZoomOnQueue(); self.requestStop(); self.turnOffTorch(); self.configured = false
                self.knownDevices.removeAll(); self.knownVideoInputs.removeAll(); self.validatedLogFormats.removeAll()
                self.previewHandoff = nil; self.previewHandoffAnnounced = true
                self.liveFrames.cancelRawPreviewHandoff()
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
    /// Reads advertised capabilities without changing the active session or camera formats.
    static func logPiPCompatibilityReport() -> String {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            return "Allow camera access first, then check again."
        }
        guard AVCaptureMultiCamSession.isMultiCamSupported else {
            return "This iPhone does not support simultaneous front and rear capture."
        }
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTrueDepthCamera],
            mediaType: .video, position: .unspecified)
        let candidates = discovery.devices.map { camera in
            (camera: camera, log: camera.formats.filter(CameraCompatibility.supportsLog))
        }
        let front = candidates.filter { $0.camera.position == .front }
        let rear = candidates.filter { $0.camera.position == .back }
        let compatiblePair = discovery.supportedMultiCamDeviceSets.contains { devices in
            let eligible = candidates.filter { candidate in
                devices.contains(candidate.camera) && candidate.log.contains { $0.isMultiCamSupported }
            }
            return eligible.contains { $0.camera.position == .front } && eligible.contains { $0.camera.position == .back }
        }
        let summary = CameraCompatibility.logPiPFormatSummary(
            frontLog: front.contains { !$0.log.isEmpty }, rearLog: rear.contains { !$0.log.isEmpty },
            compatiblePair: compatiblePair)
        let details = candidates.map { candidate in
            let camera = candidate.camera
            let side = camera.position == .front ? "Front" : "Rear"
            let multiCamLog = candidate.log.filter { $0.isMultiCamSupported }.count
            return "\(side) · \(camera.localizedName): \(candidate.log.count) Log formats, \(multiCamLog) MultiCam Log formats at 1080p or higher / 30 fps."
        }.joined(separator: "\n")
        return summary + "\n\n" + details + "\n\nThis checks advertised formats only. Simultaneous streaming, 10-bit encoding, preview color, and thermal stability still require validation. This report checks hardware formats; it does not by itself start a recording."
    }
    func prepare(front: Bool, profile: CaptureProfile = .standard, dualCamera: Bool = false,
                 pipLayout: PiPLayout = PiPLayout(), canvasFormat: MovieFormat? = nil) {
        queue.async {
            guard !dualCamera || CameraCompatibility.allowsPiP(profile: profile, deviceSupported: self.piPCapable(for: profile)) else {
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
                try self.ensureLogCaptureReady(requireOutputs: false)
                try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .videoRecording, options: [.defaultToSpeaker])
                try AVAudioSession.sharedInstance().setActive(true)
                if !self.session.isRunning { self.session.startRunning() }
                guard self.session.isRunning else { throw HomeMovieError.message("The camera could not start.") }
                guard !self.session.isInterrupted else { throw HomeMovieError.message("The camera is still interrupted. Try Resume Camera again when it is available.") }
                try self.ensureLogCaptureReady()
                if profile == .appleLog, dualCamera, self.seamless?.readyToFlip != true { return }
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
        let key = "\(configuredProfile.rawValue)-\(front ? "front" : "rear")"
        if let cached = knownDevices[key] { return cached }
        let types: [AVCaptureDevice.DeviceType] = front ? [.builtInTrueDepthCamera, .builtInWideAngleCamera] : [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: front ? .front : .back)
        let found = types.compactMap { type in discovery.devices.first {
            $0.deviceType == type && (configuredProfile == .standard || $0.formats.contains(where: CameraCompatibility.supportsLog))
        } }.first
        if let found { knownDevices[key] = found }
        return found
    }
    private func videoInput(for camera: AVCaptureDevice) throws -> AVCaptureDeviceInput {
        if let cached = knownVideoInputs[camera.uniqueID] { return cached }
        let input = try AVCaptureDeviceInput(device: camera)
        knownVideoInputs[camera.uniqueID] = input
        return input
    }
    private func configure(front: Bool, preparedForPiP: Bool = false, pipLayout: PiPLayout = PiPLayout(), canvasFormat: MovieFormat? = nil) throws {
        stopSmoothZoomOnQueue()
        previewHandoff = nil; previewHandoffAnnounced = true
        liveFrames.clear()
        pipRearFrames.clear(); pipPresenterFrames.clear()
        focusLocked = false; meteringLocks.removeAll()
        if session.isRunning { session.stopRunning() }
        seamless = nil
        selectSession(singleSession)
        // Ordinary capture clears and rebuilds in the single transaction below.
        // Only clear the unused single-camera session separately when entering MultiCam.
        if preparedForPiP {
            singleSession.beginConfiguration()
            singleSession.inputs.forEach { singleSession.removeInput($0) }
            singleSession.outputs.forEach { singleSession.removeOutput($0) }
            singleSession.commitConfiguration()
        }
        if preparedForPiP, let dual = SeamlessCapture(queue: queue, frames: liveFrames,
            rearFrames: pipRearFrames, presenterFrames: pipPresenterFrames, front: front, profile: configuredProfile, preparedForPiP: preparedForPiP,
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
            dual.onLogFailure = { [weak self] in self?.onEvent?(.failed($0)) }
            setCoordinator(dual.activeInput.device); configured = true
            return
        }
        if preparedForPiP { throw HomeMovieError.message("This device cannot sustain the selected 1080p, 30 fps front/rear camera format. Try the ordinary camera or a Standard movie.") }
        session.beginConfiguration(); defer { session.commitConfiguration() }
        guard session.canSetSessionPreset(.hd1920x1080) else { throw HomeMovieError.message("1080p recording is not available on this device.") }
        // A reused output may still request the previous camera's 10-bit format.
        // Release that request before changing inputs, presets or color spaces.
        continuousVideo.videoSettings = [:]
        session.inputs.forEach { session.removeInput($0) }; session.outputs.forEach { session.removeOutput($0) }
        session.sessionPreset = configuredProfile == .appleLog ? .inputPriority : .hd1920x1080
        session.automaticallyConfiguresCaptureDeviceForWideColor = false
        session.automaticallyConfiguresApplicationAudioSession = false
        guard let camera = device(front: front) else { throw HomeMovieError.message("No supported camera found.") }
        let input = try videoInput(for: camera)
        guard session.canAddInput(input) else { throw HomeMovieError.message("The camera input could not be added.") }
        session.addInput(input); videoInput = input; isFront = front
        guard let mic = AVCaptureDevice.default(for: .audio) else { throw HomeMovieError.message("No microphone is available.") }
        let audio = try AVCaptureDeviceInput(device: mic)
        guard session.canAddInput(audio) else { throw HomeMovieError.message("Recording could not be configured.") }
        session.addInput(audio)
        guard session.canAddOutput(continuousVideo), session.canAddOutput(continuousAudio) else {
            throw HomeMovieError.message("Continuous camera recording is unavailable.")
        }
        session.addOutput(continuousVideo); session.addOutput(continuousAudio)
        continuousVideo.alwaysDiscardsLateVideoFrames = true
        continuousVideo.setSampleBufferDelegate(self, queue: queue)
        continuousAudio.setSampleBufferDelegate(self, queue: queue)
        try configureFormat(camera)
        setCoordinator(camera)
        configureVideoConnection()
        configured = true
    }
    private func configureFormat(_ camera: AVCaptureDevice) throws {
        // Do not impose an 8-bit request while the reused device is still in Log.
        // Negotiate the output only after the target format/color space is active.
        continuousVideo.videoSettings = [:]
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
            // Negotiate the sample output itself, not a MovieFileOutput codec.
            // The same 10-bit frames feed preview and the continuous Main10 writer.
            let cached = validatedLogFormats[camera.uniqueID]
            let candidates = cached.flatMap { remembered in
                formats.contains(where: { $0 == remembered }) ? [remembered] + formats.filter { $0 != remembered } : nil
            } ?? formats
            var selected: AVCaptureDevice.Format?
            for format in candidates {
                camera.activeFormat = format
                camera.automaticallyAdjustsVideoHDREnabled = false
                if format.isVideoHDRSupported { camera.isVideoHDREnabled = false }
                camera.activeColorSpace = .appleLog
                if Self.logPixelFormat(in: continuousVideo.availableVideoPixelFormatTypes) != nil {
                    selected = format; break
                }
            }
            guard let selected else {
                camera.activeFormat = first
                throw HomeMovieError.message("This camera cannot deliver 10-bit Apple Log for continuous recording.")
            }
            camera.activeFormat = selected
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
            let available = continuousVideo.availableVideoPixelFormatTypes
            guard let pixelFormat = Self.logPixelFormat(in: available) else {
                throw HomeMovieError.message("A high-quality live Log preview is unavailable on this camera.")
            }
            continuousVideo.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat]
        } else {
            let available = continuousVideo.availableVideoPixelFormatTypes
            let preferred: [OSType] = [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_32BGRA]
            guard let pixelFormat = preferred.first(where: { available.contains($0) }) else {
                throw HomeMovieError.message("A Standard camera output is unavailable. Try reopening the camera.")
            }
            continuousVideo.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat]
        }
    }
    static func logPixelFormat(in available: [OSType]) -> OSType? {
        [kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange].first { available.contains($0) }
    }
    private func ensureLogCaptureReady(requireOutputs: Bool = true) throws {
        guard configuredProfile == .appleLog else { return }
        if let seamless { try seamless.verifyLogConfiguration(); return }
        guard let camera = videoInput?.device, camera.activeFormat.supportedColorSpaces.contains(.appleLog) else {
            throw HomeMovieError.message("The camera’s active format no longer supports Apple Log. Tap Resume Camera to reconnect.")
        }
        if camera.activeColorSpace != .appleLog {
            try camera.lockForConfiguration()
            camera.activeColorSpace = .appleLog
            camera.unlockForConfiguration()
            if previewHandoff == nil { liveFrames.clear() }
        }
        guard camera.activeColorSpace == .appleLog else {
            throw HomeMovieError.message("Apple Log could not stay enabled on this camera. Tap Resume Camera to reconnect.")
        }
        guard requireOutputs else { return }
        guard continuousVideo.connection(with: .video) != nil, continuousAudio.connection(with: .audio) != nil,
              let pixelFormat = continuousVideo.videoSettings[kCVPixelBufferPixelFormatTypeKey as String] as? OSType,
              Self.logPixelFormat(in: [pixelFormat]) != nil else {
            throw HomeMovieError.message("The continuous 10-bit Log recording outputs are not ready. Tap Resume Camera to reconnect.")
        }
        validatedLogFormats[camera.uniqueID] = camera.activeFormat
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
        pressureStopReported = false
        pressureObservation = camera.observe(\.systemPressureState, options: [.new]) { [weak self] _, change in
            let level = change.newValue?.level
            self?.queue.async {
                guard let self, self.seamless == nil else { return }
                if level == .critical || level == .shutdown {
                    guard !self.pressureStopReported else { return }
                    self.pressureStopReported = true
                    ReliabilityDiagnostics.shared.record(.resourcePressure)
                    self.onEvent?(.notice("The camera is under heavy system pressure. Finishing this take safely; let your iPhone cool before recording again."))
                    self.requestStop()
                } else if level == .nominal { self.pressureStopReported = false }
            }
        }
        coordinator = AVCaptureDevice.RotationCoordinator(device: camera, previewLayer: nil)
        updateLogPreviewRotation()
        rotationObservation = coordinator?.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.new]) { [weak self] _, _ in
            self?.queue.async {
                guard let self else { return }
                // Frame payloads carry their own sensor orientation. Updating UI
                // options must not rotate the take's already locked output canvas.
                if self.ticket == nil { self.updateLogPreviewRotation() }
                if let options = try? self.options() { self.onEvent?(.ready(options)) }
            }
        }
    }
    private func updateLogPreviewRotation() {
        guard configuredProfile == .appleLog else { return }
        liveFrames.configureRawPreview(angle: coordinator?.videoRotationAngleForHorizonLevelCapture ?? 90,
            front: isFront)
    }
    private func options() throws -> CameraOptions {
        // Late metering/rotation/zoom callbacks must not revive failed preparation.
        guard configured, session.isRunning, !session.isInterrupted, previewHandoff == nil else {
            throw HomeMovieError.message("The camera is not ready.")
        }
        guard let camera = videoInput?.device else { throw HomeMovieError.message("Camera not configured.") }
        if configuredProfile == .appleLog {
            guard camera.activeColorSpace == .appleLog,
                  seamless != nil || continuousVideo.connection(with: .video) != nil else {
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
            canFlip: device(front: !isFront) != nil && seamless?.pipEnabled != true && seamless?.needsPiPReprepare != true, hasTorch: camera.hasTorch, torchOn: camera.torchMode == .on,
            canStayOnLens: camera.isVirtualDevice && camera.activePrimaryConstituent != nil && camera.primaryConstituentDeviceSwitchingBehavior != .unsupported,
            smoothMoving: smoothTimer != nil,
            recordingFormat: configuredProfile == .appleLog ? "Apple Log · HEVC 10-bit" : "Standard · H.264",
            samplePreview: true, compositedCapture: true, canFlipWhileRecording: seamless?.readyToFlip == true || (seamless == nil && continuousVideo.connection(with: .video) != nil),
            canPreparePiP: CameraCompatibility.allowsPiP(profile: configuredProfile, deviceSupported: piPCapable(for: configuredProfile)), piPAvailable: seamless?.supportsPiP == true && seamless?.preparedForPiP == true,
            isPiPEnabled: seamless?.pipEnabled == true, dualCameraPrepared: seamless?.preparedForPiP == true,
            piPCanvasFormat: seamless?.canvasFormat,
            frontMetering: seamless.map { CameraMetering($0.frontInput.device, locked: meteringLocks[$0.frontInput.device.uniqueID] == true) },
            rearMetering: seamless.map { CameraMetering($0.backInput.device, locked: meteringLocks[$0.backInput.device.uniqueID] == true) })
    }
    func setPiPEnabled(_ enabled: Bool) {
        queue.async {
            guard CameraCompatibility.allowsPiP(profile: self.configuredProfile, deviceSupported: self.piPCapable(for: self.configuredProfile)) else {
                self.onEvent?(.notice(self.configuredProfile == .appleLog ? CameraCompatibility.logPiPExplanation : "This iPhone cannot use Dual Camera.")); return
            }
            guard self.session.isRunning, !self.session.isInterrupted,
                  let dual = self.seamless, dual.preparedForPiP else { self.onEvent?(.notice("Prepare Dual Camera before recording to use PiP.")); return }
            dual.setPiPEnabled(enabled)
        }
    }
    func setPiPLayout(_ layout: PiPLayout, canvasFormat: MovieFormat? = nil) {
        queue.async { self.seamless?.configurePiP(layout: layout, canvasFormat: canvasFormat) }
    }
    func setPiPObstacles(_ rectangles: [CGRect]) { queue.async { self.seamless?.setPiPObstacles(rectangles) } }
    func dragPiP(to point: CGPoint, finished: Bool) { queue.async { self.seamless?.dragPiP(to: point, finished: finished) } }
    func focus(at point: CGPoint, locked: Bool = false, front: Bool? = nil) {
        guard point.x.isFinite, point.y.isFinite, (0...1).contains(point.x), (0...1).contains(point.y) else { return }
        queue.async {
            guard self.session.isRunning, !self.session.isInterrupted, let camera = self.meteringCamera(front: front) else { return }
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
        if !camera.isExposurePointOfInterestSupported, camera.isExposureModeSupported(exposureMode) { camera.exposureMode = exposureMode }
        // One-shot autofocus/autoexposure settle and hold, unlike continuous metering.
        meteringLocks[camera.uniqueID] = locked
        if camera.uniqueID == videoInput?.device.uniqueID { focusLocked = locked }
        camera.isSubjectAreaChangeMonitoringEnabled = monitor
        if !locked { camera.setExposureTargetBias(0, completionHandler: nil) }
    }
    private func meteringCamera(front: Bool?) -> AVCaptureDevice? {
        guard let front else { return videoInput?.device }
        guard let seamless else { return nil }
        return front ? seamless.frontInput.device : seamless.backInput.device
    }
    func exposure(_ bias: Float, front: Bool? = nil) {
        guard bias.isFinite else { return }
        queue.async {
            guard self.session.isRunning, !self.session.isInterrupted, let camera = self.meteringCamera(front: front) else { return }
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
    // The ordinary lens dial can cross cameras regardless of Dolly's optional lens lock.
    func beginManualZoom(id: UUID) {
        queue.async {
            if self.smoothLensLocked { self.stopSmoothZoomOnQueue() }
            self.beginSmoothZoomOnQueue(lockLens: false)
            if self.smoothOpen { self.manualZoomSession.begin(id) }
        }
    }
    func manualZoom(to factor: CGFloat, inputTime: Double, id: UUID) {
        guard factor.isFinite, factor > 0, inputTime.isFinite else { return }
        queue.async {
            guard self.manualZoomSession.accepts(id) else { return }
            self.smoothInput.observe(factor: Double(factor), at: inputTime)
            self.setSmoothTargetOnQueue(factor)
        }
    }
    func endManualZoom(id: UUID) {
        queue.async {
            guard self.manualZoomSession.end(id) else { return }
            self.smoothInput.end()
            // Reach the final requested framing, then restore the camera's lens policy.
            // No inertia, spring-back, or change to Dolly's close behavior.
            if self.smoothTimer != nil { self.smoothClosing = true }
            else { self.stopSmoothZoomOnQueue() }
        }
    }
    func beginSmoothZoom() {
        queue.async {
            // Restore ordinary policy before Dolly reapplies its own lens-lock setting.
            if self.manualZoomSession.isOpen { self.stopSmoothZoomOnQueue() }
            self.beginSmoothZoomOnQueue()
        }
    }
    private func beginSmoothZoomOnQueue(lockLens: Bool = true) {
        smoothClosing = false
        guard !smoothOpen, session.isRunning, !session.isInterrupted, let camera = videoInput?.device else { return }
        do {
            try camera.lockForConfiguration(); defer { camera.unlockForConfiguration() }
            camera.cancelVideoZoomRamp()
            if camera.isVirtualDevice, camera.activePrimaryConstituent != nil,
               camera.activePrimaryConstituentDeviceSwitchingBehavior != .unsupported,
               camera.primaryConstituentDeviceSwitchingBehavior != .unsupported {
                smoothPreviousSwitching = (camera.primaryConstituentDeviceSwitchingBehavior,
                    camera.primaryConstituentDeviceRestrictedSwitchingBehaviorConditions)
            }
            // .locked holds the current primary camera and narrows its hardware zoom range.
            if lockLens, stayOnLens, smoothPreviousSwitching != nil {
                smoothUnlockedRange = camera.minAvailableVideoZoomFactor...camera.maxAvailableVideoZoomFactor
                camera.setPrimaryConstituentDeviceSwitchingBehavior(.locked, restrictedSwitchingBehaviorConditions: [])
                smoothLensLocked = true
            } else if smoothPreviousSwitching != nil {
                // Boundary crossings still permit a better lens after AE/AF settle.
                // Unlike .auto, continuous zoom ticks don't repeatedly invite fallback
                // switches as light/focus fluctuate near the telephoto boundary.
                // Do not use .videoZoomChanged: every tick would permit fallback again.
                camera.setPrimaryConstituentDeviceSwitchingBehavior(.restricted, restrictedSwitchingBehaviorConditions: [])
            }
            smoothFilter = SmoothZoomFilter(current: Double(camera.videoZoomFactor), minimum: Double(camera.minAvailableVideoZoomFactor), maximum: Double(camera.maxAvailableVideoZoomFactor))
            smoothOpen = smoothFilter != nil
            if !smoothOpen, let previous = smoothPreviousSwitching {
                camera.setPrimaryConstituentDeviceSwitchingBehavior(previous.behavior, restrictedSwitchingBehaviorConditions: previous.conditions)
                smoothPreviousSwitching = nil
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
    func pauseSmoothZoom(completion: @escaping @Sendable (CGFloat?) -> Void) {
        queue.async {
            guard self.smoothOpen, let camera = self.videoInput?.device else { completion(nil); return }
            self.smoothTimer?.cancel(); self.smoothTimer = nil
            self.smoothGeneration = UUID(); self.smoothClock.reset(); self.smoothInput.reset()
            self.smoothClosing = false
            self.smoothFilter = SmoothZoomFilter(current: Double(camera.videoZoomFactor),
                minimum: Double(camera.minAvailableVideoZoomFactor), maximum: Double(camera.maxAvailableVideoZoomFactor))
            // Hold the measured view. No zoom write, AE/AF change, or lens-policy reset.
            if let options = try? self.options() { self.onEvent?(.ready(options)) }
            completion(camera.videoZoomFactor)
        }
    }
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
        manualZoomSession.clear()
        smoothTimer?.cancel(); smoothTimer = nil; smoothGeneration = UUID(); smoothClock.reset()
        smoothFilter = nil; smoothOpen = false
        smoothClosing = false
        smoothInput.reset()
        guard let camera = videoInput?.device else { return }
        do {
            try camera.lockForConfiguration(); defer { camera.unlockForConfiguration() }
            camera.cancelVideoZoomRamp()
            if let previous = smoothPreviousSwitching, camera.activePrimaryConstituentDeviceSwitchingBehavior != .unsupported {
                camera.setPrimaryConstituentDeviceSwitchingBehavior(previous.behavior, restrictedSwitchingBehaviorConditions: previous.conditions)
            }
            smoothPreviousSwitching = nil
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
        guard let connection = continuousVideo.connection(with: .video) else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        if connection.isVideoMirroringSupported { connection.isVideoMirrored = false }
        if connection.isVideoRotationAngleSupported(0) { connection.videoRotationAngle = 0 }
        // One low-latency sample stream feeds preview and recording in either
        // profile. Sensor orientation is applied by the compositor, never here.
        CameraStabilization.configure(connection, format: videoInput?.device.activeFormat,
            preview: false, front: isFront, sharedStream: true)
    }
    func flip() {
        queue.async {
            guard CameraCompatibility.allowsFlip(profile: self.configuredProfile, recording: self.ticket != nil,
                otherCameraSupported: self.device(front: !self.isFront) != nil,
                continuousFlipSupported: self.seamless?.readyToFlip == true || self.continuousTake != nil) else {
                self.onEvent?(.notice(self.configuredProfile == .appleLog ?
                    (self.ticket != nil ? CameraCompatibility.logRecordingFlipExplanation : CameraCompatibility.logCameraExplanation) : "No other camera is available."))
                if let options = try? self.options() { self.onEvent?(.cameraChanged(options)) }
                else { self.onEvent?(.failed("The camera could not be switched. Resume Camera to reconnect.")) }
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
            guard self.previewHandoff == nil, self.ticket == nil || (self.continuousTake != nil && !self.stopRequested), let old = self.videoInput else { return }
            self.stopSmoothZoomOnQueue()
            // Preserve the outgoing frame while the new input warms up.
            self.previewHandoffAnnounced = false
            self.previewHandoff = CameraPreviewHandoff(after: CMClockGetTime(self.session.synchronizationClock ?? CMClockGetHostTimeClock()))
            let oldFront = self.isFront
            do {
                guard let camera = self.device(front: !oldFront) else { throw HomeMovieError.message("No other camera is available.") }
                let next = try self.videoInput(for: camera)
                self.turnOffTorch()
                // Commit input, format and stabilization together. Nested input
                // replacement transactions do not restart an intermediate graph.
                do {
                    self.session.beginConfiguration()
                    defer { self.session.commitConfiguration() }
                    self.continuousVideo.videoSettings = [:]
                    try self.replaceInput(old, with: next)
                    self.videoInput = next; self.isFront = !oldFront
                    do { try self.configureFormat(camera); try self.ensureLogCaptureReady() }
                    catch {
                        self.continuousVideo.videoSettings = [:]
                        try self.replaceInput(next, with: old)
                        self.videoInput = old; self.isFront = oldFront
                        try self.configureFormat(old.device)
                        try self.ensureLogCaptureReady()
                        self.configureVideoConnection()
                        throw error
                    }
                    self.configureVideoConnection()
                }
                self.setCoordinator(camera)
                if self.previewHandoff != nil {
                    // Reject samples queued by the outgoing input during configuration.
                    self.previewHandoff = CameraPreviewHandoff(after: CMClockGetTime(self.session.synchronizationClock ?? CMClockGetHostTimeClock()))
                }
                if let pending = self.previewHandoff {
                    self.queue.asyncAfter(deadline: .now() + 4) { [weak self] in
                        guard let self, self.previewHandoff?.id == pending.id else { return }
                        self.previewHandoff = nil; self.previewHandoffAnnounced = true
                        self.liveFrames.cancelRawPreviewHandoff()
                        self.onEvent?(.notice("The camera is taking longer to prepare. The last preview stays visible until fresh frames arrive."))
                        if let options = try? self.options() { self.onEvent?(.cameraChanged(options)) }
                    }
                } else { self.onEvent?(.cameraChanged(try self.options())) }
            } catch {
                self.previewHandoff = nil; self.previewHandoffAnnounced = true
                self.liveFrames.cancelRawPreviewHandoff()
                if self.videoInput?.device.uniqueID == old.device.uniqueID,
                   self.session.inputs.contains(where: { $0 === old }), let options = try? self.options() {
                    self.setCoordinator(old.device); self.configureVideoConnection()
                    self.onEvent?(.notice("Camera could not be switched. The current camera is still available."))
                    self.onEvent?(.cameraChanged(options))
                } else {
                    self.configured = false
                    self.requestStop()
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
            if let level = self.videoInput?.device.systemPressureState.level,
               level == .critical || level == .shutdown {
                self.onEvent?(.finished(ticket, HomeMovieError.message("Let your iPhone cool before recording again.")))
                return
            }
            if let dual = self.seamless {
                do {
                    try dual.record(ticket: ticket, url: url, angle: angle)
                    self.ticket = ticket; self.recordingURL = url.standardizedFileURL; self.stopRequested = false
                } catch { self.onEvent?(.finished(ticket, error)) }
                return
            }
            do {
                try self.ensureLogCaptureReady()
                self.continuousTake = try ContinuousTakePipeline(url: url, angle: angle,
                    profile: self.configuredProfile, callbackQueue: self.queue)
                self.continuousAngle = angle; self.continuousStarted = false
                self.continuousSourceAngles = [:]
                self.continuousLastStorageCheck = 0
                self.ticket = ticket; self.recordingURL = url.standardizedFileURL; self.stopRequested = false
            } catch { self.onEvent?(.finished(ticket, error)) }
        }
    }
    private func requestStop() {
        if ticket != nil { stopRequested = true }
        if let seamless { seamless.stop(); return }
        if let take = continuousTake, let ticket {
            guard !take.finishing else { return }
            take.finish { [weak self, weak take] error in
                self?.queue.async { [weak self, weak take] in
                    guard let self, let take, self.continuousTake === take else { return }
                    self.continuousTake = nil; self.ticket = nil; self.recordingURL = nil; self.stopRequested = false
                    self.onEvent?(.finished(ticket, error))
                    if self.session.isRunning, let options = try? self.options() { self.onEvent?(.ready(options)) }
                }
            }
            return
        }
    }
    func stop() { queue.async { self.requestStop() } }
    func suspend(completion: (@Sendable () -> Void)? = nil) {
        queue.async {
            self.stopSmoothZoomOnQueue()
            self.requestStop()
            self.previewHandoff = nil; self.previewHandoffAnnounced = true
            self.liveFrames.clear()
            self.turnOffTorch()
            if self.session.isRunning { self.session.stopRunning() }
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            completion?()
        }
    }
    // Both profiles retain one writer and capture clock across input changes.
    // The microphone input/output is never replaced by a camera flip.
    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === continuousAudio { continuousTake?.appendAudio(sample); return }
        guard output === continuousVideo, connection === continuousVideo.connection(with: .video) else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sample)
        if let pending = previewHandoff, pending.after.isNumeric, time <= pending.after { return }
        if configuredProfile == .appleLog, !LogPiPColor.verifyCapture(sample) {
            // Never relabel SDR data as Log or feed it into a 10-bit Log take.
            if continuousTake != nil, !stopRequested {
                onEvent?(.notice("The camera did not deliver a valid 10-bit Log frame. Finishing the current take safely."))
                requestStop()
            }
            return
        }
        guard let source = CMSampleBufferGetImageBuffer(sample), let image = continuousCopies.copy(source) else { return }
        var publishPreview = true
        if var pending = previewHandoff {
            guard !pending.after.isNumeric || time > pending.after else { return }
            publishPreview = pending.accept(time)
            previewHandoff = publishPreview ? nil : pending
        }
        if publishPreview {
            // Angle and mirroring travel with this frame, independent of take rotation.
            liveFrames.push(image, angle: coordinator?.videoRotationAngleForHorizonLevelCapture ?? 90, front: isFront)
            if !previewHandoffAnnounced, previewHandoff == nil, let options = try? options() {
                previewHandoffAnnounced = true
                onEvent?(.cameraChanged(options))
            }
        }
        guard let take = continuousTake, let ticket, !take.finishing else { return }
        // Lock each camera's source rotation independently from the writer canvas.
        let observed = coordinator?.videoRotationAngleForHorizonLevelCapture ?? continuousAngle
        let angle = continuousSourceAngles[isFront]
            ?? (MovieFormat.captureFormat(angle: observed) ?? .portrait).recordingAngle(observed: observed)
        continuousSourceAngles[isFront] = angle
        take.appendVideo(image, presenter: nil, presentation: nil, at: time, angle: angle, presenterAngle: angle) { [weak self, weak take] accepted, error in
            guard let self, let take, self.continuousTake === take else { return }
            if accepted, !self.continuousStarted {
                self.continuousStarted = true; self.onEvent?(.started(ticket.sceneID))
            }
            if error != nil { self.requestStop() }
        }
        if time.isNumeric, !continuousStorageCheckPending, time.seconds - continuousLastStorageCheck >= 2 {
            continuousLastStorageCheck = time.seconds; continuousStorageCheckPending = true
            let directory = take.outputURL.deletingLastPathComponent().path
            DispatchQueue.global(qos: .utility).async { [weak self, weak take] in
                let available = (try? FileManager.default.attributesOfFileSystem(forPath: directory)[.systemFreeSize]) as? NSNumber
                self?.queue.async { [weak self, weak take] in
                    guard let self else { return }; self.continuousStorageCheckPending = false
                    guard let take, self.continuousTake === take, let available, available.int64Value < 100_000_000 else { return }
                    self.onEvent?(.notice("Storage is nearly full. Finishing this take safely.")); self.requestStop()
                }
            }
        }
    }
}
