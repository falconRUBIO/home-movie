import XCTest
import AVFoundation
import CoreImage
@testable import HomeMovie

final class ContinuousCaptureTests: XCTestCase {
    func testFlipReadinessExpiresAndRejectsInvalidCameraTimes() {
        let now = CMTime(seconds: 10, preferredTimescale: 600)
        XCTAssertTrue(CameraFrameFreshness.isFresh(CMTime(seconds: 9.97, preferredTimescale: 600), at: now))
        XCTAssertTrue(CameraFrameFreshness.isFresh(CMTime(seconds: 9.5, preferredTimescale: 600), at: now))
        XCTAssertFalse(CameraFrameFreshness.isFresh(CMTime(seconds: 9.4, preferredTimescale: 600), at: now))
        XCTAssertFalse(CameraFrameFreshness.isFresh(CMTime(seconds: 11, preferredTimescale: 600), at: now))
        XCTAssertFalse(CameraFrameFreshness.isFresh(.invalid, at: now))
        XCTAssertFalse(CameraFrameFreshness.isFresh(now, at: .indefinite))
    }
    func testLogFlipKeepsOutgoingFrameUntilFreshNewCameraFramesArrive() async throws {
        let frames = LiveFrames(), front = try frame(red: false), rear = try frame(red: true)
        frames.configureRawPreview(angle: 90, front: true)
        frames.pushRawPreview(front, connectionAngle: 0)
        frames.holdRawPreview()
        frames.configureRawPreview(angle: 0, front: false)
        frames.pushRawPreview(rear, connectionAngle: 0, at: CMTime(seconds: 0.5, preferredTimescale: 600))
        XCTAssertTrue(frames.latest() === front)
        XCTAssertEqual(frames.snapshot()?.front, true)
        XCTAssertEqual(frames.snapshot()?.angle, 90)
        let ready = expectation(description: "New camera published")
        ready.expectedFulfillmentCount = 1; ready.assertForOverFulfill = true
        frames.resumeRawPreview(after: CMTime(seconds: 1, preferredTimescale: 600)) { ready.fulfill() }
        // Reject outgoing samples queued before the committed input change.
        frames.pushRawPreview(front, connectionAngle: 0, at: CMTime(seconds: 0.9, preferredTimescale: 600))
        for tick: Int64 in [31, 32] {
            frames.pushRawPreview(rear, connectionAngle: 0, at: CMTime(value: tick, timescale: 30))
            XCTAssertTrue(frames.latest() === front)
        }
        frames.pushRawPreview(rear, connectionAngle: 0, at: CMTime(value: 33, timescale: 30))
        XCTAssertTrue(frames.latest() === rear)
        XCTAssertEqual(frames.snapshot()?.front, false)
        XCTAssertEqual(frames.snapshot()?.angle, 0)
        frames.pushRawPreview(rear, connectionAngle: 0, at: CMTime(value: 34, timescale: 30))
        await fulfillment(of: [ready], timeout: 1)
    }

    func testCancelledLogFlipReleasesHoldWithoutSendingObsoleteReadyCallback() throws {
        let frames = LiveFrames(), image = try frame(red: true)
        frames.holdRawPreview()
        frames.resumeRawPreview(after: CMTime(seconds: 1, preferredTimescale: 600)) {
            XCTFail("A cancelled handoff must not announce the old camera switch")
        }
        frames.cancelRawPreviewHandoff()
        frames.configureRawPreview(angle: 90, front: true)
        for tick: Int64 in [31, 32, 33, 34] {
            frames.pushRawPreview(image, connectionAngle: 0, at: CMTime(value: tick, timescale: 30))
        }
        XCTAssertTrue(frames.latest() === image)
        frames.holdRawPreview(); frames.clear()
        frames.pushRawPreview(image, connectionAngle: 0)
        XCTAssertTrue(frames.latest() === image, "Repreparing must release any earlier hold")
    }

