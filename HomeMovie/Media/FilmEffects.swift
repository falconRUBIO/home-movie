import Foundation
import CoreImage
import CoreMedia
import CryptoKit

enum FilmGrainTexture: String, Codable, CaseIterable, Identifiable, Sendable {
    case fine35, coarse16
    var id: Self { self }
    var label: String { self == .fine35 ? "Fine 35mm" : "Coarse 16mm" }
    var referenceSize: Double { self == .fine35 ? 1.0 : 1.6 }
}

// Stored separately from capture profile and LUT selection. Optional on Movie for old catalogs.
struct FilmEffectsSettings: Codable, Equatable, Sendable {
    static let engineVersion = 10
    static let off = FilmEffectsSettings()
    var version = 1
    var grainEnabled = false
    var grainAmount = 0.25
    var grainSize = 1.0
    var grainTexture: FilmGrainTexture = .fine35
    var grainColor = 1.0 // 1 retains the restrained engine-9 color response; 0 is monochrome texture.
    var halationEnabled = false
    var halationAmount = 0.2
    var halationSpread = 0.35
    var halationSensitivity = 0.25
    var halationSaturation = 1.0
    var bloomEnabled = false
    var bloomAmount = 0.15
    var bloomSpread = 0.35
    var bloomSensitivity = 0.25
    var softnessEnabled = false
    var softnessAmount = 0.35
    var rolloffEnabled = false
    var rolloffAmount = 0.35
    var sharpnessAmount = 0.0
    var vignetteAmount = 0.0
    var seed: UInt32 = 104729
    init() {}
    private enum CodingKeys: String, CodingKey {
        case version, grainEnabled, grainAmount, grainSize, grainTexture, grainColor, halationEnabled, halationAmount, halationSpread, halationSensitivity, halationSaturation, bloomEnabled, bloomAmount, bloomSpread, bloomSensitivity, softnessEnabled, softnessAmount, rolloffEnabled, rolloffAmount, sharpnessAmount, vignetteAmount, seed
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
        grainEnabled = try values.decodeIfPresent(Bool.self, forKey: .grainEnabled) ?? false
        grainAmount = try values.decodeIfPresent(Double.self, forKey: .grainAmount) ?? 0.25
        grainSize = try values.decodeIfPresent(Double.self, forKey: .grainSize) ?? 1.0
        grainTexture = try values.decodeIfPresent(FilmGrainTexture.self, forKey: .grainTexture) ?? .fine35
        grainColor = try values.decodeIfPresent(Double.self, forKey: .grainColor) ?? 1
        halationEnabled = try values.decodeIfPresent(Bool.self, forKey: .halationEnabled) ?? false
        halationAmount = try values.decodeIfPresent(Double.self, forKey: .halationAmount) ?? 0.2
        halationSpread = try values.decodeIfPresent(Double.self, forKey: .halationSpread) ?? 0.35
        halationSensitivity = try values.decodeIfPresent(Double.self, forKey: .halationSensitivity) ?? 0.25
        halationSaturation = try values.decodeIfPresent(Double.self, forKey: .halationSaturation) ?? 1
        bloomEnabled = try values.decodeIfPresent(Bool.self, forKey: .bloomEnabled) ?? false
        bloomAmount = try values.decodeIfPresent(Double.self, forKey: .bloomAmount) ?? 0.15
        bloomSpread = try values.decodeIfPresent(Double.self, forKey: .bloomSpread) ?? 0.35
        bloomSensitivity = try values.decodeIfPresent(Double.self, forKey: .bloomSensitivity) ?? 0.25
        softnessEnabled = try values.decodeIfPresent(Bool.self, forKey: .softnessEnabled) ?? false
        softnessAmount = try values.decodeIfPresent(Double.self, forKey: .softnessAmount) ?? 0.35
        rolloffEnabled = try values.decodeIfPresent(Bool.self, forKey: .rolloffEnabled) ?? false
        rolloffAmount = try values.decodeIfPresent(Double.self, forKey: .rolloffAmount) ?? 0.35
        sharpnessAmount = try values.decodeIfPresent(Double.self, forKey: .sharpnessAmount) ?? 0
        vignetteAmount = try values.decodeIfPresent(Double.self, forKey: .vignetteAmount) ?? 0
        seed = try values.decodeIfPresent(UInt32.self, forKey: .seed) ?? 104729
    }
    var isActive: Bool {
        sharpnessAmount > 0 || vignetteAmount > 0 || softnessEnabled && softnessAmount > 0 || rolloffEnabled && rolloffAmount > 0 || grainEnabled && grainAmount > 0 || halationEnabled && halationAmount > 0 || bloomEnabled && bloomAmount > 0
    }
    var summary: String {
        var values: [String] = []
        if sharpnessAmount > 0 { values.append("Sharpness") }
        if vignetteAmount > 0 { values.append("Vignette") }
        if softnessEnabled && softnessAmount > 0 { values.append("Softness") }
        if rolloffEnabled && rolloffAmount > 0 { values.append("Highlight Roll-Off") }
        if grainEnabled && grainAmount > 0 { values.append(grainTexture == .fine35 ? "Fine Grain" : "Coarse Grain") }
        if halationEnabled && halationAmount > 0 { values.append("Halation") }
        if bloomEnabled && bloomAmount > 0 { values.append("Bloom") }
        return values.isEmpty ? "Off" : values.joined(separator: " · ")
    }
    func validate() throws {
        let unit = [sharpnessAmount, vignetteAmount, softnessAmount, rolloffAmount, grainAmount, grainColor, halationAmount, halationSpread, halationSensitivity, halationSaturation, bloomAmount, bloomSpread, bloomSensitivity]
        guard version == 1, unit.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              grainSize.isFinite, (0.5...2).contains(grainSize) else {
            throw HomeMovieError.message("The movie’s Film Effects settings are invalid.")
        }
    }
    var cacheIdentity: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = (try? encoder.encode(self)) ?? Data()
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    // Presentation callbacks and dropped frames never advance grain. 30fps export cadence.
    static func frameSeed(time: CMTime, seed: UInt32) -> UInt32 {
        guard time.isNumeric, time.seconds.isFinite else { return seed }
        let frame = CMTimeConvertScale(time, timescale: 30, method: .roundTowardZero).value
        return seed &+ UInt32(truncatingIfNeeded: frame) &* 747796405
    }
}

