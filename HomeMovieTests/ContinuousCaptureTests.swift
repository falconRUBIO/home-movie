import XCTest
import AVFoundation
@testable import HomeMovie

final class ContinuousCaptureTests: XCTestCase {
    func testAsynchronousPipelineKeepsAudioAndVideoAcrossPiPToggle() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let take = try ContinuousTakePipeline(url: url, angle: 0, callbackQueue: DispatchQueue(label: "test.pipelineCallbacks"))
        let rear = try frame(red: true), front = try frame(red: false)
        let presentation = PiPPresentation(rect: CGRect(x: 0.65, y: 0.65, width: 0.3, height: 0.3), opacity: 1, enabled: true)
        for index in 0..<12 {
            let time = CMTime(value: Int64(300 + index), timescale: 30)
            var written = false
            for _ in 0..<100 {
                written = await withCheckedContinuation { continuation in
                    let admitted = take.appendVideo(rear, presenter: front, presentation: index < 6 ? presentation : nil,
                        at: time, angle: 0, presenterAngle: 0) { accepted, error in
                            XCTAssertNil(error); continuation.resume(returning: accepted)
                        }
                    if !admitted { continuation.resume(returning: false) }
                }
                if written { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(written)
            take.appendAudio(try audio(at: time))
        }
        let finished = expectation(description: "Asynchronous movie and audio finish")
        take.finish { error in XCTAssertNil(error); finished.fulfill() }
        await fulfillment(of: [finished], timeout: 30)
        let asset = AVURLAsset(url: url)
        let videos = try await asset.loadTracks(withMediaType: .video)
        let audios = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(videos.count, 1); XCTAssertEqual(audios.count, 1)
        let range = try await XCTUnwrap(audios.first).load(.timeRange)
        XCTAssertGreaterThanOrEqual(range.duration.seconds, 0.35)
        let generator = AVAssetImageGenerator(asset: asset); generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let (withPiP, _) = try await generator.image(at: CMTime(value: 1, timescale: 30))
        let (withoutPiP, _) = try await generator.image(at: CMTime(value: 8, timescale: 30))
        XCTAssertNotEqual(withPiP.dataProvider?.data as Data?, withoutPiP.dataProvider?.data as Data?)
    }

    func testPiPRenderFailurePreservesMovieAndAudioAndReportsOnce() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let fallback = expectation(description: "One warning for the take")
        fallback.assertForOverFulfill = true
        let take = try ContinuousTakePipeline(url: url, angle: 0,
            callbackQueue: DispatchQueue(label: "test.pipelineFallback"),
            onPiPFallback: { fallback.fulfill() }, renderPiP: { _, _ in nil })
        let rear = try frame(red: true), front = try frame(red: false)
        let presentation = PiPPresentation(rect: CGRect(x: 0.65, y: 0.65, width: 0.3, height: 0.3), opacity: 1, enabled: true)
        for index in 0..<12 {
            let time = CMTime(value: Int64(300 + index), timescale: 30)
            var written = false
            for _ in 0..<100 {
                written = await withCheckedContinuation { continuation in
                    let admitted = take.appendVideo(rear, presenter: front, presentation: presentation,
                        at: time, angle: 0, presenterAngle: 0) { accepted, error in
                            XCTAssertNil(error); continuation.resume(returning: accepted)
                        }
                    if !admitted { continuation.resume(returning: false) }
                }
                if written { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(written)
            take.appendAudio(try audio(at: time))
        }
        let finished = expectation(description: "Asynchronous movie and audio finish")
        take.finish { error in XCTAssertNil(error); finished.fulfill() }
        await fulfillment(of: [finished, fallback], timeout: 30)
        let asset = AVURLAsset(url: url)
        let videos = try await asset.loadTracks(withMediaType: .video)
        let audios = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(videos.count, 1); XCTAssertEqual(audios.count, 1)
        let range = try await XCTUnwrap(audios.first).load(.timeRange)
        XCTAssertGreaterThanOrEqual(range.duration.seconds, 0.35)
        let generator = AVAssetImageGenerator(asset: asset)
        let decoded = try await generator.image(at: CMTime(value: 8, timescale: 30)).image
        XCTAssertEqual(decoded.width, 1920); XCTAssertEqual(decoded.height, 1080)
    }

    func testSingleWriterKeepsAudioAcrossOrdinaryFlipAndMissingVideoFrames() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let take = try ContinuousTakePipeline(url: url, angle: 0, callbackQueue: DispatchQueue(label: "test.pipelineCallbacks"))
        let rear = try frame(red: true), front = try frame(red: false)
        for index in 0..<12 {
            let time = CMTime(value: Int64(300 + index), timescale: 30)
            // Hardware may briefly stop video delivery during an input swap.
            // Audio still belongs to the same take and must span this interval.
            if index == 5 || index == 6 {
                take.appendAudio(try audio(at: time)); continue
            }
            var written = false
            for _ in 0..<100 {
                written = await withCheckedContinuation { continuation in
                    let admitted = take.appendVideo(index < 6 ? rear : front, presenter: nil, presentation: nil,
                        at: time, angle: 0, presenterAngle: 0) { accepted, error in
                            XCTAssertNil(error); continuation.resume(returning: accepted)
                        }
                    if !admitted { continuation.resume(returning: false) }
                }
                if written { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(written)
            take.appendAudio(try audio(at: time))
        }
        let finished = expectation(description: "Asynchronous movie and audio finish")
        take.finish { error in XCTAssertNil(error); finished.fulfill() }
        await fulfillment(of: [finished], timeout: 30)
        let asset = AVURLAsset(url: url)
        let videos = try await asset.loadTracks(withMediaType: .video)
        let audios = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(videos.count, 1); XCTAssertEqual(audios.count, 1)
        let range = try await XCTUnwrap(audios.first).load(.timeRange)
        XCTAssertGreaterThanOrEqual(range.duration.seconds, 0.35)
        let generator = AVAssetImageGenerator(asset: asset); generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let (beforeFlip, _) = try await generator.image(at: CMTime(value: 1, timescale: 30))
        let (afterFlip, _) = try await generator.image(at: CMTime(value: 8, timescale: 30))
        XCTAssertNotEqual(beforeFlip.dataProvider?.data as Data?, afterFlip.dataProvider?.data as Data?)
    }

    func testSlowWriterCannotBuildVideoBacklogAndStopDrainsAcceptedFrame() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let writing = DispatchQueue(label: "test.blockedWriter")
        let callbacks = DispatchQueue(label: "test.captureCallbacks")
        let take = try ContinuousTakePipeline(url: url, angle: 0, callbackQueue: callbacks, writingQueue: writing)
        let image = try frame(red: true)
        writing.suspend()
        let accepted = expectation(description: "Accepted frame written")
        XCTAssertTrue(take.appendVideo(image, presenter: nil, presentation: nil, at: .zero,
            angle: 0, presenterAngle: 0) { written, error in
                XCTAssertTrue(written); XCTAssertNil(error); accepted.fulfill()
            })
        for index in 1...100 {
            XCTAssertFalse(take.appendVideo(image, presenter: nil, presentation: nil,
                at: CMTime(value: Int64(index), timescale: 30), angle: 0, presenterAngle: 0) { _, _ in
                    XCTFail("A queued backlog must not be admitted")
                })
        }
        let finished = expectation(description: "Stop drains accepted frame")
        take.finish { error in XCTAssertNil(error); finished.fulfill() }
        XCTAssertFalse(take.appendVideo(image, presenter: nil, presentation: nil,
            at: CMTime(value: 101, timescale: 30), angle: 0, presenterAngle: 0) { _, _ in XCTFail() })
        writing.resume()
        await fulfillment(of: [accepted, finished], timeout: 30)
        let videos = try await AVURLAsset(url: url).loadTracks(withMediaType: .video)
        XCTAssertEqual(videos.count, 1)
    }

    func testRememberedPiPPreferenceCannotActivateDualCameraByItself() {
        XCTAssertFalse(CameraCompatibility.shouldPreparePiP(profile: .standard, storedPreference: true, requested: false, currentlyEnabled: false))
        XCTAssertTrue(CameraCompatibility.shouldPreparePiP(profile: .standard, storedPreference: true, requested: true, currentlyEnabled: false))
        XCTAssertTrue(CameraCompatibility.shouldPreparePiP(profile: .standard, storedPreference: true, requested: false, currentlyEnabled: true))
        XCTAssertFalse(CameraCompatibility.shouldPreparePiP(profile: .standard, storedPreference: false, requested: false, currentlyEnabled: true))
        XCTAssertFalse(CameraCompatibility.shouldPreparePiP(profile: .appleLog, storedPreference: true, requested: true, currentlyEnabled: true))
    }

    func testLogRecordingCannotUseSegmentedCameraFlip() {
        XCTAssertFalse(CameraCompatibility.allowsFlip(profile: .appleLog, recording: true,
            otherCameraSupported: true, continuousFlipSupported: false))
        XCTAssertTrue(CameraCompatibility.allowsFlip(profile: .appleLog, recording: false,
            otherCameraSupported: true, continuousFlipSupported: false))
        XCTAssertFalse(CameraCompatibility.allowsFlip(profile: .appleLog, recording: false,
            otherCameraSupported: false, continuousFlipSupported: false))
    }
    func testStandardCameraFlipKeepsExistingFallbackAndContinuousPaths() {
        for continuous in [false, true] {
            XCTAssertTrue(CameraCompatibility.allowsFlip(profile: .standard, recording: true,
                otherCameraSupported: true, continuousFlipSupported: continuous))
            XCTAssertFalse(CameraCompatibility.allowsFlip(profile: .standard, recording: true,
                otherCameraSupported: false, continuousFlipSupported: continuous))
        }
    }
    func testPiPRequiresStandardEvenOnDualCameraHardware() {
        XCTAssertFalse(CameraCompatibility.allowsPiP(profile: .appleLog, deviceSupported: true))
        XCTAssertFalse(CameraCompatibility.allowsPiP(profile: .appleLog, deviceSupported: false))
        XCTAssertFalse(CameraCompatibility.allowsPiP(profile: .standard, deviceSupported: false))
        XCTAssertTrue(CameraCompatibility.allowsPiP(profile: .standard, deviceSupported: true))
    }

    private func frame(red: Bool) throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 32, 18, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &result), kCVReturnSuccess)
        let buffer = try XCTUnwrap(result)
        CVPixelBufferLockBaseAddress(buffer, []); defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        for y in 0..<18 { for x in 0..<32 {
            let offset = y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
            base[offset] = 0; base[offset + 1] = red ? 0 : 200; base[offset + 2] = red ? 200 : 0; base[offset + 3] = 255
        }}
        return buffer
    }
    private func audio(at time: CMTime) throws -> CMSampleBuffer {
        var description = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4,
            mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &format), noErr)
        var block: CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: 6400, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: 6400, flags: 0, blockBufferOut: &block), kCMBlockBufferNoErr)
        let data = try XCTUnwrap(block)
        XCTAssertEqual(CMBlockBufferFillDataBytes(with: 0, blockBuffer: data, offsetIntoDestination: 0, dataLength: 6400), noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
            presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sampleSize = 4; var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: data,
            formatDescription: try XCTUnwrap(format), sampleCount: 1600, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
            sampleBufferOut: &sample), noErr)
        return try XCTUnwrap(sample)
    }
    func testOneTakeKeepsVideoAndAudioTimelineAcrossCameraFrameChange() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let take = try ContinuousTakeWriter(url: url, angle: 0)
        let front = try frame(red: true), back = try frame(red: false)
        for index in 0..<90 {
            let time = CMTime(value: Int64(300 + index), timescale: 30)
            var accepted = false
            for _ in 0..<100 {
                if take.appendVideo(index < 45 ? front : back, at: time) { accepted = true; break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(accepted)
            take.appendAudio(try audio(at: time))
            XCTAssertFalse(take.appendVideo(front, at: time), "A stale standby-camera timestamp must not enter the take")
        }
        let completed = expectation(description: "One continuous take finishes")
        take.finish { error in XCTAssertNil(error); completed.fulfill() }
        await fulfillment(of: [completed], timeout: 30)
        let asset = AVURLAsset(url: url)
        let videos = try await asset.loadTracks(withMediaType: .video)
        let audios = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(videos.count, 1); XCTAssertEqual(audios.count, 1)
        let range = try await XCTUnwrap(audios.first).load(.timeRange)
        XCTAssertGreaterThanOrEqual(range.duration.seconds, 2.9)
        let generator = AVAssetImageGenerator(asset: asset); generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let (first, _) = try await generator.image(at: CMTime(value: 1, timescale: 30))
        let (second, _) = try await generator.image(at: CMTime(value: 70, timescale: 30))
        XCTAssertEqual(first.width, 1920); XCTAssertEqual(second.height, 1080)
        XCTAssertNotEqual(first.dataProvider?.data as Data?, second.dataProvider?.data as Data?)
    }
    func testOnlyStartingAndRecordingCanStopATake() {
        for state in [CameraState.starting, .recording] { XCTAssertTrue(state.canStopTake) }
        for state in [CameraState.preparing, .ready, .finalizing, .denied, .interrupted, .failed] {
            XCTAssertFalse(state.canStopTake)
        }
    }
    func testStoppingBeforeFirstFrameReturnsRecoverableError() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let take = try ContinuousTakeWriter(url: url, angle: 90)
        let completed = expectation(description: "Empty take is cancelled")
        take.finish { error in XCTAssertNotNil(error); completed.fulfill() }
        await fulfillment(of: [completed], timeout: 5)
        XCTAssertEqual(take.writer.status, .cancelled)
    }
}

