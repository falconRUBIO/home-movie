import AVFoundation
import VideoToolbox

// Explicit 10-bit SDR export. Reuses the preview composition and audio mix;
// a codec preset alone does not promise Main10 for SDR content.
enum GradedMovieExporter {
    static let pixelFormat = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
    static var colorProperties: [String: Any] { [
        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2] }
    static func videoSettings(size: CGSize) -> [String: Any] { [
        AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
        AVVideoColorPropertiesKey: colorProperties,
        AVVideoCompressionPropertiesKey: [
            AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel as String,
            AVVideoAverageBitRateKey: 28_000_000, AVVideoExpectedSourceFrameRateKey: 30,
            AVVideoMaxKeyFrameIntervalKey: 30]] }
    static func export(_ bundle: CompositionBundle, to url: URL,
                       progress: @escaping @Sendable (Double) async -> Void) async throws {
        try Task.checkCancellation()
        let reader = try AVAssetReader(asset: bundle.asset)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let videoTracks = try await bundle.asset.loadTracks(withMediaType: .video)
        let audioTracks = try await bundle.asset.loadTracks(withMediaType: .audio)
        let video = AVAssetReaderVideoCompositionOutput(videoTracks: videoTracks, videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferMetalCompatibilityKey as String: true])
        video.videoComposition = bundle.videoComposition; video.alwaysCopiesSampleData = false
        let settings = videoSettings(size: bundle.videoComposition.renderSize)
        guard reader.canAdd(video), writer.canApply(outputSettings: settings, forMediaType: .video) else {
            throw HomeMovieError.message("10-bit movie export is unavailable on this device.")
        }
        reader.add(video)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        guard writer.canAdd(videoInput) else { throw HomeMovieError.message("Could not prepare 10-bit video export.") }
        writer.add(videoInput)
        var audio: AVAssetReaderAudioMixOutput?
        var audioInput: AVAssetWriterInput?
        if !audioTracks.isEmpty {
            let output = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
            output.audioMix = bundle.audioMix; output.alwaysCopiesSampleData = false
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000])
            guard reader.canAdd(output), writer.canAdd(input) else { throw HomeMovieError.message("Could not prepare movie audio.") }
            reader.add(output); writer.add(input); audio = output; audioInput = input
        }
        do {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                guard writer.startWriting(), reader.startReading() else {
                    throw writer.error ?? reader.error ?? HomeMovieError.message("Could not start 10-bit export.")
                }
                writer.startSession(atSourceTime: .zero)
                // Independent drains are essential: a blocked video read must
                // never prevent the audio output from being consumed (or vice versa).
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        try await drain(video, into: videoInput, reader: reader, writer: writer,
                                        duration: bundle.duration, progress: progress)
                    }
                    if let audio, let audioInput {
                        group.addTask {
                            try await drain(audio, into: audioInput, reader: reader, writer: writer,
                                            duration: bundle.duration)
                        }
                    }
                    do { while let _ = try await group.next() { } }
                    catch {
                        reader.cancelReading(); writer.cancelWriting(); group.cancelAll()
                        throw error
                    }
                }
                guard reader.status == .completed else { throw reader.error ?? HomeMovieError.message("The movie could not be read completely.") }
                writer.endSession(atSourceTime: bundle.duration)
                await writer.finishWriting()
                try Task.checkCancellation()
                guard writer.status == .completed else { throw writer.error ?? HomeMovieError.message("10-bit export did not finish.") }
            } onCancel: {
                reader.cancelReading(); writer.cancelWriting()
            }
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw HomeMovieError.message("The exported video is missing.") }
            let formats = try await track.load(.formatDescriptions)
            guard !formats.isEmpty, formats.allSatisfy(LogPiPColor.encodedTenBit) else {
                throw HomeMovieError.message("The export did not retain 10-bit quality. Please try again.")
            }
        } catch {
            reader.cancelReading(); writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
    private static func drain(_ output: AVAssetReaderOutput, into input: AVAssetWriterInput,
                              reader: AVAssetReader, writer: AVAssetWriter, duration: CMTime,
                              progress: (@Sendable (Double) async -> Void)? = nil) async throws {
        var frames = 0
        while true {
            try Task.checkCancellation()
            if writer.status == .failed || reader.status == .failed {
                throw writer.error ?? reader.error ?? HomeMovieError.message("Movie export was interrupted.")
            }
            if writer.status == .cancelled || reader.status == .cancelled { throw CancellationError() }
            guard input.isReadyForMoreMediaData else { try await Task.sleep(for: .milliseconds(2)); continue }
            guard let sample = output.copyNextSampleBuffer() else { input.markAsFinished(); return }
            guard input.append(sample) else { throw writer.error ?? HomeMovieError.message("Could not encode movie media.") }
            frames += 1
            if frames % 6 == 0, let progress {
                await progress(min(0.99, CMSampleBufferGetPresentationTimeStamp(sample).seconds / duration.seconds))
            }
        }
    }

}
