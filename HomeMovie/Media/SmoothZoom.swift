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
    private var velocity = 0.0
    let minimum: Double
    let maximum: Double
    init?(current: Double, minimum: Double, maximum: Double) {
        guard current.isFinite, minimum.isFinite, maximum.isFinite, minimum > 0, maximum > minimum else { return nil }
        self.minimum = minimum; self.maximum = maximum
        value = min(maximum, max(minimum, current)); target = value
    }
    mutating func setTarget(_ target: Double) {
        guard target.isFinite, target > 0 else { return }
        let next = min(maximum, max(minimum, target))
        if (log2(next) - log2(value)) * velocity < 0 { velocity = 0 }
        self.target = next
    }
    mutating func advance(seconds: Double, rate: Float) -> Double {
        guard seconds.isFinite, seconds > 0, rate.isFinite, rate > 0 else { return value }
        let dt = min(seconds, 0.1)
        let current = log2(value), wanted = log2(target)
        let distance = wanted - current
        // Ease into motion over 0.35 seconds, then ease out near the destination.
        let desired = min(Double(rate), max(-Double(rate), distance / 0.25))
        let acceleration = Double(rate) / 0.35
        velocity += min(acceleration * dt, max(-acceleration * dt, desired - velocity))
        let change = min(abs(distance), abs(velocity) * dt) * (distance < 0 ? -1 : 1)
        value = min(maximum, max(minimum, exp2(current + change)))
        if abs(log2(value) - log2(target)) < 0.0001 { value = target; velocity = 0 }
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
