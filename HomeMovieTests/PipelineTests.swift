import XCTest
import AVFoundation
import CoreImage
import MetalKit
@testable import HomeMovie

final class PipelineTests: XCTestCase {
    func testSceneAudioEdgesFadeAtActualOffsetsAndKeepFullVolumeBetweenCuts() {
        let parameters = AVMutableAudioMixInputParameters()
        MediaAssembler.smoothAudioEdges(parameters, range: CMTimeRange(start: CMTime(seconds: 2.25, preferredTimescale: 48000), duration: CMTime(seconds: 1, preferredTimescale: 48000)))
        var start: Float = -1, end: Float = -1, range = CMTimeRange.invalid
        XCTAssertTrue(parameters.getVolumeRamp(for: CMTime(seconds: 2.252, preferredTimescale: 48000), startVolume: &start, endVolume: &end, timeRange: &range))
        XCTAssertEqual(start, 0); XCTAssertEqual(end, 1)
        XCTAssertEqual(range.start.seconds, 2.25, accuracy: 0.00001)
        XCTAssertEqual(range.duration.seconds, 0.005, accuracy: 0.00001)
        XCTAssertTrue(parameters.getVolumeRamp(for: CMTime(seconds: 2.75, preferredTimescale: 48000), startVolume: &start, endVolume: &end, timeRange: &range))
        XCTAssertEqual(start, 1); XCTAssertEqual(end, 1)
        XCTAssertTrue(parameters.getVolumeRamp(for: CMTime(seconds: 3.248, preferredTimescale: 48000), startVolume: &start, endVolume: &end, timeRange: &range))
        XCTAssertEqual(start, 1); XCTAssertEqual(end, 0)
        XCTAssertEqual(CMTimeRangeGetEnd(range).seconds, 3.25, accuracy: 0.00001)
    }
    func testVeryShortSceneAudioFadesDoNotOverlap() {
        let parameters = AVMutableAudioMixInputParameters()
        MediaAssembler.smoothAudioEdges(parameters, range: CMTimeRange(start: .zero, duration: CMTime(value: 192, timescale: 48000)))
        var start: Float = -1, end: Float = -1, range = CMTimeRange.invalid
        XCTAssertTrue(parameters.getVolumeRamp(for: CMTime(value: 48, timescale: 48000), startVolume: &start, endVolume: &end, timeRange: &range))
        XCTAssertEqual(start, 0); XCTAssertEqual(end, 1)
        XCTAssertEqual(range.duration.seconds, 0.002, accuracy: 0.00001)
        XCTAssertTrue(parameters.getVolumeRamp(for: CMTime(value: 144, timescale: 48000), startVolume: &start, endVolume: &end, timeRange: &range))
        XCTAssertEqual(start, 1); XCTAssertEqual(end, 0)
        XCTAssertEqual(range.start.seconds, 0.002, accuracy: 0.00001)
    }
    func testAudioMixSurvivesSilentSceneGapsTrimsAndExport() async throws {
        let store = try await makeStore(), movie = try await store.create(name: "Audio cuts", format: .landscape)
        _ = try await record(movie, into: store)
        let ticket = try await store.begin(movieID: movie.id), target = try await store.url(ticket.staging)
        let video = store.root.appendingPathComponent("tone-video.mov"), wave = store.root.appendingPathComponent("tone.m4a")
        try await footage(video)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96000))
        buffer.frameLength = 96000
        let samples = try XCTUnwrap(buffer.floatChannelData)[0]
        for frame in 0..<96000 { samples[frame] = Float(sin(Double(frame) * 2 * .pi * 440 / 48000) * 0.5) }
        do {
            let audioFile = try AVAudioFile(forWriting: wave, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 128000],
                commonFormat: .pcmFormatFloat32, interleaved: false)
            try audioFile.write(from: buffer)
        }
        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: video), audioAsset = AVURLAsset(url: wave)
        defer { withExtendedLifetime((videoAsset, audioAsset)) {} }
        let videoTracks = try await videoAsset.loadTracks(withMediaType: .video)
        let audioTracks: [AVAssetTrack]
        do { audioTracks = try await audioAsset.loadTracks(withMediaType: .audio) }
        catch { XCTFail("AAC fixture load failed: \(error)"); throw error }
        let sourceVideo = try XCTUnwrap(videoTracks.first), sourceAudio = try XCTUnwrap(audioTracks.first)
        let videoTrack = try XCTUnwrap(composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
        let audioTrack = try XCTUnwrap(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
        let full = CMTimeRange(start: .zero, duration: CMTime(seconds: 2, preferredTimescale: 48000))
        let videoRange = try await sourceVideo.load(.timeRange), audioRange = try await sourceAudio.load(.timeRange)
        do {
            try videoTrack.insertTimeRange(CMTimeRangeGetIntersection(full, otherRange: videoRange), of: sourceVideo, at: .zero)
            try audioTrack.insertTimeRange(CMTimeRangeGetIntersection(full, otherRange: audioRange), of: sourceAudio, at: .zero)
        } catch { XCTFail("Audio fixture track assembly failed: \(error)"); throw error }
        let fixture = try XCTUnwrap(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality))
        do { try await fixture.export(to: target, as: .mov) }
        catch { XCTFail("Audio fixture mux failed: \(error)"); throw error }
        try await store.commit(ticket)
        try await store.trim(movieID: movie.id, sceneID: ticket.sceneID, start: CMTime(seconds: 0.25, preferredTimescale: 48000), end: CMTime(seconds: 1.25, preferredTimescale: 48000))
        _ = try await record(movie, into: store)
        let movies = await store.snapshot(); let snapshot = try XCTUnwrap(movies.first)
        let bundle = try await MediaAssembler().build(movie: snapshot, root: store.root)
        XCTAssertEqual(bundle.duration.seconds, 5, accuracy: 0.0001)
        let mix = try XCTUnwrap(bundle.audioMix), parameters = try XCTUnwrap(mix.inputParameters.first)
        var start: Float = -1, end: Float = -1, range = CMTimeRange.invalid
        XCTAssertTrue(parameters.getVolumeRamp(for: CMTime(seconds: 2.002, preferredTimescale: 48000), startVolume: &start, endVolume: &end, timeRange: &range))
        XCTAssertEqual(start, 0); XCTAssertEqual(end, 1); XCTAssertEqual(range.start.seconds, 2, accuracy: 0.0001)
        XCTAssertTrue(parameters.getVolumeRamp(for: CMTime(seconds: 2.998, preferredTimescale: 48000), startVolume: &start, endVolume: &end, timeRange: &range))
        XCTAssertEqual(start, 1); XCTAssertEqual(end, 0)
        let output = store.root.appendingPathComponent("smoothed.mp4")
        let exporter = try XCTUnwrap(AVAssetExportSession(asset: bundle.asset, presetName: AVAssetExportPresetHighestQuality))
        exporter.videoComposition = bundle.videoComposition; exporter.audioMix = mix
        do { try await exporter.export(to: output, as: .mp4) }
        catch { XCTFail("Scene audio mix export failed: \(error)"); throw error }
        let info = try await MediaInspector.inspect(output)
        XCTAssertTrue(info.hasAudio); XCTAssertEqual(info.duration.seconds, 5, accuracy: 0.15)
    }
    @MainActor func testLateCameraReadyUpdatesDoNotHideFailureOrInterruption() async throws {
        let app = AppModel(store: try await makeStore())
        // Keep the model's weak application owner alive for the complete test.
        let ownedCamera = CameraModel(app: app)
        let options = CameraOptions(lenses: [], zoom: 1, minimum: 1, maximum: 8, multiplier: 1,
            isFront: false, angle: 90, profile: .standard, canMeter: false, canLock: false,
            focusLocked: false, exposureBias: 0, minimumExposureBias: 0, maximumExposureBias: 0,
            canFlip: false, hasTorch: false, torchOn: false, canStayOnLens: false,
            smoothMoving: false, recordingFormat: "Standard · H.264")
        for state in [CameraState.failed, .interrupted, .denied, .starting, .recording, .finalizing] {
            ownedCamera.state = state; ownedCamera.message = "Preserved recording error"
            await ownedCamera.receive(.ready(options))
            XCTAssertEqual(ownedCamera.state, state)
            XCTAssertEqual(ownedCamera.message, "Preserved recording error")
        }
        ownedCamera.state = .preparing
        await ownedCamera.receive(.ready(options))
        XCTAssertEqual(ownedCamera.state, .ready, "An explicit retry can become ready")
    }
    func testLiveLogLookRemainsEnabledWhileSaving() {
        for state in [CameraState.ready, .starting, .recording, .finalizing] { XCTAssertTrue(state.showsLiveLook) }
        for state in [CameraState.preparing, .failed, .denied, .interrupted] { XCTAssertFalse(state.showsLiveLook) }
    }
    @MainActor func testHandsFreeCountdownCancellationRestartAndDuplicateStart() async {
        let countdown = RecordingCountdown(tick: .milliseconds(1))
        var cancelledStarts = 0, completedStarts = 0
        countdown.start(canStart: { true }, onStart: { cancelledStarts += 1 })
        XCTAssertEqual(countdown.remaining, 3)
        countdown.cancel(); XCTAssertNil(countdown.remaining)
        let started = expectation(description: "Only the new countdown starts recording")
        countdown.start(canStart: { true }, onStart: { completedStarts += 1; started.fulfill() })
        countdown.start(canStart: { true }, onStart: { XCTFail("A second Record tap must not create another start") })
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(cancelledStarts, 0)
        XCTAssertEqual(completedStarts, 1)
        XCTAssertNil(countdown.remaining)
    }
    @MainActor func testHandsFreeCountdownRechecksCameraAvailability() async {
        let countdown = RecordingCountdown(tick: .milliseconds(1))
        var available = true
        let unexpected = expectation(description: "Unavailable camera must not start")
        unexpected.isInverted = true
        countdown.start(canStart: { available }, onStart: { unexpected.fulfill() })
        available = false
        await fulfillment(of: [unexpected], timeout: 0.2)
        XCTAssertNil(countdown.remaining)
        countdown.start(canStart: { false }, onStart: { XCTFail("Do not schedule an unavailable camera") })
        XCTAssertNil(countdown.remaining)
    }
    func testTimedDollyWaitsForFullDurationEvenNearTarget() throws {
        var filter = try XCTUnwrap(SmoothZoomFilter(current: 1, minimum: 1, maximum: 16))
        filter.setTarget(8, duration: 10)
        _ = filter.advance(seconds: 9.99, rate: 0.75)
        XCTAssertLessThan(abs(log2(filter.value / filter.target)), 0.0002)
        XCTAssertFalse(filter.isSettled, "A small zoom error must not cut short the requested duration")
        XCTAssertEqual(try XCTUnwrap(filter.remainingDuration), 0.01, accuracy: 0.000001)
        _ = filter.advance(seconds: 0.01, rate: 0.75)
        XCTAssertTrue(filter.isSettled); XCTAssertEqual(filter.value, 8, accuracy: 0.00001)
    }
    func testTimedDollyUsesElapsedTimeAndPreservesRemainingTimeOnRangeChange() throws {
        var filter = try XCTUnwrap(SmoothZoomFilter(current: 1, minimum: 1, maximum: 16))
        filter.setTarget(8, duration: 3)
        _ = filter.advance(seconds: 1.5, rate: 0.75)
        XCTAssertEqual(filter.value, sqrt(8), accuracy: 0.0001)
        var changed = try XCTUnwrap(SmoothZoomFilter(current: filter.value, minimum: 1, maximum: 8))
        changed.setTarget(filter.target, duration: filter.remainingDuration)
        _ = changed.advance(seconds: 1.5, rate: 0.75)
        XCTAssertTrue(changed.isSettled); XCTAssertEqual(changed.value, 8, accuracy: 0.0001)
    }
    func testOrphanRecoveryKeepsStandardOutOfAnExistingLogRecoveryMovie() async throws {
        let store = try await makeStore()
        let logMovie = try await store.create(name: "Recovered Recordings", format: .portrait, profile: .appleLog)
        let orphan = store.root.appendingPathComponent("Staging/\(UUID().uuidString).mov")
        try await footage(orphan)
        let bytes = try Data(contentsOf: orphan)
        let reopened = ProjectStore(root: store.root); _ = try await reopened.load()
        let movies = await reopened.snapshot()
        let existing = try XCTUnwrap(movies.first { $0.id == logMovie.id })
        XCTAssertTrue(existing.scenes.isEmpty); XCTAssertEqual(existing.captureProfile, .appleLog)
        let recovered = try XCTUnwrap(movies.first { $0.id != logMovie.id && $0.name == "Recovered Recordings" })
        XCTAssertEqual(recovered.captureProfile, .standard)
        let scene = try XCTUnwrap(recovered.activeScenes.first)
        XCTAssertEqual(scene.profile, .standard)
        XCTAssertEqual(try Data(contentsOf: store.root.appendingPathComponent(scene.source)), bytes)
    }

    @MainActor func testPhotosExportRetryClearsEarlierError() async {
        actor Writer {
            var calls = 0
            func write(_ url: URL) throws -> String {
                calls += 1
                if calls == 1 { throw HomeMovieError.message("Temporary Photos failure") }
                return "saved-asset"
            }
        }
        let writer = Writer()
        let model = ExportModel(authorizePhotos: { true }, writePhotosVideo: { try await writer.write($0) })
        model.exportedURL = URL(fileURLWithPath: "/tmp/fixture-export.mp4")
        await model.saveToPhotos(); XCTAssertNotNil(model.error); XCTAssertNil(model.notice)
        await model.saveToPhotos(); XCTAssertNil(model.error); XCTAssertNotNil(model.notice)
    }
    @MainActor func testPhotosExportDoesNotClaimSuccessWithoutAReceipt() async {
        let model = ExportModel(authorizePhotos: { true }, writePhotosVideo: { _ in "" })
        model.exportedURL = URL(fileURLWithPath: "/tmp/fixture-export.mp4")
        model.notice = "Old successful save"
        await model.saveToPhotos()
        XCTAssertNotNil(model.error); XCTAssertNil(model.notice)
    }
    @MainActor func testDeniedPhotosExportNeverRequestsAWrite() async {
        let model = ExportModel(authorizePhotos: { false }, writePhotosVideo: { _ in
            XCTFail("Denied permission must not write to Photos"); return "unexpected"
        })
        model.exportedURL = URL(fileURLWithPath: "/tmp/fixture-export.mp4")
        await model.saveToPhotos(); XCTAssertNotNil(model.error); XCTAssertNil(model.notice)
    }
    @MainActor func testConcurrentPhotosExportsDoNotCreateDuplicateWrites() async {
        actor Writer {
            var calls = 0
            private var pending: CheckedContinuation<Void, Never>?
            func write(_ url: URL) async -> String {
                calls += 1
                await withCheckedContinuation { pending = $0 }
                return "saved-asset"
            }
            func finish() { pending?.resume(); pending = nil }
        }
        let writer = Writer()
        let model = ExportModel(authorizePhotos: { true }, writePhotosVideo: { await writer.write($0) })
        model.exportedURL = URL(fileURLWithPath: "/tmp/fixture-export.mp4")
        let first = Task { await model.saveToPhotos() }
        for _ in 0..<1000 {
            let calls = await writer.calls
            if calls > 0 { break }
            await Task.yield()
        }
        let startedCalls = await writer.calls
        guard startedCalls == 1 else { first.cancel(); XCTFail("First save did not start"); return }
        await model.saveToPhotos() // The first write is deliberately still in flight.
        let calls = await writer.calls
        await writer.finish(); await first.value
        XCTAssertEqual(calls, 1); XCTAssertNil(model.error); XCTAssertNotNil(model.notice)
    }

    func testLogCodecPrefersHEVCAndSupportsNativeProResWithoutSDRFallback() {
        XCTAssertEqual(LogRecordingCodec.preferred(in: [LogRecordingCodec.proRes422, .hevc, LogRecordingCodec.proResLT]), .hevc)
        XCTAssertEqual(LogRecordingCodec.preferred(in: [LogRecordingCodec.proRes422, LogRecordingCodec.proResLT]), LogRecordingCodec.proResLT)
        XCTAssertEqual(LogRecordingCodec.preferred(in: [LogRecordingCodec.proRes422]), LogRecordingCodec.proRes422)
        XCTAssertNil(LogRecordingCodec.preferred(in: [.h264]))
        XCTAssertNil(LogRecordingCodec.preferred(in: []))
    }

    @MainActor func testLiveLookCompletionCannotRevealOriginalOrInactivePreview() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let renderer = LiveLookRenderer(device: device) else {
            throw XCTSkip("Metal preview is unavailable on this simulator")
        }
        let frames = LiveFrames(), cube = try ColorCube.appleStandard.get()
        renderer.configure(frames: frames, cube: cube, active: true)
        let graded = renderer.presentationID
        XCTAssertTrue(renderer.canPresent(graded))
        renderer.configure(frames: frames, cube: nil, active: true)
        XCTAssertFalse(renderer.canPresent(graded), "A finishing GPU frame must not reveal a look after Show Original")
        renderer.configure(frames: frames, cube: cube, active: true)
        let resumed = renderer.presentationID
        XCTAssertFalse(renderer.canPresent(graded))
        XCTAssertTrue(renderer.canPresent(resumed))
        renderer.configure(frames: frames, cube: cube, active: false)
        XCTAssertFalse(renderer.canPresent(resumed), "Leaving capture must invalidate in-flight presentation")
    }
    @MainActor func testLiveLookSwitchRejectsPreviousFrameWithoutInvalidatingSameLook() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let renderer = LiveLookRenderer(device: device) else {
            throw XCTSkip("Metal preview is unavailable on this simulator")
        }
        let frames = LiveFrames(), cube = try ColorCube.appleStandard.get()
        renderer.configure(frames: frames, cube: cube, active: true)
        let initial = renderer.presentationID
        renderer.configure(frames: frames, cube: cube, active: true)
        XCTAssertTrue(renderer.canPresent(initial), "Timer and metering updates must not invalidate an unchanged look")
        var changed = cube; changed.minimum = [-1, -1, -1]
        renderer.configure(frames: frames, cube: changed, active: true)
        XCTAssertFalse(renderer.canPresent(initial), "Switching looks must reject an old frame even with identical samples")
        XCTAssertTrue(renderer.canPresent(renderer.presentationID))
        let current = renderer.presentationID
        renderer.configure(frames: LiveFrames(), cube: changed, active: true)
        XCTAssertFalse(renderer.canPresent(current), "A different capture source must invalidate the previous frame")
    }
    func testSmoothZoomOpeningDoesNotMoveAndInvalidTargetsAreIgnored() throws {
        var filter = try XCTUnwrap(SmoothZoomFilter(current: 3.2, minimum: 1, maximum: 16))
        XCTAssertEqual(filter.value, 3.2); XCTAssertEqual(filter.target, 3.2)
        XCTAssertEqual(filter.advance(seconds: 0.05, rate: 0.75), 3.2, accuracy: 0.0001)
        filter.setTarget(.nan); filter.setTarget(.infinity); filter.setTarget(-2)
        XCTAssertEqual(filter.target, 3.2)
        XCTAssertNil(SmoothZoomFilter(current: .infinity, minimum: 1, maximum: 8))
        XCTAssertNil(SmoothZoomFilter(current: 1, minimum: 0, maximum: 8))
        XCTAssertNil(SmoothZoomFilter(current: 1, minimum: 8, maximum: 8))
    }
    func testSmoothZoomTargetFollowsRateLimitWithoutOvershootAndSettlesAfterRelease() throws {
        var filter = try XCTUnwrap(SmoothZoomFilter(current: 1, minimum: 1, maximum: 16))
        filter.setTarget(8)
        var previous = filter.value
        for _ in 0..<240 {
            let value = filter.advance(seconds: 0.05, rate: 0.75)
            XCTAssertGreaterThanOrEqual(value, previous)
            XCTAssertLessThanOrEqual(value, 8)
            XCTAssertLessThanOrEqual(log2(value / previous), 0.75 * 0.05 + 0.0002)
            previous = value
        }
        XCTAssertEqual(filter.value, 8, accuracy: 0.001)
        XCTAssertEqual(filter.target, 8, "Releasing input must retain the target while the controller settles")
    }
    func testSmoothZoomReversalAndSpeedAreDirectionIndependent() throws {
        var slow = try XCTUnwrap(SmoothZoomFilter(current: 4, minimum: 1, maximum: 16))
        var fast = slow; slow.setTarget(16); fast.setTarget(16)
        for _ in 0..<20 { _ = slow.advance(seconds: 0.05, rate: SmoothZoomSpeed.slow.rate); _ = fast.advance(seconds: 0.05, rate: SmoothZoomSpeed.fast.rate) }
        XCTAssertGreaterThan(fast.value, slow.value)
        fast.setTarget(1)
        var previous = fast.value
        for _ in 0..<200 {
            let value = fast.advance(seconds: 0.05, rate: SmoothZoomSpeed.fast.rate)
            XCTAssertLessThanOrEqual(value, previous); XCTAssertGreaterThanOrEqual(value, 1)
            XCTAssertLessThanOrEqual(log2(previous / value), Double(SmoothZoomSpeed.fast.rate) * 0.05 + 0.0002)
            previous = value
        }
        XCTAssertEqual(fast.value, 1, accuracy: 0.001)
    }
    func testDollyDurationControlsFullMoveInBothDirections() throws {
        XCTAssertEqual(DollyZoomDuration.validated(99), 3)
        for duration in DollyZoomDuration.choices {
            for (start, end) in [(1.0, 8.0), (8.0, 1.0), (1.0, 4.0), (4.0, 1.0)] {
                var filter = try XCTUnwrap(SmoothZoomFilter(current: start, minimum: 1, maximum: 16))
                filter.setTarget(end, duration: Double(duration))
                XCTAssertTrue(filter.isTimed)
                let tick = Double(duration) / 200
                var steps: [Double] = []
                for frame in 0..<200 {
                    let previous = filter.value
                    let next = filter.advance(seconds: tick, rate: 0.35)
                    steps.append(abs(log2(next / previous)))
                    XCTAssertGreaterThanOrEqual(next, min(start, end))
                    XCTAssertLessThanOrEqual(next, max(start, end))
                    if frame == 99 { XCTAssertEqual(next, sqrt(start * end), accuracy: 0.0001) }
                    if frame == 149 { XCTAssertGreaterThan(abs(next - end), 0.01) }
                }
                XCTAssertEqual(filter.value, end, accuracy: 0.0001)
                XCTAssertLessThan(steps[0], steps[99])
                XCTAssertLessThan(steps[199], steps[99])
                // Dragging takes over smoothly from the reached position, without a timed move.
                filter.setTarget(start)
                XCTAssertFalse(filter.isTimed)
                XCTAssertEqual(filter.value, end, accuracy: 0.0001)
                XCTAssertNotEqual(filter.advance(seconds: 0.05, rate: 0.75), end)
            }
        }
    }
    func testDollyLensTargetsEaseInAndOutInBothDirections() throws {
        for (start, end) in [(1.0, 8.0), (8.0, 1.0), (1.0, 4.0), (4.0, 1.0)] {
            var filter = try XCTUnwrap(SmoothZoomFilter(current: start, minimum: 1, maximum: 16))
            filter.setTarget(end)
            var steps: [Double] = []
            for _ in 0..<240 {
                let previous = filter.value
                let next = filter.advance(seconds: 0.05, rate: 0.75)
                steps.append(abs(log2(next / previous)))
                XCTAssertGreaterThanOrEqual(next, min(start, end))
                XCTAssertLessThanOrEqual(next, max(start, end))
            }
            XCTAssertLessThan(steps[0], steps[6], "The beginning accelerates gently")
            XCTAssertLessThan(steps[100], steps[6], "The ending settles gently")
            XCTAssertEqual(filter.value, end, accuracy: 0.001)
        }
    }
    func testSmoothZoomRangeChangesClampTargetsAndCoordinatesRoundTrip() throws {
        var filter = try XCTUnwrap(SmoothZoomFilter(current: 8, minimum: 4, maximum: 12))
        filter.setTarget(1); XCTAssertEqual(filter.target, 4)
        filter.setTarget(16); XCTAssertEqual(filter.target, 12)
        for factor in [1.0, 2, 4, 8, 16] {
            let position = SmoothZoomFilter.position(factor, minimum: 1, maximum: 16)
            XCTAssertEqual(SmoothZoomFilter.factor(position, minimum: 1, maximum: 16), factor, accuracy: 0.0001)
        }
        XCTAssertEqual(SmoothZoomFilter.factor(-1, minimum: 4, maximum: 12), 4, accuracy: 0.0001)
        XCTAssertEqual(SmoothZoomFilter.factor(2, minimum: 4, maximum: 12), 12, accuracy: 0.0001)
        XCTAssertEqual(SmoothZoomFilter.factor(.nan, minimum: 1, maximum: 16), 1)
    }
    func testSmoothZoomDelayedTicksCannotJumpAndInvalidTimeDoesNotMove() throws {
        var filter = try XCTUnwrap(SmoothZoomFilter(current: 1, minimum: 1, maximum: 16)); filter.setTarget(16)
        let value = filter.advance(seconds: 10, rate: 0.75)
        XCTAssertLessThanOrEqual(log2(value), 0.075 + 0.0001, "A stalled capture queue must not jump to the target")
        XCTAssertEqual(filter.advance(seconds: .nan, rate: 0.75), value)
        XCTAssertEqual(filter.advance(seconds: -1, rate: 0.75), value)
        XCTAssertEqual(filter.advance(seconds: 0.05, rate: .infinity), value)
    }
    func testCaptureFormatUsesCameraAngleInBothDirections() {
        for angle in [CGFloat(0), 180, 360, -180] {
            XCTAssertEqual(MovieFormat.captureFormat(angle: angle), .landscape)
        }
        for angle in [CGFloat(90), 270, -90, 450] {
            XCTAssertEqual(MovieFormat.captureFormat(angle: angle), .portrait)
        }
        XCTAssertNil(MovieFormat.captureFormat(angle: .nan))
        XCTAssertNil(MovieFormat.captureFormat(angle: .infinity))
    }
    func testFirstSceneLocksOrientationAcrossRelaunchAndSceneDeletion() async throws {
        for format in MovieFormat.allCases {
            let store = try await makeStore()
            let movie = try await store.create(name: "Automatic", format: format == .portrait ? .landscape : .portrait)
            XCTAssertNil(movie.recordingFormat)
            let ticket = try await store.begin(movieID: movie.id, format: format)
            try await footage(store.root.appendingPathComponent(ticket.staging), rotated: format == .portrait)
            try await store.commit(ticket)
            try await store.setSceneDeleted(movieID: movie.id, sceneID: ticket.sceneID, deleted: true)
            let reopened = ProjectStore(root: store.root); _ = try await reopened.load()
            let snapshot = await reopened.snapshot()
            let saved = try XCTUnwrap(snapshot.first)
            XCTAssertEqual(saved.format, format)
            XCTAssertEqual(saved.recordingFormat, format)
            XCTAssertTrue(saved.activeScenes.isEmpty)
            do {
                _ = try await reopened.begin(movieID: movie.id, format: format == .portrait ? .landscape : .portrait)
                XCTFail("A later scene must use the original movie orientation")
            } catch {}
            let next = try await reopened.begin(movieID: movie.id, format: format)
            try await reopened.abandonUnstarted(next)
        }
    }
    func testCancelledFirstCaptureLeavesOrientationAutomatic() async throws {
        let store = try await makeStore(), movie = try await store.create(name: "Draft", format: .portrait)
        let canceled = try await store.begin(movieID: movie.id, format: .portrait)
        try await store.abandonUnstarted(canceled)
        let snapshot = await store.snapshot()
        XCTAssertNil(snapshot.first?.recordingFormat)
        let ticket = try await store.begin(movieID: movie.id, format: .landscape)
        try await footage(store.root.appendingPathComponent(ticket.staging))
        try await store.commit(ticket)
        let saved = await store.snapshot()
        XCTAssertEqual(saved.first?.recordingFormat, .landscape)
    }
    func testFirstSceneRecoveryRetainsOrientationAndLegacyTicketsDecode() async throws {
        let store = try await makeStore(), movie = try await store.create(name: "Recovered", format: .landscape)
        let ticket = try await store.begin(movieID: movie.id, format: .portrait)
        try await footage(store.root.appendingPathComponent(ticket.staging), rotated: true)
        let reopened = ProjectStore(root: store.root); _ = try await reopened.load()
        let saved = await reopened.snapshot()
        XCTAssertEqual(saved.first?.recordingFormat, .portrait)
        XCTAssertEqual(saved.first?.scenes.first?.id, ticket.sceneID)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(ticket)) as? [String: Any])
        legacy.removeValue(forKey: "format")
        let decoded = try JSONDecoder().decode(CaptureTicket.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(decoded.format)
        XCTAssertEqual(decoded.sceneID, ticket.sceneID)
    }
    func testNativeResolutionZoomChoicesIncludeSupportedEightTimes() {
        let choices = LensChoice.available(minimum: 1, maximum: 20, multiplier: 0.5,
            switchFactors: [2, 8], secondaryFactors: [4, 16, 16])
        XCTAssertEqual(choices.map(\.displayed), [0.5, 1, 2, 4, 8])
        XCTAssertEqual(choices.last?.factor, 16)
    }
    func testInternalSwitchBoundaryDoesNotBecomeAnExtraLensButton() {
        let choices = LensChoice.available(minimum: 1, maximum: 20, multiplier: 0.5,
            switchFactors: [1.8, 1.91, 2, 8], secondaryFactors: [4, 16, 16.01])
        XCTAssertEqual(choices.map(\.displayed), [0.5, 1, 2, 4, 8])
        XCTAssertEqual(choices.first(where: { $0.displayed == 1 })?.factor, 2,
            "Use the system multiplier's true 1× anchor, not a nearby switch boundary")
        XCTAssertFalse(choices.contains(where: { $0.displayed == 0.9 }))
        let single = LensChoice.available(minimum: 1, maximum: 12, multiplier: 1,
            switchFactors: [], secondaryFactors: [2])
        XCTAssertEqual(single.map(\.displayed), [1, 2])
    }
    func testZoomChoicesRespectDeviceRangeAndDoNotInventEightTimes() {
        let olderPhone = LensChoice.available(minimum: 1, maximum: 12, multiplier: 0.5,
            switchFactors: [2, 6], secondaryFactors: [])
        XCTAssertEqual(olderPhone.map(\.displayed), [0.5, 1, 3])
        let restricted = LensChoice.available(minimum: 1, maximum: 8, multiplier: 0.5,
            switchFactors: [2, 8], secondaryFactors: [4, 16])
        XCTAssertEqual(restricted.map(\.displayed), [0.5, 1, 2, 4])
    }
    func testInvalidVideoGeometryIsRejectedBeforeComposition() {
        let valid = CGSize(width: 1920, height: 1080)
        XCTAssertTrue(MediaAssembler.hasValidGeometry(size: valid, preferred: CGAffineTransform(rotationAngle: .pi / 2)))
        XCTAssertFalse(MediaAssembler.hasValidGeometry(size: .zero, preferred: .identity))
        XCTAssertFalse(MediaAssembler.hasValidGeometry(size: CGSize(width: CGFloat.infinity, height: 1080), preferred: .identity))
        XCTAssertFalse(MediaAssembler.hasValidGeometry(size: valid, preferred: CGAffineTransform(a: .nan, b: 0, c: 0, d: 1, tx: 0, ty: 0)))
    }
    func testDurationLabelsHandleExtremeAndInvalidTimes() {
        XCTAssertEqual(durationLabel(CMTime(value: Int64.max, timescale: 1)), "2562047788015215:30:07")
        XCTAssertEqual(durationLabel(.indefinite), "0:00")
        XCTAssertEqual(durationLabel(CMTime(seconds: -1, preferredTimescale: 600)), "0:00")
        XCTAssertEqual(durationLabel(CMTime(seconds: 3661, preferredTimescale: 600)), "1:01:01")
    }
    func testOversizedCatalogStorageIsRejectedWithoutOverwriting() async throws {
        let store = try await makeStore()
        _ = try await store.create(name: "Preserve", format: .landscape)
        for aggregate in [false, true] {
            var catalog = await store.catalogSnapshot()
            catalog.movies[0].scenes = (0..<(aggregate ? 5 : 1)).map { position in
                let id = UUID()
                return Scene(id: id, sequence: position, source: "Originals/\(id).mov", capturedAt: Date(), timeZone: "UTC",
                    sourceDuration: MediaTime(seconds: 1), trimStart: MediaTime(.zero), trimEnd: MediaTime(seconds: 1),
                    width: 320, height: 240, hasAudio: false, bytes: aggregate ? Int64.max / 4 : Int64.max)
            }
            let file = store.root.appendingPathComponent("catalog.json")
            let damaged = try JSONEncoder().encode(catalog)
            try damaged.write(to: file)
            let preservedMedia = store.root.appendingPathComponent(catalog.movies[0].scenes[0].source)
            try Data([1, 2, 3]).write(to: preservedMedia)
            let reopened = ProjectStore(root: store.root)
            do { _ = try await reopened.load(); XCTFail("Unsafe storage metadata must be rejected") } catch {}
            XCTAssertEqual(try Data(contentsOf: file), damaged)
            let recovery = try await reopened.recoveryFiles()
            XCTAssertTrue(recovery.contains { $0.url == preservedMedia }, "Rejected metadata must not hide preserved footage")
        }
    }
    @MainActor func testFailedLibraryReloadClearsReadyStateAndPreservesCatalog() async throws {
        let store = try await makeStore(), app = AppModel(store: store)
        await app.load()
        XCTAssertTrue(app.loaded)
        try await store.beginMaintenance()
        try await store.installImportedMovies([])
        await store.endMaintenance()
        let file = store.root.appendingPathComponent("catalog.json")
        let damaged = Data("broken reload".utf8)
        try damaged.write(to: file)
        await app.load()
        XCTAssertFalse(app.loaded)
        XCTAssertNotNil(app.loadFailure)
        XCTAssertEqual(try Data(contentsOf: file), damaged)
    }
    func testEstablishedRecordingAnglesDoNotRequirePhysicalRotation() {
        for format in MovieFormat.allCases {
            for observed in [CGFloat(0), 90, 180, 270, 360, -90] {
                XCTAssertEqual(MovieFormat.captureFormat(angle: format.recordingAngle(observed: observed)), format)
            }
        }
        XCTAssertEqual(MovieFormat.portrait.recordingAngle(observed: .nan), 90)
        XCTAssertEqual(MovieFormat.landscape.recordingAngle(observed: .infinity), 0)
    }
    func testLiveLookGeometryFillsBothOrientationsAndMirrorsFrontCamera() {
        let source = CGSize(width: 320, height: 240)
        for target in [CGSize(width: 393, height: 852), CGSize(width: 852, height: 393)] {
            for angle in [CGFloat(0), 90, 180, 270] {
                for front in [false, true] {
                    let transform = LiveLookGeometry.transform(source: source, target: target, angle: angle, front: front)
                    let bounds = CGRect(origin: .zero, size: source).applying(transform)
                    XCTAssertLessThanOrEqual(bounds.minX, 0.001); XCTAssertLessThanOrEqual(bounds.minY, 0.001)
                    XCTAssertGreaterThanOrEqual(bounds.maxX, target.width - 0.001)
                    XCTAssertGreaterThanOrEqual(bounds.maxY, target.height - 0.001)
                }
            }
        }
        let target = source
        let normal = LiveLookGeometry.transform(source: source, target: target, angle: 0, front: false)
        let mirror = LiveLookGeometry.transform(source: source, target: target, angle: 0, front: true)
        XCTAssertEqual(CGPoint(x: 20, y: 30).applying(normal).x, 20, accuracy: 0.001)
        XCTAssertEqual(CGPoint(x: 20, y: 30).applying(mirror).x, 300, accuracy: 0.001)
    }
    func testLiveMailboxReplacesFramesAndClearsWithoutQueuing() throws {
        func frame(width: Int) throws -> CVPixelBuffer {
            var buffer: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, width, 16, kCVPixelFormatType_32BGRA, nil, &buffer), kCVReturnSuccess)
            return try XCTUnwrap(buffer)
        }
        let mailbox = LiveFrames()
        mailbox.push(try frame(width: 16)); XCTAssertEqual(CVPixelBufferGetWidth(try XCTUnwrap(mailbox.latest())), 16)
        mailbox.push(try frame(width: 32)); XCTAssertEqual(CVPixelBufferGetWidth(try XCTUnwrap(mailbox.latest())), 32)
        mailbox.clear(); XCTAssertNil(mailbox.latest())
    }
    private var testCube: String { "TITLE \"Test\"\nLUT_3D_SIZE 2\n" + Array(repeating: "0.9 0.1 0.2", count: 8).joined(separator: "\n") }
    func testCubeParserBoundsDomainsAndRejectsMalformedFiles() throws {
        let cube = try ColorCube.parse(testCube, name: "Cinema LUT")
        XCTAssertEqual(cube.name, "Cinema")
        XCTAssertEqual(cube.dimension, 2)
        XCTAssertEqual(cube.rgba.count, 128)
        for text in ["LUT_1D_SIZE 4096", "LUT_3D_SIZE 128", "LUT_3D_SIZE 2\n0 0 0", testCube + "\n0 0 0",
                     testCube.replacingOccurrences(of: "0.9", with: "nan"), "LUT_3D_SIZE 2\nDOMAIN_MIN 1 1 1\nDOMAIN_MAX 0 0 0\n" + Array(repeating: "0 0 0", count: 8).joined(separator: "\n")] {
            XCTAssertThrowsError(try ColorCube.parse(text, name: "Invalid"))
        }
    }
    func testStandardLookAssetAndLegacyProfiles() throws {
        let cube = try ColorCube.appleStandard.get(); try cube.validate()
        XCTAssertEqual(cube.dimension, 65)
        let movie = Movie(name: "Legacy", format: .portrait)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(movie)) as? [String: Any])
        json.removeValue(forKey: "profile"); json.removeValue(forKey: "look")
        let decoded = try JSONDecoder().decode(Movie.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.captureProfile, .standard)
        XCTAssertNil(decoded.look)
    }
    func testBundledFilmicaDefaultsPersistAndStandardRemainsSelectable() async throws {
        let cube = try ColorCube.filmica.get(); try cube.validate()
        XCTAssertEqual(cube.name, "Cinema"); XCTAssertEqual(cube.dimension, 65)
        let first = cube.rgba.withUnsafeBytes { $0.loadUnaligned(as: Float.self) }
        XCTAssertEqual(first, 0.0308995, accuracy: 0.0000001)
        let store = try await makeStore()
        let looks = await store.availableLooks()
        XCTAssertTrue(looks.contains(.filmica))
        let movie = try await store.create(name: "Filmica", format: .portrait, profile: .appleLog)
        XCTAssertEqual(movie.look, .filmica)
        let stored = try ColorCube.load(.filmica, root: store.root)
        XCTAssertEqual(stored.rgba, cube.rgba)
        try await store.setLook(movieID: movie.id, look: nil)
        let reopened = ProjectStore(root: store.root); _ = try await reopened.load()
        let movies = await reopened.snapshot()
        XCTAssertNil(movies.first?.look, "An explicit Apple Standard selection survives relaunch")
        let standard = try await reopened.create(name: "SDR", format: .portrait)
        XCTAssertNil(standard.look)
        XCTAssertEqual(standard.captureProfile, .standard)
        XCTAssertEqual(LUTReference(id: LUTReference.filmica.id, name: "Filmica").displayName, "Cinema")
        let explicit = try await reopened.create(name: "Apple Standard", format: .portrait, profile: .appleLog, useDefaultLook: false)
        XCTAssertNil(explicit.look)
    }
    func testBundledFilmicaBackupIncludesExactSamples() async throws {
        let store = try await makeStore()
        let movie = try await store.create(name: "Default look backup", format: .portrait, profile: .appleLog)
        _ = try await record(movie, into: store)
        let service = BackupService(), backup = try await service.create(store: store) { _ in }
        let destination = try await makeStore()
        try await service.restore(from: backup.url, store: destination) { _ in }
        let movies = await destination.snapshot()
        let look = try XCTUnwrap(movies.first?.look)
        XCTAssertEqual(look.name, "Cinema")
        let restored = try ColorCube.load(look, root: destination.root)
        XCTAssertEqual(restored.rgba, try ColorCube.filmica.get().rgba)
        try await service.discard(backup.url)
    }
    func testAppleLogVerificationReadsExactTransferIdentifier() throws {
        func description(_ extensions: [String: Any]) throws -> CMFormatDescription {
            var result: CMFormatDescription?
            let status = CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                codecType: kCMVideoCodecType_AppleProRes422, width: 1920, height: 1080,
                extensions: extensions as CFDictionary, formatDescriptionOut: &result)
            XCTAssertEqual(status, noErr)
            return try XCTUnwrap(result)
        }
        let key = kCMFormatDescriptionExtension_LogTransferFunction as String
        let log = try description([key: kCMFormatDescriptionLogTransferFunction_AppleLog as String])
        XCTAssertEqual(MediaInspector.captureProfile(for: [log]), .appleLog)
        let standard = try description([:])
        XCTAssertNil(MediaInspector.captureProfile(for: [standard]))
        XCTAssertNil(MediaInspector.captureProfile(for: []))
        XCTAssertNil(MediaInspector.captureProfile(for: [log, standard]))
        let log2 = try description([key: "com.apple.apple-wide-gamut.apple-log"])
        XCTAssertNil(MediaInspector.captureProfile(for: [log2]), "Apple Log 2 needs a different color pipeline")
        let unrelated = try description(["Comment": "AppleLog"])
        XCTAssertNil(MediaInspector.captureProfile(for: [unrelated]), "A label is not verified Log metadata")
        let hdr = try description([kCMFormatDescriptionExtension_TransferFunction as String:
            kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String])
        XCTAssertNil(MediaInspector.captureProfile(for: [hdr]))
    }
    func testRecoveryRejectsSDRIntoLogAndPreservesSource() async throws {
        let store = try await makeStore()
        let movie = try await store.create(name: "Log recovery", format: .portrait, profile: .appleLog)
        let source = store.root.appendingPathComponent("Recovery/sdr.mov")
        try await footage(source)
        let files = try await store.recoveryFiles()
        let file = try XCTUnwrap(files.first { $0.url == source })
        do { try await store.recoverFile(file, movieID: movie.id); XCTFail("SDR must not be treated as Log") } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        let movies = await store.snapshot(); XCTAssertTrue(movies.first!.scenes.isEmpty)
        let standard = try await store.create(name: "SDR recovery", format: .landscape)
        try await store.recoverFile(file, movieID: standard.id)
        let recovered = await store.snapshot().first { $0.id == standard.id }
        XCTAssertEqual(recovered?.scenes.first?.profile, .standard)
    }
    func testThumbnailsHonorFilmicaAndInvalidateOnLookChange() async throws {
        let store = try await makeStore()
        var movie = try await store.create(name: "Thumbnail", format: .landscape, profile: .appleLog)
        _ = try await record(movie, into: store)
        let saved = await store.snapshot(); movie = try XCTUnwrap(saved.first)
        let scene = try XCTUnwrap(movie.activeScenes.first)
        let filmica = try await ThumbnailService.shared.image(scene: scene, root: store.root, movie: movie)
        movie.look = nil; movie.revision += 1
        let standard = try await ThumbnailService.shared.image(scene: scene, root: store.root, movie: movie)
        XCTAssertNotEqual(filmica.pngData(), standard.pngData(), "Look changes must not return a stale cached thumbnail")
        movie.profile = nil; movie.revision += 1
        let original = try await ThumbnailService.shared.image(scene: scene, root: store.root, movie: movie)
        XCTAssertNotEqual(filmica.pngData(), original.pngData())
    }
    func testUndoLastTakeIsRecoverableAndRejectsStaleTargets() async throws {
        let store = try await makeStore()
        let movie = try await store.create(name: "Undo", format: .landscape)
        let first = try await record(movie, into: store)
        let last = try await record(movie, into: store)
        let source = store.root.appendingPathComponent(last.source)
        let original = try Data(contentsOf: source)
        let before = await store.snapshot().first!
        do { try await store.undoLastTake(movieID: movie.id, expectedSceneID: first.sceneID); XCTFail("Must not undo an older take") } catch {}
        try await store.undoLastTake(movieID: movie.id, expectedSceneID: last.sceneID)
        let undone = await store.snapshot().first!
        XCTAssertEqual(undone.activeScenes.map(\.id), [first.sceneID])
        XCTAssertEqual(undone.revision, before.revision + 1)
        XCTAssertLessThan(undone.duration.seconds, before.duration.seconds)
        XCTAssertNotNil(undone.scenes.last?.deletedAt)
        XCTAssertEqual(try Data(contentsOf: source), original)
        do { try await store.undoLastTake(movieID: movie.id, expectedSceneID: last.sceneID); XCTFail("A second stale tap must not remove another take") } catch {}
        let reopened = ProjectStore(root: store.root); _ = try await reopened.load()
        let saved = await reopened.snapshot().first!
        XCTAssertEqual(saved.activeScenes.map(\.id), [first.sceneID])
        XCTAssertEqual(saved.recordingFormat, .landscape)
        try await reopened.setSceneDeleted(movieID: movie.id, sceneID: last.sceneID, deleted: false)
        let restored = await reopened.snapshot().first!
        XCTAssertEqual(restored.activeScenes.map(\.id), [first.sceneID, last.sceneID])
        XCTAssertEqual(try Data(contentsOf: source), original)
    }
    func testLookSelectionPersistsAndInvalidatesExportRevision() async throws {
        let store = try await makeStore(), movie = try await store.create(name: "Log", format: .landscape, profile: .appleLog)
        do { _ = try await store.begin(movieID: movie.id, profile: .standard); XCTFail("A Log movie must not silently record Standard") } catch {}
        let file = store.root.appendingPathComponent("Cinema.cube"); try testCube.write(to: file, atomically: true, encoding: .utf8)
        let look = try await store.importLook(from: file)
        try await store.setLook(movieID: movie.id, look: look)
        let revision = await store.snapshot().first!.revision
        try await store.setLook(movieID: movie.id, look: look)
        let unchanged = await store.snapshot()
        XCTAssertEqual(unchanged.first?.revision, revision)
        let reopened = ProjectStore(root: store.root); _ = try await reopened.load()
        let saved = await reopened.snapshot()
        XCTAssertEqual(saved.first?.look, look)
        XCTAssertEqual(saved.first?.captureProfile, .appleLog)
        let restoredCube = try ColorCube.load(look, root: store.root)
        XCTAssertEqual(restoredCube.rgba.count, 128)
        try await reopened.setLook(movieID: movie.id, look: nil)
        let standard = await reopened.snapshot()
        XCTAssertEqual(standard.first?.revision, revision + 1)
        XCTAssertNil(standard.first?.look)
    }
    func testInitialLookCreationIsAtomicWhenLookIsMissing() async throws {
        let store = try await makeStore()
        do {
            _ = try await store.create(name: "Missing", format: .portrait, profile: .appleLog, look: LUTReference(id: UUID(), name: "Missing"))
            XCTFail("Missing looks must fail before creating a movie")
        } catch {}
        let empty = await store.snapshot(); XCTAssertTrue(empty.isEmpty)
        let file = store.root.appendingPathComponent("Initial.cube"); try testCube.write(to: file, atomically: true, encoding: .utf8)
        let look = try await store.importLook(from: file)
        let movie = try await store.create(name: "Initial", format: .portrait, profile: .appleLog, look: look)
        XCTAssertEqual(movie.look, look); XCTAssertEqual(movie.revision, 0)
        let reopened = ProjectStore(root: store.root); _ = try await reopened.load()
        let saved = await reopened.snapshot(); XCTAssertEqual(saved.first?.look, look)
    }
    func testBackupCarriesSelectedLookWithoutChangingExistingFiles() async throws {
        let store = try await makeStore(), movie = try await store.create(name: "Look Backup", format: .landscape, profile: .appleLog)
        let ticket = try await record(movie, into: store)
        let original = try Data(contentsOf: store.root.appendingPathComponent(ticket.source))
        let file = store.root.appendingPathComponent("Cinema.cube"); try testCube.write(to: file, atomically: true, encoding: .utf8)
        let look = try await store.importLook(from: file); try await store.setLook(movieID: movie.id, look: look)
        let backup = BackupService(), prepared = try await backup.create(store: store) { _ in }
        let destination = try await makeStore()
        try await backup.restore(from: prepared.url, store: destination) { _ in }
        let restored = await destination.snapshot()
        let imported = try XCTUnwrap(restored.first?.look)
        XCTAssertNotEqual(imported.id, look.id)
        let a = try ColorCube.load(imported, root: destination.root), b = try ColorCube.load(look, root: store.root)
        XCTAssertEqual(a.rgba, b.rgba)
        XCTAssertEqual(try Data(contentsOf: store.root.appendingPathComponent(ticket.source)), original)
        try await backup.discard(prepared.url)
    }
    func testCustomLookPlaybackAndExportUseSameCompositor() async throws {
        let store = try await makeStore(), movie = try await store.create(name: "Look Export", format: .portrait, profile: .appleLog)
        _ = try await record(movie, into: store, rotated: true)
        let file = store.root.appendingPathComponent("Look.cube"); try testCube.write(to: file, atomically: true, encoding: .utf8)
        let look = try await store.importLook(from: file); try await store.setLook(movieID: movie.id, look: look)
        let snapshot = await store.snapshot().first!, assembler = MediaAssembler()
        let bundle = try await assembler.build(movie: snapshot, root: store.root)
        XCTAssertEqual(bundle.videoComposition.customVideoCompositorClass.map { ObjectIdentifier($0) }, ObjectIdentifier(LogVideoCompositor.self))
        let original = try await assembler.build(movie: snapshot, root: store.root, showOriginalLog: true)
        XCTAssertNil((original.videoComposition.instructions.first as? ColorInstruction)?.cube)
        let preview = AVAssetImageGenerator(asset: bundle.asset); preview.videoComposition = bundle.videoComposition
        let previewImage = try await preview.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image
        let output = store.root.appendingPathComponent("look-export.mp4")
        let exporter = try XCTUnwrap(AVAssetExportSession(asset: bundle.asset, presetName: AVAssetExportPresetHighestQuality))
        exporter.videoComposition = bundle.videoComposition; try await exporter.export(to: output, as: .mp4)
        let result = try await MediaInspector.inspect(output)
        XCTAssertEqual(result.size.width, 1080, accuracy: 1); XCTAssertEqual(result.size.height, 1920, accuracy: 1)
        let exportImage = try await AVAssetImageGenerator(asset: AVURLAsset(url: output)).image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image
        func sample(_ image: CGImage) -> [UInt8] {
            var pixel = [UInt8](repeating: 0, count: 4)
            CIContext().render(CIImage(cgImage: image), toBitmap: &pixel, rowBytes: 4,
                bounds: CGRect(x: image.width / 2, y: image.height / 2, width: 1, height: 1), format: .RGBA8,
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            return pixel
        }
        let a = sample(previewImage), b = sample(exportImage)
        XCTAssertGreaterThan(a[0], 180); XCTAssertLessThan(a[1], 80)
        for channel in 0..<3 { XCTAssertEqual(Double(a[channel]), Double(b[channel]), accuracy: 8) }
    }
    private func makeStore() async throws -> ProjectStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ProjectStore(root: root); _ = try await store.load()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return store
    }
    private func footage(_ url: URL, rotated: Bool = false) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 240])
        if rotated { input.transform = CGAffineTransform(rotationAngle: .pi / 2) }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 240])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? HomeMovieError.message("Fixture writer failed") }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<60 {
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed { throw writer.error ?? HomeMovieError.message("Fixture writer failed") }
                await Task.yield()
            }
            var buffer: CVPixelBuffer?
            let result = CVPixelBufferCreate(kCFAllocatorDefault, 320, 240, kCVPixelFormatType_32BGRA, nil, &buffer)
            guard result == kCVReturnSuccess, let buffer else { throw HomeMovieError.message("Fixture buffer failed") }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) { memset(base, frame % 2 == 0 ? 60 : 120, CVPixelBufferGetBytesPerRow(buffer) * 240) }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else { throw writer.error ?? HomeMovieError.message("Fixture append failed") }
        }
        writer.endSession(atSourceTime: CMTime(value: 60, timescale: 30)); input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? HomeMovieError.message("Fixture did not finish") }
    }
    private func record(_ movie: Movie, into store: ProjectStore, rotated: Bool = false) async throws -> CaptureTicket {
        let ticket = try await store.begin(movieID: movie.id)
        let staging = try await store.url(ticket.staging)
        try await footage(staging, rotated: rotated)
        try await store.commit(ticket); return ticket
    }
    func testIndependentMoviesPersistAndCommitIsIdempotent() async throws {
        let store = try await makeStore()
        let a = try await store.create(name: "A", format: .landscape), b = try await store.create(name: "B", format: .portrait)
        let ticket = try await record(a, into: store)
        _ = try await record(b, into: store, rotated: true)
        try await store.commit(ticket)
        let reopened = ProjectStore(root: store.root); _ = try await reopened.load()
        let movies = await reopened.snapshot()
        XCTAssertEqual(movies.count, 2)
        XCTAssertEqual(movies.first { $0.id == a.id }?.scenes.count, 1)
        XCTAssertEqual(movies.first { $0.id == b.id }?.scenes.count, 1)
        XCTAssertEqual(movies.first { $0.id == a.id }?.scenes.first?.id, ticket.sceneID)
    }
    func testCancelledUnstartedCaptureRemovesOnlyEmptyJournal() async throws {
        let store = try await makeStore(), movie = try await store.create(name: "Cancel", format: .landscape)
        let ticket = try await store.begin(movieID: movie.id)
        let journal = try await store.url(ticket.journal)
        XCTAssertTrue(FileManager.default.fileExists(atPath: journal.path))
        try await store.abandonUnstarted(ticket)
        try await store.abandonUnstarted(ticket)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
        let reopened = ProjectStore(root: store.root)
        let notices = try await reopened.load()
        XCTAssertTrue(notices.isEmpty)
        let movies = await reopened.snapshot()
        XCTAssertTrue(movies.first!.scenes.isEmpty)
        _ = try await record(movie, into: reopened)
        let afterRecording = await reopened.snapshot()
        XCTAssertEqual(afterRecording.first!.scenes.count, 1)
    }
    func testCancellingNeverRemovesStagingOrOriginalBytes() async throws {
        let store = try await makeStore(), movie = try await store.create(name: "Keep footage", format: .landscape)
        for original in [false, true] {
            let ticket = try await store.begin(movieID: movie.id)
            let media = try await store.url(original ? ticket.source : ticket.staging)
            let journal = try await store.url(ticket.journal)
            let bytes = Data([1, 2, 3])
            try bytes.write(to: media)
            do { try await store.abandonUnstarted(ticket); XCTFail("Existing footage must be preserved") } catch {}
            XCTAssertEqual(try Data(contentsOf: media), bytes)
            XCTAssertTrue(FileManager.default.fileExists(atPath: journal.path))
        }
    }
    func testJournalRecoversCompletedButUncommittedTake() async throws {
        let store = try await makeStore(), movie = try await store.create(name: "Recovery", format: .landscape)
        let ticket = try await store.begin(movieID: movie.id)
        let staging = try await store.url(ticket.staging)
        try await footage(staging)
        let reopened = ProjectStore(root: store.root)
        let notices = try await reopened.load(), movies = await reopened.snapshot()
        XCTAssertFalse(notices.isEmpty)
        XCTAssertEqual(movies.first?.scenes.first?.id, ticket.sceneID)
        let original = try await reopened.url(ticket.source)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
    }
    func testInvalidTakePreservedAndNeverCommitted() async throws {
        let store = try await makeStore(), movie = try await store.create(name: "Interrupted", format: .landscape)
        let ticket = try await store.begin(movieID: movie.id), path = try await store.url(ticket.staging)
        try Data([1, 2, 3]).write(to: path)
        do { try await store.commit(ticket); XCTFail("Invalid media must not commit") } catch {}
        let movies = await store.snapshot()
        XCTAssertTrue(movies.first!.scenes.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
    }
    func testTrimAndDeletionPreserveOriginalBytesAndRevision() async throws {
        let store = try await makeStore(), movie = try await store.create(name: "Originals", format: .landscape)
        let ticket = try await record(movie, into: store), path = try await store.url(ticket.source)
        let original = try Data(contentsOf: path)
        try await store.trim(movieID: movie.id, sceneID: ticket.sceneID, start: CMTime(value: 15, timescale: 30), end: CMTime(value: 45, timescale: 30))
        try await store.setSceneDeleted(movieID: movie.id, sceneID: ticket.sceneID, deleted: true)
        try await store.setSceneDeleted(movieID: movie.id, sceneID: ticket.sceneID, deleted: false)
        let restored = await store.snapshot().first!
        XCTAssertEqual(try Data(contentsOf: path), original)
        XCTAssertEqual(restored.revision, 4)
        XCTAssertEqual(restored.duration.seconds, 1, accuracy: 0.001)
        do { try await store.trim(movieID: movie.id, sceneID: ticket.sceneID, start: CMTime(seconds: -1, preferredTimescale: 600), end: CMTime(seconds: 10, preferredTimescale: 600)); XCTFail("Invalid trim must be rejected") } catch {}
        let afterInvalid = await store.snapshot().first!
        XCTAssertEqual(afterInvalid.revision, restored.revision)
    }
    func testCompositionSnapshotAndExportAgreeWithoutAudio() async throws {
        let store = try await makeStore(), movie = try await store.create(name: "Joins", format: .landscape)
        _ = try await record(movie, into: store)
        _ = try await record(movie, into: store, rotated: true)
        let snapshot = await store.snapshot().first!, assembler = MediaAssembler()
        let bundle = try await assembler.build(movie: snapshot, root: store.root)
        XCTAssertEqual(bundle.duration.seconds, 4, accuracy: 0.05)
        XCTAssertEqual(bundle.videoComposition.instructions.count, 2)
        let audioTracks = try await bundle.asset.loadTracks(withMediaType: .audio)
        XCTAssertTrue(audioTracks.isEmpty, "Video-only movies must not include formatless audio tracks")
        _ = try await record(movie, into: store)
        XCTAssertEqual(bundle.duration.seconds, 4, accuracy: 0.05)
        let output = store.root.appendingPathComponent("test-export.mp4")
        let exporter = try XCTUnwrap(AVAssetExportSession(asset: bundle.asset, presetName: AVAssetExportPresetHighestQuality))
        exporter.videoComposition = bundle.videoComposition
        try await exporter.export(to: output, as: .mp4)
        let info = try await MediaInspector.inspect(output)
        XCTAssertEqual(info.duration.seconds, bundle.duration.seconds, accuracy: 0.15)
        XCTAssertEqual(info.size.width, 1920, accuracy: 1)
        XCTAssertEqual(info.size.height, 1080, accuracy: 1)
        XCTAssertFalse(info.hasAudio)
    }
    func testPortraitExportUsesFullPortraitCanvas() async throws {
        let store = try await makeStore(), movie = try await store.create(name: "Portrait", format: .portrait)
        _ = try await record(movie, into: store, rotated: true)
        let snapshot = await store.snapshot().first!, assembler = MediaAssembler()
        let bundle = try await assembler.build(movie: snapshot, root: store.root)
        let output = store.root.appendingPathComponent("portrait.mp4")
        let exporter = try XCTUnwrap(AVAssetExportSession(asset: bundle.asset, presetName: AVAssetExportPresetHighestQuality))
        exporter.videoComposition = bundle.videoComposition
        try await exporter.export(to: output, as: .mp4)
        let info = try await MediaInspector.inspect(output)
        XCTAssertEqual(info.size.width, 1080, accuracy: 1)
        XCTAssertEqual(info.size.height, 1920, accuracy: 1)
        XCTAssertFalse(info.hasAudio)
    }
    func testDamagedCatalogIsNeverReplacedWithAnEmptyLibrary() async throws {
        let store = try await makeStore()
        _ = try await store.create(name: "Keep me", format: .landscape)
        let path = store.root.appendingPathComponent("catalog.json")
        let damaged = Data("{broken manifest".utf8)
        try damaged.write(to: path)
        let reopened = ProjectStore(root: store.root)
        do { _ = try await reopened.load(); XCTFail("A damaged manifest must fail closed") } catch {}
        XCTAssertEqual(try Data(contentsOf: path), damaged)
    }
    func testRotatedPortraitFitsLandscapeWithoutCropping() {
        let size = CGSize(width: 1920, height: 1080), canvas = CGSize(width: 1920, height: 1080)
        let rotation = CGAffineTransform(rotationAngle: .pi / 2)
        let transform = MediaAssembler.fitTransform(size: size, preferred: rotation, canvas: canvas)
        let fitted = CGRect(origin: .zero, size: size).applying(transform)
        XCTAssertGreaterThanOrEqual(fitted.minX, -0.001)
        XCTAssertGreaterThanOrEqual(fitted.minY, -0.001)
        XCTAssertLessThanOrEqual(fitted.maxX, canvas.width + 0.001)
        XCTAssertLessThanOrEqual(fitted.maxY, canvas.height + 0.001)
        XCTAssertEqual(fitted.midX, canvas.width / 2, accuracy: 0.01)
        XCTAssertEqual(fitted.midY, canvas.height / 2, accuracy: 0.01)
    }
}
