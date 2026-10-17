import XCTest
import AVFoundation
import CoreImage
import UIKit
import MetalKit
@testable import HomeMovie

final class PictureInPictureTests: XCTestCase {
    func testPortraitInsetKeepsShapeWhenReturningFromEitherSplitLayout() throws {
        let canvas = MovieFormat.portrait.canvas
        var layout = PiPLayout(corner: .bottomRight, orientation: .portrait, zoom: 1.25)
        let originalRect = try XCTUnwrap(PiPGeometry.rect(layout: layout, canvas: canvas))
        var timeline = PiPTimeline()
        timeline.setEnabled(true, at: .zero)
        for split in [PiPComposition.topAndBottom, .sideBySide] {
            layout.composition = split
            timeline.setLayout(layout)
            XCTAssertEqual(timeline.presentation(at: CMTime(seconds: 1, preferredTimescale: 30), canvas: canvas).rect,
                           split.presenterRect)
            layout.composition = .inset
            layout = try JSONDecoder().decode(PiPLayout.self, from: JSONEncoder().encode(layout))
            timeline.setLayout(layout)
            let state = timeline.presentation(at: CMTime(seconds: 1, preferredTimescale: 30), canvas: canvas)
            XCTAssertEqual(state.rect, originalRect)
            XCTAssertEqual(layout.orientation, .portrait)
            XCTAssertEqual(state.zoom, 1.25)
            XCTAssertEqual(state.rect.width * canvas.width / (state.rect.height * canvas.height), 0.75, accuracy: 0.001)
        }
    }

