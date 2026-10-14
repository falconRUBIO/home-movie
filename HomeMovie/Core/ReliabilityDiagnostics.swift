import Foundation

// Local, bounded support events. Never record titles, paths, media or error userInfo.
final class ReliabilityDiagnostics: @unchecked Sendable {
    enum Event: String, Codable {
        case appLaunched, lowMemory, cameraRequested, cameraReady, cameraFailed, cameraInterrupted
        case recordingRequested, recordingStarted, recordingFinished, recordingFailed
        case exportRequested, exportFinished, exportFailed, exportCancelled
    }
    private struct Entry: Codable {
        let date: Date
        let event: Event
        let domain: String?
        let code: Int?
    }
    static let shared = ReliabilityDiagnostics()
    private let queue = DispatchQueue(label: "HomeMovie.diagnostics", qos: .utility)
    private let file: URL
    private let limit: Int
    private var entries: [Entry]?
    init(file: URL = URL.applicationSupportDirectory.appendingPathComponent("Reliability/events.json"), limit: Int = 128) {
        self.file = file; self.limit = max(1, min(256, limit))
    }
    private func load() -> [Entry] {
        if let entries { return entries }
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 131072,
              let data = try? Data(contentsOf: file), let decoded = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return Array(decoded.suffix(limit))
    }
    func record(_ event: Event, error: Error? = nil) {
        let error = error as NSError?
        let knownDomains = [NSCocoaErrorDomain, NSPOSIXErrorDomain, NSOSStatusErrorDomain, "AVFoundationErrorDomain", "PHPhotosErrorDomain", "HomeMovie.HomeMovieError"]
        let domain = error.map { knownDomains.contains($0.domain) ? $0.domain : "OtherError" }
        let code = error?.code
        queue.async {
            var values = self.load()
            values.append(Entry(date: Date(), event: event, domain: domain, code: code))
            self.entries = Array(values.suffix(self.limit))
            self.persist()
        }
    }
    private func persist() {
        // Diagnostics must never prevent camera operation or recovery if storage is full.
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(entries ?? []).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch { }
    }
    func report() async -> String {
        await withCheckedContinuation { continuation in
            queue.async {
                let values = self.load()
                let info = Bundle.main.infoDictionary ?? [:]
                let version = info["CFBundleShortVersionString"] as? String ?? "—"
                let build = info["CFBundleVersion"] as? String ?? "—"
                let formatter = ISO8601DateFormatter()
                let events = values.map { entry in
                    let failure = entry.domain.map { " [\($0):\(entry.code ?? 0)]" } ?? ""
                    return "\(formatter.string(from: entry.date)) \(entry.event.rawValue)\(failure)"
                }
                continuation.resume(returning: (["Home Movie \(version) (\(build))", ProcessInfo.processInfo.operatingSystemVersionString,
                    "Local support events; this is not a full crash report.",
                    "An unfinished operation may indicate interruption, force quit or termination.", ""] + events).joined(separator: "\n"))
            }
        }
    }
    func clear() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { self.entries = []; self.persist(); continuation.resume() }
        }
    }
}
