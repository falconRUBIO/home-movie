import Foundation
import CoreMedia

struct MediaTime: Codable, Equatable, Sendable {
    var value: Int64
    var scale: Int32
    init(_ time: CMTime) { value = time.value; scale = time.timescale }
    init(seconds: Double) { self.init(CMTime(seconds: seconds, preferredTimescale: 600)) }
    var cmTime: CMTime { CMTime(value: value, timescale: scale) }
    var seconds: Double { CMTimeGetSeconds(cmTime) }
    var isValid: Bool { scale > 0 && seconds.isFinite && seconds >= 0 }
}

enum MovieFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case landscape, portrait
    var id: Self { self }
    var label: String { rawValue.capitalized }
    var aspect: CGFloat { self == .landscape ? 16 / 9 : 9 / 16 }
    func recordingAngle(observed: CGFloat) -> CGFloat {
        guard observed.isFinite else { return self == .portrait ? 90 : 0 }
        let normalized = (observed.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        let candidates: [CGFloat] = self == .portrait ? [90, 270] : [0, 180]
        func distance(_ value: CGFloat) -> CGFloat { min(abs(normalized - value), 360 - abs(normalized - value)) }
        return candidates.min { distance($0) < distance($1) } ?? candidates[0]
    }
    var canvas: CGSize { self == .landscape ? CGSize(width: 1920, height: 1080) : CGSize(width: 1080, height: 1920) }
    static func captureFormat(angle: CGFloat) -> MovieFormat? {
        guard angle.isFinite else { return nil }
        let quarterTurns = (angle.truncatingRemainder(dividingBy: 360) / 90).rounded()
        return abs(quarterTurns.truncatingRemainder(dividingBy: 2)) == 1 ? .portrait : .landscape
    }
}

enum CaptureProfile: String, Codable, Sendable { case standard, appleLog }

struct Scene: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var sequence: Int
    var source: String
    var capturedAt: Date
    var timeZone: String
    var sourceDuration: MediaTime
    var trimStart: MediaTime
    var trimEnd: MediaTime
    var width: Double
    var height: Double
    var hasAudio: Bool
    var bytes: Int64
    var deletedAt: Date?
    var photosAssetID: String?
    var photosCopiedAt: Date?
    var missing = false
    var profile: CaptureProfile? = nil
    var playableDuration: CMTime { CMTimeSubtract(trimEnd.cmTime, trimStart.cmTime) }
    var validTrim: Bool {
        trimStart.isValid && trimEnd.isValid && sourceDuration.isValid &&
        CMTimeCompare(trimEnd.cmTime, trimStart.cmTime) > 0 &&
        CMTimeCompare(trimEnd.cmTime, sourceDuration.cmTime) <= 0
    }
}

struct Movie: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var format: MovieFormat
    var createdAt = Date()
    var lastRecordedAt: Date?
    var revision = 0
    var deletedAt: Date?
    var lastFilesBackupRevision: Int?
    var lastFilesBackupAt: Date?
    var scenes: [Scene] = []
    var profile: CaptureProfile? = nil
    var look: LUTReference? = nil
    var filmEffects: FilmEffectsSettings? = nil
    var pipLayout: PiPLayout? = nil
    var dualCameraCapture: Bool? = nil
    var preferredPiPLayout: PiPLayout { pipLayout ?? PiPLayout() }
    var exportEffects: FilmEffectsSettings { filmEffects ?? .off }
    var captureProfile: CaptureProfile { profile ?? .standard }
    var lookName: String { look?.displayName ?? "Apple Standard" }
    // Deleted scenes still lock the movie; removing a scene never changes its canvas.
    var recordingFormat: MovieFormat? { scenes.isEmpty && lastRecordedAt == nil ? nil : format }
    var activeScenes: [Scene] { scenes.filter { $0.deletedAt == nil }.sorted { $0.sequence < $1.sequence } }
    var duration: CMTime { activeScenes.reduce(.zero) { CMTimeAdd($0, $1.playableDuration) } }
    var nextSequence: Int { (scenes.map(\.sequence).max() ?? -1) + 1 }
}

struct Catalog: Codable, Sendable {
    var schemaVersion = 1
    var movies: [Movie] = []
}

struct CaptureTicket: Codable, Sendable {
    var sceneID = UUID()
    var movieID: UUID
    var sequence: Int
    var capturedAt = Date()
    var timeZone = TimeZone.current.identifier
    var format: MovieFormat? = nil
    var profile: CaptureProfile? = nil
    var staging: String { "Staging/\(sceneID.uuidString).mov" }
    var source: String { "Originals/\(sceneID.uuidString).mov" }
    var journal: String { "Journal/\(sceneID.uuidString).json" }
}

enum HomeMovieError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}

func durationLabel(_ time: CMTime) -> String {
    let seconds = CMTimeGetSeconds(time)
    guard seconds.isFinite else { return "0:00" }
    guard seconds > 0 else { return "0:00" }
    // Double(Int.max) rounds upward on 64-bit platforms; do not convert that value.
    let s = seconds >= Double(Int.max) ? Int.max : Int(seconds)
    return s >= 3600 ? "\(s / 3600):" + String(format: "%02d:%02d", s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}

