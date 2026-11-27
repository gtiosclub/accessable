import SwiftUI

/// Owner: Calls (VOLUNTEER-4, Call action from VOLUNTEER-7). Every volunteer with live
/// online/offline status, online first.
struct VolunteerListView: View {
    @Environment(AppRouter.self) private var router
    @State private var viewModel: VolunteerListViewModel

    init(services: AppServices) {
        _viewModel = State(initialValue: VolunteerListViewModel(services: services))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ScreenHeader(title: "Volunteers") { router.pop() }
                    .padding(.bottom, 8)
                if !viewModel.hasLoaded {
                    ProgressView("Loading volunteers")
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                } else if viewModel.rows.isEmpty {
                    Text("No volunteers yet.")
                        .font(.title3)
                        .padding(.top, 40)
                } else {
                    Text(viewModel.summary)
                        .font(.title3)
                        .padding(.vertical, 8)
                    ForEach(viewModel.rows) { row in
                        VolunteerStatusRow(row: row, onCall: {
                            router.push(.call(Volunteer(id: row.id, name: row.name, availableUntil: "", isOnline: true)))
                        }, onMessage: {
                            router.push(.chat(Volunteer(id: row.id, name: row.name, availableUntil: "", isOnline: row.isOnline)))
                        })
                    }
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
        .background(Color.black.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .accessibilityAction(.escape) { router.pop() }
        .task { await viewModel.start() }
    }
}

private struct VolunteerStatusRow: View {
    let row: VolunteerListViewModel.Row
    let onCall: () -> Void
    let onMessage: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
            : AnyLayout(HStackLayout(spacing: 16))
        return layout {
            // One VoiceOver stop for who they are ("Sam, online, speaks English") and a separate
            // one for the Call button, so the button stays reachable.
            HStack(spacing: 16) {
                HelperAvatar(isOnline: row.isOnline)
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.name)
                        .font(.title3.bold())
                    Text(row.isOnline ? "Online" : "Offline")
                        .font(.subheadline)
                    if !row.languages.isEmpty {
                        Text("Speaks \(row.languages)")
                            .font(.subheadline)
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(row.accessibilityLabel)

            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }

            HStack(spacing: 16) {
                if row.isOnline {
                    CircleIconButton(
                        systemImage: "phone",
                        label: "Video call \(row.name)",
                        fill: Theme.red,
                        foreground: .white,
                        diameter: 54,
                        action: onCall
                    )
                }
                // Messages wait for an offline volunteer, so this shows either way.
                CircleIconButton(
                    systemImage: "ellipsis.message",
                    label: "Message \(row.name)",
                    diameter: 54,
                    action: onMessage
                )
            }
        }
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.cyan.opacity(0.6)).frame(height: 1)
        }
    }
}

#Preview {
    NavigationStack {
        VolunteerListView(services: .preview)
    }
    .environment(AppRouter())
    .preferredColorScheme(.dark)
}
