import Foundation
import CoreImage

// Five fixed input anchors, with three movable output levels. Monotone cubic
// interpolation avoids reversals, overshoot and abrupt contrast joins.
struct LightCurve: Codable, Equatable, Sendable {
    static let neutral = LightCurve()
    var shadows = 0.25
    var midtones = 0.5
    var highlights = 0.75
    var isActive: Bool { self != .neutral }
    var levels: [Double] { [0, shadows, midtones, highlights, 1] }
    var slopes: [Double] {
        let y = levels
        let d = (0..<4).map { (y[$0 + 1] - y[$0]) * 4 }
        return [max(0, min(3 * d[0], (3 * d[0] - d[1]) / 2)),
            2 * d[0] * d[1] / (d[0] + d[1]),
            2 * d[1] * d[2] / (d[1] + d[2]),
            2 * d[2] * d[3] / (d[2] + d[3]),
            max(0, min(3 * d[3], (3 * d[3] - d[2]) / 2))]
    }
    func validate() throws {
        let y = levels
        guard y.allSatisfy(\.isFinite), zip(y, y.dropFirst()).allSatisfy({ $0.0 < $0.1 }) else {
            throw HomeMovieError.message("This scene’s tonal curve is invalid.")
        }
    }
    mutating func move(_ index: Int, to value: Double) {
        guard (1...3).contains(index), value.isFinite else { return }
        let y = levels
        let next = min(y[index + 1] - 0.02, max(y[index - 1] + 0.02, value))
        switch index {
        case 1: shadows = next
        case 2: midtones = next
        default: highlights = next
        }
    }
    func output(at input: Double) -> Double {
        let x = min(1, max(0, input)), y = levels, m = slopes
        let i = min(3, Int(x * 4)), t = x * 4 - Double(i)
        let t2 = t * t, t3 = t2 * t
        return (2 * t3 - 3 * t2 + 1) * y[i] + (t3 - 2 * t2 + t) * m[i] / 4
            + (-2 * t3 + 3 * t2) * y[i + 1] + (t3 - t2) * m[i + 1] / 4
    }
    func apply(to image: CIImage, fade: Double) throws -> CIImage {
        try validate()
        guard fade.isFinite, (0...1).contains(fade) else {
            throw HomeMovieError.message("This scene’s fade adjustment is invalid.")
        }
        guard isActive || fade != 0 else { return image }
        let y = levels, m = slopes
        let kernel = try Self.kernel.get()
        guard let result = kernel.apply(extent: image.extent, arguments: [image,
            CIVector(x: CGFloat(y[0]), y: CGFloat(y[1]), z: CGFloat(y[2]), w: CGFloat(y[3])),
            CIVector(x: CGFloat(m[0]), y: CGFloat(m[1]), z: CGFloat(m[2]), w: CGFloat(m[3])), m[4], fade]) else {
            throw HomeMovieError.message("This scene’s tonal curve could not be rendered.")
        }
        return result
    }
    private static let kernel: Result<CIColorKernel, Error> = Result {
        guard let url = Bundle.main.url(forResource: "FilmEffects", withExtension: "metallib") else {
            throw HomeMovieError.message("Light adjustments could not load.")
        }
        return try CIColorKernel(functionName: "sceneTone", fromMetalLibraryData: Data(contentsOf: url))
    }
}