    func testSplitLayoutsDecodePersistAndMatchCaptureWithoutInsetPlacement() throws {
        let old = Data(#"{"corner":"bottomRight","size":"small"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(PiPLayout.self, from: old).composition, .inset)
        for mode in [PiPComposition.topAndBottom, .sideBySide] {
            let layout = PiPLayout(corner: .topLeft, orientation: .portrait, zoom: 1.5, composition: mode)
            XCTAssertEqual(try JSONDecoder().decode(PiPLayout.self, from: JSONEncoder().encode(layout)), layout)
            for format in MovieFormat.allCases {
                var timeline = PiPTimeline()
                timeline.setLayout(layout); timeline.setEnabled(true, at: .zero)
                let time = CMTime(seconds: 1, preferredTimescale: 30)
                let presentation = timeline.presentation(at: time, canvas: format.canvas,
                    obstacles: [CGRect(x: 0, y: 0, width: 1, height: 1)])
                XCTAssertEqual(presentation.composition, mode)
                XCTAssertEqual(presentation.rect, mode.presenterRect)
                XCTAssertEqual(presentation.rect, PiPGeometry.rect(layout: layout, canvas: format.canvas))
                XCTAssertEqual(presentation.rect.width * presentation.rect.height, 0.5, accuracy: 0.0001)
                timeline.drag(to: .zero, at: time, canvas: format.canvas, obstacles: [])
                XCTAssertEqual(timeline.settle(at: time, canvas: format.canvas, obstacles: []), layout)
            }
        }
    }

    func testSplitCompositorUsesCorrectEqualHalvesWithoutGaps() throws {
        let rear = try frame(red: 0, green: 0, blue: 220)
        let front = try frame(red: 220, green: 0, blue: 0)
        for mode in [PiPComposition.topAndBottom, .sideBySide] {
            for canvas in [CGSize(width: 320, height: 180), CGSize(width: 180, height: 320)] {
                let state = PiPPresentation(composition: mode, rect: try XCTUnwrap(mode.presenterRect),
                                            opacity: 1, enabled: true)
                let image = PiPCompositor.image(background: rear, presenter: front, canvas: canvas,
                    backgroundAngle: 0, presenterAngle: 0, presentation: state)
                XCTAssertEqual(image.extent, CGRect(origin: .zero, size: canvas))
                let rearPoint = mode == .topAndBottom
                    ? CGPoint(x: canvas.width / 2, y: canvas.height * 0.75)
                    : CGPoint(x: canvas.width * 0.25, y: canvas.height / 2)
                let frontPoint = mode == .topAndBottom
                    ? CGPoint(x: canvas.width / 2, y: canvas.height * 0.25)
                    : CGPoint(x: canvas.width * 0.75, y: canvas.height / 2)
                XCTAssertGreaterThan(sample(image, point: rearPoint)[2], 180)
                XCTAssertGreaterThan(sample(image, point: frontPoint)[0], 180)
                // Sample directly on each side of the seam.
                for delta: CGFloat in [-1, 1] {
                    let point = mode == .topAndBottom
                        ? CGPoint(x: canvas.width / 2, y: canvas.height / 2 + delta)
                        : CGPoint(x: canvas.width / 2 + delta, y: canvas.height / 2)
                    let pixel = sample(image, point: point)
                    XCTAssertGreaterThan(max(pixel[0], pixel[2]), 180)
                }
                let missing = PiPCompositor.image(background: rear, presenter: nil, canvas: canvas,
                    backgroundAngle: 0, presenterAngle: 0, presentation: state)
                XCTAssertGreaterThan(sample(missing, point: frontPoint)[2], 180)
            }
        }
    }

    func testEverySelectedCornerMatchesMovieCanvasInSettingsAndCapture() throws {
        for canvas in [MovieFormat.portrait.canvas, MovieFormat.landscape.canvas] {
            for corner in PiPCorner.allCases {
                for orientation in PiPOrientation.allCases {
                    let layout = PiPLayout(corner: corner, orientation: orientation)
                    var timeline = PiPTimeline(); timeline.setLayout(layout)
                    timeline.setEnabled(true, at: .zero)
                    let recorded = timeline.presentation(at: CMTime(seconds: 1, preferredTimescale: 30), canvas: canvas)
                    let settings = try XCTUnwrap(PiPGeometry.rect(layout: layout, canvas: canvas))
                    XCTAssertEqual(recorded.rect, settings)
                    let margin = min(canvas.width, canvas.height) * 0.022
                    if corner == .topLeft || corner == .bottomLeft {
                        XCTAssertEqual(settings.minX * canvas.width, margin, accuracy: 0.001)
                    } else { XCTAssertEqual((1 - settings.maxX) * canvas.width, margin, accuracy: 0.001) }
                    if corner == .topLeft || corner == .topRight {
                        XCTAssertEqual(settings.minY * canvas.height, margin, accuracy: 0.001)
                    } else { XCTAssertEqual((1 - settings.maxY) * canvas.height, margin, accuracy: 0.001) }
                }
            }
        }
    }
    func testPreviewFitsPortraitAndLandscapeCanvasWithinAvailableArea() {
        let area = CGSize(width: 358, height: 340)
        let portrait = PiPGeometry.fittedPreview(canvas: CGSize(width: 1080, height: 1920), available: area)
        XCTAssertEqual(portrait.height, 340, accuracy: 0.001)
        XCTAssertEqual(portrait.width / portrait.height, 9.0 / 16, accuracy: 0.001)
        let landscape = PiPGeometry.fittedPreview(canvas: CGSize(width: 1920, height: 1080), available: area)
        XCTAssertEqual(landscape.width, 358, accuracy: 0.001)
        XCTAssertEqual(landscape.width / landscape.height, 16.0 / 9, accuracy: 0.001)
        XCTAssertEqual(PiPGeometry.fittedPreview(canvas: .zero, available: area), .zero)
    }
    func testZoomPreferenceDecodesLegacyClampsAndTravelsWithCapturePresentation() throws {
        let legacy = Data(#"{"corner":"bottomRight","size":"small"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(PiPLayout.self, from: legacy).zoom, 1)
        let layout = PiPLayout(orientation: .portrait, zoom: 1.75)
        XCTAssertEqual(try JSONDecoder().decode(PiPLayout.self, from: JSONEncoder().encode(layout)), layout)
        XCTAssertEqual(PiPLayout(zoom: .infinity).framingZoom, 1)
        XCTAssertEqual(PiPLayout(zoom: 5).framingZoom, 2)
        var timeline = PiPTimeline(); timeline.setLayout(layout)
        let time = CMTime(seconds: 1, preferredTimescale: 600)
        timeline.setEnabled(true, at: time)
        XCTAssertEqual(timeline.presentation(at: time, canvas: CGSize(width: 1080, height: 1920)).zoom, 1.75)
    }
    func testPresenterZoomCropsAroundCenterWithoutChangingRearOrInsetBounds() throws {
        let rear = try frame(red: 0, green: 0, blue: 220)
        let front = try frame(red: 220, green: 0, blue: 0)
        CVPixelBufferLockBaseAddress(front, [])
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(front)).assumingMemoryBound(to: UInt8.self)
        for y in 0..<36 { for x in 22..<42 {
            let offset = y * CVPixelBufferGetBytesPerRow(front) + x * 4
            base[offset + 1] = 220; base[offset + 2] = 0
        }}
        CVPixelBufferUnlockBaseAddress(front, [])
        let canvas = CGSize(width: 320, height: 240)
        let rect = CGRect(x: 0.1, y: 0.1, width: 0.4, height: 0.4)
        let wide = PiPPresentation(rect: rect, opacity: 1, enabled: true, zoom: 1)
        let close = PiPPresentation(rect: rect, opacity: 1, enabled: true, zoom: 2)
        let a = PiPCompositor.image(background: rear, presenter: front, canvas: canvas, backgroundAngle: 0, presenterAngle: 0, presentation: wide)
        let b = PiPCompositor.image(background: rear, presenter: front, canvas: canvas, backgroundAngle: 0, presenterAngle: 0, presentation: close)
        for x: CGFloat in [0.2, 0.8] {
            let point = CGPoint(x: (rect.minX + rect.width * x) * canvas.width, y: (1 - rect.midY) * canvas.height)
            XCTAssertGreaterThan(sample(a, point: point)[0], 180)
            XCTAssertGreaterThan(sample(b, point: point)[1], 180)
        }
        XCTAssertGreaterThan(sample(b, point: CGPoint(x: 260, y: 120))[2], 180)
    }
    @MainActor func testPortraitFrontPreviewUsesFrameOrientationAndMirrorBeforeUIHandoff() async throws {
        let source = try frame(red: 220, green: 0, blue: 0, split: true)
        CVPixelBufferLockBaseAddress(source, [])
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(source)).assumingMemoryBound(to: UInt8.self)
        for y in 0..<18 { for x in 0..<64 {
            let offset = y * CVPixelBufferGetBytesPerRow(source) + x * 4
            base[offset] = 220; base[offset + 1] = 0; base[offset + 2] = 0
        }}
        CVPixelBufferUnlockBaseAddress(source, [])
        let frames = LiveFrames()
        frames.push(source, angle: 270, front: true)
        let snapshot = try XCTUnwrap(frames.snapshot())
        XCTAssertEqual(snapshot.angle, 270); XCTAssertEqual(snapshot.front, true)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let renderer = try XCTUnwrap(LiveLookRenderer(device: device))
        renderer.configure(frames: frames, cube: nil, active: true, passthrough: true)
        renderer.angle = 90; renderer.front = false // Outgoing UI camera metadata.
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 36, height: 64, mipmapped: false)
        descriptor.storageMode = .shared; descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let queue = try XCTUnwrap(device.makeCommandQueue()), command = try XCTUnwrap(queue.makeCommandBuffer())
        try renderer.encode(snapshot.buffer, to: texture, command: command,
            sourceAngle: snapshot.angle, sourceFront: snapshot.front)
        let completed = expectation(description: "Portrait front preview")
        command.addCompletedHandler { _ in completed.fulfill() }; command.commit()
        await fulfillment(of: [completed], timeout: 15)
        XCTAssertEqual(command.status, .completed)
        func pixel(_ x: Int, _ y: Int) -> [UInt8] {
            var bgra = [UInt8](repeating: 0, count: 4)
            texture.getBytes(&bgra, bytesPerRow: 4, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
            return bgra
        }
        // CVPixelBuffer rows are top-down; Core Image's image coordinates are bottom-up.
        let topLeft = pixel(9, 16), topRight = pixel(27, 16), bottomLeft = pixel(9, 48)
        XCTAssertGreaterThan(topRight[0], 180, "Blue side: topLeft=\(topLeft), topRight=\(topRight)")
        XCTAssertGreaterThan(topLeft[1], 180, "Upright green: \(topLeft)")
        XCTAssertGreaterThan(bottomLeft[2], 180, "Upright red: \(bottomLeft)")
        frames.push(source, angle: 90, front: false)
        XCTAssertEqual(frames.snapshot()?.front, false)
        frames.clear(); XCTAssertNil(frames.snapshot())
    }

