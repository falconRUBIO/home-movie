import SwiftUI

struct DiagnosticsView: View {
    @State private var report = ""
    @State private var confirmClear = false
    var body: some View {
        Form {
            Section {
                Text("Recent camera, recording and export events stay on this iPhone. No video, audio or movie titles are included. Nothing is sent automatically.")
                    .font(.subheadline).foregroundStyle(.secondary)
                if !report.isEmpty {
                    ShareLink(item: report) { Label("Share Diagnostics", systemImage: "square.and.arrow.up") }
                    Button("Clear Diagnostics", role: .destructive) { confirmClear = true }
                }
            }
            Section("Recent Events") {
                Text(report.isEmpty ? "Loading…" : report).font(.caption.monospaced()).textSelection(.enabled)
            }
        }
        .navigationTitle("Diagnostics").navigationBarTitleDisplayMode(.inline)
        .task { report = await ReliabilityDiagnostics.shared.report() }
        .alert("Clear diagnostics?", isPresented: $confirmClear) {
            Button("Cancel", role: .cancel) { }
            Button("Clear", role: .destructive) {
                Task { await ReliabilityDiagnostics.shared.clear(); report = await ReliabilityDiagnostics.shared.report() }
            }
        } message: { Text("Your movies and recordings are kept.") }
    }
}
