import XCTest
import CoreImage
import MetalKit
@testable import HomeMovie

final class PiPMeteringTests: XCTestCase {
    func testTouchMappingInvertsTheActualCropRotationAndFramingZoom() throws {
        let canvas = CGSize(width: 390, height: 844), source = CGSize(width: 128, height: 72)
        for panel in [CGRect(x: 0.65, y: 0.6, width: 0.3, height: 0.25), CGRect(x: 0, y: 0, width: 0.5, height: 1)] {
            let rect = CGRect(x: panel.minX * canvas.width, y: panel.minY * canvas.height,
                width: panel.width * canvas.width, height: panel.height * canvas.height)
            for angle: CGFloat in [0, 90, 180, 270] {
                for zoom: CGFloat in [1, 2] {
                    let sensor = CGPoint(x: 0.49, y: 0.51)
                    let transform = LiveLookGeometry.transform(source: source, target: rect.size, angle: angle, front: false)
                        .concatenating(CGAffineTransform(a: zoom, b: 0, c: 0, d: zoom,
                            tx: rect.width * (1 - zoom) / 2, ty: rect.height * (1 - zoom) / 2))
                    let local = CGPoint(x: sensor.x * source.width, y: (1 - sensor.y) * source.height).applying(transform)
                    let touch = CGPoint(x: rect.minX + local.x, y: rect.minY + rect.height - local.y)
                    let hit = try XCTUnwrap(PiPMeteringGeometry.hit(at: touch, canvas: canvas, source: source,
                        angle: angle, panel: panel, zoom: zoom, front: true))
                    XCTAssertTrue(hit.front)
                    XCTAssertEqual(hit.point.x, sensor.x, accuracy: 0.00001)
                    XCTAssertEqual(hit.point.y, sensor.y, accuracy: 0.00001)
                }
            }
            XCTAssertNil(PiPMeteringGeometry.hit(at: CGPoint(x: -1, y: -1), canvas: canvas, source: source,
                angle: 90, panel: panel, zoom: 1, front: true))
        }
    }
    @MainActor func testCustomMeteringUsesRoutedCoordinatesAndHonorsProtectedControls() {
        let view = PreviewUIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        var calls = 0
        view.meteringConversion = { _, _ in CGPoint(x: 0.25, y: 0.75) }
        view.onFocus = { point, locked in
            calls += 1; XCTAssertEqual(point, CGPoint(x: 0.25, y: 0.75)); XCTAssertFalse(locked); return true
        }
        view.requestFocus(at: CGPoint(x: 300, y: 600), locked: false)
        XCTAssertEqual(calls, 1)
        view.protectedRegions = [CGRect(x: 0, y: 0, width: 390, height: 100)]
        view.requestFocus(at: CGPoint(x: 100, y: 40), locked: false)
        XCTAssertEqual(calls, 1)
        view.detachPreview()
    }
    @MainActor func testSampleAndPiPPreviewsApplySelectedLookOnceAndOriginalStaysLog() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let renderer = try XCTUnwrap(LiveLookRenderer(device: device))
        var data: [Float] = []
        for b in 0...1 { for g in 0...1 { for r in 0...1 { data += [Float(r) * 0.5, Float(g) * 0.5, Float(b) * 0.5, 1] } } }
        let cube = data.withUnsafeBytes { ColorCube(name: "Half", dimension: 2, rgba: Data($0)) }
        let frames = LiveFrames(), context = CIContext(options: LogPiPColor.contextOptions())
        func frame(_ value: CGFloat) throws -> CVPixelBuffer {
            try XCTUnwrap(PiPFrameRenderer(profile: .appleLog).render(
                CIImage(color: CIColor(red: value, green: value, blue: value)), canvas: CGSize(width: 64, height: 64)))
        }
        func sample(_ image: CIImage, x: Int) -> Float {
            var pixel = [Float](repeating: 0, count: 4)
            pixel.withUnsafeMutableBytes { context.render(image, toBitmap: $0.baseAddress!, rowBytes: 16,
                bounds: CGRect(x: x, y: 32, width: 1, height: 1), format: .RGBAf, colorSpace: nil) }
            return pixel[0]
        }
        let rear = try frame(0.4), front = try frame(0.8)
        let state = PiPPresentation(composition: .sideBySide, rect: CGRect(x: 0.5, y: 0, width: 0.5, height: 1), opacity: 1, enabled: true)
        let pip = LivePiPFrame(presenter: front, backgroundAngle: 0, presenterAngle: 0, presentation: state)
        renderer.configure(frames: frames, cube: cube, active: true, passthrough: true, logSource: true)
        let graded = try renderer.previewImage(rear, to: CGSize(width: 128, height: 64), pip: pip)
        XCTAssertEqual(sample(graded, x: 32), 0.2, accuracy: 0.02)
        XCTAssertEqual(sample(graded, x: 96), 0.4, accuracy: 0.02)
        let single = try renderer.previewImage(rear, to: CGSize(width: 64, height: 64), pip: nil)
        XCTAssertEqual(sample(single, x: 32), 0.2, accuracy: 0.02)
        renderer.configure(frames: frames, cube: nil, active: true, passthrough: true, logSource: true)
        let original = try renderer.previewImage(rear, to: CGSize(width: 128, height: 64), pip: pip)
        XCTAssertEqual(sample(original, x: 32), 0.4, accuracy: 0.02)
        XCTAssertEqual(sample(original, x: 96), 0.8, accuracy: 0.02)
        XCTAssertEqual(sample(CIImage(cvPixelBuffer: rear, options: [.colorSpace: NSNull()]), x: 32), 0.4, accuracy: 0.02)
        XCTAssertTrue(LogPiPColor.isLog(rear)); XCTAssertTrue(LogPiPColor.isLog(front))
    }
}
