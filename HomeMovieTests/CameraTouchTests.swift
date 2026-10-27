import XCTest
import UIKit
import AVFoundation
@testable import HomeMovie

final class CameraTouchTests: XCTestCase {
    func testForegroundResumeWaitsForSavingThenRunsOnlyOnce() {
        var resume = CameraForegroundResume()
        resume.request()
        for _ in 0..<3 {
            XCTAssertFalse(resume.consumeIfReady(state: .finalizing, busy: true, foreground: true,
                cameraVisible: true, recoverableTake: false))
            XCTAssertTrue(resume.pending)
        }
        XCTAssertTrue(resume.consumeIfReady(state: .interrupted, busy: false, foreground: true,
            cameraVisible: true, recoverableTake: false))
        XCTAssertFalse(resume.consumeIfReady(state: .ready, busy: false, foreground: true,
            cameraVisible: true, recoverableTake: false))
    }
    func testForegroundResumeCancelsOnDepartureFailureAndRecoverableClip() {
        for scenario in 0..<4 {
            var resume = CameraForegroundResume(); resume.request()
            XCTAssertFalse(resume.consumeIfReady(state: scenario == 2 ? .failed : .interrupted,
                busy: false, foreground: scenario != 0, cameraVisible: scenario != 1,
                recoverableTake: scenario == 3))
            XCTAssertFalse(resume.pending)
            XCTAssertFalse(resume.consumeIfReady(state: .ready, busy: false, foreground: true,
                cameraVisible: true, recoverableTake: false))
        }
        var resume = CameraForegroundResume(); resume.request(); resume.cancel()
        XCTAssertFalse(resume.consumeIfReady(state: .interrupted, busy: false, foreground: true,
            cameraVisible: true, recoverableTake: false))
    }
    func testForegroundResumeCanRecheckPermissionsAndCancelledPreparation() {
        for state in [CameraState.denied, .preparing, .ready] {
            var resume = CameraForegroundResume(); resume.request()
            XCTAssertTrue(resume.consumeIfReady(state: state, busy: false, foreground: true,
                cameraVisible: true, recoverableTake: false))
        }
    }
    func testCameraHandoffWaitsForFreshOrderedFramesAndResetsAfterStall() {
        func time(_ value: Double) -> CMTime { CMTime(seconds: value, preferredTimescale: 600) }
        var gate = CameraPreviewHandoff(after: time(10))
        XCTAssertFalse(gate.accept(time(9.9)))
        XCTAssertFalse(gate.accept(time(10.01)))
        XCTAssertFalse(gate.accept(time(10.01)))
        XCTAssertFalse(gate.accept(time(10.04)))
        XCTAssertTrue(gate.accept(time(10.07)))
        var stalled = CameraPreviewHandoff(after: time(10))
        XCTAssertFalse(stalled.accept(time(10.01)))
        XCTAssertFalse(stalled.accept(time(10.5)))
        XCTAssertFalse(stalled.accept(time(10.53)))
        XCTAssertTrue(stalled.accept(time(10.56)))
    }

    @MainActor func testDollyCountdownRunsDuringRecordingAndCanBeCancelledWithoutStoppingTake() async throws {
        let model = CameraModel(app: AppModel())
        model.state = .recording
        let countdown = RecordingCountdown(tick: .milliseconds(10))
        let started = expectation(description: "Dolly starts after delay")
        var moves = 0
        countdown.start(seconds: 3, canStart: { model.state == .recording }, onStart: {
            moves += 1; started.fulfill()
        })
        XCTAssertEqual(countdown.remaining, 3)
        XCTAssertEqual(moves, 0)
        XCTAssertTrue(model.recordingSessionActive)
        await fulfillment(of: [started], timeout: 1)
        XCTAssertEqual(moves, 1); XCTAssertEqual(model.state, .recording)
        countdown.start(seconds: 3, canStart: { model.state == .recording }, onStart: { moves += 1 })
        countdown.cancel()
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertNil(countdown.remaining)
        XCTAssertEqual(moves, 1); XCTAssertEqual(model.state, .recording)
    }
    @MainActor func testPendingDollyDoesNotStartAfterRecordingStops() async throws {
        let model = CameraModel(app: AppModel())
        model.state = .recording
        let countdown = RecordingCountdown(tick: .milliseconds(10))
        var moves = 0
        countdown.start(seconds: 3, canStart: { model.state == .recording }, onStart: { moves += 1 })
        model.state = .finalizing
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(moves, 0); XCTAssertNil(countdown.remaining)
    }

