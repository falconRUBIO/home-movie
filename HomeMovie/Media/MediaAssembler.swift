import AVFoundation
import Foundation

struct MediaInfo: Sendable {
    var duration: CMTime
    var size: CGSize
    var hasAudio: Bool
    var bytes: Int64
}

enum MediaInspector {
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
        guard range.duration.isNumeric, range.duration.seconds > 0, bounds.width > 0, bounds.height > 0 else {
            throw HomeMovieError.message("The recording has no valid video duration.")
        }
        let audio = try await asset.loadTracks(withMediaType: .audio)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return MediaInfo(duration: range.duration, size: CGSize(width: abs(bounds.width), height: abs(bounds.height)),
            hasAudio: !audio.isEmpty, bytes: (attributes[.size] as? NSNumber)?.int64Value ?? 0)
    }
}

struct CompositionBundle: @unchecked Sendable {
    let asset: AVMutableComposition
    let videoComposition: AVMutableVideoComposition
    let duration: CMTime
}

actor MediaAssembler {
    // Every build uses an immutable movie snapshot. Trims never modify source files.
    func build(movie: Movie, root: URL) async throws -> CompositionBundle {
        let scenes = movie.activeScenes
        guard !scenes.isEmpty else { throw HomeMovieError.message("Record a scene first.") }
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw HomeMovieError.message("Could not prepare movie tracks.")
        }
        var cursor = CMTime.zero
        var instructions: [AVVideoCompositionInstructionProtocol] = []
        for scene in scenes {
            try Task.checkCancellation()
            guard !scene.missing, scene.validTrim else { throw HomeMovieError.message("A scene is missing or has an invalid trim. Restore or remove it before playing this movie.") }
            let asset = AVURLAsset(url: root.appendingPathComponent(scene.source))
            guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else { throw HomeMovieError.message("A scene has no video track.") }
            let sourceRange = try await sourceVideo.load(.timeRange)
            let start = CMTimeAdd(sourceRange.start, scene.trimStart.cmTime)
            let selected = CMTimeRange(start: start, duration: scene.playableDuration)
            guard CMTimeCompare(CMTimeRangeGetEnd(selected), CMTimeRangeGetEnd(sourceRange)) <= 0 else { throw HomeMovieError.message("A scene trim extends beyond the video track.") }
            try videoTrack.insertTimeRange(selected, of: sourceVideo, at: cursor)
            if let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first {
                let audioRange = try await sourceAudio.load(.timeRange)
                let intersection = CMTimeRangeGetIntersection(selected, audioRange)
                if intersection.isValid, intersection.duration.isNumeric, intersection.duration.seconds > 0 {
                    let audioPosition = CMTimeAdd(cursor, CMTimeSubtract(intersection.start, selected.start))
                    try audioTrack.insertTimeRange(intersection, of: sourceAudio, at: audioPosition)
                }
            }
            let naturalSize = try await sourceVideo.load(.naturalSize)
            let preferred = try await sourceVideo.load(.preferredTransform)
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
            layer.setTransform(Self.fitTransform(size: naturalSize, preferred: preferred, canvas: movie.format.canvas), at: cursor)
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: cursor, duration: scene.playableDuration)
            instruction.backgroundColor = CGColor(gray: 0, alpha: 1)
            instruction.layerInstructions = [layer]
            instructions.append(instruction)
            cursor = CMTimeAdd(cursor, scene.playableDuration)
        }
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = movie.format.canvas
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.instructions = instructions
        return CompositionBundle(asset: composition, videoComposition: videoComposition, duration: cursor)
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
