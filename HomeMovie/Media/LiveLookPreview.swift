import AVFoundation
import CoreImage
import MetalKit
import UIKit

final class LiveFrames: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var frame: CVPixelBuffer?
    private var listener: (@Sendable () -> Void)?
    private var notificationPending = false
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let image = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        push(image)
    }
    func push(_ image: CVPixelBuffer) {
        lock.lock(); frame = image
        let notify = notificationPending ? nil : listener
        if notify != nil { notificationPending = true }
        lock.unlock(); notify?()
    }
    func setListener(_ listener: (@Sendable () -> Void)?) {
        lock.lock(); self.listener = listener; notificationPending = false; lock.unlock()
    }
    func notificationHandled() { lock.lock(); notificationPending = false; lock.unlock() }
    func latest() -> CVPixelBuffer? { lock.lock(); defer { lock.unlock() }; return frame }
    func clear() { lock.lock(); frame = nil; lock.unlock() }
}
enum LiveLookGeometry {
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
    private let context: CIContext
    private(set) var frames: LiveFrames?
    private(set) var cube: ColorCube?
    private(set) var presentationID = UUID()
    private(set) var status = LiveLookStatus.inactive
    var onStatusChanged: ((LiveLookStatus) -> Void)?
    private func report(_ status: LiveLookStatus) {
        guard self.status != status else { return }
        self.status = status; onStatusChanged?(status)
    }
    func configure(frames: LiveFrames?, cube: ColorCube?, active: Bool) {
        let nextFrames = active && cube != nil ? frames : nil
        let nextCube = active ? cube : nil
        if self.frames !== nextFrames || self.cube?.rgba != nextCube?.rgba ||
            self.cube?.dimension != nextCube?.dimension || self.cube?.minimum != nextCube?.minimum ||
            self.cube?.maximum != nextCube?.maximum {
            presentationID = UUID()
            report(nextFrames == nil ? .inactive : .preparing)
        }
        self.frames = nextFrames; self.cube = nextCube
    }
    func canPresent(_ id: UUID) -> Bool { id == presentationID && frames != nil && cube != nil }
    var angle: CGFloat = 90
    var front = false
    private var rendering = false
    init?(device: MTLDevice) {
        guard let queue = device.makeCommandQueue() else { return nil }
        self.queue = queue
        context = CIContext(mtlDevice: device, options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .cacheIntermediates: false])
        super.init()
    }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    func encode(_ source: CVPixelBuffer, to texture: MTLTexture, command: MTLCommandBuffer) throws {
        guard let cube else { throw HomeMovieError.message("No live look is selected.") }
        let target = CGSize(width: texture.width, height: texture.height)
        var image = try cube.apply(to: CIImage(cvPixelBuffer: source, options: [.colorSpace: NSNull()]))
        image = image.transformed(by: LiveLookGeometry.transform(source: image.extent.size, target: target, angle: angle, front: front))
            .cropped(to: CGRect(origin: .zero, size: target))
        let destination = CIRenderDestination(mtlTexture: texture, commandBuffer: command)
        destination.colorSpace = nil; destination.isFlipped = true
        _ = try context.startTask(toRender: image, to: destination)
    }
    func draw(in view: MTKView) {
        guard !rendering, cube != nil, let source = frames?.latest(), let drawable = view.currentDrawable,
              let command = queue.makeCommandBuffer() else { return }
        do {
            try encode(source, to: drawable.texture, command: command)
            rendering = true
            let presentationID = self.presentationID
            command.addCompletedHandler { [weak self] buffer in
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
