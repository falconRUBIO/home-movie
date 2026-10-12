import AVFoundation
import Foundation

struct MediaInfo: Sendable {
    var duration: CMTime
    var size: CGSize
    var hasAudio: Bool
    var bytes: Int64
    var profile: CaptureProfile? = nil
}

enum MediaInspector {
    static func captureProfile(for descriptions: [CMFormatDescription]) -> CaptureProfile? {
        // The actual Apple Log identifier contains a hyphen: com.apple.rec2020.apple-log.
        // Read the specific field and compare Apple's constant, never a dictionary's debug text.
        guard !descriptions.isEmpty, descriptions.allSatisfy({ description in
            let identifier = CMFormatDescriptionGetExtension(description,
                extensionKey: kCMFormatDescriptionExtension_LogTransferFunction) as? String
            return identifier == kCMFormatDescriptionLogTransferFunction_AppleLog as String
        }) else { return nil }
        return .appleLog
    }
    static func inspect(_ url: URL) async throws -> MediaInfo {
        guard FileManager.default.fileExists(atPath: url.path) else { throw HomeMovieError.message("A recording file is missing.") }
        let asset = AVURLAsset(url: url)
        guard try await asset.load(.isPlayable), let video = try await asset.loadTracks(withMediaType: .video).first else {
            throw HomeMovieError.message("This recording is incomplete or cannot be played. Its file has been preserved.")
        }
        let range = try await video.load(.timeRange)
        let size = try await video.load(.naturalSize)
        let transform = try await video.load(.preferredTransform)
        let bounds = CGRect(origin: .zero, size: size).applying(transform)
        guard MediaAssembler.hasValidGeometry(size: size, preferred: transform), range.isValid,
              range.start.isNumeric, range.start.seconds.isFinite, range.duration.isNumeric, range.duration.seconds.isFinite, range.duration.seconds > 0,
              bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else {
            throw HomeMovieError.message("The recording has no valid video duration.")
        }
        let descriptions = try await video.load(.formatDescriptions)
        let profile = captureProfile(for: descriptions)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return MediaInfo(duration: range.duration, size: CGSize(width: abs(bounds.width), height: abs(bounds.height)),
            hasAudio: !audio.isEmpty, bytes: (attributes[.size] as? NSNumber)?.int64Value ?? 0, profile: profile)
    }
}

struct CompositionBundle: @unchecked Sendable {
    let asset: AVMutableComposition
    let videoComposition: AVMutableVideoComposition
    let audioMix: AVAudioMix?
    let duration: CMTime
}

