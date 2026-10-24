import Foundation
import CoreGraphics

/// Geometry inside the leading-safe camera viewport. Landscape consumes the full
/// screen height and trailing edge; the notch remains outside this coordinate space.
struct CameraViewportLayout {
    let preview: CGRect
    let controls: CGRect
    init(size: CGSize, landscape: Bool, portraitFooter: CGFloat = 64, canvasAspect: CGFloat? = nil) {
        let width = max(1, size.width), height = max(1, size.height)
        let rail: CGFloat = landscape ? min(96, width * 0.2) : 0
        let footer = landscape ? 0 : min(portraitFooter, height * 0.25)
        let available = CGRect(x: 0, y: 0, width: width - rail, height: height - footer)
        if landscape && canvasAspect == nil {
            preview = available // Same fill behavior as the native landscape camera.
        } else {
            let ratio = canvasAspect ?? (landscape ? 16.0 / 9.0 : 9.0 / 16.0)
            let validRatio = ratio.isFinite && ratio > 0 ? ratio : 1
            let fittedWidth = min(available.width, available.height * validRatio)
            let fittedHeight = fittedWidth / validRatio
            preview = CGRect(x: (available.width - fittedWidth) / 2, y: (available.height - fittedHeight) / 2,
                width: fittedWidth, height: fittedHeight)
        }
        controls = landscape ? CGRect(x: width - rail, y: 0, width: rail, height: height) :
            CGRect(x: 0, y: height - footer, width: width, height: footer)
    }
}

enum CameraPreviewRotation {
    static func matches(source: CGSize, angle: CGFloat, format: MovieFormat) -> Bool {
        guard source.width.isFinite, source.height.isFinite, source.width > 0, source.height > 0,
              angle.isFinite else { return false }
        if abs(source.width - source.height) < 1 { return true }
        let turns = Int((angle.truncatingRemainder(dividingBy: 360) / 90).rounded())
        let swapped = abs(turns % 2) == 1
        let wide = swapped ? source.height > source.width : source.width > source.height
        return wide == (format == .landscape)
    }
}
