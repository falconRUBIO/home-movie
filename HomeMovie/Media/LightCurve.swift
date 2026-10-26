import Foundation
import CoreImage

// Shape-preserving cubic interpolation for freely positioned control points.
// Legacy levels remain decodable so existing edits retain their original curve.
struct LightCurve: Codable, Equatable, Sendable {
    static let neutral = LightCurve()
    var shadows = 0.25
    var midtones = 0.5
    var highlights = 0.75
    struct Point: Codable, Equatable, Sendable {
        var x: Double
        var y: Double
    }
    static let maximumPoints = 16
    var points: [Point]? = nil
    var controlPoints: [Point] {
        if let points { return points }
        if shadows == 0.25 && midtones == 0.5 && highlights == 0.75 {
            return [Point(x: 0, y: 0), Point(x: 1, y: 1)]
        }
        return levels.enumerated().map { Point(x: Double($0.offset) / 4, y: $0.element) }
    }
    var isActive: Bool {
        let p = controlPoints
        return p.first != Point(x: 0, y: 0) || p.last != Point(x: 1, y: 1) || p.contains { $0.x != $0.y }
    }
    @discardableResult mutating func add(at x: Double, y: Double) -> Int? {
        var p = controlPoints
        guard x.isFinite, y.isFinite, p.count < Self.maximumPoints,
              x > p[0].x, x < p[p.count - 1].x,
              p.allSatisfy({ abs($0.x - x) >= 0.02 }) else { return nil }
        let index = p.firstIndex(where: { $0.x > x })!
        p.insert(Point(x: x, y: min(1, max(0, y))), at: index)
        points = p; return index
    }
    mutating func movePoint(_ index: Int, x: Double, y: Double) {
        var p = controlPoints
        guard p.indices.contains(index), x.isFinite, y.isFinite else { return }
        let lower = index == 0 ? 0 : p[index - 1].x + 0.001
        let upper = index == p.count - 1 ? 1 : p[index + 1].x - 0.001
        p[index] = Point(x: min(upper, max(lower, x)), y: min(1, max(0, y)))
        points = p
    }
    mutating func removePoint(_ index: Int) {
        var p = controlPoints
        guard index > 0, index < p.count - 1 else { return }
        p.remove(at: index); points = p
    }
    private var pointSlopes: [Double] {
        let p = controlPoints, n = p.count
        let h = (0..<(n - 1)).map { p[$0 + 1].x - p[$0].x }
        let d = (0..<(n - 1)).map { (p[$0 + 1].y - p[$0].y) / h[$0] }
        if n == 2 { return [d[0], d[0]] }
        func endpoint(_ h0: Double, _ h1: Double, _ d0: Double, _ d1: Double) -> Double {
            let m = ((2 * h0 + h1) * d0 - h0 * d1) / (h0 + h1)
            if m * d0 <= 0 { return 0 }
            return abs(m) > abs(3 * d0) ? 3 * d0 : m
        }
        var m = Array(repeating: 0.0, count: n)
        m[0] = endpoint(h[0], h[1], d[0], d[1])
        m[n - 1] = endpoint(h[n - 2], h[n - 3], d[n - 2], d[n - 3])
        for i in 1..<(n - 1) where d[i - 1] * d[i] > 0 {
            let w1 = 2 * h[i] + h[i - 1], w2 = h[i] + 2 * h[i - 1]
            m[i] = (w1 + w2) / (w1 / d[i - 1] + w2 / d[i])
        }
        return m
    }
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
        let p = controlPoints
        let legacyValid = points != nil || (levels.allSatisfy(\.isFinite) && zip(levels, levels.dropFirst()).allSatisfy { $0.0 < $0.1 })
        guard legacyValid, (2...Self.maximumPoints).contains(p.count),
              p.allSatisfy({ $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y) }),
              zip(p, p.dropFirst()).allSatisfy({ $0.1.x - $0.0.x >= 0.0005 }) else {
            throw HomeMovieError.message("This clip’s tonal curve is invalid.")
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
        let p = controlPoints, m = pointSlopes
        let x = min(1, max(0, input))
        if x <= p[0].x { return p[0].y }
        if x >= p[p.count - 1].x { return p[p.count - 1].y }
        let i = (0..<(p.count - 1)).first { x <= p[$0 + 1].x }!
        let h = p[i + 1].x - p[i].x, t = (x - p[i].x) / h
        let t2 = t * t, t3 = t2 * t
        return min(1, max(0, (2 * t3 - 3 * t2 + 1) * p[i].y + (t3 - 2 * t2 + t) * m[i] * h
            + (-2 * t3 + 3 * t2) * p[i + 1].y + (t3 - t2) * m[i + 1] * h))
    }

    func apply(to image: CIImage, fade: Double) throws -> CIImage {
        try validate()
        guard fade.isFinite, (0...1).contains(fade) else {
            throw HomeMovieError.message("This clip’s fade adjustment is invalid.")
        }
        guard isActive || fade != 0 else { return image }
        let p = controlPoints, m = pointSlopes
        var arguments: [Any] = [image]
        for i in 0..<Self.maximumPoints {
            let j = min(i, p.count - 1)
            arguments.append(CIVector(x: CGFloat(p[j].x), y: CGFloat(p[j].y), z: CGFloat(m[j]), w: 0))
        }
        arguments.append(Double(p.count)); arguments.append(fade)
        let kernel = try Self.kernel.get()
        guard let result = kernel.apply(extent: image.extent, arguments: arguments) else {
            throw HomeMovieError.message("This clip’s tonal curve could not be rendered.")
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
