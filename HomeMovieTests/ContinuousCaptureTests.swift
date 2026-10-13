import XCTest
import AVFoundation
@testable import HomeMovie

final class ContinuousCaptureTests: XCTestCase {
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
        for index in 0..<12 {
            let time = CMTime(value: Int64(300 + index), timescale: 30)
            var accepted = false
            for _ in 0..<100 {
                if take.appendVideo(index < 6 ? front : back, at: time) { accepted = true; break }
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
        XCTAssertGreaterThanOrEqual(range.duration.seconds, 0.35)
        let generator = AVAssetImageGenerator(asset: asset); generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let (first, _) = try await generator.image(at: CMTime(value: 1, timescale: 30))
        let (second, _) = try await generator.image(at: CMTime(value: 8, timescale: 30))
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

