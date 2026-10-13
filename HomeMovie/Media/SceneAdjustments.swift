import Foundation
import CoreImage

// A separate, reversible recipe on each scene. Applied after its Log conversion/LUT.
struct SceneAdjustments: Codable, Equatable, Sendable {
    static let neutral = SceneAdjustments()
    static let engineVersion = 1
    var exposure = 0.0
    var shadows = 0.0
    var highlights = 0.0
    var isActive: Bool { self != .neutral }
    func validate() throws {
        guard [exposure, shadows, highlights].allSatisfy({ $0.isFinite && (-1...1).contains($0) }) else {
            throw HomeMovieError.message("This scene’s light adjustments are invalid.")
        }
    }
    func apply(to source: CIImage) throws -> CIImage {
        try validate()
        guard isActive else { return source }
        guard let kernel = try Self.kernel.get(), let output = kernel.apply(extent: source.extent,
            arguments: [source, exposure, shadows, highlights]) else {
            throw HomeMovieError.message("This scene’s light adjustments could not be rendered.")
        }
        return output
    }
    private static let kernel: Result<CIColorKernel?, Error> = Result {
        guard let url = Bundle.main.url(forResource: "FilmEffects", withExtension: "metallib") else {
            throw HomeMovieError.message("Light adjustments could not load.")
        }
        return try CIColorKernel(functionName: "sceneLight", fromMetalLibraryData: Data(contentsOf: url))
    }
}
