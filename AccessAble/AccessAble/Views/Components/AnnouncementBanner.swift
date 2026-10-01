import SwiftUI

/// Visual mirror of the last spoken announcement, for low-vision and sighted-helper users.
/// VoiceOver users already hear the announcement, so this is a single static element (not a live region).
struct AnnouncementBanner: View {
    let event: AnnouncementEvent

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(event.text)
                .font(.body.weight(.medium))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
        .background(tint.opacity(0.15), in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(tint, lineWidth: 2))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Last announcement: \(event.text)")
    }

    private var symbol: String {
        switch event.category {
        case .hazard: "exclamationmark.triangle.fill"
        case .maneuver: "arrow.turn.up.right"
        case .landmark: "mappin.and.ellipse"
        case .ambient: "eye"
        case .system: "info.circle"
        }
    }

    private var tint: Color {
        switch event.priority {
        case .critical: .red
        case .high: .orange
        case .normal, .low: .accentColor
        }
    }
}

#Preview {
    AnnouncementBanner(event: AnnouncementEvent(
        category: .hazard, priority: .critical, text: "Person 2 metres ahead.", source: .obstacleDetection
    ))
    .padding()
}