    func testLateManualZoomCancellationCannotEndNewerDialOrDolly() {
        var owner = ManualZoomSession()
        let old = UUID(), current = UUID()
        owner.begin(old); XCTAssertTrue(owner.accepts(old))
        owner.begin(current)
        XCTAssertFalse(owner.end(old)); XCTAssertTrue(owner.accepts(current))
        XCTAssertTrue(owner.end(current)); XCTAssertFalse(owner.accepts(current))
        XCTAssertTrue(owner.isOpen) // Settling still owns the camera switching policy.
        owner.clear() // Dolly takes over, or the camera stops.
        XCTAssertFalse(owner.end(current)); XCTAssertFalse(owner.isOpen)
    }

    func testManualDialMovesScaleWithFingerAndUsesProportionalTravel() {
        XCTAssertEqual(ManualZoomScale.factor(start: 1, translation: 0, minimum: 0.5, maximum: 24), 1, accuracy: 0.00001)
        // Higher marks sit to the right; dragging the wheel left brings them to center.
        XCTAssertEqual(ManualZoomScale.factor(start: 1, translation: -48, minimum: 0.5, maximum: 24), 2, accuracy: 0.00001)
        XCTAssertEqual(ManualZoomScale.factor(start: 8, translation: -48, minimum: 0.5, maximum: 24), 16, accuracy: 0.00001)
        XCTAssertEqual(ManualZoomScale.factor(start: 8, translation: 48, minimum: 0.5, maximum: 24), 4, accuracy: 0.00001)
    }
    func testManualDialClampsAtActiveDeviceLimitsAndReverses() {
        let end = ManualZoomScale.factor(start: 2, translation: -67, minimum: 0.5, maximum: 24)
        XCTAssertEqual(ManualZoomScale.factor(start: end, translation: 67, minimum: 0.5, maximum: 24), 2, accuracy: 0.00001)
        XCTAssertEqual(ManualZoomScale.factor(start: 1, translation: -10000, minimum: 0.5, maximum: 24), 24, accuracy: 0.00001)
        XCTAssertEqual(ManualZoomScale.factor(start: 1, translation: 10000, minimum: 0.5, maximum: 24), 0.5, accuracy: 0.00001)
        XCTAssertEqual(ManualZoomScale.factor(start: 1, translation: -48, minimum: 1, maximum: 1), 1)
    }
    func testManualDialRejectsInvalidInputAndDisplaysDeviceMultiplier() {
        XCTAssertEqual(ManualZoomScale.factor(start: .nan, translation: 2, minimum: 0.5, maximum: 24), 0.5)
        XCTAssertEqual(ManualZoomScale.factor(start: 1, translation: .infinity, minimum: 1, maximum: 24), 1)
        XCTAssertEqual(ManualZoomScale.label(1 * 0.5), "0.5×")
        XCTAssertEqual(ManualZoomScale.label(48 * 0.5), "24×")
        XCTAssertEqual(ManualZoomScale.label(1.7), "1.7×")
    }

    func testExtendedZoomUsesDisplayMultiplierAndActiveDeviceLimits() {
        let targets = ExtendedZoomTargets.available(minimum: 1, maximum: 48, multiplier: 0.5)
        XCTAssertEqual(targets, [20, 30, 40, 48])
        XCTAssertEqual(ExtendedZoomTargets.available(minimum: 1, maximum: 7, multiplier: 1), [7])
        XCTAssertTrue(ExtendedZoomTargets.available(minimum: 1, maximum: 24, multiplier: 0).isEmpty)
        XCTAssertTrue(ExtendedZoomTargets.available(minimum: 1, maximum: .infinity, multiplier: 1).isEmpty)
    }

