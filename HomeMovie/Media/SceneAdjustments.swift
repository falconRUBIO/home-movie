import Foundation
import CoreImage

// Reversible per-scene nodes: source balance, look, then display finishing.
struct SceneAdjustments: Codable, Equatable, Sendable {
    static let neutral = SceneAdjustments()
    static let engineVersion = 4
    var exposure = 0.0
    var shadows = 0.0
    var highlights = 0.0
    var warmth = 0.0
    var tint = 0.0
    var brightness = 0.0
    var brilliance = 0.0
    var pushPull = 0.0
    var contrast = 0.0
    var blackPoint = 0.0
    var saturation = 0.0
    var vibrance = 0.0
    // 1 preserves historical all-after-LUT edits; 2 balances before the look.
    var pipelineVersion = 2
    private enum CodingKeys: String, CodingKey { case exposure, shadows, highlights, warmth, tint, brightness, brilliance, pushPull, contrast, blackPoint, saturation, vibrance, pipelineVersion }
    private var values: [Double] { [exposure, shadows, highlights, warmth, tint, brightness, brilliance, pushPull, contrast, blackPoint, saturation, vibrance] }
    var isActive: Bool { values.contains { $0 != 0 } }
    func validate() throws {
        guard (1...2).contains(pipelineVersion), values.allSatisfy({ $0.isFinite && (-1...1).contains($0) }) else {
            throw HomeMovieError.message("This scene’s light adjustments are invalid.")
        }
    }
    // Decode to scene-linear, balance, and re-encode into the LUT's ORIGINAL
    // input encoding. Never feed linear RGB straight into an Apple Log LUT.
    func applyingBalance(to source: CIImage, logEncoded: Bool) throws -> CIImage {
        try validate()
        guard pipelineVersion == 2, exposure != 0 || warmth != 0 || tint != 0 else { return source }
        guard let kernel = try Self.balanceKernel.get(), let output = kernel.apply(extent: source.extent,
            arguments: [source, exposure, warmth, tint, logEncoded ? 1.0 : 0.0]) else {
            throw HomeMovieError.message("This scene’s source balance could not be rendered.")
        }
        return output
    }
    func applyingFinishing(to source: CIImage) throws -> CIImage {
        var finishing = self
        if pipelineVersion == 2 { finishing.exposure = 0; finishing.warmth = 0; finishing.tint = 0 }
        return try finishing.apply(to: source)
    }
    func apply(to source: CIImage) throws -> CIImage {
        try validate()
        guard isActive else { return source }
        guard let kernel = try Self.kernel.get(), let output = kernel.apply(extent: source.extent,
            arguments: [source, exposure, shadows, highlights, warmth, tint, brightness, brilliance, pushPull,
                contrast, blackPoint, saturation, vibrance]) else {
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
    private static let balanceKernel: Result<CIColorKernel?, Error> = Result {
        guard let url = Bundle.main.url(forResource: "FilmEffects", withExtension: "metallib") else {
            throw HomeMovieError.message("Source balance could not load.")
        }
        return try CIColorKernel(functionName: "sceneBalance", fromMetalLibraryData: Data(contentsOf: url))
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
        contrast = try values.decodeIfPresent(Double.self, forKey: .contrast) ?? 0
        blackPoint = try values.decodeIfPresent(Double.self, forKey: .blackPoint) ?? 0
        saturation = try values.decodeIfPresent(Double.self, forKey: .saturation) ?? 0
        vibrance = try values.decodeIfPresent(Double.self, forKey: .vibrance) ?? 0
        pipelineVersion = try values.decodeIfPresent(Int.self, forKey: .pipelineVersion)
            ?? ((exposure != 0 || warmth != 0 || tint != 0) ? 1 : 2)
        try validate()
    }
}
