import Foundation

// Local, bounded support events. Never record titles, paths, media or error userInfo.
final class ReliabilityDiagnostics: @unchecked Sendable {
    enum Event: String, Codable {
        case appLaunched, lowMemory, resourcePressure, firstPreviewFrame, cameraRequested, cameraReady, cameraFailed, cameraInterrupted
        case recordingRequested, recordingStarted, recordingFinished, recordingFailed, recordingGeometry
        case exportRequested, exportFinished, exportFailed, exportCancelled
    }
    struct CaptureContext: Codable, Sendable {
        enum Camera: String, Codable, Sendable { case front, rear }
        var camera: Camera? = nil
        var interface: MovieFormat? = nil
        var canvas: MovieFormat? = nil
        var sensorAngle: Double? = nil
        var savedWidth: Int? = nil
        var savedHeight: Int? = nil
    }
    private struct Entry: Codable {
        let date: Date
        let event: Event
        let domain: String?
        let code: Int?
        let capture: CaptureContext?
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
    func record(_ event: Event, error: Error? = nil, capture: CaptureContext? = nil) {
        let error = error as NSError?
        let knownDomains = [NSCocoaErrorDomain, NSPOSIXErrorDomain, NSOSStatusErrorDomain, "AVFoundationErrorDomain", "PHPhotosErrorDomain", "HomeMovie.HomeMovieError"]
        let domain = error.map { knownDomains.contains($0.domain) ? $0.domain : "OtherError" }
        let code = error?.code
        queue.async {
            var values = self.load()
            values.append(Entry(date: Date(), event: event, domain: domain, code: code, capture: capture))
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
    private var systemDirectory: URL { file.deletingLastPathComponent().appendingPathComponent("AppleReports", isDirectory: true) }
    private func systemFiles() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: systemDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])) ?? []
        return files.filter {
            guard $0.pathExtension == "json", let values = try? $0.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) else { return false }
            return values.isRegularFile == true && values.isSymbolicLink != true && (values.fileSize ?? Int.max) <= 1_048_576
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    func saveSystemReport(_ data: Data) {
        guard data.count <= 1_048_576, (try? JSONSerialization.jsonObject(with: data)) != nil else { return }
        queue.async {
            do {
                try FileManager.default.createDirectory(at: self.systemDirectory, withIntermediateDirectories: true)
                // Remove before writing: never retain more than four bounded reports.
                for old in self.systemFiles().dropLast(3) { try FileManager.default.removeItem(at: old) }
                let name = String(format: "%.6f", Date().timeIntervalSince1970) + "-" + UUID().uuidString + ".json"
                try data.write(to: self.systemDirectory.appendingPathComponent(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            } catch { }
        }
    }
    func report() async -> String {
        await withCheckedContinuation { continuation in
            queue.async {
                let values = self.load()
                let info = Bundle.main.infoDictionary ?? [:]
                let version = info["CFBundleShortVersionString"] as? String ?? "—"
                let build = info["CFBundleVersion"] as? String ?? "—"
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let events = values.map { entry in
                    let failure = entry.domain.map { " [\($0):\(entry.code ?? 0)]" } ?? ""
                    var geometry: [String] = []
                    if let capture = entry.capture {
                        if let camera = capture.camera { geometry.append("camera=\(camera.rawValue)") }
                        if let interface = capture.interface { geometry.append("interface=\(interface.rawValue)") }
                        if let canvas = capture.canvas { geometry.append("canvas=\(canvas.rawValue)") }
                        if let angle = capture.sensorAngle, angle.isFinite { geometry.append("sensor=\(angle)") }
                        if let width = capture.savedWidth, let height = capture.savedHeight { geometry.append("saved=\(width)x\(height)") }
                    }
                    let details = geometry.isEmpty ? "" : " [" + geometry.joined(separator: " ") + "]"
                    return "\(formatter.string(from: entry.date)) \(entry.event.rawValue)\(failure)\(details)"
                }
                let apple = self.systemFiles().suffix(4).compactMap { try? String(contentsOf: $0, encoding: .utf8) }
                continuation.resume(returning: (["HOME MOVIE CLIPS \(version) (\(build))", ProcessInfo.processInfo.operatingSystemVersionString,
                    "Local support events; Apple performance/crash reports appear below when delivered.",
                    "An unfinished operation may indicate interruption, force quit or termination.", ""] + events + apple).joined(separator: "\n"))
            }
        }
    }
    func clear() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                self.entries = []; self.persist()
                for file in self.systemFiles() { try? FileManager.default.removeItem(at: file) }
                continuation.resume()
            }
        }
    }
}