actor MediaAssembler {
    // Every build uses an immutable movie snapshot. Trims never modify source files.
    func build(movie: Movie, root: URL, showOriginalLog: Bool = false) async throws -> CompositionBundle {
        let scenes = movie.activeScenes
        guard !scenes.isEmpty else { throw HomeMovieError.message("Record a scene first.") }
        let usesLog = movie.captureProfile == .appleLog || scenes.contains { $0.profile == .appleLog }
        let cube: ColorCube? = usesLog && !showOriginalLog ? try movie.look.map { try ColorCube.load($0, root: root) } ?? ColorCube.appleStandard.get() : nil
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw HomeMovieError.message("Could not prepare movie tracks.")
        }
        // A silent movie must not contain an empty, formatless audio track.
        var audioTrack: AVMutableCompositionTrack?
        var audioParameters: AVMutableAudioMixInputParameters?
        var cursor = CMTime.zero
        var instructions: [AVVideoCompositionInstructionProtocol] = []
        for scene in scenes {
            try Task.checkCancellation()
            guard !scene.missing, scene.validTrim else { throw HomeMovieError.message("A scene is missing or has an invalid trim. Restore or remove it before playing this movie.") }
            let asset = AVURLAsset(url: root.appendingPathComponent(scene.source))
            guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else { throw HomeMovieError.message("A scene has no video track.") }
            let sourceRange = try await sourceVideo.load(.timeRange)
            guard sourceRange.isValid, sourceRange.start.isNumeric, sourceRange.start.seconds.isFinite,
                  sourceRange.duration.isNumeric, sourceRange.duration.seconds.isFinite, sourceRange.duration.seconds > 0 else {
                throw HomeMovieError.message("A scene has an invalid video time range. Its original file has been preserved.")
            }
            let start = CMTimeAdd(sourceRange.start, scene.trimStart.cmTime)
            let selected = CMTimeRange(start: start, duration: scene.playableDuration)
            guard CMTimeCompare(CMTimeRangeGetEnd(selected), CMTimeRangeGetEnd(sourceRange)) <= 0 else { throw HomeMovieError.message("A scene trim extends beyond the video track.") }
            try videoTrack.insertTimeRange(selected, of: sourceVideo, at: cursor)
            if let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first {
                let audioRange = try await sourceAudio.load(.timeRange)
                let intersection = CMTimeRangeGetIntersection(selected, otherRange: audioRange)
                if intersection.isValid, intersection.duration.isNumeric, intersection.duration.seconds > 0 {
                    if audioTrack == nil {
                        audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                        audioParameters = audioTrack.map { AVMutableAudioMixInputParameters(track: $0) }
                    }
                    guard let audioTrack else { throw HomeMovieError.message("Could not prepare movie audio.") }
                    let audioPosition = CMTimeAdd(cursor, CMTimeSubtract(intersection.start, selected.start))
                    try audioTrack.insertTimeRange(intersection, of: sourceAudio, at: audioPosition)
                    if let audioParameters {
                        Self.smoothAudioEdges(audioParameters, range: CMTimeRange(start: audioPosition, duration: intersection.duration))
                    }
                }
            }
            let naturalSize = try await sourceVideo.load(.naturalSize)
            let preferred = try await sourceVideo.load(.preferredTransform)
            guard Self.hasValidGeometry(size: naturalSize, preferred: preferred) else {
                throw HomeMovieError.message("A scene has invalid video dimensions. Its original file has been preserved.")
            }
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
            layer.setTransform(Self.fitTransform(size: naturalSize, preferred: preferred, canvas: movie.format.canvas), at: cursor)
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: cursor, duration: scene.playableDuration)
            instruction.backgroundColor = CGColor(gray: 0, alpha: 1)
            instruction.layerInstructions = [layer]
            if usesLog {
                instructions.append(ColorInstruction(range: instruction.timeRange, trackID: videoTrack.trackID,
                    transform: Self.fitTransform(size: naturalSize, preferred: preferred, canvas: movie.format.canvas),
                    cube: (scene.profile ?? movie.captureProfile) == .appleLog ? cube : nil))
            } else { instructions.append(instruction) }
            cursor = CMTimeAdd(cursor, scene.playableDuration)
        }
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = movie.format.canvas
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.sourceTrackIDForFrameTiming = videoTrack.trackID
        videoComposition.instructions = instructions
        if usesLog {
            videoComposition.customVideoCompositorClass = LogVideoCompositor.self
            videoComposition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
            videoComposition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
            videoComposition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        }
        let audioMix: AVMutableAudioMix? = audioParameters.map { parameters in
            let mix = AVMutableAudioMix(); mix.inputParameters = [parameters]; return mix
        }
        return CompositionBundle(asset: composition, videoComposition: videoComposition, audioMix: audioMix, duration: cursor)
    }
    // Brief fades remove waveform discontinuities at cuts without changing scene timing or source files.
    nonisolated static func smoothAudioEdges(_ parameters: AVMutableAudioMixInputParameters, range: CMTimeRange) {
        guard range.isValid, range.duration.isNumeric, range.duration.seconds > 0 else { return }
        let fade = CMTimeMinimum(CMTime(value: 1, timescale: 50), CMTimeMultiplyByFloat64(range.duration, multiplier: 0.5))
        parameters.setVolumeRamp(fromStartVolume: 0, toEndVolume: 1,
            timeRange: CMTimeRange(start: range.start, duration: fade))
        parameters.setVolumeRamp(fromStartVolume: 1, toEndVolume: 0,
            timeRange: CMTimeRange(start: CMTimeSubtract(CMTimeRangeGetEnd(range), fade), duration: fade))
    }
    nonisolated static func hasValidGeometry(size: CGSize, preferred: CGAffineTransform) -> Bool {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              [preferred.a, preferred.b, preferred.c, preferred.d, preferred.tx, preferred.ty].allSatisfy({ $0.isFinite }) else { return false }
        let bounds = CGRect(origin: .zero, size: size).applying(preferred)
        return bounds.width.isFinite && bounds.height.isFinite && bounds.width > 0 && bounds.height > 0
    }
    nonisolated static func fitTransform(size: CGSize, preferred: CGAffineTransform, canvas: CGSize) -> CGAffineTransform {
        let bounds = CGRect(origin: .zero, size: size).applying(preferred)
        let scale = min(canvas.width / abs(bounds.width), canvas.height / abs(bounds.height))
        let x = (canvas.width - abs(bounds.width) * scale) / 2
        let y = (canvas.height - abs(bounds.height) * scale) / 2
        return preferred.concatenating(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: x, y: y))
    }
}
