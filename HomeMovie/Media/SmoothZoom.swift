import Foundation

enum SmoothZoomSpeed: String, CaseIterable, Identifiable, Sendable {
    case slow, normal, fast
    var id: Self { self }
    var label: String { rawValue.capitalized }
    var responseTime: Double { switch self { case .slow: 0.55; case .normal: 0.4; case .fast: 0.28 } }
    var responseDescription: String {
        switch self {
        case .slow: "Gentler response to your drag."
        case .normal: "Balanced response to your drag."
        case .fast: "Quicker response to your drag."
        }
    }
    // Perceived motion speed in log2 zoom units per second, independent of direction.
    var rate: Float { switch self { case .slow: 0.35; case .normal: 0.75; case .fast: 1.5 } }
}
enum DollyZoomDuration {
    static let choices = [1, 2, 3, 5, 8, 10, 15, 20, 25, 30]
    static func validated(_ seconds: Int) -> Int { choices.contains(seconds) ? seconds : 3 }
}
// Presentation follows measured zoom, never a separate timer or pretend animation.
struct DollyZoomRoute: Equatable {
    let id = UUID()
    let start: Double
    private(set) var destination: Double
    let seconds: Int
    init?(start: Double, destination: Double, seconds: Int) {
        guard start.isFinite, destination.isFinite, start > 0, destination > 0,
              abs(log2(destination / start)) > 0.00001 else { return nil }
        self.start = start; self.destination = destination
        self.seconds = DollyZoomDuration.validated(seconds)
    }
    func adjustingDestination(to zoom: Double) -> Self {
        guard zoom.isFinite, zoom > 0 else { return self }
        var adjusted = self
        adjusted.destination = zoom
        return adjusted
    }
    func progress(at zoom: Double) -> Double {
        guard zoom.isFinite, zoom > 0 else { return 0 }
        let distance = log2(destination / start)
        guard abs(distance) > 0.00001 else { return hasArrived(at: zoom) ? 1 : 0 }
        return min(1, max(0, log2(zoom / start) / distance))
    }
    func hasArrived(at zoom: Double) -> Bool {
        zoom.isFinite && zoom > 0 && abs(log2(zoom / destination)) < 0.005
    }
}
struct SmoothZoomFilter: Sendable {
    private(set) var value: Double
    private(set) var target: Double
    private(set) var requestedTarget: Double
    private(set) var velocity = 0.0
    private var acceleration = 0.0
    private var timedCurve: [Double]?
    private var timedBridge: [Double]?
    private var timedBridgeDuration = 0.0
    private var timedDuration = 0.0
    private var timedElapsed = 0.0
    var isTimed: Bool { timedCurve != nil }
    var remainingDuration: Double? { isTimed ? max(0, timedDuration - timedElapsed) : nil }
    var isSettled: Bool {
        if isTimed { return timedElapsed >= timedDuration - 0.000001 }
        return abs(log2(value / target)) < 0.00001 && abs(velocity) < 0.00005
    }
    private(set) var minimum: Double
    private(set) var maximum: Double
    init?(current: Double, minimum: Double, maximum: Double) {
        guard current.isFinite, minimum.isFinite, maximum.isFinite, minimum > 0, maximum > minimum else { return nil }
        self.minimum = minimum; self.maximum = maximum
        value = min(maximum, max(minimum, current)); target = value; requestedTarget = value
    }
    mutating func setTarget(_ target: Double, duration: Double? = nil) {
        guard target.isFinite, target > 0 else { return }
        requestedTarget = target
        let next = min(maximum, max(minimum, target))
        self.target = next
        if let duration, duration.isFinite, duration > 0 {
            let start = log2(value), distance = log2(next) - start
            timedBridge = nil; timedBridgeDuration = 0
            var mainStart = start, mainVelocity = velocity
            if abs(velocity) > 0.00005 || abs(acceleration) > 0.0001 {
                // Blend incoming momentum briefly, rather than stretching it over a long
                // newly selected duration and overshooting a nearby lens by several stops.
                let blend = min(duration * 0.25, max(1.0 / 120, min(0.25,
                    abs(distance) / max(0.001, abs(velocity) + 1.5 * abs(distance) / duration))))
                let proposedVelocity = distance / duration * 1.5
                mainStart = min(log2(maximum), max(log2(minimum),
                    start + (velocity + proposedVelocity) * blend / 2 + acceleration * blend * blend / 12))
                let remaining = duration - blend, remainingDistance = log2(next) - mainStart
                mainVelocity = (remainingDistance < 0 ? -1 : 1) * min(abs(proposedVelocity), 1.5 * abs(remainingDistance) / remaining)
                timedBridge = Self.curve(start: start, end: mainStart, velocity: velocity,
                    endVelocity: mainVelocity, acceleration: acceleration, duration: blend)
                timedBridgeDuration = blend
            }
            timedCurve = Self.curve(start: mainStart, end: log2(next), velocity: mainVelocity,
                endVelocity: 0, acceleration: timedBridge == nil ? acceleration : 0, duration: duration - timedBridgeDuration)
            timedDuration = duration; timedElapsed = 0
        } else { timedCurve = nil; timedBridge = nil }
    }
    mutating func adjustTimedDestination(to target: Double) {
        guard let remaining = remainingDuration, remaining > 0 else { return }
        setTarget(target, duration: remaining)
    }
    private static func curve(start: Double, end: Double, velocity: Double, endVelocity: Double,
                              acceleration: Double, duration: Double) -> [Double] {
        let distance = end - start, v = velocity * duration, final = endVelocity * duration
        let a = acceleration * duration * duration / 2
        return [start, v, a, 10 * distance - 6 * v - 4 * final - 3 * a,
            -15 * distance + 8 * v + 7 * final + 3 * a, 6 * distance - 3 * v - 3 * final - a]
    }
    mutating func reconfigure(current: Double, minimum: Double, maximum: Double) -> Bool {
        guard current.isFinite, minimum.isFinite, maximum.isFinite, minimum > 0, maximum > minimum else { return false }
        let remaining = remainingDuration, destination = requestedTarget
        self.minimum = minimum; self.maximum = maximum
        value = min(maximum, max(minimum, current))
        if value == minimum && velocity < 0 || value == maximum && velocity > 0 { velocity = 0; acceleration = 0 }
        setTarget(destination, duration: remaining)
        return true
    }
    mutating func finishMotion() {
        // A short timed finish continues in the incoming direction instead of
        // springing back to the exact position where the control was closed.
        let duration = 0.2
        let destination = exp2(log2(value) + velocity * duration * 0.5)
        setTarget(destination, duration: duration)
    }
    mutating func advance(seconds: Double, rate: Float, response: Double = 0.4) -> Double {
        guard seconds.isFinite, seconds > 0, rate.isFinite, rate > 0, response.isFinite, response > 0 else { return value }
        if let main = timedCurve {
            timedElapsed = min(timedDuration, timedElapsed + seconds)
            let blending = timedElapsed < timedBridgeDuration && timedBridge != nil
            let c = blending ? timedBridge! : main
            let segmentDuration = blending ? timedBridgeDuration : timedDuration - timedBridgeDuration
            let t = (blending ? timedElapsed : timedElapsed - timedBridgeDuration) / segmentDuration
            let position = c[0] + t * (c[1] + t * (c[2] + t * (c[3] + t * (c[4] + t * c[5]))))
            velocity = (c[1] + t * (2 * c[2] + t * (3 * c[3] + t * (4 * c[4] + t * 5 * c[5])))) / segmentDuration
            acceleration = (2 * c[2] + t * (6 * c[3] + t * (12 * c[4] + t * 20 * c[5]))) / (segmentDuration * segmentDuration)
            value = min(maximum, max(minimum, exp2(position)))
            if value == minimum && velocity < 0 || value == maximum && velocity > 0 { velocity = 0; acceleration = 0 }
            if timedElapsed >= timedDuration { value = target; velocity = 0; acceleration = 0 }
            return value
        }
        // A critically damped spring preserves velocity on drag reversal and speed changes.
        // Small analytic substeps keep behavior consistent across timer/gesture cadences.
        let elapsed = min(seconds, 0.1), count = max(1, Int(ceil(elapsed * 120)))
        let dt = elapsed / Double(count), omega = 2 / response, decay = exp(-omega * dt)
        for _ in 0..<count {
            let current = log2(value), wanted = log2(target)
            let displacement = min(Double(rate) * response, max(-Double(rate) * response, current - wanted))
            let effectiveTarget = current - displacement
            let temporary = (velocity + omega * displacement) * dt
            let next = effectiveTarget + (displacement + temporary) * decay
            let previousVelocity = velocity
            velocity = (velocity - omega * temporary) * decay
            acceleration = (velocity - previousVelocity) / dt
            value = min(maximum, max(minimum, exp2(next)))
            if value == minimum && velocity < 0 || value == maximum && velocity > 0 { velocity = 0; acceleration = 0 }
        }
        if isSettled { value = target; velocity = 0; acceleration = 0 }
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

struct SmoothZoomClock: Sendable {
    private var lastTick: Double?
    mutating func reset(at time: Double? = nil) { lastTick = time?.isFinite == true ? time : nil }
    mutating func step(at time: Double) -> Double {
        guard time.isFinite else { return 0 }
        guard let previous = lastTick else { lastTick = time; return 0 }
        guard time > previous else { return 0 }
        lastTick = time
        // A busy capture queue must pause the curve rather than catch up in one visible jump.
        return min(1.0 / 30, time - previous)
    }
}

struct SmoothZoomInput: Sendable {
    private var lastFactor: Double?
    private var lastTime: Double?
    private var motionRate = 0.0
    func rate(baseline: Float) -> Float { max(baseline, Float(motionRate)) }
    mutating func reset() { lastFactor = nil; lastTime = nil; motionRate = 0 }
    mutating func end() { lastFactor = nil; lastTime = nil }
    mutating func observe(factor: Double, at time: Double) {
        guard factor.isFinite, factor > 0, time.isFinite else { return }
        guard let previousFactor = lastFactor, let previousTime = lastTime else {
            lastFactor = factor; lastTime = time; motionRate = 0; return
        }
        let elapsed = time - previousTime
        guard elapsed > 0 else { return }
        lastFactor = factor; lastTime = time
        guard elapsed <= 0.25 else { motionRate = 0; return }
        // Measure hand speed in perceived zoom units. Headroom avoids lagging a fast drag;
        // a short low-pass filter removes gesture-timestamp noise without a speed snap.
        let measured = min(8, abs(log2(factor / previousFactor)) / max(1.0 / 240, elapsed) * 1.4)
        let response = 1 - exp(-elapsed / 0.06)
        motionRate += (measured - motionRate) * response
    }
}
