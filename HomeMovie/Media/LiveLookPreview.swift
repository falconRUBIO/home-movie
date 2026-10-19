import AVFoundation
import CoreImage
import MetalKit
import UIKit

// Long-lived preview/writer snapshots must not retain the camera's own buffer pool.
// Copy native planes without color conversion into a bounded, app-owned pool.
final class CaptureFrameCopy {
    private var pool: CVPixelBufferPool?
    private var width = 0, height = 0
    private var format: OSType = 0
    func copy(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(source), height = CVPixelBufferGetHeight(source)
        let format = CVPixelBufferGetPixelFormatType(source)
        if pool == nil || self.width != width || self.height != height || self.format != format {
            pool = nil; self.width = width; self.height = height; self.format = format
            let attributes: [String: Any] = [kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height, kCVPixelBufferPixelFormatTypeKey as String: format,
                kCVPixelBufferMetalCompatibilityKey as String: true, kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
            guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess else { return nil }
        }
        guard let pool else { return nil }
        var result: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool,
            [kCVPixelBufferPoolAllocationThresholdKey as String: 8] as CFDictionary, &result) == kCVReturnSuccess,
              let result else { return nil }
        guard CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
        guard CVPixelBufferLockBaseAddress(result, []) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(result, []) }
        let planes = CVPixelBufferGetPlaneCount(source)
        guard planes == CVPixelBufferGetPlaneCount(result) else { return nil }
        for plane in 0..<max(1, planes) {
            let from = planes == 0 ? CVPixelBufferGetBaseAddress(source) : CVPixelBufferGetBaseAddressOfPlane(source, plane)
            let to = planes == 0 ? CVPixelBufferGetBaseAddress(result) : CVPixelBufferGetBaseAddressOfPlane(result, plane)
            guard let from, let to else { return nil }
            let fromStride = planes == 0 ? CVPixelBufferGetBytesPerRow(source) : CVPixelBufferGetBytesPerRowOfPlane(source, plane)
            let toStride = planes == 0 ? CVPixelBufferGetBytesPerRow(result) : CVPixelBufferGetBytesPerRowOfPlane(result, plane)
            let rows = planes == 0 ? height : CVPixelBufferGetHeightOfPlane(source, plane)
            for row in 0..<rows { memcpy(to.advanced(by: row * toStride), from.advanced(by: row * fromStride), min(fromStride, toStride)) }
        }
        CVBufferPropagateAttachments(source, result)
        return result
    }
}

struct LivePiPFrame {
    let presenter: CVPixelBuffer?
    let backgroundAngle: CGFloat
    let presenterAngle: CGFloat
    let presentation: PiPPresentation
}