// All new shaders are independently written. No GPL code or grain assets are bundled.
// Optical effects operate on the selected SDR rendition, linearized as Rec.709.
// This deliberately preserves the existing Cinema/Apple Standard input contract.
final class FilmEffectsRenderer {
    private static let kernels: Result<[String: CIColorKernel], Error> = Result {
        guard let url = Bundle.main.url(forResource: "FilmEffects", withExtension: "metallib") else {
            throw HomeMovieError.message("Film Effects could not load. Your original recordings are safe.")
        }
        let data = try Data(contentsOf: url)
        var result: [String: CIColorKernel] = [:]
        for name in ["filmLinear", "filmHighlights", "filmOptics", "filmSoftness", "filmRolloff", "filmGrain", "filmGrain16", "filmVignette", "filmDetail"] {
            result[name] = try CIColorKernel(functionName: name, fromMetalLibraryData: data)
        }
        return result
    }
    private func apply(_ name: String, extent: CGRect, arguments: [Any]) throws -> CIImage {
        guard let kernel = try Self.kernels.get()[name], let image = kernel.apply(extent: extent, arguments: arguments) else {
            throw HomeMovieError.message("Film Effects could not render this frame.")
        }
        return image
    }
    func render(_ source: CIImage, settings: FilmEffectsSettings, time: CMTime, contentBounds: CGRect? = nil) throws -> CIImage {
        try settings.validate()
        guard settings.isActive else { return source }
        let bounds = source.extent
        let content = contentBounds ?? bounds
        let scale = Double(max(1, min(content.width, content.height))) / 1080
        var image = source
        if settings.halationEnabled && settings.halationAmount > 0 || settings.bloomEnabled && settings.bloomAmount > 0 {
            let linear = try apply("filmLinear", extent: bounds, arguments: [source])
            let black = CIImage(color: .black).cropped(to: bounds)
            var bloom = black, bloomSource = black, red = black, orange = black, halationSource = black
            if settings.bloomEnabled && settings.bloomAmount > 0 {
                let threshold = 0.86 - 0.32 * settings.bloomSensitivity
                let highlight = try apply("filmHighlights", extent: bounds, arguments: [linear, threshold, 0])
                    .insertingIntermediate(cache: false)
                bloomSource = highlight
                let radius = (5 + 35 * settings.bloomSpread) * scale
                bloom = diffuse(highlight, radius: radius, extent: bounds, weights: [0.6, 0.3, 0.1])
            }
            if settings.halationEnabled && settings.halationAmount > 0 {
                let threshold = 0.88 - 0.28 * settings.halationSensitivity
                let highlight = try apply("filmHighlights", extent: bounds, arguments: [linear, threshold, 1])
                    .insertingIntermediate(cache: false)
                halationSource = highlight
                let radius = (2 + 14 * settings.halationSpread) * scale
                red = diffuse(highlight, radius: radius * 1.6, extent: bounds, weights: [0.75, 0.2, 0.05])
                orange = diffuse(highlight, radius: radius * 0.65, extent: bounds, weights: [0.8, 0.15, 0.05])
            }
            image = try apply("filmOptics", extent: bounds, arguments: [linear, bloom, bloomSource, red, orange, halationSource,
                settings.bloomEnabled ? settings.bloomAmount : 0,
                settings.halationEnabled ? settings.halationAmount : 0, settings.halationSaturation])
        }
        // Diffusion reduces fine-detail contrast rather than laying a blur over everything.
        // Work in linear light, after optical scattering, and before final grain.
        if settings.softnessEnabled && settings.softnessAmount > 0 {
            let linear = try apply("filmLinear", extent: bounds, arguments: [image])
            let radius = (0.7 + 1.8 * settings.softnessAmount) * scale
            let soft = linear.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: ["inputRadius": radius]).cropped(to: bounds)
            image = try apply("filmSoftness", extent: bounds, arguments: [linear, soft, settings.softnessAmount])
        }
        if settings.rolloffEnabled && settings.rolloffAmount > 0 {
            image = try apply("filmRolloff", extent: bounds, arguments: [image, settings.rolloffAmount])
        }
        if settings.sharpnessAmount > 0 {
            let sharp = image.clampedToExtent().applyingFilter("CISharpenLuminance", parameters: [
                "inputSharpness": settings.sharpnessAmount * 1.2]).cropped(to: bounds)
            image = try apply("filmDetail", extent: bounds, arguments: [image, sharp])
        }
        if settings.vignetteAmount > 0 {
            image = try apply("filmVignette", extent: bounds, arguments: [image, settings.vignetteAmount, CIVector(cgRect: content)])
        }
        if settings.grainEnabled && settings.grainAmount > 0 {
            let seed = FilmEffectsSettings.frameSeed(time: time, seed: settings.seed)
            let size = settings.grainSize * settings.grainTexture.referenceSize * scale
            // One small shared neighborhood pass measures detail without softening
            // the image or changing the grain's timeline-dependent random fields.
            let local = image.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [
                "inputRadius": max(0.5, size * 0.8)]).cropped(to: bounds)
            image = try apply(settings.grainTexture == .coarse16 ? "filmGrain16" : "filmGrain", extent: bounds, arguments: [image, local,
                settings.grainAmount, size, settings.grainColor,
                Float(seed & 65535), Float(seed >> 16), CIVector(cgRect: content)])
        }
        return image.cropped(to: bounds)
    }
    private func diffuse(_ source: CIImage, radius: Double, extent: CGRect, weights: [Double]) -> CIImage {
        // Reduced-resolution diffusion retains a full-resolution sharp base and grain.
        let reduction: CGFloat = radius > 8 ? 0.25 : 0.5
        // Highlight extraction has an explicit intermediate before reduction:
        // nonlinear thresholding must run on native pixels, before averaging.
        // Respect the compositor's cacheIntermediates=false across frames.
        // Request antialiased downsampling explicitly: Core Image's default is
        // platform-dependent. Tiny lamps must not blink as they cross the
        // reduced-resolution sampling grid on iPhone.
        let reduced = source.transformed(by: CGAffineTransform(scaleX: reduction, y: reduction), highQualityDownsample: true)
        let small = reduced.extent
        var result = CIImage(color: .black).cropped(to: small)
        for (index, weight) in weights.enumerated() {
            let layer = reduced.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: ["inputRadius": radius * Double(reduction) * pow(2, Double(index))])
                .cropped(to: small).applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: weight, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: weight, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: weight, w: 0)])
            result = layer.applyingFilter("CIAdditionCompositing", parameters: ["inputBackgroundImage": result])
        }
        return result.transformed(by: CGAffineTransform(scaleX: 1 / reduction, y: 1 / reduction)).cropped(to: extent)
    }
}
