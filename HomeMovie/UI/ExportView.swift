import SwiftUI

struct ExportView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    let movie: Movie
    @StateObject private var export = ExportModel()
    @State private var sharing = false
    @State private var savingFiles = false
    @State private var savingPhotos = false
    @State private var showingEffects = false
    @State private var detent: PresentationDetent = .medium
    private var currentMovie: Movie { app.movie(movie.id) ?? movie }
    var body: some View {
        NavigationStack {
            Form {
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
                    Section { Button("Export Movie") { export.start(movie: currentMovie, app: app) } }
                }

                Section {
                    LabeledContent("Movie", value: currentMovie.name)
                    LabeledContent("Duration", value: durationLabel(currentMovie.duration))
                    LabeledContent("Quality", value: "1080p SDR · MP4")
                    if currentMovie.captureProfile == .appleLog { LabeledContent("Look", value: currentMovie.lookName) }
                } footer: { Text("Export creates a copy. You can keep recording into your original movie.") }
                Section {
                    Button { detent = .large; showingEffects = true } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Film Effects").foregroundStyle(.primary)
                                Text(currentMovie.exportEffects.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        }.padding(.vertical, 2)
                    }.disabled(export.running || savingPhotos || currentMovie.activeScenes.isEmpty)
                }
                if let notice = export.notice { Section { Text(notice).foregroundStyle(.secondary) } }
                if let error = export.error { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationDestination(isPresented: $showingEffects) { FilmEffectsView(movie: currentMovie).environmentObject(app) }
            .onChange(of: currentMovie.revision) { _, _ in export.invalidate() }
            .navigationTitle("Export Movie").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(export.running || savingPhotos) } }
            .sheet(isPresented: $sharing) { if let url = export.exportedURL { SystemShareSheet(url: url) } }
            .sheet(isPresented: $savingFiles) { if let url = export.exportedURL { SystemFilesExporter(url: url) } }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .interactiveDismissDisabled(export.running || savingPhotos || showingEffects)
        .onDisappear { export.cancel() }
    }
}

