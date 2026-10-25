import Foundation

struct SceneEditState: Equatable {
    var start: Double
    var end: Double
    var adjustments: SceneAdjustments
    var effects: FilmEffectsSettings
    var clipEffects: FilmEffectsTweaks? = nil
}

// Session-local history. A drag is one transaction, not hundreds of frames.
struct SceneEditHistory {
    private(set) var current: SceneEditState
    private var backwards: [SceneEditState] = []
    private var forwards: [SceneEditState] = []
    private var groupStart: SceneEditState?
    private let limit: Int
    init(_ state: SceneEditState, limit: Int = 50) { current = state; self.limit = max(1, limit) }
    var isGrouping: Bool { groupStart != nil }
    var canUndo: Bool { !isGrouping && !backwards.isEmpty }
    var canRedo: Bool { !isGrouping && !forwards.isEmpty }
    mutating func observe(_ state: SceneEditState) {
        guard state != current else { return }
        if !isGrouping { push(current); forwards.removeAll() }
        current = state
    }
    mutating func begin(_ state: SceneEditState) {
        guard !isGrouping else { return }
        observe(state); groupStart = current
    }
    mutating func end(_ state: SceneEditState) {
        guard let before = groupStart else { observe(state); return }
        observe(state); groupStart = nil
        if before != current { push(before); forwards.removeAll() }
    }
    mutating func undo() -> SceneEditState? {
        guard canUndo, let previous = backwards.popLast() else { return nil }
        forwards.append(current); current = previous; return previous
    }
    mutating func redo() -> SceneEditState? {
        guard canRedo, let next = forwards.popLast() else { return nil }
        push(current); current = next; return next
    }
    private mutating func push(_ state: SceneEditState) {
        backwards.append(state)
        if backwards.count > limit { backwards.removeFirst(backwards.count - limit) }
    }
}

struct SceneAdjustmentSelection: OptionSet, Sendable {
    let rawValue: Int
    static let light = Self(rawValue: 1 << 0)
    static let color = Self(rawValue: 1 << 1)
    static let hsl = Self(rawValue: 1 << 2)
    static let exposure = Self(rawValue: 1 << 3)
    static let whiteBalance = Self(rawValue: 1 << 4)
    static let suggested: Self = [.light, .color, .hsl]
}

// An app-local clipboard intentionally cannot carry FX, trim, LUTs or media.
struct SceneAdjustmentClipboard {
    let source: SceneAdjustments
    let selection: SceneAdjustmentSelection
    init(source: SceneAdjustments, selection: SceneAdjustmentSelection) throws {
        try source.validate()
        guard !selection.isEmpty else { throw HomeMovieError.message("Choose adjustments to copy.") }
        self.source = source; self.selection = selection
    }
    func applying(to target: SceneAdjustments) throws -> SceneAdjustments {
        try target.validate()
        guard source.pipelineVersion == target.pipelineVersion || !target.isActive else {
            throw HomeMovieError.message("Reset this scene’s adjustments before pasting edits from a different processing version.")
        }
        var result = target
        if !target.isActive { result.pipelineVersion = source.pipelineVersion }
        if selection.contains(.light) {
            result.shadows = source.shadows; result.highlights = source.highlights
            result.brilliance = source.brilliance; result.brightness = source.brightness
            result.contrast = source.contrast; result.blackPoint = source.blackPoint
            result.whitePoint = source.whitePoint; result.pushPull = source.pushPull
            result.fade = source.fade; result.curve = source.curve
        }
        if selection.contains(.color) { result.saturation = source.saturation; result.vibrance = source.vibrance }
        if selection.contains(.hsl) { result.hsl = source.hsl }
        if selection.contains(.exposure) { result.exposure = source.exposure }
        if selection.contains(.whiteBalance) { result.warmth = source.warmth; result.tint = source.tint }
        try result.validate()
        return result
    }
}

// Choose the next clip in movie order, falling back to the previous clip.
enum SceneEditorSelection {
    static func afterDeleting(_ id: UUID, from ids: [UUID]) -> UUID? {
        guard let index = ids.firstIndex(of: id) else { return ids.first }
        if index + 1 < ids.count { return ids[index + 1] }
        return index > 0 ? ids[index - 1] : nil
    }
}