    @MainActor func testSharedPreviewShowsRearAndPresenterAtBothDisplaySizes() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let renderer = try XCTUnwrap(PiPLayoutRenderer(device: device))
        let rear = try frame(red: 0, green: 0, blue: 230)
        let front = try frame(red: 230, green: 0, blue: 0)
        for canvas in [CGSize(width: 320, height: 180), CGSize(width: 960, height: 540),
                       CGSize(width: 540, height: 960)] {
            for size in PiPSize.allCases {
                for orientation in PiPOrientation.allCases {
                    let layout = PiPLayout(size: size, orientation: orientation)
                    let rect = try XCTUnwrap(PiPGeometry.rect(layout: layout, canvas: canvas))
                    let image = renderer.image(background: rear, presenter: front, canvas: canvas,
                        backgroundAngle: 0, presenterAngle: 0,
                        presentation: PiPPresentation(rect: rect, opacity: 1, enabled: true))
                    XCTAssertGreaterThan(sample(image, point: CGPoint(x: canvas.width * 0.2, y: canvas.height * 0.8))[2], 180)
                    XCTAssertGreaterThan(sample(image, point: CGPoint(x: rect.midX * canvas.width,
                        y: (1 - rect.midY) * canvas.height))[0], 180)
                }
            }
        }
    }
    @MainActor func testPreviewDrawableResizesFromSmallToLargeAndBack() throws {
        let view = PiPMetalView(frame: CGRect(x: 0, y: 0, width: 160, height: 90),
                               device: try XCTUnwrap(MTLCreateSystemDefaultDevice()))
        view.autoResizeDrawable = false
        for size in [CGSize(width: 160, height: 90), CGSize(width: 800, height: 450),
                     CGSize(width: 300, height: 700), CGSize(width: 160, height: 90)] {
            view.frame.size = size
            view.resizeDrawable()
            XCTAssertEqual(view.drawableSize, PiPFrameRenderer.previewCanvas(for:
                CGSize(width: size.width * 2, height: size.height * 2)))
            XCTAssertLessThanOrEqual(max(view.drawableSize.width, view.drawableSize.height), 960)
        }
    }

    func testPresenterMatchingResumesAfterTemporaryGapWithoutReset() throws {
        var matcher = PiPFrameMatcher()
        let old = try frame(red: 40, green: 0, blue: 0)
        let fresh = try frame(red: 220, green: 0, blue: 0)
        matcher.push(old, at: .zero)
        XCTAssertNil(matcher.frame(at: CMTime(seconds: 1, preferredTimescale: 30)))
        matcher.push(fresh, at: CMTime(seconds: 1, preferredTimescale: 30))
        XCTAssertTrue(matcher.frame(at: CMTime(seconds: 1.01, preferredTimescale: 300)) === fresh)
    }

    func testCaptureCopiesOwnPixelsAndBoundRetainedBuffers() throws {
        let source = try frame(red: 220, green: 0, blue: 0)
        let copier = CaptureFrameCopy()
        var retained: [CVPixelBuffer] = []
        for _ in 0..<8 { retained.append(try XCTUnwrap(copier.copy(source))) }
        XCTAssertFalse(retained[0] === source)
        CVPixelBufferLockBaseAddress(source, [])
        memset(try XCTUnwrap(CVPixelBufferGetBaseAddress(source)), 0, CVPixelBufferGetDataSize(source))
        CVPixelBufferUnlockBaseAddress(source, [])
        XCTAssertGreaterThan(sample(CIImage(cvPixelBuffer: retained[0]), point: CGPoint(x: 10, y: 10))[0], 180)
        XCTAssertNil(copier.copy(source))
        retained.removeAll()
        XCTAssertNotNil(copier.copy(source))
    }
    func testNativePlanarCaptureCopyPreservesBothPlanes() throws {
        var source: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 36, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &source), kCVReturnSuccess)
        let buffer = try XCTUnwrap(source)
        CVPixelBufferLockBaseAddress(buffer, [])
        for plane in 0..<2 {
            memset(try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, plane)), plane == 0 ? 90 : 140,
                CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let copy = try XCTUnwrap(CaptureFrameCopy().copy(buffer))
        XCTAssertEqual(CVPixelBufferGetPlaneCount(copy), 2)
        CVPixelBufferLockBaseAddress(copy, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(copy, .readOnly) }
        for plane in 0..<2 {
            let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(copy, plane)).assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(copy, plane)
            for row in 0..<CVPixelBufferGetHeightOfPlane(copy, plane) {
                XCTAssertEqual(bytes[row * stride], plane == 0 ? 90 : 140)
            }
        }
    }

    func testMediumInsetRemainsVisibleWhenControlsCoverEveryPlacement() throws {
        for canvas in [MovieFormat.portrait.canvas, MovieFormat.landscape.canvas] {
            for orientation in PiPOrientation.allCases {
                var timeline = PiPTimeline()
                timeline.setLayout(PiPLayout(size: .medium, orientation: orientation))
                timeline.setEnabled(true, at: .zero)
                let presentation = timeline.presentation(at: CMTime(seconds: 1, preferredTimescale: 30),
                    canvas: canvas, obstacles: [CGRect(x: 0, y: 0, width: 1, height: 1)])
                XCTAssertTrue(presentation.isPlaceable); XCTAssertEqual(presentation.opacity, 1)
                XCTAssertFalse(presentation.rect.isEmpty)
                XCTAssertTrue(CGRect(x: 0, y: 0, width: 1, height: 1).contains(presentation.rect))
            }
        }
    }
    func testFrameMatcherReleasesOldCaptureBuffers() throws {
        var matcher = PiPFrameMatcher()
        var old: CVPixelBuffer? = try frame(red: 20, green: 0, blue: 0)
        weak var retained = old
        matcher.push(try XCTUnwrap(old), at: .zero); old = nil
        XCTAssertNotNil(retained)
        matcher.push(try frame(red: 40, green: 0, blue: 0), at: CMTime(value: 1, timescale: 30))
        matcher.push(try frame(red: 60, green: 0, blue: 0), at: CMTime(value: 2, timescale: 30))
        XCTAssertNil(retained)
    }

    func testLegacyLayoutKeepsLandscapeAndNewOrientationRoundTrips() throws {
        let legacy = Data(#"{"corner":"bottomRight","size":"small"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(PiPLayout.self, from: legacy).orientation, .landscape)
        let portrait = PiPLayout(corner: .topLeft, size: .medium, orientation: .portrait)
        XCTAssertEqual(try JSONDecoder().decode(PiPLayout.self, from: JSONEncoder().encode(portrait)), portrait)
    }
    func testBothInsetShapesFitBothMovieOrientationsAndSettleWithoutChangingShape() throws {
        for canvas in [CGSize(width: 1920, height: 1080), CGSize(width: 1080, height: 1920)] {
            for orientation in PiPOrientation.allCases {
                for size in PiPSize.allCases {
                    for corner in PiPCorner.allCases {
                        let layout = PiPLayout(corner: corner, size: size, orientation: orientation)
                        let rect = try XCTUnwrap(PiPGeometry.rect(layout: layout, canvas: canvas))
                        XCTAssertTrue(CGRect(x: 0, y: 0, width: 1, height: 1).contains(rect))
                        XCTAssertEqual(rect.width * canvas.width / (rect.height * canvas.height), orientation == .portrait ? 0.75 : 4.0 / 3, accuracy: 0.001)
                        var timeline = PiPTimeline(); timeline.setLayout(layout)
                        timeline.drag(to: CGPoint(x: 0.1, y: 0.1), at: .zero, canvas: canvas, obstacles: [])
                        XCTAssertEqual(timeline.settle(at: .zero, canvas: canvas, obstacles: []).orientation, orientation)
                    }
                }
            }
        }
    }

    func testLivePairIsAtomicAndClearedWhenReturningToOrdinaryFrames() throws {
        let rear = try frame(red: 0, green: 0, blue: 220), front = try frame(red: 220, green: 0, blue: 0)
        let frames = LiveFrames()
        let presentation = PiPPresentation(rect: CGRect(x: 0.7, y: 0.7, width: 0.25, height: 0.2), opacity: 1, enabled: true)
        frames.push(rear, angle: 0, pip: LivePiPFrame(presenter: front, backgroundAngle: 0, presenterAngle: 90, presentation: presentation))
        let pair = try XCTUnwrap(frames.snapshot())
        XCTAssertTrue(pair.buffer === rear); XCTAssertTrue(pair.pip?.presenter === front)
        XCTAssertEqual(pair.pip?.presentation, presentation); XCTAssertEqual(pair.pip?.presenterAngle, 90)
        frames.push(front, angle: 180)
        let ordinary = try XCTUnwrap(frames.snapshot())
        XCTAssertTrue(ordinary.buffer === front); XCTAssertNil(ordinary.pip); XCTAssertEqual(ordinary.angle, 180)
        frames.clear(); XCTAssertNil(frames.snapshot())
    }
    @MainActor func testDirectGPUPreviewKeepsInsetPlacementAndDoesNotDoubleMirror() async throws {
        let rear = try frame(red: 0, green: 0, blue: 220), front = try frame(red: 220, green: 0, blue: 0, split: true)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let renderer = try XCTUnwrap(LiveLookRenderer(device: device))
        renderer.configure(frames: LiveFrames(), cube: nil, active: true, passthrough: true)
        // UI camera metadata must not rotate or mirror an already-composed recipe.
        renderer.angle = 90; renderer.front = true
        let canvas = CGSize(width: 640, height: 360)
        let rect = try XCTUnwrap(PiPGeometry.rect(layout: PiPLayout(), canvas: canvas))
        let presentation = PiPPresentation(rect: rect, opacity: 1, enabled: true)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 640, height: 360, mipmapped: false)
        descriptor.storageMode = .shared; descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let queue = try XCTUnwrap(device.makeCommandQueue()), command = try XCTUnwrap(queue.makeCommandBuffer())
        try renderer.encode(rear, to: texture, command: command, pip: LivePiPFrame(presenter: front,
            backgroundAngle: 0, presenterAngle: 0, presentation: presentation))
        let completed = expectation(description: "Direct live PiP render")
        command.addCompletedHandler { _ in completed.fulfill() }; command.commit()
        await fulfillment(of: [completed], timeout: 15)
        XCTAssertEqual(command.status, .completed)
        func pixel(x: CGFloat, y: CGFloat) -> [UInt8] {
            var bgra = [UInt8](repeating: 0, count: 4)
            texture.getBytes(&bgra, bytesPerRow: 4, from: MTLRegionMake2D(Int(x), Int(y), 1, 1), mipmapLevel: 0)
            return bgra
        }
        let y = rect.midY * canvas.height
        let left = pixel(x: (rect.minX + rect.width * 0.25) * canvas.width, y: y)
        let right = pixel(x: (rect.minX + rect.width * 0.75) * canvas.width, y: y)
        XCTAssertGreaterThan(left[2], 180); XCTAssertLessThan(left[1], 30)
        XCTAssertGreaterThan(right[1], 180); XCTAssertLessThan(right[2], 30)
        let outside = pixel(x: rect.minX * canvas.width - 3, y: y)
        XCTAssertGreaterThan(outside[0], 180); XCTAssertLessThan(outside[2], 30)
    }

    func testIdlePreviewReducesPixelWorkWithoutChangingInsetGeometry() throws {
        for format in [MovieFormat.landscape, .portrait] {
            let full = format.canvas, preview = PiPFrameRenderer.previewCanvas(for: full)
            XCTAssertEqual(max(preview.width, preview.height), 960)
            XCTAssertEqual(preview.width / preview.height, full.width / full.height, accuracy: 0.0001)
            XCTAssertEqual(preview.width * preview.height, full.width * full.height / 4)
            for corner in PiPCorner.allCases {
                let layout = PiPLayout(corner: corner)
                let a = try XCTUnwrap(PiPGeometry.rect(layout: layout, canvas: full))
                let b = try XCTUnwrap(PiPGeometry.rect(layout: layout, canvas: preview))
                XCTAssertEqual(a.minX, b.minX, accuracy: 0.0001)
                XCTAssertEqual(a.minY, b.minY, accuracy: 0.0001)
                XCTAssertEqual(a.width, b.width, accuracy: 0.0001)
                XCTAssertEqual(a.height, b.height, accuracy: 0.0001)
            }
        }
    }

    private func frame(red: UInt8, green: UInt8, blue: UInt8, split: Bool = false) throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 36, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &result), kCVReturnSuccess)
        let buffer = try XCTUnwrap(result)
        CVPixelBufferLockBaseAddress(buffer, []); defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        for y in 0..<36 { for x in 0..<64 {
            let offset = y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
            base[offset] = blue; base[offset + 1] = split && x >= 32 ? 220 : green
            base[offset + 2] = split && x >= 32 ? 0 : red; base[offset + 3] = 255
        }}
        return buffer
    }
    private func sample(_ image: CIImage, point: CGPoint) -> [UInt8] {
        var rgba = [UInt8](repeating: 0, count: 4)
        CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()]).render(image,
            toBitmap: &rgba, rowBytes: 4, bounds: CGRect(x: point.x, y: point.y, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        return rgba
    }
    private func audio(at time: CMTime) throws -> CMSampleBuffer {
        var description = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4, mFramesPerPacket: 1,
            mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description, layoutSize: 0,
            layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format), noErr)
        var block: CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: 6400,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: 6400, flags: 0, blockBufferOut: &block), noErr)
        let data = try XCTUnwrap(block)
        XCTAssertEqual(CMBlockBufferFillDataBytes(with: 0, blockBuffer: data, offsetIntoDestination: 0, dataLength: 6400), noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000), presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sampleSize = 4; var result: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: data, formatDescription: try XCTUnwrap(format),
            sampleCount: 1600, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize, sampleBufferOut: &result), noErr)
        return try XCTUnwrap(result)
    }
    func testInsetUsesMovieWidthAndFourByThreeAtEveryCorner() throws {
        for canvas in [MovieFormat.landscape.canvas, MovieFormat.portrait.canvas] {
            for size in PiPSize.allCases { for corner in PiPCorner.allCases {
                let rect = try XCTUnwrap(PiPGeometry.rect(layout: PiPLayout(corner: corner, size: size), canvas: canvas))
                XCTAssertTrue(CGRect(x: 0, y: 0, width: 1, height: 1).contains(rect))
                XCTAssertEqual(rect.width, size.fraction, accuracy: 0.0001)
                XCTAssertEqual(rect.width * canvas.width / (rect.height * canvas.height), 4 / 3, accuracy: 0.0001)
                XCTAssertEqual(PiPGeometry.nearestCorner(to: CGPoint(x: rect.midX, y: rect.midY), layout: PiPLayout(size: size), canvas: canvas), corner)
            }}
        }
    }
    func testDragClampsInsideMovieAndAvoidsExistingPreviewControls() throws {
        let canvas = MovieFormat.landscape.canvas
        let controls = [CGRect(x: 0, y: 0, width: 1, height: 0.1), CGRect(x: 0.2, y: 0.82, width: 0.6, height: 0.18), CGRect(x: 0.88, y: 0.35, width: 0.12, height: 0.3)]
        for point in [CGPoint(x: -4, y: -3), CGPoint(x: 10, y: 4), CGPoint(x: 0.93, y: 0.6), CGPoint(x: 0.5, y: 0.92)] {
            let rect = try XCTUnwrap(PiPGeometry.safeRect(center: point, canvas: canvas, size: .small, obstacles: controls))
            XCTAssertTrue(CGRect(x: 0, y: 0, width: 1, height: 1).contains(rect))
            XCTAssertFalse(controls.contains { $0.intersects(rect) })
        }
        XCTAssertNil(PiPGeometry.safeRect(center: CGPoint(x: 0.5, y: 0.5), canvas: canvas, size: .medium, obstacles: [CGRect(x: 0, y: 0, width: 1, height: 1)]))
    }
    func testToggleAndCornerSettleFollowVideoTimeWithoutBounce() throws {
        var timeline = PiPTimeline(); let canvas = MovieFormat.landscape.canvas
        timeline.setEnabled(true, at: CMTime(seconds: 10, preferredTimescale: 600))
        XCTAssertEqual(timeline.opacity(at: CMTime(seconds: 10, preferredTimescale: 600)), 0)
        XCTAssertEqual(timeline.opacity(at: CMTime(seconds: 10.09, preferredTimescale: 600)), 0.5, accuracy: 0.001)
        timeline.drag(to: CGPoint(x: 0.15, y: 0.25), at: CMTime(seconds: 11, preferredTimescale: 600), canvas: canvas, obstacles: [])
        let before = timeline.presentation(at: CMTime(seconds: 11, preferredTimescale: 600), canvas: canvas)
        let layout = timeline.settle(at: CMTime(seconds: 11, preferredTimescale: 600), canvas: canvas, obstacles: [])
        XCTAssertEqual(layout.corner, .topLeft)
        let halfway = timeline.presentation(at: CMTime(seconds: 11.09, preferredTimescale: 600), canvas: canvas)
        let after = timeline.presentation(at: CMTime(seconds: 11.18, preferredTimescale: 600), canvas: canvas)
        XCTAssertEqual(halfway.rect.midX, (before.rect.midX + after.rect.midX) / 2, accuracy: 0.001)
        XCTAssertEqual(halfway.rect.midY, (before.rect.midY + after.rect.midY) / 2, accuracy: 0.001)
        timeline.setEnabled(false, at: CMTime(seconds: 12, preferredTimescale: 600))
        XCTAssertEqual(timeline.opacity(at: CMTime(seconds: 12.09, preferredTimescale: 600)), 0.5, accuracy: 0.001)
        XCTAssertEqual(timeline.opacity(at: CMTime(seconds: 12.18, preferredTimescale: 600)), 0, accuracy: 0.001)
    }
    func testRendererRejectsInvalidCanvasAndRecoversForValidFrames() throws {
        let renderer = PiPFrameRenderer()
        let image = CIImage(color: .red)
        for canvas in [CGSize.zero, CGSize(width: -1, height: 360), CGSize(width: CGFloat.nan, height: 360), CGSize(width: 100_000, height: 360)] {
            XCTAssertNil(renderer.render(image, canvas: canvas))
        }
        let buffer = try XCTUnwrap(renderer.render(image, canvas: CGSize(width: 640, height: 360)))
        XCTAssertEqual(CVPixelBufferGetWidth(buffer), 640)
        XCTAssertEqual(CVPixelBufferGetHeight(buffer), 360)
        let portrait = try XCTUnwrap(renderer.render(image, canvas: CGSize(width: 360, height: 640)))
        XCTAssertEqual(CVPixelBufferGetHeight(portrait), 640)
    }
    func testRendererBoundsRetainedFramesAndResumesAfterRelease() throws {
        let renderer = PiPFrameRenderer()
        let canvas = CGSize(width: 64, height: 36)
        var retained: [CVPixelBuffer] = []
        for _ in 0..<8 { retained.append(try XCTUnwrap(renderer.render(CIImage(color: .red), canvas: canvas))) }
        XCTAssertNil(renderer.render(CIImage(color: .red), canvas: canvas))
        retained.removeAll()
        XCTAssertNotNil(renderer.render(CIImage(color: .blue), canvas: canvas))
    }
    func testFrameMatchingRejectsLateAndFutureFramesWithoutWaitingForFront() throws {
        let old = try frame(red: 30, green: 0, blue: 0), current = try frame(red: 120, green: 0, blue: 0), future = try frame(red: 220, green: 0, blue: 0)
        var matcher = PiPFrameMatcher()
        matcher.push(future, at: CMTime(seconds: 12, preferredTimescale: 600))
        matcher.push(current, at: CMTime(seconds: 10, preferredTimescale: 600))
        matcher.push(old, at: CMTime(seconds: 8, preferredTimescale: 600))
        XCTAssertTrue(matcher.frame(at: CMTime(seconds: 10.03, preferredTimescale: 600)) === current)
        XCTAssertNil(matcher.frame(at: CMTime(seconds: 11, preferredTimescale: 600)))
        matcher.clear(); XCTAssertNil(matcher.frame(at: CMTime(seconds: 12, preferredTimescale: 600)))
    }
    func testCompositorIsFramelessUnmirroredAndRearContinuesWhenPresenterMissing() throws {
        let rear = try frame(red: 0, green: 0, blue: 220), front = try frame(red: 220, green: 0, blue: 0, split: true)
        let canvas = CGSize(width: 640, height: 360)
        let rect = try XCTUnwrap(PiPGeometry.rect(layout: PiPLayout(), canvas: canvas))
        let state = PiPPresentation(rect: rect, opacity: 1, enabled: true)
        let image = PiPCompositor.image(background: rear, presenter: front, canvas: canvas, backgroundAngle: 0, presenterAngle: 0, presentation: state)
        let y = (1 - rect.midY) * canvas.height
        let left = sample(image, point: CGPoint(x: (rect.minX + rect.width * 0.25) * canvas.width, y: y))
        let right = sample(image, point: CGPoint(x: (rect.minX + rect.width * 0.75) * canvas.width, y: y))
        XCTAssertGreaterThan(left[0], 180); XCTAssertLessThan(left[1], 30)
        XCTAssertGreaterThan(right[1], 180); XCTAssertLessThan(right[0], 30)
        let outside = sample(image, point: CGPoint(x: rect.minX * canvas.width - 3, y: y))
        XCTAssertGreaterThan(outside[2], 180); XCTAssertLessThan(outside[0], 30)
        let missing = PiPCompositor.image(background: rear, presenter: nil, canvas: canvas, backgroundAngle: 0, presenterAngle: 0, presentation: state)
        XCTAssertGreaterThan(sample(missing, point: CGPoint(x: rect.midX * canvas.width, y: y))[2], 180)
    }
    func testPreferencesPersistPerMovieAndSurviveBackupWithoutChangingLog() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let other = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: other) }
        let store = ProjectStore(root: root); _ = try await store.load()
        let movie = try await store.create(name: "Tour", format: .landscape)
        let log = try await store.create(name: "Cinema", format: .portrait, profile: .appleLog)
        let layout = PiPLayout(corner: .topLeft, size: .medium, orientation: .portrait, zoom: 1.5, composition: .sideBySide)
        try await store.setPiPLayout(movieID: movie.id, layout: layout)
        try await store.setDualCameraCapture(movieID: movie.id, enabled: true)
        do { try await store.setDualCameraCapture(movieID: log.id, enabled: true); XCTFail("Log must not silently downgrade") } catch { }
        // Project backups require recorded footage, not an empty movie catalog.
        let ticket = try await store.begin(movieID: movie.id, format: .landscape, profile: .standard)
        let writer = try ContinuousTakeWriter(url: try await store.url(ticket.staging), angle: 0)
        let fixture = try frame(red: 0, green: 0, blue: 220)
        for index in 0..<12 {
            let time = CMTime(value: Int64(index), timescale: 30)
            var accepted = false
            for _ in 0..<100 {
                if writer.appendVideo(fixture, at: time) { accepted = true; break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(accepted)
            writer.appendAudio(try audio(at: time))
        }
        let finished = expectation(description: "Backup fixture recording finishes")
        writer.finish { error in XCTAssertNil(error); finished.fulfill() }
        await fulfillment(of: [finished], timeout: 30)
        try await store.commit(ticket)
        let reopened = ProjectStore(root: root); _ = try await reopened.load()
        let values = await reopened.snapshot()
        XCTAssertEqual(values.first { $0.id == movie.id }?.preferredPiPLayout, layout)
        XCTAssertEqual(values.first { $0.id == movie.id }?.dualCameraCapture, true)
        XCTAssertEqual(values.first { $0.id == log.id }?.captureProfile, .appleLog)
        XCTAssertEqual(values.first { $0.id == log.id }?.look, log.look)
        let backup = BackupService(); let archive = try await backup.create(store: reopened) { _ in }
        defer { Task { try? await backup.discard(archive.url) } }
        let restored = ProjectStore(root: other); _ = try await restored.load()
        try await backup.restore(from: archive.url, store: restored) { _ in }
        let restoredMovies = await restored.snapshot()
        XCTAssertEqual(restoredMovies.first { $0.name == "Tour (Restored)" }?.preferredPiPLayout, layout)
        XCTAssertEqual(restoredMovies.first { $0.name == "Tour (Restored)" }?.dualCameraCapture, true)
        XCTAssertEqual(restoredMovies.first { $0.name == "Cinema (Restored)" }?.captureProfile, .appleLog)
        let legacy = Movie(name: "Legacy", format: .portrait)
        let decoded = try JSONDecoder().decode(Movie.self, from: JSONEncoder().encode(legacy))
        XCTAssertEqual(decoded.preferredPiPLayout, PiPLayout()); XCTAssertNil(decoded.dualCameraCapture)
    }
    @MainActor func testInsetAndPiPControlRegionsCannotTriggerViewfinderFocus() {
        let preview = PreviewUIView(frame: CGRect(x: 0, y: 0, width: 393, height: 698))
        preview.protectedRegions = [CGRect(x: 277, y: 610, width: 106, height: 80), CGRect(x: 300, y: 538, width: 44, height: 44)]
        XCTAssertFalse(preview.permitsPreviewInteraction(at: CGPoint(x: 325, y: 650)))
        XCTAssertFalse(preview.permitsPreviewInteraction(at: CGPoint(x: 325, y: 560)))
        XCTAssertTrue(preview.permitsPreviewInteraction(at: CGPoint(x: 190, y: 340)))
    }
    func testRecordedPiPChangesAreBakedIntoOneNormalClipAndMovieExport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(root: root); _ = try await store.load()
        let movie = try await store.create(name: "Tour recording", format: .landscape)
        let ticket = try await store.begin(movieID: movie.id, format: .landscape, profile: .standard)
        let writer = try ContinuousTakeWriter(url: try await store.url(ticket.staging), angle: 0)
        let rear = try frame(red: 0, green: 0, blue: 220), front = try frame(red: 220, green: 0, blue: 0)
        let renderer = PiPFrameRenderer(); var timeline = PiPTimeline()
        for index in 0..<36 {
            let time = CMTime(value: Int64(index), timescale: 30)
            if index == 6 { timeline.setEnabled(true, at: time) }
            if index == 18 {
                timeline.drag(to: CGPoint(x: 0.15, y: 0.25), at: time, canvas: writer.canvas, obstacles: [])
                timeline.settle(at: time, canvas: writer.canvas, obstacles: [])
            }
            if index == 27 { timeline.setEnabled(false, at: time) }
            let image = PiPCompositor.image(background: rear, presenter: front, canvas: writer.canvas, backgroundAngle: 0,
                presenterAngle: 0, presentation: timeline.presentation(at: time, canvas: writer.canvas))
            let buffer = try XCTUnwrap(renderer.render(image, canvas: writer.canvas))
            var accepted = false
            for _ in 0..<100 {
                if writer.appendRenderedVideo(buffer, at: time) { accepted = true; break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(accepted); writer.appendAudio(try audio(at: time))
        }
        let done = expectation(description: "PiP take closes once")
        writer.finish { error in XCTAssertNil(error); done.fulfill() }; await fulfillment(of: [done], timeout: 30)
        try await store.commit(ticket)
        var settings = FilmEffectsSettings(); settings.grainEnabled = true; settings.grainAmount = 0.05
        try await store.setFilmEffects(movieID: movie.id, settings: settings)
        let movies = await store.snapshot(); let saved = try XCTUnwrap(movies.first)
        XCTAssertEqual(saved.activeScenes.count, 1); XCTAssertTrue(saved.activeScenes[0].hasAudio)
        let asset = AVURLAsset(url: try await store.url(saved.activeScenes[0].source))
        let videoTracks = try await asset.loadTracks(withMediaType: .video), audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(videoTracks.count, 1); XCTAssertEqual(audioTracks.count, 1)
        let audioRange = try await XCTUnwrap(audioTracks.first).load(.timeRange)
        XCTAssertGreaterThan(audioRange.duration.seconds, 1.1)
        let composition = try await MediaAssembler().build(movie: saved, root: root, filmEffects: settings)
        let output = root.appendingPathComponent("PiP-export.mp4")
        let export = try XCTUnwrap(AVAssetExportSession(asset: composition.asset, presetName: AVAssetExportPresetHighestQuality))
        export.videoComposition = composition.videoComposition; export.audioMix = composition.audioMix
        try await export.export(to: output, as: .mp4)
        let exported = AVURLAsset(url: output)
        let generator = AVAssetImageGenerator(asset: exported); generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        func pixel(at time: Double, corner: PiPCorner) async throws -> [UInt8] {
            let (cg, _) = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 30))
            let rect = try XCTUnwrap(PiPGeometry.rect(layout: PiPLayout(corner: corner), canvas: writer.canvas))
            return sample(CIImage(cgImage: cg), point: CGPoint(x: rect.midX * writer.canvas.width, y: (1 - rect.midY) * writer.canvas.height))
        }
        let before = try await pixel(at: 2 / 30, corner: .bottomRight)
        let visible = try await pixel(at: 13 / 30, corner: .bottomRight)
        let moved = try await pixel(at: 24 / 30, corner: .topLeft)
        let hidden = try await pixel(at: 35 / 30, corner: .topLeft)
        XCTAssertGreaterThan(before[2], 150); XCTAssertGreaterThan(visible[0], 150)
        XCTAssertGreaterThan(moved[0], 150); XCTAssertGreaterThan(hidden[2], 150)
    }
}

