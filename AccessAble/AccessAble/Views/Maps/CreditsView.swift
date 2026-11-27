import SwiftUI

/// Owner: Maps. The map data credits the OpenStreetMap licence and Stadia Maps ask for, pushed from Settings.
struct CreditsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                SettingsSectionTitle("Credits")
                ForEach(MapCredits.all) { credit in
                    creditCard(credit)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(SettingsPalette.background.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .navigationTitle("Credits")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
    }

    private func creditCard(_ credit: MapCredit) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(credit.heading)
                .font(.subheadline.bold())
                .accessibilityAddTraits(.isHeader)
            Text(credit.text)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
            Link(credit.linkTitle, destination: credit.url)
                .font(.body.weight(.semibold))
                .foregroundStyle(SettingsPalette.accent)
                .frame(minHeight: AccessibilityMetrics.minimumTapTarget, alignment: .leading)
                .accessibilityLabel(credit.linkAccessibilityLabel)
        }
        .foregroundStyle(.white)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SettingsPalette.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white, lineWidth: 1.5)
        )
        .accessibilityElement(children: .contain)
    }
}

#Preview {
    NavigationStack {
        CreditsView()
    }
}
