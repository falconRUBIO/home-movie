import SwiftUI

struct ExportView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    let movie: Movie
    @StateObject private var export = ExportModel()
    @State private var sharing = false
    @State private var savingFiles = false
    @State private var savingPhotos = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Movie", value: movie.name)
                    LabeledContent("Duration", value: durationLabel(movie.duration))
                    LabeledContent("Quality", value: "1080p SDR · MP4")
                    if movie.captureProfile == .appleLog { LabeledContent("Look", value: movie.lookName) }
                } footer: { Text("Export creates a copy. You can keep recording into your original movie.") }
                if export.running {
                    Section {
                        ProgressView(value: export.progress) { Text("Exporting…") } currentValueLabel: { Text(export.progress, format: .percent.precision(.fractionLength(0))) }
                        Button("Cancel Export", role: .destructive) { export.cancel() }
                    } footer: { Text("Keep Home Movie open while exporting.") }
                } else if export.exportedURL != nil {
                    Section {
                        Button("Save to Photos", systemImage: "photo") {
                            savingPhotos = true
                            Task { await export.saveToPhotos(); savingPhotos = false }
                        }.disabled(savingPhotos)
                        Button("Save to Files", systemImage: "folder") { savingFiles = true }.disabled(savingPhotos)
                        Button("Share Video", systemImage: "square.and.arrow.up") { sharing = true }.disabled(savingPhotos)
                    }
                } else {
                    Section { Button("Export Movie") { export.start(movie: movie, app: app) } }
                }
                if let notice = export.notice { Section { Text(notice).foregroundStyle(.secondary) } }
                if let error = export.error { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle("Export Movie").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(export.running || savingPhotos) } }
            .sheet(isPresented: $sharing) { if let url = export.exportedURL { SystemShareSheet(url: url) } }
            .sheet(isPresented: $savingFiles) { if let url = export.exportedURL { SystemFilesExporter(url: url) } }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(export.running || savingPhotos)
        .onDisappear { export.cancel() }
    }
}
