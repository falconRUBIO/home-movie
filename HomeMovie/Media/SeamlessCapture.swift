import AVFoundation
import CoreImage

// A take has one writer, one clock and one microphone regardless of the selected camera.
// Each writer is confined to one serial queue; the capture pipeline uses a dedicated writing queue.
final class ContinuousTakeWriter {
    let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let audio: AVAssetWriterInput
    private let pixels: AVAssetWriterInputPixelBufferAdaptor
    private let context: CIContext
    private let profile: CaptureProfile
    private let size: CGSize
    private let angle: CGFloat
    var canvas: CGSize { size }
    var rotationAngle: CGFloat { angle }
    private var start: CMTime?
    private var lastVideo: CMTime?
    private var lastAudio: CMTime?
    private(set) var failure: Error?
    private(set) var finishing = false
    init(url: URL, angle: CGFloat, profile: CaptureProfile = .standard) throws {
        self.profile = profile
        context = CIContext(options: profile == .appleLog ? LogPiPColor.contextOptions() : [.cacheIntermediates: false])
        self.angle = angle
        let portrait = abs(angle.truncatingRemainder(dividingBy: 180)) == 90
        size = portrait ? CGSize(width: 1080, height: 1920) : CGSize(width: 1920, height: 1080)
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        // Periodic MOV fragments improve salvage after termination; finalization is still required for a complete take.
        writer.movieFragmentInterval = CMTime(value: 1, timescale: 1)
        let standardSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 16_000_000,
                AVVideoExpectedSourceFrameRateKey: 30, AVVideoMaxKeyFrameIntervalKey: 30]]
        let videoSettings = profile == .appleLog ? LogPiPColor.videoSettings(canvas: size) : standardSettings
        guard profile == .standard || writer.canApply(outputSettings: videoSettings, forMediaType: .video) else {
            throw HomeMovieError.message("This iOS encoder cannot write the requested 10-bit Apple Log settings. Use the ordinary camera.")
        }
        video = AVAssetWriterInput(mediaType: .video,
            outputSettings: videoSettings,
            sourceFormatHint: profile == .appleLog ? try LogPiPColor.sourceHint(canvas: size) : nil)
        audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 128_000])
        video.expectsMediaDataInRealTime = true; audio.expectsMediaDataInRealTime = true
        pixels = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: profile == .appleLog ? LogPiPColor.pixelFormat : kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height),
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]])
        guard writer.canAdd(video), writer.canAdd(audio) else { throw HomeMovieError.message("Continuous recording is unavailable.") }
        writer.add(video); writer.add(audio)
        guard writer.startWriting() else { throw writer.error ?? HomeMovieError.message("Recording could not start.") }
    }
    var canAcceptVideo: Bool { !finishing && failure == nil && video.isReadyForMoreMediaData }
    @discardableResult func appendVideo(_ buffer: CVPixelBuffer, at time: CMTime, sourceAngle: CGFloat? = nil) -> Bool {
        if writer.status == .failed { failure = writer.error; return false }
        guard !finishing, failure == nil, time.isNumeric, lastVideo.map({ time > $0 }) ?? true else { return false }
        guard video.isReadyForMoreMediaData else { return false }
        if start == nil { writer.startSession(atSourceTime: time); start = time }
        guard let pool = pixels.pixelBufferPool else { return false }
        var destination: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool,
            [kCVPixelBufferPoolAllocationThresholdKey as String: 8] as CFDictionary, &destination) == kCVReturnSuccess,
              let destination else { return false }
        if profile == .appleLog, !LogPiPColor.isLog(buffer) {
            failure = HomeMovieError.message("The camera stopped delivering verified 10-bit Apple Log frames."); return false
        }
        let source = CIImage(cvPixelBuffer: buffer, options: profile == .appleLog ? [.colorSpace: NSNull()] : [:])
        let image = source.transformed(by: LiveLookGeometry.transform(source: source.extent.size,
            target: size, angle: sourceAngle ?? angle, front: false)).cropped(to: CGRect(origin: .zero, size: size))
        if profile == .appleLog { LogPiPColor.attach(to: destination) }
        context.render(image, to: destination, bounds: CGRect(origin: .zero, size: size),
            colorSpace: profile == .appleLog ? nil : CGColorSpace(name: CGColorSpace.sRGB))
        if profile == .appleLog { LogPiPColor.attach(to: destination) }
        guard pixels.append(destination, withPresentationTime: time) else {
            failure = writer.error ?? HomeMovieError.message("Video could not be saved."); return false
        }
        lastVideo = time; return true
    }
    @discardableResult func appendRenderedVideo(_ buffer: CVPixelBuffer, at time: CMTime) -> Bool {
        if writer.status == .failed { failure = writer.error; return false }
        guard !finishing, failure == nil, time.isNumeric, lastVideo.map({ time > $0 }) ?? true else { return false }
        if profile == .appleLog, !LogPiPColor.isLog(buffer) {
            failure = HomeMovieError.message("The composition is not verified 10-bit Apple Log."); return false
        }
        guard CVPixelBufferGetWidth(buffer) == Int(size.width), CVPixelBufferGetHeight(buffer) == Int(size.height) else {
            failure = HomeMovieError.message("The camera composition changed size during recording."); return false
        }
        guard video.isReadyForMoreMediaData else { return false }
        if start == nil { writer.startSession(atSourceTime: time); start = time }
        guard pixels.append(buffer, withPresentationTime: time) else {
            failure = writer.error ?? HomeMovieError.message("The camera composition could not be saved."); return false
        }
        lastVideo = time; return true
    }
    func appendAudio(_ sample: CMSampleBuffer) {
        let time = CMSampleBufferGetPresentationTimeStamp(sample)
        guard !finishing, failure == nil, let start, time.isNumeric, time >= start,
              lastAudio.map({ time > $0 }) ?? true, audio.isReadyForMoreMediaData else { return }
        if audio.append(sample) { lastAudio = time }
        else { failure = writer.error ?? HomeMovieError.message("Audio could not be saved.") }
    }
    func finish(_ completion: @escaping @Sendable (Error?) -> Void) {
        guard !finishing else { return }; finishing = true
        guard start != nil else {
            writer.cancelWriting(); completion(HomeMovieError.message("No camera frames were recorded.")); return
        }
        guard writer.status == .writing else {
            completion(failure ?? writer.error ?? HomeMovieError.message("The take could not be finished.")); return
        }
        video.markAsFinished(); audio.markAsFinished()
        let priorFailure = failure
        let recordedProfile = profile, canvas = size, url = writer.outputURL
        writer.finishWriting { [writer] in
            let error = priorFailure ?? (writer.status == .completed ? nil : writer.error ?? HomeMovieError.message("The take could not be finished."))
            guard error == nil, recordedProfile == .appleLog else { completion(error); return }
            Task {
                do { try await LogPiPValidation.verifySavedFile(url: url, expectedCanvas: canvas); completion(nil) }
                catch { completion(error) }
            }
        }
    }
}