    func testDualCameraStabilizesBothStreamsWithoutCinematicOrPreviewOnlyModes() {
        for front in [true, false] {
            XCTAssertEqual(CameraStabilization.dualCameraMode(front: front, supports: { $0 == .standard }), .standard)
            XCTAssertEqual(CameraStabilization.dualCameraMode(front: front, supports: { _ in false }), .off)
            XCTAssertEqual(CameraStabilization.dualCameraMode(front: front, supports: {
                [.auto, .cinematic, .cinematicExtended, .previewOptimized].contains($0)
            }), .off)
            if #available(iOS 26.0, *) {
                XCTAssertEqual(CameraStabilization.dualCameraMode(front: front, supports: { _ in true }), .lowLatency)
            }
        }
    }
    func testFrontRecordingPrefersSupportedLowLatencyWithoutChangingRearPolicy() {
        if #available(iOS 26.0, *) {
            XCTAssertEqual(CameraStabilization.preferredMode(preview: false, front: true, supports: { _ in true }), .lowLatency)
            XCTAssertEqual(CameraStabilization.preferredMode(preview: false, front: false, supports: { _ in true }), .auto)
        }
        XCTAssertEqual(CameraStabilization.preferredMode(preview: false, front: true, supports: { $0 == .standard }), .auto)
    }

    func testRecordingDoesNotOverridePreviewLensSelectionWithASeparateRestrictedPolicy() {
        let output = AVCaptureMovieFileOutput()
        CameraVideoTuning.configureRecordingOutput(output)
        XCTAssertFalse(output.isPrimaryConstituentDeviceSwitchingBehaviorForRecordingEnabled)
    }
    func testRecordingFlipCannotResumeUntilFootageIsSavedAndCameraIsAvailable() {
        let movieID = UUID(), elapsed = CMTime(seconds: 12, preferredTimescale: 600)
        var handoff = RecordingFlipHandoff(movieID: movieID, elapsed: elapsed)
        XCTAssertFalse(handoff.mayResume(active: true, interrupted: false))
        handoff.footageSaved()
        XCTAssertTrue(handoff.mayResume(active: true, interrupted: false))
        XCTAssertFalse(handoff.mayResume(active: false, interrupted: false))
        XCTAssertFalse(handoff.mayResume(active: true, interrupted: true))
        XCTAssertEqual(handoff.movieID, movieID); XCTAssertEqual(handoff.elapsed, elapsed)
    }
    @MainActor func testLateCameraSwitchCallbacksCannotResetAnActiveOrInterruptedRecording() async {
        let app = AppModel(), model = CameraModel(app: app)
        let options = CameraOptions(lenses: [], zoom: 1, minimum: 1, maximum: 8, multiplier: 1,
            isFront: true, angle: 90, profile: .standard, canMeter: false, canLock: false,
            focusLocked: false, exposureBias: 0, minimumExposureBias: -2, maximumExposureBias: 2,
            canFlip: true, hasTorch: false, torchOn: false, canStayOnLens: false,
            smoothMoving: false, recordingFormat: "Standard")
        model.state = .recording
        await model.receive(.cameraChanged(options))
        XCTAssertEqual(model.state, .recording)
        model.state = .preparing
        await model.receive(.cameraChanged(options))
        XCTAssertEqual(model.state, .ready)
        await model.receive(.interrupted("Test interruption"))
        await model.receive(.cameraChanged(options))
        XCTAssertEqual(model.state, .interrupted)
        XCTAssertNil(model.recordingFlip)
    }
    func testRecordingLeavesDeviceAndFormatNegotiationToApple() {
        for supported in [[AVCaptureVideoStabilizationMode.previewOptimized], [.standard], []] {
            XCTAssertEqual(CameraStabilization.preferredMode(preview: false, supports: { supported.contains($0) }), .auto)
        }
    }
    func testPreviewUsesResponsiveSupportedModesWithOlderFormatFallbacks() {
        XCTAssertEqual(CameraStabilization.preferredMode(preview: true, supports: { [.previewOptimized, .standard].contains($0) }), .previewOptimized)
        XCTAssertEqual(CameraStabilization.preferredMode(preview: true, supports: { $0 == .standard }), .standard)
        XCTAssertEqual(CameraStabilization.preferredMode(preview: true, supports: { _ in false }), .auto)
    }
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
