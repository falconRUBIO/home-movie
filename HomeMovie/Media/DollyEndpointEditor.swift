import Foundation

enum DollyEndpoint: String, CaseIterable, Identifiable {
    case start, end
    var id: Self { self }
    var title: String { self == .start ? "Start" : "End" }
}

/// Selection never moves the camera. Only an explicit edit to Start requests a preview.
struct DollyEndpointEditor {
    var start: Double?
    var end: Double?
    var selected: DollyEndpoint = .end

    mutating func selectNearest(position: Double, startPosition: Double, endPosition: Double) {
        guard position.isFinite, startPosition.isFinite, endPosition.isFinite else { return }
        let a = abs(position - startPosition), b = abs(position - endPosition)
        if abs(a - b) > 0.000001 { selected = a < b ? .start : .end }
        // Overlapping/equidistant markers keep the explicitly selected endpoint.
    }
    @discardableResult mutating func edit(_ factor: Double, endpoint: DollyEndpoint,
                                           minimum: Double, maximum: Double) -> Double? {
        guard factor.isFinite, factor > 0, minimum.isFinite, maximum.isFinite,
              minimum > 0, maximum >= minimum else { return nil }
        selected = endpoint
        let value = min(maximum, max(minimum, factor))
        if endpoint == .start { start = value; return value }
        end = value
        return nil
    }
}
