import SwiftUI

/// Owner: User Interaction (3.x). Text chat with a volunteer, sent through `ChatService` (CHAT-1).
struct VolunteerChatView: View {
    @Environment(AppRouter.self) private var router
    let volunteer: Volunteer
    @State private var model: ChatViewModel

    init(volunteer: Volunteer, services: AppServices) {
        self.volunteer = volunteer
        _model = State(initialValue: ChatViewModel(
            service: services.chat, target: .volunteer(id: volunteer.id), partnerName: volunteer.name))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(.white.opacity(0.6))
                .frame(height: 1)
                .accessibilityHidden(true)
            ChatConversationView(model: model)
        }
        .background(Color.black.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .accessibilityAction(.escape) { router.pop() }
    }

    private var header: some View {
        HStack(spacing: 16) {
            Button { router.pop() } label: {
                Image(systemName: "chevron.left")
                    .font(.title.weight(.semibold))
                    .foregroundStyle(.white)
                    .minimumTapTarget()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back")

            HelperAvatar(isOnline: volunteer.isOnline, size: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text(volunteer.name)
                    .font(.title3.bold())
                    .accessibilityAddTraits(.isHeader)
                if !volunteer.availableUntil.isEmpty {
                    Text(volunteer.availableUntil)
                        .font(.subheadline)
                }
            }
            .foregroundStyle(.white)
            .accessibilityElement(children: .combine)
            Spacer()
            CircleIconButton(
                systemImage: "phone",
                label: "Video call \(volunteer.name)",
                fill: Theme.red,
                foreground: .white,
                diameter: 54
            ) {
                // The real call flow: consent screen first, then rings this volunteer.
                router.push(.call(volunteer))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

/// The messages and the composer, shared by the caller's screen and the volunteer's inbox.
struct ChatConversationView: View {
    @Bindable var model: ChatViewModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 12) {
                    if model.hasLoaded && model.messages.isEmpty {
                        Text("No messages yet. Say hello to \(model.partnerName).")
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.85))
                            .multilineTextAlignment(.center)
                            .padding(.top, 24)
                    }
                    ForEach(model.messages) { message in
                        bubble(message)
                    }
                }
                .padding(20)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            if let error = model.errorMessage {
                HStack {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.white)
                    Spacer()
                    Button("Dismiss") { model.dismissError() }
                        .foregroundStyle(Theme.cyan)
                        .minimumTapTarget()
                }
                .padding(.horizontal, 20)
            }
            composer
        }
        .background(Color.black.ignoresSafeArea())
        .task { await model.start() }
        .onChange(of: model.lastIncoming) { _, message in
            guard let message else { return }
            AccessibilityNotification.Announcement("\(model.partnerName): \(message.text)").post()
        }
        .onChange(of: model.errorMessage) { _, text in
            if let text { AccessibilityNotification.Announcement(text).post() }
        }
    }

    private func bubble(_ message: ChatMessage) -> some View {
        let isFromMe = model.isFromMe(message)
        return HStack {
            if isFromMe { Spacer(minLength: 60) }
            Text(message.text)
                .font(.callout)
                .foregroundStyle(.white)
                .padding(12)
                .background(Theme.bubble, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .accessibilityLabel(isFromMe ? "You: \(message.text)" : "\(model.partnerName): \(message.text)")
            if !isFromMe { Spacer(minLength: 60) }
        }
    }

    private var composer: some View {
        HStack {
            TextField("Message", text: $model.draft, prompt: Text("Enter message").foregroundStyle(.white.opacity(0.85)), axis: .vertical)
                .font(.title3)
                .foregroundStyle(.white)
                .lineLimit(1...4)
                .submitLabel(.send)
                .onSubmit { Task { await model.send() } }
            Button { Task { await model.send() } } label: {
                Image(systemName: "paperplane")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .minimumTapTarget()
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.isSending ? "Sending" : "Send")
            .disabled(!model.canSend)
        }
        .padding(.leading, 20)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .overlay(Capsule().strokeBorder(.white, lineWidth: 1.5))
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

#Preview {
    NavigationStack {
        VolunteerChatView(volunteer: SampleContent.activeVolunteers[0], services: .preview)
    }
    .environment(AppRouter())
    .preferredColorScheme(.dark)
}
