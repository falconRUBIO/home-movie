import Foundation
import CoreImage

// A separate, reversible recipe on each scene. Applied after its Log conversion/LUT.
struct SceneAdjustments: Codable, Equatable, Sendable {
    static let neutral = SceneAdjustments()
    static let engineVersion = 3
    var exposure = 0.0
    var shadows = 0.0
    var highlights = 0.0
    var warmth = 0.0
    var tint = 0.0
    var brightness = 0.0
    var brilliance = 0.0
    var pushPull = 0.0
    private enum CodingKeys: String, CodingKey { case exposure, shadows, highlights, warmth, tint, brightness, brilliance, pushPull }
    var isActive: Bool { self != .neutral }
    func validate() throws {
        guard [exposure, shadows, highlights, warmth, tint, brightness, brilliance, pushPull].allSatisfy({ $0.isFinite && (-1...1).contains($0) }) else {
            throw HomeMovieError.message("This scene’s light adjustments are invalid.")
        }
    }
    func apply(to source: CIImage) throws -> CIImage {
        try validate()
        guard isActive else { return source }
        guard let kernel = try Self.kernel.get(), let output = kernel.apply(extent: source.extent,
            arguments: [source, exposure, shadows, highlights, warmth, tint, brightness, brilliance, pushPull]) else {
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


extension SceneAdjustments {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        exposure = try values.decodeIfPresent(Double.self, forKey: .exposure) ?? 0
        shadows = try values.decodeIfPresent(Double.self, forKey: .shadows) ?? 0
        highlights = try values.decodeIfPresent(Double.self, forKey: .highlights) ?? 0
        warmth = try values.decodeIfPresent(Double.self, forKey: .warmth) ?? 0
        tint = try values.decodeIfPresent(Double.self, forKey: .tint) ?? 0
        brightness = try values.decodeIfPresent(Double.self, forKey: .brightness) ?? 0
        brilliance = try values.decodeIfPresent(Double.self, forKey: .brilliance) ?? 0
        pushPull = try values.decodeIfPresent(Double.self, forKey: .pushPull) ?? 0
        try validate()
    }
}