// Capture never waits for rendering/encoding. One video job and a bounded number of
// audio jobs may be outstanding; all writer mutations and finish remain ordered.
final class ContinuousTakePipeline: @unchecked Sendable {
    private let writer: ContinuousTakeWriter
    private let compositor: PiPFrameRenderer
    private let profile: CaptureProfile
    private let writingQueue: DispatchQueue
    private let onPiPFallback: (@Sendable () -> Void)?
    private let renderPiP: ((CIImage, CGSize) -> CVPixelBuffer?)?
    private var reportedPiPFallback = false // Writing queue only.
    private let videoSlot = DispatchSemaphore(value: 1)
    private let audioSlots = DispatchSemaphore(value: 8)
    private let callbackQueue: DispatchQueue
    let canvas: CGSize
    let outputURL: URL
    private(set) var finishing = false // Capture queue only.
    init(url: URL, angle: CGFloat, profile: CaptureProfile = .standard, callbackQueue: DispatchQueue,
         writingQueue: DispatchQueue = DispatchQueue(label: "HomeMovie.continuousWriter", qos: .userInitiated, autoreleaseFrequency: .workItem),
         onPiPFallback: (@Sendable () -> Void)? = nil,
         renderPiP: ((CIImage, CGSize) -> CVPixelBuffer?)? = nil) throws {
        self.profile = profile; compositor = PiPFrameRenderer(profile: profile)
        writer = try ContinuousTakeWriter(url: url, angle: angle, profile: profile)
        canvas = writer.canvas; outputURL = url; self.callbackQueue = callbackQueue; self.writingQueue = writingQueue
        self.onPiPFallback = onPiPFallback; self.renderPiP = renderPiP
    }
    @discardableResult func appendVideo(_ image: CVPixelBuffer, presenter: CVPixelBuffer?, presentation: PiPPresentation?,
                     at time: CMTime, angle: CGFloat, presenterAngle: CGFloat,
                     completion: @escaping @Sendable (Bool, Error?) -> Void) -> Bool {
        guard !finishing, videoSlot.wait(timeout: .now()) == .success else { return false }
        writingQueue.async { [self] in
            defer { videoSlot.signal() }
            autoreleasepool {
                if profile == .appleLog, !LogPiPColor.isLog(image) || presenter.map({ !LogPiPColor.isLog($0) }) == true {
                    callbackQueue.async { completion(false, HomeMovieError.message("Both PiP inputs must be verified 10-bit Apple Log.")) }
                    return
                }
                let accepted: Bool
                if !writer.canAcceptVideo { accepted = false }
                else if let presentation {
                    let composition = PiPCompositor.image(background: image, presenter: presenter, canvas: canvas,
                        backgroundAngle: angle, presenterAngle: presenterAngle, presentation: presentation, profile: profile)
                    let rendered: CVPixelBuffer?
                    if let renderPiP { rendered = renderPiP(composition, canvas) }
                    else { rendered = compositor.render(composition, canvas: canvas) }
                    if let rendered {
                        accepted = writer.appendRenderedVideo(rendered, at: time)
                    } else {
                        accepted = writer.appendVideo(image, at: time, sourceAngle: angle)
                        if accepted, presentation.opacity > 0, !reportedPiPFallback {
                            reportedPiPFallback = true
                            if let onPiPFallback { callbackQueue.async(execute: onPiPFallback) }
                        }
                    }
                } else { accepted = writer.appendVideo(image, at: time, sourceAngle: angle) }
                let failure = writer.failure ?? (writer.writer.status == .failed ? writer.writer.error : nil)
                callbackQueue.async { completion(accepted, failure) }
            }
        }
        return true
    }
    func appendAudio(_ sample: CMSampleBuffer) {
        guard !finishing, audioSlots.wait(timeout: .now()) == .success else { return }
        writingQueue.async { [self] in
            defer { audioSlots.signal() }; autoreleasepool { writer.appendAudio(sample) }
        }
    }
    func finish(_ completion: @escaping @Sendable (Error?) -> Void) {
        guard !finishing else { return }; finishing = true
        writingQueue.async { [self] in writer.finish(completion) }
    }
}