    func testRawLogPreviewKeepsPortraitAndMirroringWhenOutputBuffersRotate() throws {
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        let sourceSize = CGSize(width: 32, height: 18)
        let source = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 16, height: 9))
            .composited(over: CIImage(color: CIColor(red: 0, green: 1, blue: 0)).cropped(to: CGRect(x: 16, y: 0, width: 16, height: 9)))
            .composited(over: CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: CGRect(x: 0, y: 9, width: 16, height: 9)))
            .composited(over: CIImage(color: CIColor(red: 1, green: 1, blue: 0)).cropped(to: CGRect(x: 16, y: 9, width: 16, height: 9)))
        func buffer(_ image: CIImage) throws -> CVPixelBuffer {
            var result: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, Int(image.extent.width), Int(image.extent.height),
                kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &result), kCVReturnSuccess)
            let pixelBuffer = try XCTUnwrap(result)
            context.render(image, to: pixelBuffer, bounds: image.extent, colorSpace: nil)
            return pixelBuffer
        }
        func pixels(_ image: CIImage, target: CGSize) -> Data {
            var bytes = [UInt8](repeating: 0, count: Int(target.width * target.height) * 4)
            context.render(image, toBitmap: &bytes, rowBytes: Int(target.width) * 4,
                bounds: CGRect(origin: .zero, size: target), format: .RGBA8, colorSpace: nil)
            return Data(bytes)
        }
        for front in [false, true] {
            for captureAngle: CGFloat in [0, 90, 180, 270] {
                let target = captureAngle == 90 || captureAngle == 270 ? CGSize(width: 18, height: 32) : sourceSize
                let frames = LiveFrames()
                frames.configureRawPreview(angle: captureAngle, front: front)
                let expected = source.transformed(by: LiveLookGeometry.transform(source: sourceSize,
                    target: target, angle: captureAngle, front: front))
                for connectionAngle: CGFloat in [0, 90, 180, 270] {
                    // Simulate data-output buffer rotation independently of the file output
                    // and the native preview layer changing orientation at recording start.
                    var delivered = source.transformed(by: CGAffineTransform(rotationAngle: -connectionAngle * .pi / 180))
                    delivered = delivered.transformed(by: CGAffineTransform(translationX: -delivered.extent.minX, y: -delivered.extent.minY))
                    frames.pushRawPreview(try buffer(delivered), connectionAngle: connectionAngle)
                    let snapshot = try XCTUnwrap(frames.snapshot())
                    XCTAssertEqual(snapshot.front, front)
                    let actual = CIImage(cvPixelBuffer: snapshot.buffer).transformed(by:
                        LiveLookGeometry.transform(source: delivered.extent.size, target: target,
                            angle: try XCTUnwrap(snapshot.angle), front: snapshot.front ?? false))
                    XCTAssertEqual(pixels(actual, target: target), pixels(expected, target: target),
                        "Capture \(captureAngle), output \(connectionAngle), front \(front)")
                }
            }
        }
    }

    @MainActor func testFirstPortraitFrontTakeSavesPortraitDespiteLandscapeSensorAngle() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(root: root); _ = try await store.load()
        let movie = try await store.create(name: "Portrait first take", format: .landscape)
        let visibleFormat = OrientationPolicy.interfaceFormat(.portrait, observed: 0)
        let angle = visibleFormat.recordingAngle(observed: 0)
        let ticket = try await store.begin(movieID: movie.id, format: visibleFormat, profile: .standard)
        let writer = try ContinuousTakeWriter(url: try await store.url(ticket.staging), angle: angle)
        let front = try frame(red: false)
        CVPixelBufferLockBaseAddress(front, [])
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(front)).assumingMemoryBound(to: UInt8.self)
        for y in 0..<9 { for x in 0..<32 {
            let offset = y * CVPixelBufferGetBytesPerRow(front) + x * 4
            base[offset + 1] = 0; base[offset + 2] = 220
        }}
        CVPixelBufferUnlockBaseAddress(front, [])
        XCTAssertEqual(writer.canvas, MovieFormat.portrait.canvas)
        for index in 0..<10 {
            var accepted = false
            for _ in 0..<100 {
                if writer.appendVideo(front, at: CMTime(value: Int64(index), timescale: 30), sourceAngle: 0) {
                    accepted = true; break
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(accepted)
        }
        let finished = expectation(description: "Portrait take finishes")
        writer.finish { error in XCTAssertNil(error); finished.fulfill() }
        await fulfillment(of: [finished], timeout: 30)
        try await store.commit(ticket)
        let reopened = ProjectStore(root: root); _ = try await reopened.load()
        let snapshots = await reopened.snapshot()
        let saved = try XCTUnwrap(snapshots.first)
        XCTAssertEqual(saved.recordingFormat, .portrait)
        let scene = try XCTUnwrap(saved.activeScenes.first)
        XCTAssertEqual(scene.width, 1080); XCTAssertEqual(scene.height, 1920)
        let asset = try await MediaInspector.inspect(reopened.root.appendingPathComponent(scene.source))
        XCTAssertEqual(asset.size, MovieFormat.portrait.canvas)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: reopened.root.appendingPathComponent(scene.source)))
        generator.appliesPreferredTrackTransform = true
        let (frame, _) = try await generator.image(at: CMTime(value: 1, timescale: 30))
        let image = CIImage(cgImage: frame)
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        func pixel(at fraction: CGFloat) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: 4)
            context.render(image, toBitmap: &bytes, rowBytes: 4,
                bounds: CGRect(x: image.extent.midX, y: image.extent.height * fraction, width: 1, height: 1),
                format: .RGBA8, colorSpace: nil)
            return bytes
        }
        let top = pixel(at: 0.25), bottom = pixel(at: 0.75)
        XCTAssertGreaterThan(abs(Int(top[0]) - Int(bottom[0])), 100)
        XCTAssertGreaterThan(abs(Int(top[1]) - Int(bottom[1])), 100)
    }

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
        XCTAssertTrue(CameraCompatibility.shouldPreparePiP(profile: .appleLog, storedPreference: true, requested: true, currentlyEnabled: true))
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
    func testPiPAllowsEitherProfileOnlyWhenItsDeviceFormatsAreSupported() {
        XCTAssertTrue(CameraCompatibility.allowsPiP(profile: .appleLog, deviceSupported: true))
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
    @MainActor func testLogFlipUsesContinuousCaptureAndRequiresTenBitFormats() {
        XCTAssertTrue(CameraCompatibility.allowsFlip(profile: .appleLog, recording: true,
            otherCameraSupported: true, continuousFlipSupported: true))
        XCTAssertFalse(CameraCompatibility.allowsFlip(profile: .appleLog, recording: true,
            otherCameraSupported: false, continuousFlipSupported: true))
        XCTAssertNil(CaptureService.logPixelFormat(in: [kCVPixelFormatType_32BGRA, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]))
        XCTAssertEqual(CaptureService.logPixelFormat(in: [kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange]), kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange)
        XCTAssertEqual(CaptureService.logPixelFormat(in: [kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, LogPiPColor.pixelFormat]), LogPiPColor.pixelFormat)
        let portrait = OrientationPolicy.interfaceFormat(.portrait, observed: 0)
        XCTAssertEqual(portrait.recordingAngle(observed: 0, profile: .appleLog, composited: true), 90)
    }
    func testOrdinaryLogKeepsOnePortraitTakeAndAudioAcrossFrontRearFront() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let angle = MovieFormat.portrait.recordingAngle(observed: 0, profile: .appleLog, composited: true)
        let writer = try ContinuousTakeWriter(url: url, angle: angle, profile: .appleLog)
        let renderer = PiPFrameRenderer(profile: .appleLog)
        func image(_ value: CGFloat, size: CGSize) throws -> CVPixelBuffer {
            try XCTUnwrap(renderer.render(CIImage(color: CIColor(red: value, green: value, blue: value)), canvas: size))
        }
        let front = try image(0.2, size: CGSize(width: 64, height: 96))
        let rear = try image(0.8, size: CGSize(width: 96, height: 64))
        let returnedFront = try image(0.4, size: CGSize(width: 64, height: 96))
        for index in 0..<45 {
            let buffer = index < 15 ? front : index < 30 ? rear : returnedFront
            let sensorAngle: CGFloat = index >= 15 && index < 30 ? 90 : 0
            let time = CMTime(value: Int64(index), timescale: 30)
            var accepted = false
            for _ in 0..<100 {
                if writer.appendVideo(buffer, at: time, sourceAngle: sensorAngle) { accepted = true; break }
                if let error = writer.failure { throw error }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(accepted)
            writer.appendAudio(try audio(at: time))
        }
        let completed = expectation(description: "Continuous front/rear Log take finishes")
        writer.finish { error in XCTAssertNil(error); completed.fulfill() }
        await fulfillment(of: [completed], timeout: 30)
        try await LogPiPValidation.verifySavedFile(url: url, expectedCanvas: MovieFormat.portrait.canvas)
        let asset = AVURLAsset(url: url)
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(video.count, 1); XCTAssertEqual(audio.count, 1)
        let range = try await XCTUnwrap(audio.first).load(.timeRange)
        XCTAssertGreaterThanOrEqual(range.duration.seconds, 1.4)
        let track = try XCTUnwrap(video.first)
        let context = CIContext(options: LogPiPColor.contextOptions())
        for (time, expected) in [(0.2, Float(0.2)), (0.7, Float(0.8)), (1.2, Float(0.4))] {
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: LogPiPColor.pixelFormat])
            reader.add(output)
            reader.timeRange = CMTimeRange(start: CMTime(seconds: time, preferredTimescale: 600), duration: CMTime(value: 1, timescale: 30))
            XCTAssertTrue(reader.startReading())
            let sample = try XCTUnwrap(output.copyNextSampleBuffer())
            let buffer = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
            XCTAssertTrue(LogPiPColor.isTenBit(buffer))
            var pixel = [Float](repeating: 0, count: 4)
            pixel.withUnsafeMutableBytes {
                context.render(CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()]),
                    toBitmap: $0.baseAddress!, rowBytes: 16, bounds: CGRect(x: 540, y: 960, width: 1, height: 1),
                    format: .RGBAf, colorSpace: nil)
            }
            XCTAssertEqual(pixel[0], expected, accuracy: 0.03, "Log code values must survive both camera changes without baking a look")
            reader.cancelReading()
        }
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
