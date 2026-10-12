import XCTest
import UIKit
@testable import HomeMovie

final class CameraTouchTests: XCTestCase {
    @MainActor func testNativeHitTestingRoutesLensAndDollyTouchesAwayFromFocus() {
        // The viewfinder is deliberately above the control in UIKit ordering: even if
        // SwiftUI/Glass bridges reorder native surfaces, protected control taps pass through.
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        let lens = UIButton(frame: CGRect(x: 35, y: 520, width: 44, height: 44))
        container.addSubview(lens)
        let preview = PreviewUIView(frame: container.bounds)
        container.addSubview(preview)
        for region in [CGRect(x: 20, y: 515, width: 350, height: 52),
                       CGRect(x: 20, y: 405, width: 350, height: 162)] {
            preview.protectedRegions = [region]
            XCTAssertTrue(container.hitTest(CGPoint(x: 57, y: 542), with: nil) === lens)
            XCTAssertNil(preview.hitTest(CGPoint(x: 57, y: 542), with: nil))
            XCTAssertTrue(preview.hitTest(CGPoint(x: 180, y: 240), with: nil) === preview)
        }
    }
    @MainActor func testControlsHostedInsideNativePreviewKeepTheirHitTargets() {
        let preview = PreviewUIView(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        let button = UIButton(frame: CGRect(x: 35, y: 520, width: 44, height: 44))
        preview.addSubview(button)
        preview.protectedRegions = [CGRect(x: 20, y: 515, width: 350, height: 52)]
        XCTAssertTrue(preview.hitTest(CGPoint(x: 57, y: 542), with: nil) === button)
        XCTAssertFalse(preview.permitsPreviewInteraction(at: CGPoint(x: 57, y: 542)))
    }
    @MainActor func testProtectedRegionsFollowRotationAndDoNotDisableTheViewfinder() {
        let preview = PreviewUIView(frame: CGRect(x: 0, y: 0, width: 650, height: 365))
        preview.protectedRegions = [CGRect(x: 140, y: 295, width: 360, height: 52),
                                    CGRect(x: 555, y: 140, width: 78, height: 78)]
        XCTAssertNil(preview.hitTest(CGPoint(x: 320, y: 320), with: nil))
        XCTAssertNil(preview.hitTest(CGPoint(x: 590, y: 180), with: nil))
        XCTAssertNotNil(preview.hitTest(CGPoint(x: 320, y: 180), with: nil))
        preview.protectedRegions = [CGRect(x: 140, y: 190, width: 360, height: 157)]
        XCTAssertNil(preview.hitTest(CGPoint(x: 320, y: 230), with: nil))
        XCTAssertNotNil(preview.hitTest(CGPoint(x: 50, y: 230), with: nil))
    }
}
