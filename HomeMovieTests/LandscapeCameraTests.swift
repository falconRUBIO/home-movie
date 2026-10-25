import XCTest
import UIKit
@testable import HomeMovie

final class LandscapeCameraTests: XCTestCase {
    func testLandscapePreviewConsumesFullHeightWithOnlyOneSlimRail() {
        // iPhone landscape area after the leading notch inset; top, bottom and
        // trailing safe-area padding are removed by the camera surface.
        for size in [CGSize(width: 794, height: 393), CGSize(width: 852, height: 393), CGSize(width: 896, height: 414)] {
            let layout = CameraViewportLayout(size: size, landscape: true)
            XCTAssertEqual(layout.preview.minX, 0)
            XCTAssertEqual(layout.preview.minY, 0)
            XCTAssertEqual(layout.preview.height, size.height)
            XCTAssertEqual(layout.preview.maxX, layout.controls.minX)
            XCTAssertEqual(layout.controls.width, 96)
            XCTAssertEqual(layout.controls.maxX, size.width)
            XCTAssertEqual(layout.controls.height, size.height)
        }
    }
    func testOppositeLandscapeKeepsPreviewAndControlsOutsideTheNotchSide() {
        let size = CGSize(width: 794, height: 393)
        let layout = CameraViewportLayout(size: size, landscape: true, controlsOnLeading: true)
        XCTAssertEqual(layout.controls.minX, 0)
        XCTAssertEqual(layout.controls.width, 96)
        XCTAssertEqual(layout.preview.minX, layout.controls.maxX)
        XCTAssertEqual(layout.preview.maxX, size.width)
        XCTAssertEqual(layout.preview.height, size.height)
        let pip = CameraViewportLayout(size: size, landscape: true, controlsOnLeading: true, canvasAspect: 9.0 / 16.0)
        XCTAssertGreaterThanOrEqual(pip.preview.minX, pip.controls.maxX)
        XCTAssertLessThanOrEqual(pip.preview.maxX, size.width)
    }

    func testPortraitAndExplicitPiPCanvasKeepTheirExistingAspect() {
        let portrait = CameraViewportLayout(size: CGSize(width: 390, height: 760), landscape: false)
        XCTAssertEqual(portrait.controls.height, 64)
        XCTAssertEqual(portrait.preview.width / portrait.preview.height, 9.0 / 16.0, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(portrait.preview.maxY, portrait.controls.minY)
        let pip = CameraViewportLayout(size: CGSize(width: 794, height: 393), landscape: true, canvasAspect: 9.0 / 16.0)
        XCTAssertEqual(pip.preview.width / pip.preview.height, 9.0 / 16.0, accuracy: 0.0001)
        XCTAssertEqual(pip.preview.height, 393)
        XCTAssertLessThan(pip.preview.maxX, pip.controls.minX)
    }
    func testRotationGateUsesPixelGeometryRatherThanAssumingFrontSensorOrientation() {
        let rear = CGSize(width: 1920, height: 1080)
        let portraitSensor = CGSize(width: 1080, height: 1920)
        XCTAssertTrue(CameraPreviewRotation.matches(source: rear, angle: 0, format: .landscape))
        XCTAssertTrue(CameraPreviewRotation.matches(source: rear, angle: 180, format: .landscape))
        XCTAssertFalse(CameraPreviewRotation.matches(source: rear, angle: 90, format: .landscape))
        XCTAssertTrue(CameraPreviewRotation.matches(source: portraitSensor, angle: 90, format: .landscape))
        XCTAssertFalse(CameraPreviewRotation.matches(source: portraitSensor, angle: 0, format: .landscape))
        XCTAssertTrue(CameraPreviewRotation.matches(source: portraitSensor, angle: 0, format: .portrait))
        XCTAssertFalse(CameraPreviewRotation.matches(source: rear, angle: .nan, format: .landscape))
    }
    @MainActor func testIdleCameraNeverReusesLastTakeOrientationAndRecordingKeepsItsLock() {
        let camera = CameraModel(app: AppModel())
        camera.takeFormat = .portrait; camera.state = .ready
        XCTAssertNil(camera.activeTakeOrientation)
        camera.state = .recording
        XCTAssertEqual(camera.activeTakeOrientation, .portrait)
        camera.takeFormat = .landscape
        XCTAssertEqual(camera.activeTakeOrientation, .landscape)
        camera.state = .finalizing
        XCTAssertEqual(camera.activeTakeOrientation, .landscape)
        camera.state = .ready
        XCTAssertNil(camera.activeTakeOrientation)
        camera.takeFormat = .portrait
        camera.options = CameraOptions(lenses: [], zoom: 1, minimum: 1, maximum: 8, multiplier: 1,
            isFront: false, angle: 0, profile: .standard, canMeter: false, canLock: false,
            focusLocked: false, exposureBias: 0, minimumExposureBias: -2, maximumExposureBias: 2,
            canFlip: true, hasTorch: false, torchOn: false, canStayOnLens: false,
            smoothMoving: false, recordingFormat: "Standard")
        camera.flip()
        XCTAssertTrue(camera.busy)
        XCTAssertTrue(camera.switchingCamera)
        XCTAssertNil(camera.activeTakeOrientation)
        XCTAssertNotNil(camera.switchingFormat)
    }
    @MainActor func testLandscapeLockPreservesCurrentSideAndUnlockAllowsBoth() {
        XCTAssertEqual(OrientationPolicy.orientationMask(format: .landscape, current: .landscapeLeft), .landscapeLeft)
        XCTAssertEqual(OrientationPolicy.orientationMask(format: .landscape, current: .landscapeRight), .landscapeRight)
        let unlocked = OrientationPolicy.orientationMask(format: nil, current: .landscapeRight)
        XCTAssertEqual(unlocked, .allButUpsideDown)
        XCTAssertTrue(OrientationPolicy.contains(unlocked, orientation: .landscapeRight))
        XCTAssertTrue(OrientationPolicy.contains(unlocked, orientation: .portrait))
        XCTAssertFalse(OrientationPolicy.contains(.landscapeRight, orientation: .portrait))
    }
    @MainActor func testStalePiPFadeCannotBlockOrdinaryCameraFlip() async {
        let camera = CameraModel(app: AppModel())
        camera.state = .ready
        var options = CameraOptions(lenses: [], zoom: 1, minimum: 1, maximum: 8, multiplier: 1,
            isFront: false, angle: 0, profile: .standard, canMeter: false, canLock: false,
            focusLocked: false, exposureBias: 0, minimumExposureBias: -2, maximumExposureBias: 2,
            canFlip: true, hasTorch: false, torchOn: false, canStayOnLens: false,
            smoothMoving: false, recordingFormat: "Standard")
        camera.options = options
        var stale = PiPPresentation(); stale.opacity = 1
        await camera.receive(.pipPresentation(stale))
        XCTAssertTrue(camera.canFlipCamera)
        options.dualCameraPrepared = true; camera.options = options
        XCTAssertFalse(camera.canFlipCamera)
        await camera.receive(.pipPresentation(PiPPresentation()))
        XCTAssertTrue(camera.canFlipCamera)
        options.isPiPEnabled = true; camera.options = options
        XCTAssertFalse(camera.canFlipCamera)
        options.isPiPEnabled = false; options.dualCameraPrepared = false
        camera.options = options; camera.state = .recording
        XCTAssertFalse(camera.canFlipCamera)
        options.canFlipWhileRecording = true; camera.options = options
        XCTAssertTrue(camera.canFlipCamera)
    }
}
