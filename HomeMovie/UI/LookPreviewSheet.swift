import SwiftUI
import UniformTypeIdentifiers
import UIKit

@MainActor struct LookPreviewSheet: View {
    @ObservedObject var app: AppModel
    let movieID: UUID
    @Binding var previewMode: CameraPreviewMode
    let canChangeLook: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var looks: [LUTReference] = []
    @State private var working = false
    @State private var problem: String?
    private var movie: Movie? { app.movie(movieID) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Recording: Apple Log", systemImage: "record.circle")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Section {
                    lookRow("Standard", reference: nil)
                    ForEach(looks, id: \.id) { look in
                        lookRow(look.displayName, reference: look)
                    }
                } header: { Text("Movie Look") } footer: {
                    Text(canChangeLook ? "Used for playback and export."
                         : "Used for playback and export. Stop recording to change it.")
                }
                ViewfinderPreviewSection(mode: $previewMode)
                    .disabled(working)
                Section {
                    NavigationLink {
                        LookFileImportView(importing: $working) { url, displayReferred in
                            guard canChangeLook else { throw HomeMovieError.message("Stop recording before importing a look.") }
                            let look = try await app.store.importLook(from: url, displayReferred: displayReferred)
                            try await app.store.setLook(movieID: movieID, look: look)
                            looks = await app.store.availableLooks()
                            await app.refresh()
                        }
                    } label: {
                        Label("Import Look…", systemImage: "square.and.arrow.down")
                    }.disabled(!canChangeLook || working)
                }
                if working { Section { ProgressView("Updating Look…") } }
            }
            .navigationTitle("Look & Preview").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(working) }
            }
            .task {
                let available = await app.store.availableLooks()
                guard !Task.isCancelled else { return }
                looks = available
            }
            .alert("Couldn’t Change Look", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
                Button("OK") { problem = nil }
            } message: { Text(problem ?? "") }
        }
        .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(working)
        .preferredColorScheme(.dark)
    }

    private func lookRow(_ name: String, reference: LUTReference?) -> some View {
        let selected = movie?.look?.id == reference?.id
        return Button {
            guard !working, canChangeLook, !selected else { return }
            UISelectionFeedbackGenerator().selectionChanged()
            working = true
            Task {
                defer { working = false }
                do {
                    try await app.store.setLook(movieID: movieID, look: reference)
                    await app.refresh()
                } catch { problem = error.localizedDescription }
            }
        } label: {
            HStack {
                Text(name).foregroundStyle(.primary)
                Spacer()
                if selected { Image(systemName: "checkmark").fontWeight(.semibold).accessibilityHidden(true) }
            }.frame(minHeight: 28).contentShape(Rectangle())
        }
        .disabled(!canChangeLook || working)
        .accessibilityLabel(name)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

struct ViewfinderPreviewSection: View {
    @Binding var mode: CameraPreviewMode
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showingGuide = false
    private var picker: some View {
        Picker("Viewfinder", selection: $mode.withSelectionFeedback()) {
            ForEach(CameraPreviewMode.allCases) { choice in Text(choice.title).tag(choice) }
        }
    }
    var body: some View {
        Section {
            if dynamicTypeSize.isAccessibilitySize { picker.pickerStyle(.inline) }
            else { picker.pickerStyle(.segmented) }
            if mode == .falseColor {
                Button("False Color Guide", systemImage: "info.circle") { showingGuide = true }
            }
        } header: { Text("Viewfinder") } footer: {
            Text(mode.explanation + " Preview only.")
        }
        .sheet(isPresented: $showingGuide) { FalseColorGuideView() }
    }
}

@MainActor struct LookFileImportView: View {
    @Binding var importing: Bool
    let onImport: (URL, Bool) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var displayReferred = false
    @State private var choosingFile = false
    @State private var problem: String?

    var body: some View {
        Form {
            Section {
                Picker("Look Input", selection: $displayReferred.withSelectionFeedback()) {
                    Text("Apple Log").tag(false)
                    Text("Rec.709").tag(true)
                }.pickerStyle(.inline)
            } header: { Text("Designed For") } footer: {
                Text("Choose the input format specified by the look’s creator. Rec.709 looks receive the Apple Log conversion automatically.")
            }
            Section {
                Button("Choose File…", systemImage: "doc") { choosingFile = true }
            } footer: { Text("Import a 3D LUT in .cube format.") }
            if importing { Section { ProgressView("Importing Look…") } }
        }
        .disabled(importing)
        .navigationTitle("Import Look").navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(importing)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(importing) } }
        .interactiveDismissDisabled(importing)
        .fileImporter(isPresented: $choosingFile,
            allowedContentTypes: [UTType(filenameExtension: "cube") ?? .data], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                let inputIsDisplayReferred = displayReferred
                importing = true
                Task {
                    defer { importing = false }
                    do { try await onImport(url, inputIsDisplayReferred); dismiss() }
                    catch { problem = error.localizedDescription }
                }
            case .failure(let error):
                if (error as? CocoaError)?.code != .userCancelled { problem = error.localizedDescription }
            }
        }
        .alert("Couldn’t Import Look", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK") { problem = nil }
        } message: { Text(problem ?? "") }
    }
}
