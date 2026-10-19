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
    case small, medium, large
    var id: Self { self }
    var fraction: CGFloat {
        switch self { case .small: 0.36; case .medium: 0.44; case .large: 0.52 }
    }
    var title: String { rawValue.capitalized }
}
enum PiPOrientation: String, Codable, CaseIterable, Identifiable, Sendable {
    case landscape, portrait
    var id: Self { self }
    var title: String { rawValue.capitalized }
}
enum PiPComposition: String, Codable, CaseIterable, Identifiable, Sendable {
    case inset, topAndBottom, sideBySide
    var id: Self { self }
    var title: String {
        switch self { case .inset: "Inset"; case .topAndBottom: "Top & Bottom"; case .sideBySide: "Side by Side" }
    }
    var symbol: String {
        switch self {
        case .inset: "pip"
        case .topAndBottom: "rectangle.split.1x2"
        case .sideBySide: "rectangle.split.2x1"
        }
    }
    /// Front camera's region, measured from the top-left of the movie.
    var presenterRect: CGRect? {
        switch self {
        case .inset: nil
        case .topAndBottom: CGRect(x: 0, y: 0.5, width: 1, height: 0.5)
        case .sideBySide: CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        }
    }
    func presenterRect(swapped: Bool) -> CGRect? {
        guard let rect = presenterRect else { return nil }
        guard swapped else { return rect }
        return self == .topAndBottom
            ? CGRect(x: 0, y: 0, width: 1, height: 0.5)
            : CGRect(x: 0, y: 0, width: 0.5, height: 1)
    }

}
struct PiPLayout: Codable, Equatable, Sendable {
    var corner = PiPCorner.bottomRight
    var size = PiPSize.small
    var orientation = PiPOrientation.landscape
    var composition = PiPComposition.inset
    var splitSwapped = false
    var zoom: CGFloat = 1
    var framingZoom: CGFloat { Self.clampedZoom(zoom) }
    static func clampedZoom(_ value: CGFloat) -> CGFloat { value.isFinite ? min(2, max(1, value)) : 1 }
    init(corner: PiPCorner = .bottomRight, size: PiPSize = .small, orientation: PiPOrientation = .landscape, zoom: CGFloat = 1, composition: PiPComposition = .inset, splitSwapped: Bool = false) {
        self.splitSwapped = splitSwapped
        self.composition = composition
        self.corner = corner; self.size = size; self.orientation = orientation; self.zoom = Self.clampedZoom(zoom)
    }
    var splitPresenterRect: CGRect? { composition.presenterRect(swapped: splitSwapped) }
    private enum CodingKeys: String, CodingKey { case corner, size, orientation, zoom, composition, splitSwapped }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        splitSwapped = try values.decodeIfPresent(Bool.self, forKey: .splitSwapped) ?? false
        composition = try values.decodeIfPresent(PiPComposition.self, forKey: .composition) ?? .inset
        corner = try values.decode(PiPCorner.self, forKey: .corner)
        size = try values.decode(PiPSize.self, forKey: .size)
        orientation = try values.decodeIfPresent(PiPOrientation.self, forKey: .orientation) ?? .landscape
        zoom = Self.clampedZoom(try values.decodeIfPresent(CGFloat.self, forKey: .zoom) ?? 1)
    }
}
struct PiPPresentation: Equatable, Sendable {
    var composition = PiPComposition.inset
    var splitSwapped = false
    var rect = CGRect.zero // UIKit-normalized coordinates in the actual movie canvas.
    var opacity: CGFloat = 0
    var enabled = false
    var corner = PiPCorner.bottomRight
    var isPlaceable = true
    var zoom: CGFloat = 1
}
enum PiPGeometry {
    static func fittedPreview(canvas: CGSize, available: CGSize) -> CGSize {
        guard canvas.width > 0, canvas.height > 0, available.width > 0, available.height > 0,
              canvas.width.isFinite, canvas.height.isFinite, available.width.isFinite, available.height.isFinite else { return .zero }
        let scale = min(available.width / canvas.width, available.height / canvas.height)
        return CGSize(width: canvas.width * scale, height: canvas.height * scale)
    }
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
        if let split = layout.splitPresenterRect { return split }
        let center = desiredCenter(corner: layout.corner, canvas: canvas, size: layout.size, orientation: layout.orientation)
        return safeRect(center: center, canvas: canvas, size: layout.size, orientation: layout.orientation, obstacles: obstacles)
            ?? safeRect(center: center, canvas: canvas, size: layout.size, orientation: layout.orientation)
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
        guard layout.composition == .inset else { return }
        guard let rect = PiPGeometry.safeRect(center: center, canvas: canvas, size: layout.size, orientation: layout.orientation, obstacles: obstacles) else { return }
        self.center = CGPoint(x: rect.midX, y: rect.midY); moveFrom = nil; moveTo = nil
    }
    @discardableResult mutating func settle(at time: CMTime, canvas: CGSize, obstacles: [CGRect]) -> PiPLayout {
        guard layout.composition == .inset else { return layout }
        let current = currentCenter(at: time, canvas: canvas)
        layout.corner = PiPGeometry.nearestCorner(to: current, layout: layout, canvas: canvas, obstacles: obstacles)
        let target = PiPGeometry.rect(layout: layout, canvas: canvas, obstacles: obstacles)
        moveFrom = current; moveTo = target.map { CGPoint(x: $0.midX, y: $0.midY) }; moveStart = time
        center = moveTo; return layout
    }
    func presentation(at time: CMTime, canvas: CGSize, obstacles: [CGRect] = []) -> PiPPresentation {
        let rect = layout.splitPresenterRect ?? PiPGeometry.safeRect(center: currentCenter(at: time, canvas: canvas), canvas: canvas, size: layout.size, orientation: layout.orientation, obstacles: obstacles)
            ?? PiPGeometry.rect(layout: layout, canvas: canvas)
        return PiPPresentation(composition: layout.composition, splitSwapped: layout.splitSwapped, rect: rect ?? .zero, opacity: rect == nil ? 0 : opacity(at: time), enabled: enabled, corner: layout.corner, isPlaceable: rect != nil, zoom: layout.framingZoom)
    }
}
// Choose a recent front frame from the same capture clock without waiting for it.
// Small delivery-order jitter is tolerated; old/future samples never stall rear timing.
struct PiPFrameMatcher {
    private var frames: [(buffer: CVPixelBuffer, time: CMTime)] = []
    mutating func push(_ buffer: CVPixelBuffer, at time: CMTime) {
        guard time.isNumeric else { return }
        frames.append((buffer, time)); frames.sort { $0.time < $1.time }
        if frames.count > 2 { frames.removeFirst(frames.count - 2) }
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
                      backgroundAngle: CGFloat, presenterAngle: CGFloat, presentation: PiPPresentation, profile: CaptureProfile = .standard) -> CIImage {
        let bounds = CGRect(origin: .zero, size: canvas)
        let imageOptions: [CIImageOption: Any] = profile == .appleLog ? [.colorSpace: NSNull()] : [:]
        let source = CIImage(cvPixelBuffer: background, options: imageOptions)
        var result = source.transformed(by: LiveLookGeometry.transform(source: source.extent.size, target: canvas, angle: backgroundAngle, front: false)).cropped(to: bounds)
        guard presentation.opacity > 0, presentation.isPlaceable, let presenter, !presentation.rect.isEmpty else { return result }
        if presentation.composition != .inset {
            let frontUnit = presentation.composition.presenterRect(swapped: presentation.splitSwapped) ?? presentation.rect
            let rearUnit = presentation.composition.presenterRect(swapped: !presentation.splitSwapped) ?? .zero
            func panel(_ buffer: CVPixelBuffer, unit: CGRect, angle: CGFloat, zoom: CGFloat) -> CIImage {
                let rect = CGRect(x: unit.minX * canvas.width, y: (1 - unit.maxY) * canvas.height,
                                  width: unit.width * canvas.width, height: unit.height * canvas.height)
                let image = CIImage(cvPixelBuffer: buffer, options: imageOptions)
                return image.transformed(by: LiveLookGeometry.transform(source: image.extent.size,
                        target: rect.size, angle: angle, front: false))
                    .transformed(by: CGAffineTransform(a: zoom, b: 0, c: 0, d: zoom,
                        tx: rect.width * (1 - zoom) / 2, ty: rect.height * (1 - zoom) / 2))
                    .transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
                    .cropped(to: rect)
            }
            let split = panel(presenter, unit: frontUnit, angle: presenterAngle,
                              zoom: PiPLayout.clampedZoom(presentation.zoom))
                .composited(over: panel(background, unit: rearUnit, angle: backgroundAngle, zoom: 1))
                .cropped(to: bounds)
            // Fade the entire split composition together when dual camera is toggled.
            return split.applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: min(1, max(0, presentation.opacity)))
            ]).composited(over: result).cropped(to: bounds)
        }
        let unit = presentation.rect
        let rect = CGRect(x: unit.minX * canvas.width, y: (1 - unit.maxY) * canvas.height,
            width: unit.width * canvas.width, height: unit.height * canvas.height)
        let front = CIImage(cvPixelBuffer: presenter, options: imageOptions)
        let zoom = PiPLayout.clampedZoom(presentation.zoom)
        let zoomTransform = CGAffineTransform(a: zoom, b: 0, c: 0, d: zoom,
            tx: rect.width * (1 - zoom) / 2, ty: rect.height * (1 - zoom) / 2)
        var inset = front.transformed(by: LiveLookGeometry.transform(source: front.extent.size, target: rect.size, angle: presenterAngle, front: false))
            .transformed(by: zoomTransform)
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
    private let context: CIContext
    private let profile: CaptureProfile
    init(profile: CaptureProfile = .standard) {
        self.profile = profile
        context = CIContext(options: profile == .appleLog ? LogPiPColor.contextOptions() : [.cacheIntermediates: false])
    }
    private var pool: CVPixelBufferPool?
    private var canvas = CGSize.zero
    func render(_ image: CIImage, canvas: CGSize) -> CVPixelBuffer? {
        guard canvas.width.isFinite, canvas.height.isFinite, canvas.width > 0, canvas.height > 0,
              canvas.width <= 4096, canvas.height <= 4096 else { return nil }
        if self.canvas != canvas || pool == nil {
            pool = nil; self.canvas = canvas
            let attributes: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: profile == .appleLog ? LogPiPColor.pixelFormat : kCVPixelFormatType_32BGRA,
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
        if profile == .appleLog { LogPiPColor.attach(to: buffer) }
        context.render(image, to: buffer, bounds: CGRect(origin: .zero, size: canvas), colorSpace: profile == .appleLog ? nil : CGColorSpace(name: CGColorSpace.sRGB))
        if profile == .appleLog { LogPiPColor.attach(to: buffer) }
        return buffer
    }
}

