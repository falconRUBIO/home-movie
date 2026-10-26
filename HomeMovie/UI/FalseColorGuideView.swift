import SwiftUI

// A categorical key, not a histogram or an estimate of the frame's exposure.
struct FalseColorIndicator: View {
    let status: LiveLookStatus
    let showGuide: () -> Void
    var body: some View {
        Button(action: showGuide) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(status == .ready ? "False Color" : "Loading False Color…")
                        .font(.caption.weight(.semibold))
                    HStack(spacing: 3) {
                        ForEach(FalseColorZone.allCases) { zone in
                            RoundedRectangle(cornerRadius: 2).fill(zone.color)
                                .frame(width: 20, height: 5)
                        }
                    }.accessibilityHidden(true)
                }
                Image(systemName: "info.circle").font(.caption)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(minHeight: 44)
            // Keep overlay colors neutral and readable over the exposure map.
            .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("False Color exposure guide")
        .accessibilityValue(status == .ready ? "Purple, blue, green, pink, orange, red" : "Loading")
        .accessibilityHint("Shows the meaning of every exposure color")
    }
}

extension FalseColorZone {
    var color: Color { Color(red: Double(rgb.x), green: Double(rgb.y), blue: Double(rgb.z)) }
}

struct FalseColorGuideView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Colors show exposure, not the subject’s real color. The on-screen key always shows all six colors. Exposure ranges between the colored zones remain grayscale.")
                }
                Section {
                    ForEach(FalseColorZone.allCases) { zone in
                        HStack(alignment: .top, spacing: 12) {
                            Circle().fill(zone.color).frame(width: 18, height: 18).padding(.top, 3)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(zone.title).font(.body.weight(.medium))
                                Text("\(zone.colorName) · \(zone.rangeLabel)")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 3).accessibilityElement(children: .combine)
                    }
                } header: { Text("Low to High Exposure") } footer: {
                    Text("Stops are relative to 18% middle gray. These ranges are exposure guides, not measured sensor clipping limits.")
                }
                Section("Using the Guide") {
                    Text("For a neutral gray card, adjust exposure until it appears green. Other subjects can naturally fall above or below that reference.")
                    Text("Purple marks very low exposure. Increasing exposure moves those areas toward blue and gray. If a scene is intentionally dark, those colors may be expected.")
                    Text("False Color changes only the viewfinder. Your original recording stays in Apple Log, and your movie look is unchanged.")
                }
            }
            .navigationTitle("False Color Guide").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.large]).presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
    }
}
