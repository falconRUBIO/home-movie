import AVFoundation
import CoreImage

/// Display-only Apple Log exposure map. Never pass this output to a movie writer.
/// Stops are relative to 18% gray; the high/low zones are exposure guides, not
/// calibrated sensor saturation or noise-floor measurements.
enum FalseColorPreview {
    static let preferenceKey = "falseColorPreview"
    private static let kernel: Result<CIColorKernel, Error> = Result {
        guard let url = Bundle.main.url(forResource: "FilmEffects", withExtension: "metallib") else {
            throw HomeMovieError.message("False Color could not load. Recording is unaffected.")
        }
        return try CIColorKernel(functionName: "logFalseColor", fromMetalLibraryData: Data(contentsOf: url))
    }
    static func apply(to image: CIImage) throws -> CIImage {
        guard let output = try kernel.get().apply(extent: image.extent, arguments: [image]) else {
            throw HomeMovieError.message("False Color preview is unavailable. Recording is unaffected.")
        }
        return output
    }
    static func image(_ buffer: CVPixelBuffer) throws -> CIImage {
        // Reject unverified SDR/HLG frames, including during camera handoffs.
        guard LogPiPColor.isLog(buffer) else {
            throw HomeMovieError.message("False Color requires verified Apple Log frames.")
        }
        // Core Image expands the pixel format's video/full range and YCbCr matrix.
        // Disable color management so the Apple Log code values reach the kernel intact.
        return try apply(to: CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()]))
    }
    static func image(background: CVPixelBuffer, presenter: CVPixelBuffer?, canvas: CGSize,
                      backgroundAngle: CGFloat, presenterAngle: CGFloat,
                      presentation: PiPPresentation) throws -> CIImage {
        let rear = try image(background)
        let front = try presenter.map { try image($0) }
        return PiPCompositor.image(background: rear, presenter: front, canvas: canvas,
            backgroundAngle: backgroundAngle, presenterAngle: presenterAngle, presentation: presentation)
    }
}