final class LiveFrames: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var frame: CVPixelBuffer?
    private var composed = false
    private var rotationAngle: CGFloat?
    private var sourceFront: Bool?
    private var pip: LivePiPFrame?
    private var listener: (@Sendable () -> Void)?
    private var notificationPending = false
    private var rawPreviewAngle: CGFloat?
    private var rawPreviewFront: Bool?
    private var rawPreviewHeld = false
    private var rawPreviewHandoff: CameraPreviewHandoff?
    private var rawPreviewReady: (@Sendable () -> Void)?
    func holdRawPreview() {
        lock.lock(); rawPreviewHeld = true; rawPreviewHandoff = nil; rawPreviewReady = nil; lock.unlock()
    }
    func resumeRawPreview(after time: CMTime, onReady: @escaping @Sendable () -> Void) {
        lock.lock(); rawPreviewHandoff = CameraPreviewHandoff(after: time)
        rawPreviewReady = onReady; rawPreviewHeld = false; lock.unlock()
    }
    func cancelRawPreviewHandoff() {
        lock.lock(); rawPreviewHeld = false; rawPreviewHandoff = nil; rawPreviewReady = nil; lock.unlock()
    }
    func configureRawPreview(angle: CGFloat, front: Bool) {
        lock.lock(); rawPreviewAngle = angle; rawPreviewFront = front; lock.unlock()
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let image = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        pushRawPreview(image, connectionAngle: connection.videoRotationAngle, at: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }
    func pushRawPreview(_ image: CVPixelBuffer, connectionAngle: CGFloat, at time: CMTime = .invalid) {
        lock.lock()
        guard !rawPreviewHeld else { lock.unlock(); return }
        var ready: (@Sendable () -> Void)?
        if var handoff = rawPreviewHandoff {
            guard handoff.accept(time) else { rawPreviewHandoff = handoff; lock.unlock(); return }
            rawPreviewHandoff = nil; ready = rawPreviewReady; rawPreviewReady = nil
        }
        let angle = rawPreviewAngle; let front = rawPreviewFront; lock.unlock()
        // Data outputs may physically rotate their buffers. Apply only the remaining
        // sensor correction, independently of the native preview layer and movie output.
        push(image, angle: angle.map { LiveLookGeometry.remainingRotation(captureAngle: $0,
            connectionAngle: connectionAngle) }, front: front)
        ready?()
    }
    func push(_ image: CVPixelBuffer, composed: Bool = false, angle: CGFloat? = nil, pip: LivePiPFrame? = nil, front: Bool? = nil) {
        lock.lock(); frame = image; self.composed = composed; rotationAngle = angle; self.pip = pip; sourceFront = front
        let notify = notificationPending ? nil : listener
        if notify != nil { notificationPending = true }
        lock.unlock(); notify?()
    }
    func setListener(_ listener: (@Sendable () -> Void)?) {
        lock.lock(); self.listener = listener; notificationPending = false; lock.unlock()
    }
    func notificationHandled() { lock.lock(); notificationPending = false; lock.unlock() }
    func latest() -> CVPixelBuffer? { lock.lock(); defer { lock.unlock() }; return frame }
    func snapshot() -> (buffer: CVPixelBuffer, composed: Bool, angle: CGFloat?, pip: LivePiPFrame?, front: Bool?)? {
        lock.lock(); defer { lock.unlock() }
        return frame.map { ($0, composed, rotationAngle, pip, sourceFront) }
    }
    func clear() {
        lock.lock(); frame = nil; pip = nil; composed = false; rotationAngle = nil; sourceFront = nil
        rawPreviewHeld = false; rawPreviewHandoff = nil; rawPreviewReady = nil; lock.unlock()
    }
}
enum LiveLookGeometry {
    static func remainingRotation(captureAngle: CGFloat, connectionAngle: CGFloat) -> CGFloat {
        guard captureAngle.isFinite, connectionAngle.isFinite else { return 0 }
        return ((captureAngle - connectionAngle).truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360)
    }
    static func transform(source: CGSize, target: CGSize, angle: CGFloat, front: Bool) -> CGAffineTransform {
        guard [source.width, source.height, target.width, target.height, angle].allSatisfy({ $0.isFinite }), source.width > 0, source.height > 0, target.width > 0, target.height > 0 else { return .identity }
        let rotate = CGAffineTransform(rotationAngle: -angle * .pi / 180)
        let bounds = CGRect(origin: .zero, size: source).applying(rotate)
        var result = rotate.concatenating(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
        if front { result = result.concatenating(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: bounds.width, ty: 0)) }
        let scale = max(target.width / bounds.width, target.height / bounds.height)
        return result.concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: (target.width - bounds.width * scale) / 2,
                                           y: (target.height - bounds.height * scale) / 2))
    }
}
enum LiveLookStatus: Equatable { case inactive, preparing, ready, unavailable }

