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
    @discardableResult func appendVideo(_ buffer: CVPixelBuffer, at time: CMTime) -> Bool {
        guard !finishing, failure == nil, time.isNumeric, lastVideo.map({ time > $0 }) ?? true else { return false }
        if start == nil { writer.startSession(atSourceTime: time); start = time }
        guard video.isReadyForMoreMediaData, let pool = pixels.pixelBufferPool else { return false }
        var destination: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &destination) == kCVReturnSuccess,
              let destination else { return false }
        let source = CIImage(cvPixelBuffer: buffer)
        let image = source.transformed(by: LiveLookGeometry.transform(source: source.extent.size,
            target: size, angle: angle, front: false)).cropped(to: CGRect(origin: .zero, size: size))
        context.render(image, to: destination, bounds: CGRect(origin: .zero, size: size),
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        guard pixels.append(destination, withPresentationTime: time) else {
            failure = writer.error ?? HomeMovieError.message("Video could not be saved."); return false
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
        video.markAsFinished(); audio.markAsFinished()
        let priorFailure = failure
        writer.finishWriting { [writer] in
            completion(priorFailure ?? (writer.status == .completed ? nil : writer.error ?? HomeMovieError.message("The take could not be finished.")))
        }
    }
}

// Prepared before recording: a flip changes frame selection, never the capture graph.
final class SeamlessCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    let session = AVCaptureMultiCamSession()
    let frontInput: AVCaptureDeviceInput
    let backInput: AVCaptureDeviceInput
    private let frontOutput = AVCaptureVideoDataOutput()
    private let backOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let frames: LiveFrames
    private var frontReady = false
    private var backReady = false
    private var frontFrame: CVPixelBuffer?
    private var backFrame: CVPixelBuffer?
    private(set) var front = true
    var activeInput: AVCaptureDeviceInput { front ? frontInput : backInput }
    var readyToFlip: Bool { frontReady && backReady }
    private var take: ContinuousTakeWriter?
    private var ticket: CaptureTicket?
    private var announcedStart = false
    var onStarted: ((UUID) -> Void)?
    var onFinished: ((CaptureTicket, Error?) -> Void)?
    var onReady: (() -> Void)?
    private let queue: DispatchQueue
    init?(queue: DispatchQueue, frames: LiveFrames) {
        guard AVCaptureMultiCamSession.isMultiCamSupported else { return nil }
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .builtInTrueDepthCamera], mediaType: .video, position: .unspecified)
        guard let pair = discovery.supportedMultiCamDeviceSets.first(where: { set in
            set.contains(where: { $0.position == .front }) && set.contains(where: { $0.position == .back && $0.deviceType == .builtInWideAngleCamera })
        }), let frontCamera = pair.first(where: { $0.position == .front }),
              let backCamera = pair.first(where: { $0.position == .back && $0.deviceType == .builtInWideAngleCamera }),
              let frontInput = try? AVCaptureDeviceInput(device: frontCamera),
              let backInput = try? AVCaptureDeviceInput(device: backCamera) else { return nil }
        self.frontInput = frontInput; self.backInput = backInput; self.queue = queue; self.frames = frames
        super.init()
        do { try configure() } catch { return nil }
        guard session.hardwareCost <= 1, session.systemPressureCost <= 1 else { return nil }
    }
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
            if camera.isExposureModeSupported(.continuousAutoExposure) { camera.exposureMode = .continuousAutoExposure }
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
            CameraStabilization.configure(connection, format: format, preview: false)
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
        guard readyToFlip, take?.finishing != true else { return false }
        front.toggle()
        if let image = front ? frontFrame : backFrame { frames.push(image) }
        return true
    }
    func record(ticket: CaptureTicket, url: URL, angle: CGFloat) throws {
        guard take == nil, session.isRunning else { throw HomeMovieError.message("The camera is not ready.") }
        take = try ContinuousTakeWriter(url: url, angle: angle); self.ticket = ticket; announcedStart = false
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
        let wasReady = readyToFlip
        if output === frontOutput { frontReady = true; frontFrame = image }
        else { backReady = true; backFrame = image }
        if !wasReady && readyToFlip { onReady?() }
        guard output === (front ? frontOutput : backOutput) else { return }
        frames.push(image)
        if let take, let ticket,
           take.appendVideo(image, at: CMSampleBufferGetPresentationTimeStamp(sample)), !announcedStart {
            announcedStart = true; onStarted?(ticket.sceneID)
        }
        if take?.failure != nil { stop() }
    }
}