// Prepared before recording: a flip changes frame selection, never the capture graph.
final class SeamlessCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureMultiCamSession()
    let frontInput: AVCaptureDeviceInput
    let backInput: AVCaptureDeviceInput
    private let frontOutput = AVCaptureVideoDataOutput()
    private let backOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let frames: LiveFrames
    let rearFrames: LiveFrames
    let presenterFrames: LiveFrames
    private var frontRotation: AVCaptureDevice.RotationCoordinator?
    private var backRotation: AVCaptureDevice.RotationCoordinator?
    private var recordedPresenterAngle: CGFloat = 90
    private var recordedRearAngle: CGFloat = 90
    private var pendingPiPEnable = false
    private var presenterStallReported = false
    private var timeline = PiPTimeline()
    private var matcher = PiPFrameMatcher()
    private let frontCopies = CaptureFrameCopy()
    private let backCopies = CaptureFrameCopy()
    private var obstacles: [CGRect] = []
    private var lastVideoTime = CMTime.invalid
    private var lastPresentation = PiPPresentation()
    private var lastPresenterTime = CMTime.invalid
    private var presenterDisabled = false
    private var pressureObservations: [NSKeyValueObservation] = []
    private var thermalObserver: NSObjectProtocol?
    private var lastStorageCheck: Double = 0
    private var storageCheckPending = false
    let profile: CaptureProfile
    let preparedForPiP: Bool
    private var preferredCanvas: MovieFormat?
    var canvasFormat: MovieFormat? { preferredCanvas }
    var supportsPiP: Bool { readyToFlip && !presenterDisabled }
    var pipEnabled: Bool { timeline.enabled }
    var pipLayout: PiPLayout { timeline.layout }
    var needsPiPReprepare: Bool { presenterDisabled }
    private var frontReady = false
    private var backReady = false
    private var frontFrame: CVPixelBuffer?
    private var backFrame: CVPixelBuffer?
    private(set) var front = true
    var activeInput: AVCaptureDeviceInput { front ? frontInput : backInput }
    var readyToFlip: Bool { frontReady && backReady && !presenterDisabled }
    private var take: ContinuousTakePipeline?
    private var ticket: CaptureTicket?
    private var announcedStart = false
    var onStarted: ((UUID) -> Void)?
    var onFinished: ((CaptureTicket, Error?) -> Void)?
    var onReady: (() -> Void)?
    var onSelectionChanged: (() -> Void)?
    var onPiPPresentation: ((PiPPresentation) -> Void)?
    var onPiPLayout: ((PiPLayout) -> Void)?
    var onNotice: ((String) -> Void)?
    var onLogFailure: ((String) -> Void)?
    private var reportedInvalidLog = false
    private let queue: DispatchQueue
    // Prefer the square Center Stage sensor only when its formats support MultiCam.
    // Keep the full square feed fixed; both preview and writer crop it identically.
    // Switching the device aspect ratio during a take would change source dimensions.
    private static func captureFormat(for camera: AVCaptureDevice, profile: CaptureProfile = .standard) -> AVCaptureDevice.Format? {
        let formats = camera.formats.filter {
            $0.isMultiCamSupported && (profile == .standard || CameraCompatibility.supportsLog($0)) && $0.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }
        }
        if camera.position == .front, #available(iOS 26.0, *) {
            let square = formats.filter {
                let size = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
                return size.width == size.height && size.width >= 1280 && size.width <= 2160 &&
                    $0.supportedDynamicAspectRatios.contains(.ratio1x1)
            }.sorted {
                CMVideoFormatDescriptionGetDimensions($0.formatDescription).width < CMVideoFormatDescriptionGetDimensions($1.formatDescription).width
            }
            if let format = square.first { return format }
        }
        return formats.filter {
            let size = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            return CameraCompatibility.isHD(width: size.width, height: size.height)
        }.sorted {
            let a = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            let b = CMVideoFormatDescriptionGetDimensions($1.formatDescription)
            return Int64(a.width) * Int64(a.height) < Int64(b.width) * Int64(b.height)
        }.first
    }
    private static func cameraPair(profile: CaptureProfile = .standard) -> (front: AVCaptureDevice, back: AVCaptureDevice)? {
        guard AVCaptureMultiCamSession.isMultiCamSupported else { return nil }
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTrueDepthCamera], mediaType: .video, position: .unspecified)
        let pairs = discovery.supportedMultiCamDeviceSets.compactMap { set -> (front: AVCaptureDevice, back: AVCaptureDevice)? in
            guard let front = set.first(where: { $0.position == .front && captureFormat(for: $0, profile: profile) != nil }),
                  let back = set.filter({ $0.position == .back && captureFormat(for: $0, profile: profile) != nil })
                    .sorted(by: { ($0.deviceType == .builtInWideAngleCamera ? 0 : 1) < ($1.deviceType == .builtInWideAngleCamera ? 0 : 1) }).first else { return nil }
            return (front, back)
        }
        return pairs.sorted {
            let a = ($0.back.deviceType == .builtInWideAngleCamera ? 0 : 2) + ($0.front.deviceType == .builtInUltraWideCamera ? 0 : 1)
            let b = ($1.back.deviceType == .builtInWideAngleCamera ? 0 : 2) + ($1.front.deviceType == .builtInUltraWideCamera ? 0 : 1)
            return a == b ? $0.front.uniqueID < $1.front.uniqueID : a < b
        }.first
    }
    static func canPreparePiP(profile: CaptureProfile = .standard) -> Bool { cameraPair(profile: profile) != nil }
    init?(queue: DispatchQueue, frames: LiveFrames, rearFrames: LiveFrames = LiveFrames(), presenterFrames: LiveFrames = LiveFrames(),
          front: Bool = true, profile: CaptureProfile = .standard, preparedForPiP: Bool = false, layout: PiPLayout = PiPLayout(), canvasFormat: MovieFormat? = nil) {
        guard let pair = Self.cameraPair(profile: profile),
              case let frontCamera = pair.front, case let backCamera = pair.back,
              let frontInput = try? AVCaptureDeviceInput(device: frontCamera),
              let backInput = try? AVCaptureDeviceInput(device: backCamera) else { return nil }
        self.frontInput = frontInput; self.backInput = backInput; self.queue = queue; self.frames = frames
        self.rearFrames = rearFrames; self.presenterFrames = presenterFrames
        self.front = front; self.profile = profile; self.preparedForPiP = preparedForPiP; timeline.setLayout(layout); preferredCanvas = canvasFormat
        super.init()
        do { try configure() } catch { return nil }
        guard session.hardwareCost <= 1, session.systemPressureCost <= 1 else { return nil }
        if preparedForPiP, ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical { return nil }
        frontRotation = AVCaptureDevice.RotationCoordinator(device: frontCamera, previewLayer: nil)
        backRotation = AVCaptureDevice.RotationCoordinator(device: backCamera, previewLayer: nil)
        for camera in [frontCamera, backCamera] {
            pressureObservations.append(camera.observe(\.systemPressureState, options: [.new]) { [weak self] _, change in
                let level = change.newValue?.level
                self?.queue.async { [weak self] in
                    if level == .serious || level == .critical || level == .shutdown { self?.suspendPresenter() }
                }
            })
        }
        thermalObserver = NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.queue.async { [weak self] in
                if ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical { self?.suspendPresenter() }
            }
        }
    }
    deinit { if let thermalObserver { NotificationCenter.default.removeObserver(thermalObserver) } }
    private func configure() throws {
        session.beginConfiguration(); defer { session.commitConfiguration() }
        session.automaticallyConfiguresApplicationAudioSession = false
        session.automaticallyConfiguresCaptureDeviceForWideColor = false
        for (input, output) in [(frontInput, frontOutput), (backInput, backOutput)] {
            let camera = input.device
            guard let format = Self.captureFormat(for: camera, profile: profile) else { throw HomeMovieError.message("Dual-camera 1080p recording is unavailable.") }
            try camera.lockForConfiguration()
            camera.activeFormat = format
            if camera.position == .front, #available(iOS 26.0, *), format.supportedDynamicAspectRatios.contains(.ratio1x1) {
                camera.setDynamicAspectRatio(.ratio1x1, completionHandler: nil)
            }
            camera.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
            camera.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
            camera.automaticallyAdjustsVideoHDREnabled = false
            if format.isVideoHDRSupported { camera.isVideoHDREnabled = false }
            if profile == .appleLog { camera.activeColorSpace = .appleLog }
            else if format.supportedColorSpaces.contains(.sRGB) { camera.activeColorSpace = .sRGB }
            if camera.isFocusModeSupported(.continuousAutoFocus) { camera.focusMode = .continuousAutoFocus }
            CameraVideoTuning.configureFocus(camera)
            if camera.isExposureModeSupported(.continuousAutoExposure) { camera.exposureMode = .continuousAutoExposure }
            if camera.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { camera.whiteBalanceMode = .continuousAutoWhiteBalance }
            if camera.isFocusPointOfInterestSupported { camera.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5) }
            if camera.isExposurePointOfInterestSupported { camera.exposurePointOfInterest = CGPoint(x: 0.5, y: 0.5) }
            camera.videoZoomFactor = camera.position == .front ? camera.minAvailableVideoZoomFactor :
                min(camera.maxAvailableVideoZoomFactor, max(camera.minAvailableVideoZoomFactor, 1 / camera.displayVideoZoomFactorMultiplier))
            camera.setExposureTargetBias(0, completionHandler: nil)
            camera.unlockForConfiguration()
            guard session.canAddInput(input), session.canAddOutput(output) else { throw HomeMovieError.message("Dual cameras could not be connected.") }
            session.addInputWithNoConnections(input); session.addOutputWithNoConnections(output)
            guard let port = input.ports.first(where: { $0.mediaType == .video }) else { throw HomeMovieError.message("Camera port unavailable.") }
            let pixelFormat = profile == .appleLog ? LogPiPColor.pixelFormat : kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: queue)
            let connection = AVCaptureConnection(inputPorts: [port], output: output)
            guard session.canAddConnection(connection) else { throw HomeMovieError.message("Camera connection unavailable.") }
            session.addConnection(connection)
            // Query after connection so the output reports this camera's formats.
            guard output.availableVideoPixelFormatTypes.contains(pixelFormat) else { throw HomeMovieError.message("This camera cannot deliver the required dual-camera pixel format.") }
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat]
            connection.automaticallyAdjustsVideoMirroring = false
            if connection.isVideoMirroringSupported { connection.isVideoMirrored = false }
            if connection.isVideoRotationAngleSupported(0) { connection.videoRotationAngle = 0 }
            if connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = CameraStabilization.dualCameraMode(front: camera.position == .front,
                    supports: { format.isVideoStabilizationModeSupported($0) })
            }
        }
        guard let microphone = AVCaptureDevice.default(for: .audio) else { throw HomeMovieError.message("Microphone unavailable.") }
        let micInput = try AVCaptureDeviceInput(device: microphone)
        guard session.canAddInput(micInput), session.canAddOutput(audioOutput) else { throw HomeMovieError.message("Microphone could not be connected.") }
        session.addInputWithNoConnections(micInput); session.addOutputWithNoConnections(audioOutput)
        // Keep exactly this microphone port for the entire take; no front/rear audio steering.
        guard let port = micInput.ports.first(where: { $0.mediaType == .audio }) else { throw HomeMovieError.message("Microphone port unavailable.") }
        let connection = AVCaptureConnection(inputPorts: [port], output: audioOutput)
        guard session.canAddConnection(connection) else { throw HomeMovieError.message("Microphone connection unavailable.") }
        session.addConnection(connection); audioOutput.setSampleBufferDelegate(self, queue: queue)
        guard session.hardwareCost <= 1, session.systemPressureCost <= 1 else { throw HomeMovieError.message("Dual-camera recording exceeds this device's capacity.") }
    }
    func verifyLogConfiguration() throws {
        guard profile == .appleLog else { return }
        guard [frontInput, backInput].allSatisfy({ $0.device.activeColorSpace == .appleLog && $0.device.activeFormat.isMultiCamSupported }),
              [frontOutput, backOutput].allSatisfy({ ($0.videoSettings[kCVPixelBufferPixelFormatTypeKey as String] as? OSType) == LogPiPColor.pixelFormat }) else {
            throw HomeMovieError.message("Both cameras must remain in 10-bit Apple Log for Log PiP.")
        }
    }
    @discardableResult func flip() -> Bool {
        guard readyToFlip, take?.finishing != true, !timeline.enabled else { return false }
        front.toggle()
        if let image = front ? frontFrame : backFrame { frames.push(image, angle: previewAngle, front: front) }
        return true
    }
    func record(ticket: CaptureTicket, url: URL, angle: CGFloat) throws {
        try verifyLogConfiguration()
        guard take == nil, session.isRunning, profile == .standard || readyToFlip else { throw HomeMovieError.message("The camera is not ready.") }
        take = try ContinuousTakePipeline(url: url, angle: angle, profile: profile, callbackQueue: queue,
            onPiPFallback: { [weak self] in
                self?.onNotice?("Some frames were saved without PiP because the inset could not render. Main video and audio continue.")
            }); self.ticket = ticket; announcedStart = false
        let frontObserved = frontRotation?.videoRotationAngleForHorizonLevelCapture ?? angle
        let rearObserved = backRotation?.videoRotationAngleForHorizonLevelCapture ?? angle
        // Keep source sensor compensation independent of the output canvas.
        recordedPresenterAngle = (MovieFormat.captureFormat(angle: frontObserved) ?? .portrait).recordingAngle(observed: frontObserved)
        recordedRearAngle = (MovieFormat.captureFormat(angle: rearObserved) ?? .portrait).recordingAngle(observed: rearObserved)
    }
    func configurePiP(layout: PiPLayout, canvasFormat: MovieFormat?) {
        guard take == nil else { return }
        timeline.setLayout(layout); preferredCanvas = canvasFormat
    }
    private var previewAngle: CGFloat {
        let observed = (front ? frontRotation : backRotation)?.videoRotationAngleForHorizonLevelCapture ?? 90
        return (MovieFormat.captureFormat(angle: observed) ?? .portrait).recordingAngle(observed: observed)
    }
    private var geometryCanvas: CGSize { take?.canvas ?? (preferredCanvas ?? MovieFormat.captureFormat(angle: previewAngle) ?? .portrait).canvas }
    private var eventTime: CMTime { lastVideoTime.isNumeric ? lastVideoTime : CMClockGetTime(session.synchronizationClock ?? CMClockGetHostTimeClock()) }
    func setPiPEnabled(_ enabled: Bool) {
        if enabled, !readyToFlip, !presenterDisabled, take == nil { pendingPiPEnable = true; return }
        guard !enabled || supportsPiP else { onNotice?("The presenter camera is not ready. Rear recording continues."); return }
        pendingPiPEnable = false
        if enabled, front { front = false; onSelectionChanged?() }
        timeline.setEnabled(enabled, at: eventTime); onReady?()
    }
    func setPiPObstacles(_ obstacles: [CGRect]) { self.obstacles = Array(obstacles.prefix(32)) }
    func dragPiP(to point: CGPoint, finished: Bool) {
        guard timeline.enabled else { return }
        timeline.drag(to: point, at: eventTime, canvas: geometryCanvas, obstacles: obstacles)
        if finished { onPiPLayout?(timeline.settle(at: eventTime, canvas: geometryCanvas, obstacles: obstacles)) }
    }
    private func suspendPresenter() {
        guard preparedForPiP || timeline.enabled, !presenterDisabled else { return }
        ReliabilityDiagnostics.shared.record(.resourcePressure)
        presenterDisabled = true
        timeline.setEnabled(false, at: eventTime)
        frontOutput.connection(with: .video)?.isEnabled = false
        frontFrame = nil; matcher.clear(); presenterFrames.clear()
        if front { front = false; onSelectionChanged?() }
        onReady?(); onNotice?("PiP paused to keep this recording safe as the iPhone warms up. Rear video and audio continue.")
    }
    func stop() {
        guard let take, let ticket, !take.finishing else { return }
        take.finish { [weak self] error in
            self?.queue.async { [weak self] in
                guard let self else { return }; self.take = nil; self.ticket = nil
                self.onFinished?(ticket, error)
            }
        }
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === audioOutput { take?.appendAudio(sample); return }
        // Disabling a connection does not cancel frames already queued for delivery.
        guard output !== frontOutput || !presenterDisabled else { return }
        guard profile == .standard || LogPiPColor.verifyCapture(sample) else {
            if !reportedInvalidLog {
                reportedInvalidLog = true
                if take != nil { onNotice?("A camera stopped delivering 10-bit Log. Finishing this take safely."); stop() }
                else { onLogFailure?("A camera did not deliver verified 10-bit Apple Log frames. Use the ordinary camera and retry Log PiP later.") }
            }
            return
        }
        guard let source = CMSampleBufferGetImageBuffer(sample),
              let image = (output === frontOutput ? frontCopies : backCopies).copy(source) else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sample)
        guard time.isNumeric else { return }
        let wasReady = readyToFlip
        if output === frontOutput {
            frontReady = true; frontFrame = image; matcher.push(image, at: time); lastPresenterTime = time
            presenterFrames.push(image, angle: frontRotation?.videoRotationAngleForHorizonLevelCapture)
        } else { backReady = true; backFrame = image; rearFrames.push(image, angle: backRotation?.videoRotationAngleForHorizonLevelCapture) }
        if !wasReady && readyToFlip {
            if pendingPiPEnable { setPiPEnabled(true) }
            onReady?()
        }
        guard output === (front ? frontOutput : backOutput) else { return }
        lastVideoTime = time
        let presenterStalled = timeline.enabled && lastPresenterTime.isNumeric && CMTimeSubtract(time, lastPresenterTime).seconds > 0.5
        if presenterStalled, !presenterStallReported {
            presenterStallReported = true
            onNotice?("The presenter camera paused. Rear video and audio continue; PiP resumes when fresh frames arrive.")
        } else if !presenterStalled { presenterStallReported = false }
        let presentation = timeline.presentation(at: time, canvas: geometryCanvas, obstacles: obstacles)
        if presentation != lastPresentation { lastPresentation = presentation; onPiPPresentation?(presentation) }
        let composing = timeline.enabled || presentation.opacity > 0
        if composing {
            let angle = take == nil ? previewAngle : (front ? recordedPresenterAngle : recordedRearAngle)
            let frontObserved = frontRotation?.videoRotationAngleForHorizonLevelCapture ?? angle
            let frontAngle = take == nil ? (MovieFormat.captureFormat(angle: frontObserved) ?? .portrait).recordingAngle(observed: frontObserved) : recordedPresenterAngle
            let presenter = matcher.frame(at: time)
            // Publish raw paired frames immediately. Display composition is independent
            // of the full-resolution recording buffer and stays latest-frame-only.
            frames.push(image, angle: previewAngle, pip: LivePiPFrame(presenter: presenter,
                backgroundAngle: angle, presenterAngle: frontAngle, presentation: presentation))
            enqueueRecording(image, presenter: presenter, presentation: presentation, at: time,
                angle: angle, presenterAngle: frontAngle)
        } else {
            frames.push(image, angle: previewAngle, front: front)
            enqueueRecording(image, presenter: nil, presentation: nil, at: time,
                angle: front ? recordedPresenterAngle : recordedRearAngle, presenterAngle: recordedPresenterAngle)
        }
        if let take, !storageCheckPending, time.seconds - lastStorageCheck >= 2 {
            lastStorageCheck = time.seconds; storageCheckPending = true
            let directory = take.outputURL.deletingLastPathComponent().path
            DispatchQueue.global(qos: .utility).async { [weak self, weak take] in
                let available = (try? FileManager.default.attributesOfFileSystem(forPath: directory)[.systemFreeSize]) as? NSNumber
                self?.queue.async { [weak self, weak take] in
                    guard let self else { return }; self.storageCheckPending = false
                    guard let take, self.take === take, let available, available.int64Value < 100_000_000 else { return }
                    self.onNotice?("Storage is nearly full. Finishing this take safely."); self.stop()
                }
            }
        }
    }

    private func enqueueRecording(_ image: CVPixelBuffer, presenter: CVPixelBuffer?, presentation: PiPPresentation?,
                                  at time: CMTime, angle: CGFloat, presenterAngle: CGFloat) {
        guard let take, let ticket else { return }
        take.appendVideo(image, presenter: presenter, presentation: presentation, at: time,
            angle: angle, presenterAngle: presenterAngle) { [weak self, weak take] accepted, error in
            guard let self, let take, self.take === take else { return }
            if accepted, !self.announcedStart {
                self.announcedStart = true; self.onStarted?(ticket.sceneID)
            }
            if error != nil { self.stop() }
        }
    }

}

