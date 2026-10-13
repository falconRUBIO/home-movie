import Foundation
import AVFoundation
import CoreImage

enum PiPCorner: String, Codable, CaseIterable, Identifiable, Sendable {
    case topLeft, topRight, bottomLeft, bottomRight
    var id: Self { self }
    var title: String {
        switch self { case .topLeft: "Top Left"; case .topRight: "Top Right"; case .bottomLeft: "Bottom Left"; case .bottomRight: "Bottom Right" }
    }
}
enum PiPSize: String, Codable, CaseIterable, Identifiable, Sendable {
    case small, medium
    var id: Self { self }
    var fraction: CGFloat { self == .small ? 0.27 : 0.36 }
    var title: String { rawValue.capitalized }
}
enum PiPOrientation: String, Codable, CaseIterable, Identifiable, Sendable {
    case landscape, portrait
    var id: Self { self }
    var title: String { rawValue.capitalized }
}
struct PiPLayout: Codable, Equatable, Sendable {
    var corner = PiPCorner.bottomRight
    var size = PiPSize.small
    var orientation = PiPOrientation.landscape
    init(corner: PiPCorner = .bottomRight, size: PiPSize = .small, orientation: PiPOrientation = .landscape) {
        self.corner = corner; self.size = size; self.orientation = orientation
    }
    private enum CodingKeys: String, CodingKey { case corner, size, orientation }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        corner = try values.decode(PiPCorner.self, forKey: .corner)
        size = try values.decode(PiPSize.self, forKey: .size)
        orientation = try values.decodeIfPresent(PiPOrientation.self, forKey: .orientation) ?? .landscape
    }
}
struct PiPPresentation: Equatable, Sendable {
    var rect = CGRect.zero // UIKit-normalized coordinates in the actual movie canvas.
    var opacity: CGFloat = 0
    var enabled = false
    var corner = PiPCorner.bottomRight
    var isPlaceable = true
}
enum PiPGeometry {
    static func extent(canvas: CGSize, size: PiPSize, orientation: PiPOrientation = .landscape) -> CGSize {
        let longEdge = canvas.width * size.fraction
        return orientation == .portrait
            ? CGSize(width: longEdge * 0.75, height: longEdge)
            : CGSize(width: longEdge, height: longEdge * 0.75)
    }
    static func desiredCenter(corner: PiPCorner, canvas: CGSize, size: PiPSize, orientation: PiPOrientation = .landscape) -> CGPoint {
        let extent = extent(canvas: canvas, size: size, orientation: orientation), margin = min(canvas.width, canvas.height) * 0.022
        let left = corner == .topLeft || corner == .bottomLeft
        let top = corner == .topLeft || corner == .topRight
        return CGPoint(x: (left ? margin + extent.width / 2 : canvas.width - margin - extent.width / 2) / canvas.width,
            y: (top ? margin + extent.height / 2 : canvas.height - margin - extent.height / 2) / canvas.height)
    }
    static func safeRect(center: CGPoint, canvas: CGSize, size: PiPSize, orientation: PiPOrientation = .landscape, obstacles: [CGRect] = []) -> CGRect? {
        guard canvas.width > 0, canvas.height > 0, center.x.isFinite, center.y.isFinite else { return nil }
        let extent = extent(canvas: canvas, size: size, orientation: orientation), margin = min(canvas.width, canvas.height) * 0.022
        let width = extent.width / canvas.width, height = extent.height / canvas.height
        let mx = margin / canvas.width, my = margin / canvas.height
        let xmin = mx + width / 2, xmax = 1 - mx - width / 2
        let ymin = my + height / 2, ymax = 1 - my - height / 2
        guard xmax >= xmin, ymax >= ymin else { return nil }
        let obstacles = obstacles.filter { !$0.isEmpty && !$0.isNull }.map { $0.insetBy(dx: -2 / canvas.width, dy: -2 / canvas.height) }
        func clamped(_ value: CGPoint) -> CGPoint { CGPoint(x: min(xmax, max(xmin, value.x)), y: min(ymax, max(ymin, value.y))) }
        func rect(_ point: CGPoint) -> CGRect { CGRect(x: point.x - width / 2, y: point.y - height / 2, width: width, height: height) }
        let requested = clamped(center)
        if !obstacles.contains(where: { $0.intersects(rect(requested)) }) { return rect(requested) }
        let xs = [requested.x, xmin, xmax] + obstacles.flatMap { [$0.minX - width / 2, $0.maxX + width / 2] }
        let ys = [requested.y, ymin, ymax] + obstacles.flatMap { [$0.minY - height / 2, $0.maxY + height / 2] }
        let candidates = xs.flatMap { x in ys.map { clamped(CGPoint(x: x, y: $0)) } }
            .filter { candidate in !obstacles.contains { $0.intersects(rect(candidate)) } }
        guard let closest = candidates.min(by: { distance($0, requested) < distance($1, requested) }) else { return nil }
        return rect(closest)
    }
    static func rect(layout: PiPLayout, canvas: CGSize, obstacles: [CGRect] = []) -> CGRect? {
        safeRect(center: desiredCenter(corner: layout.corner, canvas: canvas, size: layout.size, orientation: layout.orientation), canvas: canvas, size: layout.size, orientation: layout.orientation, obstacles: obstacles)
    }
    static func nearestCorner(to point: CGPoint, layout: PiPLayout, canvas: CGSize, obstacles: [CGRect] = []) -> PiPCorner {
        PiPCorner.allCases.min { a, b in
            let ar = rect(layout: PiPLayout(corner: a, size: layout.size, orientation: layout.orientation), canvas: canvas, obstacles: obstacles)
            let br = rect(layout: PiPLayout(corner: b, size: layout.size, orientation: layout.orientation), canvas: canvas, obstacles: obstacles)
            let da = ar.map { distance(CGPoint(x: $0.midX, y: $0.midY), point) } ?? .infinity
            let db = br.map { distance(CGPoint(x: $0.midX, y: $0.midY), point) } ?? .infinity
            return da < db
        } ?? .bottomRight
    }
    static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { (a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y) }
}
struct PiPTimeline {
    private(set) var layout = PiPLayout()
    private(set) var enabled = false
    private var fadeStart = CMTime.invalid
    private var fadeFrom: CGFloat = 0
    private var center: CGPoint?
    private var moveStart = CMTime.invalid
    private var moveFrom: CGPoint?
    private var moveTo: CGPoint?
    static let transitionSeconds = 0.18
    mutating func setLayout(_ layout: PiPLayout) { self.layout = layout; center = nil; moveFrom = nil; moveTo = nil }
    func opacity(at time: CMTime) -> CGFloat {
        guard fadeStart.isNumeric, time.isNumeric else { return enabled ? 1 : 0 }
        let progress = min(1, max(0, CMTimeSubtract(time, fadeStart).seconds / Self.transitionSeconds))
        let t = CGFloat(progress * progress * (3 - 2 * progress))
        return fadeFrom + ((enabled ? 1 : 0) - fadeFrom) * t
    }
    mutating func setEnabled(_ enabled: Bool, at time: CMTime) {
        guard self.enabled != enabled else { return }
        fadeFrom = opacity(at: time); fadeStart = time; self.enabled = enabled
    }
    private func currentCenter(at time: CMTime, canvas: CGSize) -> CGPoint {
        guard let moveFrom, let moveTo, moveStart.isNumeric, time.isNumeric else {
            return center ?? PiPGeometry.desiredCenter(corner: layout.corner, canvas: canvas, size: layout.size, orientation: layout.orientation)
        }
        let p = min(1, max(0, CMTimeSubtract(time, moveStart).seconds / Self.transitionSeconds))
        let t = CGFloat(p * p * (3 - 2 * p))
        return CGPoint(x: moveFrom.x + (moveTo.x - moveFrom.x) * t, y: moveFrom.y + (moveTo.y - moveFrom.y) * t)
    }
    mutating func drag(to center: CGPoint, at time: CMTime, canvas: CGSize, obstacles: [CGRect]) {
        guard let rect = PiPGeometry.safeRect(center: center, canvas: canvas, size: layout.size, orientation: layout.orientation, obstacles: obstacles) else { return }
        self.center = CGPoint(x: rect.midX, y: rect.midY); moveFrom = nil; moveTo = nil
    }
    @discardableResult mutating func settle(at time: CMTime, canvas: CGSize, obstacles: [CGRect]) -> PiPLayout {
        let current = currentCenter(at: time, canvas: canvas)
        layout.corner = PiPGeometry.nearestCorner(to: current, layout: layout, canvas: canvas, obstacles: obstacles)
        let target = PiPGeometry.rect(layout: layout, canvas: canvas, obstacles: obstacles)
        moveFrom = current; moveTo = target.map { CGPoint(x: $0.midX, y: $0.midY) }; moveStart = time
        center = moveTo; return layout
    }
    func presentation(at time: CMTime, canvas: CGSize, obstacles: [CGRect] = []) -> PiPPresentation {
        let rect = PiPGeometry.safeRect(center: currentCenter(at: time, canvas: canvas), canvas: canvas, size: layout.size, orientation: layout.orientation, obstacles: obstacles)
        return PiPPresentation(rect: rect ?? .zero, opacity: rect == nil ? 0 : opacity(at: time), enabled: enabled, corner: layout.corner, isPlaceable: rect != nil)
    }
}
// Choose a recent front frame from the same capture clock without waiting for it.
// Small delivery-order jitter is tolerated; old/future samples never stall rear timing.
struct PiPFrameMatcher {
    private var frames: [(buffer: CVPixelBuffer, time: CMTime)] = []
    mutating func push(_ buffer: CVPixelBuffer, at time: CMTime) {
        guard time.isNumeric else { return }
        frames.append((buffer, time)); frames.sort { $0.time < $1.time }
        if frames.count > 6 { frames.removeFirst(frames.count - 6) }
    }
    func frame(at rearTime: CMTime) -> CVPixelBuffer? {
        frames.last { frame in
            let age = CMTimeSubtract(rearTime, frame.time).seconds
            return age.isFinite && age >= -1 / 60 && age <= 0.5
        }?.buffer
    }
    mutating func clear() { frames.removeAll() }
}
enum PiPCompositor {
    // Both views are intentionally unmirrored in preview AND saved footage, so text stays readable.
    static func image(background: CVPixelBuffer, presenter: CVPixelBuffer?, canvas: CGSize,
                      backgroundAngle: CGFloat, presenterAngle: CGFloat, presentation: PiPPresentation) -> CIImage {
        let bounds = CGRect(origin: .zero, size: canvas)
        let source = CIImage(cvPixelBuffer: background)
        var result = source.transformed(by: LiveLookGeometry.transform(source: source.extent.size, target: canvas, angle: backgroundAngle, front: false)).cropped(to: bounds)
        guard presentation.opacity > 0, presentation.isPlaceable, let presenter, !presentation.rect.isEmpty else { return result }
        let unit = presentation.rect
        let rect = CGRect(x: unit.minX * canvas.width, y: (1 - unit.maxY) * canvas.height,
            width: unit.width * canvas.width, height: unit.height * canvas.height)
        let front = CIImage(cvPixelBuffer: presenter)
        var inset = front.transformed(by: LiveLookGeometry.transform(source: front.extent.size, target: rect.size, angle: presenterAngle, front: false))
            .transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY)).cropped(to: rect)
        if let mask = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
            "inputExtent": CIVector(cgRect: rect), "inputRadius": min(canvas.width, canvas.height) * 0.003,
            "inputColor": CIColor.white])?.outputImage {
            inset = inset.applyingFilter("CIBlendWithAlphaMask", parameters: [kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: bounds), kCIInputMaskImageKey: mask.cropped(to: bounds)])
        }
        inset = inset.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: presentation.opacity)])
        result = inset.composited(over: result).cropped(to: bounds)
        return result
    }
}
final class PiPFrameRenderer {
    static func previewCanvas(for canvas: CGSize) -> CGSize {
        guard canvas.width.isFinite, canvas.height.isFinite, canvas.width > 0, canvas.height > 0 else { return .zero }
        let scale = min(1, 960 / max(canvas.width, canvas.height))
        return CGSize(width: (canvas.width * scale).rounded(), height: (canvas.height * scale).rounded())
    }
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var pool: CVPixelBufferPool?
    private var canvas = CGSize.zero
    func render(_ image: CIImage, canvas: CGSize) -> CVPixelBuffer? {
        guard canvas.width.isFinite, canvas.height.isFinite, canvas.width > 0, canvas.height > 0,
              canvas.width <= 4096, canvas.height <= 4096 else { return nil }
        if self.canvas != canvas || pool == nil {
            pool = nil; self.canvas = canvas
            let attributes: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(canvas.width), kCVPixelBufferHeightKey as String: Int(canvas.height),
                kCVPixelBufferMetalCompatibilityKey as String: true, kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
            guard CVPixelBufferPoolCreate(kCFAllocatorDefault, [kCVPixelBufferPoolMinimumBufferCountKey as String: 3] as CFDictionary,
                attributes as CFDictionary, &pool) == kCVReturnSuccess else { return nil }
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool,
            [kCVPixelBufferPoolAllocationThresholdKey as String: 8] as CFDictionary, &buffer) == kCVReturnSuccess,
            let buffer else { return nil }
        context.render(image, to: buffer, bounds: CGRect(origin: .zero, size: canvas), colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return buffer
    }
}
