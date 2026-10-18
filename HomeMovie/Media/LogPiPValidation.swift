import AVFoundation
import CoreImage

// Exercise the actual encoder once per process before exposing Log PiP. Merely
// advertising MultiCam formats does not prove that the saved MOV retains Log.
actor LogPiPValidation {
    static let shared = LogPiPValidation()
    private var validation: Task<Void, Error>?
    func check() async throws {
        if let validation { return try await validation.value }
        let job = Task { try await Self.validateEncoder() }
        validation = job
        do { try await job.value }
        catch { validation = nil; throw error }
    }
    private static func validateEncoder() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("log-pip-check-\(UUID()).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try ContinuousTakeWriter(url: url, angle: 0, profile: .appleLog)
        guard let frame = PiPFrameRenderer(profile: .appleLog).render(
            CIImage(color: CIColor(red: 0.4, green: 0.4, blue: 0.4)), canvas: CGSize(width: 64, height: 64)) else {
            writer.writer.cancelWriting()
            throw HomeMovieError.message("This iPhone could not render a 10-bit Log frame. Your movie remains in Log; use the ordinary camera.")
        }
        do {
            for index in 0..<3 {
                var accepted = false
                for _ in 0..<100 {
                    try Task.checkCancellation()
                    if writer.appendVideo(frame, at: CMTime(value: Int64(index), timescale: 30)) { accepted = true; break }
                    if let failure = writer.failure { throw failure }
                    try await Task.sleep(for: .milliseconds(10))
                }
                guard accepted else { throw HomeMovieError.message("The 10-bit Log encoder did not accept a frame.") }
            }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                writer.finish { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            }
            let info = try await MediaInspector.inspect(url)
            guard info.profile == .appleLog else {
                throw HomeMovieError.message("This iOS encoder did not preserve Apple Log metadata. Your movie stays in Log; use the ordinary camera.")
            }
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw HomeMovieError.message("The Log encoder produced no video track.") }
            let descriptions = try await track.load(.formatDescriptions)
            guard !descriptions.isEmpty, descriptions.allSatisfy(LogPiPColor.encodedTenBit) else {
                throw HomeMovieError.message("The Log PiP encoder did not save 10-bit HEVC components.")
            }
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: LogPiPColor.pixelFormat])
            reader.add(output)
            guard reader.startReading(), let sample = output.copyNextSampleBuffer(),
                  let decoded = CMSampleBufferGetImageBuffer(sample), LogPiPColor.isTenBit(decoded) else {
                throw HomeMovieError.message("The Log PiP test could not decode 10-bit video.")
            }
            reader.cancelReading()
        } catch {
            if writer.writer.status == .writing { writer.writer.cancelWriting() }
            throw error
        }
    }
}
