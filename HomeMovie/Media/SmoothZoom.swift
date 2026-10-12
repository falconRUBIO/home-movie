import Foundation

enum SmoothZoomSpeed: String, CaseIterable, Identifiable, Sendable {
    case slow, normal, fast
    var id: Self { self }
    var label: String { rawValue.capitalized }
    // AVFoundation ramp rates are octaves per second, independent of direction.
    var rate: Float { switch self { case .slow: 0.35; case .normal: 0.75; case .fast: 1.5 } }
}
struct SmoothZoomFilter: Sendable {
    private(set) var value: Double
    private(set) var target: Double
    let minimum: Double
    let maximum: Double
    init?(current: Double, minimum: Double, maximum: Double) {
        guard current.isFinite, minimum.isFinite, maximum.isFinite, minimum > 0, maximum > minimum else { return nil }
        self.minimum = minimum; self.maximum = maximum
        value = min(maximum, max(minimum, current)); target = value
    }
    mutating func setTarget(_ target: Double) {
        guard target.isFinite, target > 0 else { return }
        self.target = min(maximum, max(minimum, target))
    }
    mutating func advance(seconds: Double, rate: Float) -> Double {
        guard seconds.isFinite, seconds > 0, rate.isFinite, rate > 0 else { return value }
        let dt = min(seconds, 0.1)
        let current = log2(value), wanted = log2(target)
        let filtered = (wanted - current) * (1 - exp(-dt / 0.12))
        let limit = Double(rate) * dt
        let change = min(limit, max(-limit, filtered))
        value = min(maximum, max(minimum, exp2(current + change)))
        if abs(log2(value) - log2(target)) < 0.0001 { value = target }
        return value
    }
    static func position(_ factor: Double, minimum: Double, maximum: Double) -> Double {
        guard factor.isFinite, minimum > 0, maximum.isFinite, maximum > minimum else { return 0 }
        return min(1, max(0, (log2(max(minimum, factor)) - log2(minimum)) / (log2(maximum) - log2(minimum))))
    }
    static func factor(_ position: Double, minimum: Double, maximum: Double) -> Double {
        guard position.isFinite, minimum.isFinite, minimum > 0, maximum.isFinite, maximum > minimum else { return minimum.isFinite && minimum > 0 ? minimum : 1 }
        return min(maximum, max(minimum, exp2(log2(minimum) + (log2(maximum) - log2(minimum)) * min(1, max(0, position)))))
    }
}
