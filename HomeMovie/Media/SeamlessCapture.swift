import AVFoundation
import CoreImage

// A take has one writer, one clock and one microphone regardless of the selected camera.
// Every method and sample callback runs on CaptureService's serial capture queue.
final class ContinuousTakeWriter {
    let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let audio: AVAssetWriterInput
    private let pixels: AVAssetWriterInputPixelBufferAdaptor
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let size: CGSize
    private let angle: CGFloat
    var canvas: CGSize { size }
    var rotationAngle: CGFloat { angle }
    private var start: CMTime?
    private var lastVideo: CMTime?
    private var lastAudio: CMTime?
    private(set) var failure: Error?
    private(set) var finishing = false
    init(url: URL, angle: CGFloat) throws {
        self.angle = angle
        let portrait = abs(angle.truncatingRemainder(dividingBy: 180)) == 90
        size = portrait ? CGSize(width: 1080, height: 1920) : CGSize(width: 1920, height: 1080)
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 16_000_000,
                AVVideoExpectedSourceFrameRateKey: 30, AVVideoMaxKeyFrameIntervalKey: 30]])
        audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 128_000])
        video.expectsMediaDataInRealTime = true; audio.expectsMediaDataInRealTime = true
        pixels = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height),
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]])
        guard writer.canAdd(video), writer.canAdd(audio) else { throw HomeMovieError.message("Continuous recording is unavailable.") }
        writer.add(video); writer.add(audio)
        guard writer.startWriting() else { throw writer.error ?? HomeMovieError.message("Recording could not start.") }
    }
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
        let source = CIImage(cvPixelBuffer: buffer)
        let image = source.transformed(by: LiveLookGeometry.transform(source: source.extent.size,
            target: size, angle: sourceAngle ?? angle, front: false)).cropped(to: CGRect(origin: .zero, size: size))
        context.render(image, to: destination, bounds: CGRect(origin: .zero, size: size),
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        guard pixels.append(destination, withPresentationTime: time) else {
            failure = writer.error ?? HomeMovieError.message("Video could not be saved."); return false
        }
        lastVideo = time; return true
    }
    @discardableResult func appendRenderedVideo(_ buffer: CVPixelBuffer, at time: CMTime) -> Bool {
        if writer.status == .failed { failure = writer.error; return false }
        guard !finishing, failure == nil, time.isNumeric, lastVideo.map({ time > $0 }) ?? true else { return false }
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
        writer.finishWriting { [writer] in
            completion(priorFailure ?? (writer.status == .completed ? nil : writer.error ?? HomeMovieError.message("The take could not be finished.")))
        }
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
    private var noSpaceReported = false
    private var timeline = PiPTimeline()
    private var matcher = PiPFrameMatcher()
    private let compositor = PiPFrameRenderer()
    private var obstacles: [CGRect] = []
    private var lastVideoTime = CMTime.invalid
    private var lastPresentation = PiPPresentation()
    private var lastPresenterTime = CMTime.invalid
    private var presenterDisabled = false
    private var pressureObservations: [NSKeyValueObservation] = []
    private var thermalObserver: NSObjectProtocol?
    private var lastStorageCheck: Double = 0
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
    private var take: ContinuousTakeWriter?
    private var ticket: CaptureTicket?
    private var announcedStart = false
    var onStarted: ((UUID) -> Void)?
    var onFinished: ((CaptureTicket, Error?) -> Void)?
    var onReady: (() -> Void)?
    var onSelectionChanged: (() -> Void)?
    var onPiPPresentation: ((PiPPresentation) -> Void)?
    var onPiPLayout: ((PiPLayout) -> Void)?
    var onNotice: ((String) -> Void)?
    private let queue: DispatchQueue
    static func canPreparePiP() -> Bool {
        guard AVCaptureMultiCamSession.isMultiCamSupported else { return false }
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .builtInTrueDepthCamera], mediaType: .video, position: .unspecified)
        return discovery.supportedMultiCamDeviceSets.contains { pair in
            pair.contains { $0.position == .front } && pair.contains { $0.position == .back && $0.deviceType == .builtInWideAngleCamera }
        }
    }
    init?(queue: DispatchQueue, frames: LiveFrames, rearFrames: LiveFrames = LiveFrames(), presenterFrames: LiveFrames = LiveFrames(),
          front: Bool = true, preparedForPiP: Bool = false, layout: PiPLayout = PiPLayout(), canvasFormat: MovieFormat? = nil) {
        guard AVCaptureMultiCamSession.isMultiCamSupported else { return nil }
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .builtInTrueDepthCamera], mediaType: .video, position: .unspecified)
        guard let pair = discovery.supportedMultiCamDeviceSets.first(where: { set in
            set.contains(where: { $0.position == .front }) && set.contains(where: { $0.position == .back && $0.deviceType == .builtInWideAngleCamera })
        }), let frontCamera = pair.first(where: { $0.position == .front }),
              let backCamera = pair.first(where: { $0.position == .back && $0.deviceType == .builtInWideAngleCamera }),
              let frontInput = try? AVCaptureDeviceInput(device: frontCamera),
              let backInput = try? AVCaptureDeviceInput(device: backCamera) else { return nil }
        self.frontInput = frontInput; self.backInput = backInput; self.queue = queue; self.frames = frames
        self.rearFrames = rearFrames; self.presenterFrames = presenterFrames
        self.front = front; self.preparedForPiP = preparedForPiP; timeline.setLayout(layout); preferredCanvas = canvasFormat
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
            let formats = camera.formats.filter { format in
                let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                return format.isMultiCamSupported && dimensions.width == 1920 && dimensions.height == 1080 &&
                    format.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }
            }
            guard let format = formats.first else { throw HomeMovieError.message("Dual-camera 1080p recording is unavailable.") }
            try camera.lockForConfiguration()
            camera.activeFormat = format
            camera.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
            camera.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
            camera.automaticallyAdjustsVideoHDREnabled = false
            if format.isVideoHDRSupported { camera.isVideoHDREnabled = false }
            if format.supportedColorSpaces.contains(.sRGB) { camera.activeColorSpace = .sRGB }
            if camera.isFocusModeSupported(.continuousAutoFocus) { camera.focusMode = .continuousAutoFocus }
            CameraVideoTuning.configureFocus(camera)
            if camera.isExposureModeSupported(.continuousAutoExposure) { camera.exposureMode = .continuousAutoExposure }
            if camera.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { camera.whiteBalanceMode = .continuousAutoWhiteBalance }
            if camera.isFocusPointOfInterestSupported { camera.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5) }
            if camera.isExposurePointOfInterestSupported { camera.exposurePointOfInterest = CGPoint(x: 0.5, y: 0.5) }
            camera.videoZoomFactor = min(camera.maxAvailableVideoZoomFactor, max(camera.minAvailableVideoZoomFactor, 1 / camera.displayVideoZoomFactorMultiplier))
            camera.setExposureTargetBias(0, completionHandler: nil)
            camera.unlockForConfiguration()
            guard session.canAddInput(input), session.canAddOutput(output) else { throw HomeMovieError.message("Dual cameras could not be connected.") }
            session.addInputWithNoConnections(input); session.addOutputWithNoConnections(output)
            guard let port = input.ports.first(where: { $0.mediaType == .video }) else { throw HomeMovieError.message("Camera port unavailable.") }
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: queue)
            let connection = AVCaptureConnection(inputPorts: [port], output: output)
            guard session.canAddConnection(connection) else { throw HomeMovieError.message("Camera connection unavailable.") }
            session.addConnection(connection)
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
    @discardableResult func flip() -> Bool {
        guard readyToFlip, take?.finishing != true, !timeline.enabled else { return false }
        front.toggle()
        if let image = front ? frontFrame : backFrame { frames.push(image, angle: previewAngle) }
        return true
    }
    func record(ticket: CaptureTicket, url: URL, angle: CGFloat) throws {
        guard take == nil, session.isRunning else { throw HomeMovieError.message("The camera is not ready.") }
        take = try ContinuousTakeWriter(url: url, angle: angle); self.ticket = ticket; announcedStart = false
        let frontObserved = frontRotation?.videoRotationAngleForHorizonLevelCapture ?? angle
        let rearObserved = backRotation?.videoRotationAngleForHorizonLevelCapture ?? angle
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
        guard let image = CMSampleBufferGetImageBuffer(sample) else { return }
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
        if timeline.enabled, lastPresenterTime.isNumeric, CMTimeSubtract(time, lastPresenterTime).seconds > 0.3 {
            timeline.setEnabled(false, at: time); onReady?()
            onNotice?("The presenter camera paused. Rear video and audio are still recording.")
        }
        let presentation = timeline.presentation(at: time, canvas: geometryCanvas, obstacles: obstacles)
        if timeline.enabled, !presentation.isPlaceable, !noSpaceReported {
            noSpaceReported = true
            onNotice?("PiP is hidden while the camera controls cover its available space. Close Dolly or choose Small before the next take.")
        } else if presentation.isPlaceable { noSpaceReported = false }
        if presentation != lastPresentation { lastPresentation = presentation; onPiPPresentation?(presentation) }
        let composing = timeline.enabled || presentation.opacity > 0
        var accepted = false
        if composing {
            let angle = take == nil ? previewAngle : (front ? recordedPresenterAngle : recordedRearAngle)
            let frontObserved = frontRotation?.videoRotationAngleForHorizonLevelCapture ?? angle
            let frontAngle = take == nil ? (MovieFormat.captureFormat(angle: frontObserved) ?? .portrait).recordingAngle(observed: frontObserved) : recordedPresenterAngle
            let presenter = matcher.frame(at: time)
            // Publish raw paired frames immediately. Display composition is independent
            // of the full-resolution recording buffer and stays latest-frame-only.
            frames.push(image, angle: previewAngle, pip: LivePiPFrame(presenter: presenter,
                backgroundAngle: angle, presenterAngle: frontAngle, presentation: presentation))
            if let take, !take.finishing {
                let composition = PiPCompositor.image(background: image, presenter: presenter, canvas: take.canvas,
                    backgroundAngle: angle, presenterAngle: frontAngle, presentation: presentation)
                if let rendered = compositor.render(composition, canvas: take.canvas) {
                    accepted = take.appendRenderedVideo(rendered, at: time)
                } else {
                    // Optional composition failure preserves the main video/audio clock.
                    accepted = take.appendVideo(image, at: time, sourceAngle: angle)
                    if timeline.enabled {
                        timeline.setEnabled(false, at: time); onReady?()
                        onNotice?("PiP paused because the composition could not be rendered. Rear recording continues.")
                    }
                }
            }
        } else {
            frames.push(image, angle: previewAngle)
            accepted = take?.appendVideo(image, at: time, sourceAngle: front ? recordedPresenterAngle : recordedRearAngle) ?? false
        }
        if let ticket, accepted, !announcedStart {
            announcedStart = true; onStarted?(ticket.sceneID)
        }
        if take?.failure != nil { stop() }
        if take != nil, time.seconds - lastStorageCheck >= 2 {
            lastStorageCheck = time.seconds
            if let available = try? FileManager.default.attributesOfFileSystem(forPath: take!.writer.outputURL.deletingLastPathComponent().path)[.systemFreeSize] as? NSNumber,
               available.int64Value < 100_000_000 {
                onNotice?("Storage is nearly full. Finishing this take safely."); stop()
            }
        }
    }
}
