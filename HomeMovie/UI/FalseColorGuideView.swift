import SwiftUI

// A categorical key, not a histogram or an estimate of the frame's exposure.
struct FalseColorIndicator: View {
    let status: LiveLookStatus
    let showGuide: () -> Void
    var body: some View {
        Button(action: showGuide) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text(status == .ready ? "False Color · Exposure" : "Loading False Color…")
                        .font(.caption.weight(.semibold))
                    Spacer(minLength: 4)
                    Image(systemName: "info.circle").font(.caption)
                }
                HStack(alignment: .top, spacing: 5) {
                    ForEach(FalseColorZone.allCases) { zone in
                        VStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 2).fill(zone.color)
                                .frame(height: 6)
                            Text(zone.shortLabel).font(.caption2)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }.frame(maxWidth: .infinity)
                    }
                }.accessibilityHidden(true)
                Text("Check your subject · Tap for help")
                    .font(.caption2).foregroundStyle(.white.opacity(0.8))
            }
            .frame(maxWidth: 296)
            .foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(minHeight: 44)
            // Keep overlay colors neutral and readable over the exposure map.
            .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("False Color exposure guide")
        .accessibilityValue(status == .ready
            ? "Purple: very dark. Blue: dark. Green: middle gray. Pink: one stop above gray. Orange: bright. Red: very bright."
            : "Loading")
        .accessibilityHint("Shows what to aim for and how to adjust exposure for your subject")
    }
}

extension FalseColorZone {
    var color: Color { Color(red: Double(rgb.x), green: Double(rgb.y), blue: Double(rgb.z)) }
    var shortLabel: String {
        switch self {
        case .purple: "Very dark"
        case .blue: "Dark"
        case .middleGray: "Mid-gray"
        case .pink: "+1 stop"
        case .orange: "Bright"
        case .red: "Very bright"
        }
    }
    var guidance: String {
        switch self {
        case .purple: "Very dark areas. If this covers your subject, consider raising exposure or adding light. Deep shadows may belong here."
        case .blue: "Dark areas. Check whether the shadow detail you want is visible when you return to With Look."
        case .middleGray: "The reference for an 18% gray card. Make the card green when using one; the whole scene does not need to be green."
        case .pink: "One stop brighter than the gray reference. This is a brightness marker, not a target for every face or skin tone."
        case .orange: "Bright areas. Check important highlights, such as a face in sunlight or a bright window."
        case .red: "Very bright areas. Consider lowering exposure if you need detail there. Red alone does not mean that detail is clipped."
        }
    }
}

struct FalseColorGuideView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section("The Goal") {
                    Text("Keep useful detail in the person or object you are filming. Use the colors to spot areas that are much darker or brighter than your subject.")
                    Text("You do not need to make the whole image green.")
                        .fontWeight(.semibold)
                    Text("The top key runs from dark on the left to bright on the right. It is a color reference, not a live graph of your exposure.")
                }
                Section {
                    ForEach(FalseColorZone.allCases) { zone in
                        HStack(alignment: .top, spacing: 12) {
                            Circle().fill(zone.color).frame(width: 18, height: 18).padding(.top, 3)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(zone.title).font(.body.weight(.medium))
                                Text(zone.colorName).font(.subheadline).foregroundStyle(.secondary)
                                Text(zone.guidance).font(.subheadline)
                                Text(zone.rangeLabel).font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 3).accessibilityElement(children: .combine)
                    }
                } header: { Text("Low to High Exposure") } footer: {
                    Text("Stops measure brightness relative to 18% middle gray. +1 stop means twice as much light. Gray areas between the color bands are normal. These colors are exposure references, not measured sensor clipping limits.")
                }
                Section("Adjust Exposure") {
                    Text("Start with your subject. If it is too dark, raise exposure or add light. If important bright areas lose detail, lower exposure and check that your subject still looks right.")
                    Text("For example, a window may show red while a person indoors shows blue. Raising exposure helps the person but makes the window brighter. You may need more light on the person or a different angle.")
                    Text("Faces vary with skin tone and lighting. Do not force every face to green or pink. Switch back to With Look to judge the result.")
                }
                Section("Preview Only") {
                    Text("False Color changes only the viewfinder. It does not adjust exposure for you or add these colors to your video. Your original recording stays in Apple Log, and your movie look is unchanged.")
                }
            }
            .navigationTitle("False Color Guide").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.large]).presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
    }
}
