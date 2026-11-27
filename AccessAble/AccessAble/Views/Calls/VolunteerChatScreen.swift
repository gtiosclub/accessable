import SwiftUI

/// Which caller the volunteer's chat screen is with.
struct VolunteerChatRoute: Hashable, Identifiable {
    let callerID: String
    let name: String
    var id: String { callerID }
}

/// The volunteer's chat with one caller (CHAT-1), with a star to save them (SAVE-1).
struct VolunteerChatScreen: View {
    let route: VolunteerChatRoute
    @State private var model: ChatViewModel
    @State private var star: SaveStarModel
    @Environment(\.dismiss) private var dismiss

    init(route: VolunteerChatRoute, services: AppServices) {
        self.route = route
        _model = State(initialValue: ChatViewModel(
            service: services.chat, target: .caller(id: route.callerID), partnerName: route.name))
        _star = State(initialValue: SaveStarModel(service: services.saves, personID: route.callerID))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.title.weight(.semibold))
                        .foregroundStyle(.white)
                        .minimumTapTarget()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
                PersonAvatar(isOnline: nil, size: 48)
                Text(route.name)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                SaveStarButton(name: route.name, isSaved: star.isSaved, isBusy: star.isBusy) {
                    Task { await star.toggle() }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Rectangle()
                .fill(.white.opacity(0.6))
                .frame(height: 1)
                .accessibilityHidden(true)
            ChatConversationView(model: model)
        }
        .background(Color.black.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .accessibilityAction(.escape) { dismiss() }
        .task { await star.start() }
        .onChange(of: star.errorMessage) { _, text in
            if let text { AccessibilityNotification.Announcement(text).post() }
        }
    }
}
