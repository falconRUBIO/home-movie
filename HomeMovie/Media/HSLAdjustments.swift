import Foundation
import CoreImage

// Fixed, named bands keep saved recipes stable across releases.
enum HSLBand: Int, CaseIterable, Identifiable {
    case red, orange, yellow, green, aqua, blue, purple, magenta
    var id: Int { rawValue }
    var name: String { ["Red", "Orange", "Yellow", "Green", "Aqua", "Blue", "Purple", "Magenta"][rawValue] }
    var degrees: Double { [0, 30, 60, 120, 180, 240, 270, 300][rawValue] }
}
struct HSLValues: Codable, Equatable, Sendable {
    var hue = 0.0
    var saturation = 0.0
    var lightness = 0.0
    var isActive: Bool { hue != 0 || saturation != 0 || lightness != 0 }
}
struct HSLAdjustments: Codable, Equatable, Sendable {
    private var bands = Array(repeating: HSLValues(), count: 8)
    subscript(_ band: HSLBand) -> HSLValues {
        get { bands[band.rawValue] }
        set { bands[band.rawValue] = newValue }
    }
    var isActive: Bool { bands.contains { $0.isActive } }
    func validate() throws {
        guard bands.count == 8, bands.allSatisfy({ value in
            [value.hue, value.saturation, value.lightness].allSatisfy { $0.isFinite && (-1...1).contains($0) }
        }) else { throw HomeMovieError.message("This clip’s HSL adjustments are invalid.") }
    }
    func apply(to image: CIImage) throws -> CIImage {
        try validate()
        guard isActive else { return image }
        let arguments: [Any] = [image] + HSLBand.allCases.map { band -> Any in
            let value = self[band]
            return CIVector(x: CGFloat(value.hue), y: CGFloat(value.saturation),
                z: CGFloat(value.lightness), w: CGFloat(band.degrees / 360))
        }
        let kernel = try Self.kernel.get()
        guard let output = kernel.apply(extent: image.extent, arguments: arguments) else {
            throw HomeMovieError.message("This clip’s HSL adjustments could not be rendered.")
        }
        return output
    }
    private static let kernel: Result<CIColorKernel, Error> = Result {
        guard let url = Bundle.main.url(forResource: "FilmEffects", withExtension: "metallib") else {
            throw HomeMovieError.message("HSL adjustments could not load.")
        }
        return try CIColorKernel(functionName: "sceneHSL", fromMetalLibraryData: Data(contentsOf: url))
    }
}
