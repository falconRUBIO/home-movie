import SwiftUI

struct CopySceneAdjustmentsView: View {
    @Environment(\.dismiss) private var dismiss
    let source: SceneAdjustments
    let copy: (SceneAdjustmentClipboard) -> Void
    @State private var selection = SceneAdjustmentSelection.suggested
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Light", isOn: selected(.light))
                    Toggle("Color", isOn: selected(.color))
                    Toggle("HSL", isOn: selected(.hsl))
                } header: { Text("Adjustments") }
                footer: { Text("Replace selected adjustments in the destination clip. Light includes curves and fade; Color includes saturation and vibrance.") }
                Section {
                    Toggle("Exposure", isOn: selected(.exposure))
                    Toggle("White Balance", isOn: selected(.whiteBalance))
                } header: { Text("Shot Corrections") }
                footer: { Text("Usually specific to each shot. FX already applies to the entire movie.") }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("Copy Adjustments").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Copy") {
                        do {
                            copy(try SceneAdjustmentClipboard(source: source, selection: selection))
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }.disabled(selection.isEmpty)
                }
            }
        }.presentationDetents([.medium, .large])
    }
    private func selected(_ item: SceneAdjustmentSelection) -> Binding<Bool> {
        Binding(get: { selection.contains(item) }, set: { included in
            if included { selection.insert(item) } else { selection.remove(item) }
        })
    }
}