@MainActor final class LiveLookRenderer: NSObject, MTKViewDelegate {
    private let queue: MTLCommandQueue
    private var context: CIContext?
    private var contextPassthrough: Bool?
    private(set) var frames: LiveFrames?
    private(set) var cube: ColorCube?
    private(set) var presentationID = UUID()
    private(set) var status = LiveLookStatus.inactive
    private var passthrough = false
    private var logSource = false
    var onStatusChanged: ((LiveLookStatus) -> Void)?
    private func report(_ status: LiveLookStatus) {
        guard self.status != status else { return }
        self.status = status
        if status == .ready { ReliabilityDiagnostics.shared.record(.firstPreviewFrame) }
        onStatusChanged?(status)
    }
    func configure(frames: LiveFrames?, cube: ColorCube?, active: Bool, passthrough: Bool = false, logSource: Bool = false) {
        let nextFrames = active && (cube != nil || passthrough) ? frames : nil
        let nextCube = active ? cube : nil
        let managed = passthrough && !logSource && cube == nil
        if nextFrames != nil, contextPassthrough != managed {
            var options: [CIContextOption: Any] = [.cacheIntermediates: false, .name: "HomeMovie.LivePreview"]
            if !managed { options[.workingColorSpace] = NSNull(); options[.outputColorSpace] = NSNull() }
            context = CIContext(mtlCommandQueue: queue, options: options)
            contextPassthrough = managed
        }
        if self.frames !== nextFrames || self.passthrough != passthrough || self.cube?.rgba != nextCube?.rgba ||
            self.cube?.dimension != nextCube?.dimension || self.cube?.minimum != nextCube?.minimum ||
            self.cube?.maximum != nextCube?.maximum {
            presentationID = UUID()
            report(nextFrames == nil ? .inactive : .preparing)
        }
        self.frames = nextFrames; self.cube = nextCube; self.passthrough = passthrough; self.logSource = logSource
    }
    func canPresent(_ id: UUID) -> Bool { id == presentationID && frames != nil && (cube != nil || passthrough) }
    var angle: CGFloat = 90
    var front = false
    private var rendering = false
    init?(device: MTLDevice) {
        guard let queue = device.makeCommandQueue() else { return nil }
        self.queue = queue
        super.init()
    }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    func previewImage(_ source: CVPixelBuffer, to canvas: CGSize, pip: LivePiPFrame?) throws -> CIImage {
        let isLog = logSource || cube != nil || LogPiPColor.isLog(source)
        let image: CIImage
        if let pip {
            image = PiPCompositor.image(background: source, presenter: pip.presenter, canvas: canvas,
                backgroundAngle: pip.backgroundAngle, presenterAngle: pip.presenterAngle, presentation: pip.presentation,
                profile: isLog ? .appleLog : .standard)
        } else { image = CIImage(cvPixelBuffer: source, options: isLog ? [.colorSpace: NSNull()] : [:]) }
        // A sample-buffer preview can still have a viewing LUT. Apply it once,
        // after spatial composition, to both cameras; never to recorded buffers.
        return try Self.viewingImage(image, cube: cube)
    }
    static func viewingImage(_ image: CIImage, cube: ColorCube?) throws -> CIImage {
        try cube?.apply(to: image) ?? image
    }
    func encode(_ source: CVPixelBuffer, to texture: MTLTexture, command: MTLCommandBuffer, composed: Bool = false, sourceAngle: CGFloat? = nil, pip: LivePiPFrame? = nil, sourceFront: Bool? = nil) throws {
        let target = CGSize(width: texture.width, height: texture.height)
        var image = try previewImage(source, to: target, pip: pip)
        let directPiP = pip != nil
        image = image.transformed(by: LiveLookGeometry.transform(source: image.extent.size, target: target, angle: composed || directPiP ? 0 : (sourceAngle ?? angle), front: composed || directPiP ? false : (sourceFront ?? front)))
            .cropped(to: CGRect(origin: .zero, size: target))
        let destination = CIRenderDestination(mtlTexture: texture, commandBuffer: command)
        destination.colorSpace = contextPassthrough == true ? CGColorSpace(name: CGColorSpace.sRGB) : nil
        destination.isFlipped = true
        guard let context else { throw HomeMovieError.message("The live preview is not configured.") }
        _ = try context.startTask(toRender: image, to: destination)
    }
    func draw(in view: MTKView) {
        guard !rendering, cube != nil || passthrough, let source = frames?.snapshot(), let drawable = view.currentDrawable,
              let command = queue.makeCommandBuffer() else { return }
        do {
            try encode(source.buffer, to: drawable.texture, command: command, composed: source.composed, sourceAngle: source.angle, pip: source.pip, sourceFront: source.front)
            rendering = true
            let presentationID = self.presentationID
            // Keep pool-backed source frames alive until the GPU has finished reading.
            // Holding only the CI graph during encode lets the capture pool recycle
            // presenter pixels while the asynchronous preview command is in flight.
            command.addCompletedHandler { [weak self, source] buffer in
                withExtendedLifetime(source) { }
                Task { @MainActor in
                    self?.rendering = false
                    guard let self, self.canPresent(presentationID) else { return }
                    self.report(buffer.status == .completed ? .ready : .unavailable)
                }
            }
            command.present(drawable); command.commit()
        } catch {
            // A preview failure never changes or stops the original recording.
            report(.unavailable)
        }
    }
}

// Keep the outgoing frame until three fresh incoming samples arrive at a usable cadence.
struct CameraPreviewHandoff: Sendable {
    let id = UUID()
    let after: CMTime
    private var last = CMTime.invalid
    private var count = 0
    init(after: CMTime) { self.after = after }
    mutating func accept(_ time: CMTime) -> Bool {
        guard time.isNumeric, !after.isNumeric || time > after else { return false }
        if last.isNumeric {
            let interval = CMTimeSubtract(time, last).seconds
            guard interval > 0 else { return false }
            if interval > 0.25 { count = 0 }
        }
        last = time; count += 1
        return count >= 3
    }
}
