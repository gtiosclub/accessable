import SwiftUI

/// Large, full-width action button used for primary actions across the app.
/// Scales with Dynamic Type (including accessibility sizes), meets the 44 pt target, and requires a hint.
struct AccessibleActionButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    let hint: LocalizedStringKey
    var role: ButtonRole?
    let action: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Button(role: role, action: action) {
            // Stack vertically at accessibility sizes so long labels don't truncate.
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                : AnyLayout(HStackLayout(spacing: 12))
            layout {
                Image(systemName: systemImage)
                    .font(.title2)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .padding(.horizontal)
        }
        .buttonStyle(.borderedProminent)
        .accessibilityLabel(title)
        .accessibilityHint(hint)
    }
}

#Preview {
    VStack {
        AccessibleActionButton(title: "Describe my surroundings", systemImage: "eye",
                               hint: "Speaks what the camera sees") {}
        AccessibleActionButton(title: "Start a trip", systemImage: "figure.walk",
                               hint: "Search for a destination") {}
    }
    .padding()
}
