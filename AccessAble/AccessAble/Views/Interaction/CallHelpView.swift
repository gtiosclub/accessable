import SwiftUI

/// Owner: User Interaction (3.x). Volunteers who are available now (Live) or saved / called before (History).
/// Calls and messages use sample volunteers until the calling backend exists.
struct CallHelpView: View {
    @Environment(AppRouter.self) private var router
    @Environment(AppViewModel.self) private var app
    @State private var tab: Tab = .live
    /// Who is online now, from the volunteer directory (sample volunteers without Firebase).
    @State private var liveVolunteers: [Volunteer] = []
    @State private var hasLoadedLive = false

    enum Tab: String, CaseIterable {
        case live = "Live"
        case history = "History"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ScreenHeader(title: "Call Help") { router.pop() }
                tabPicker
                switch tab {
                case .live:
                    volunteerSection("Currently Active", volunteers: liveVolunteers)
                    if hasLoadedLive && liveVolunteers.isEmpty {
                        Text("No volunteers are online right now.")
                            .font(.title3)
                            .foregroundStyle(.white)
                    }
                case .history:
                    volunteerSection("Saved", volunteers: SampleContent.savedVolunteers)
                    volunteerSection("History", volunteers: SampleContent.recentVolunteers)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
        .background(Color.black.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .accessibilityAction(.escape) { router.pop() }
        .task {
            for await volunteers in app.services.volunteers.onlineVolunteers() {
                liveVolunteers = volunteers
                hasLoadedLive = true
            }
        }
    }

    private var tabPicker: some View {
        VStack(spacing: 6) {
            HStack(spacing: 0) {
                ForEach(Tab.allCases, id: \.self) { item in
                    let isSelected = tab == item
                    Button {
                        tab = item
                    } label: {
                        Text(item.rawValue)
                            .font(.title2)
                            .foregroundStyle(isSelected ? .black : .white)
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .background(isSelected ? Theme.cyan : .clear, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
                    .accessibilityHint(item == .live ? "Volunteers available now" : "Saved and recent volunteers")
                }
            }
            Rectangle()
                .fill(.white.opacity(0.6))
                .frame(height: 1)
                .accessibilityHidden(true)
        }
    }

    private func volunteerSection(_ title: String, volunteers: [Volunteer]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.title2)
                .foregroundStyle(.white)
                .padding(.top, 12)
                .padding(.bottom, 8)
                .accessibilityAddTraits(.isHeader)
            ForEach(volunteers) { volunteer in
                VolunteerRow(
                    volunteer: volunteer,
                    onCall: { router.push(.call(volunteer)) },
                    onMessage: { router.push(.chat(volunteer)) }
                )
            }
        }
    }
}

private struct VolunteerRow: View {
    let volunteer: Volunteer
    let onCall: () -> Void
    let onMessage: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                HelperAvatar(isOnline: volunteer.isOnline)
                VStack(alignment: .leading, spacing: 4) {
                    Text(volunteer.name)
                        .font(.title3.bold())
                    Text(volunteer.availableUntil.isEmpty ? "Online now" : volunteer.availableUntil)
                        .font(.subheadline)
                }
                .foregroundStyle(.white)
                .accessibilityElement(children: .combine)
                Spacer(minLength: 8)
                CircleIconButton(
                    systemImage: "phone",
                    label: "Video call \(volunteer.name)",
                    fill: Theme.red,
                    foreground: .white,
                    diameter: 54,
                    action: onCall
                )
                CircleIconButton(
                    systemImage: "ellipsis.message",
                    label: "Message \(volunteer.name)",
                    diameter: 54,
                    action: onMessage
                )
            }
            .padding(.vertical, 14)
            .padding(.leading, 16)
            Rectangle()
                .fill(Theme.cyan.opacity(0.6))
                .frame(height: 1)
                .accessibilityHidden(true)
        }
    }
}

#Preview {
    NavigationStack {
        CallHelpView()
    }
    .environment(AppRouter())
    .environment(AppViewModel.preview)
    .preferredColorScheme(.dark)
}
