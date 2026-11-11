import SwiftUI

/// Owner: User Interaction (3.x). Text chat with a volunteer. Messages stay on this screen
/// until a messaging backend exists.
struct VolunteerChatView: View {
    @Environment(AppRouter.self) private var router
    let volunteer: Volunteer
    @State private var messages: [ChatMessage]
    @State private var draft = ""
    @State private var isCalling = false

    init(volunteer: Volunteer) {
        self.volunteer = volunteer
        _messages = State(initialValue: SampleContent.conversation(with: volunteer))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(.white.opacity(0.6))
                .frame(height: 1)
                .accessibilityHidden(true)
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(messages) { message in
                        bubble(message)
                    }
                }
                .padding(20)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            composer
        }
        .background(Color.black.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .accessibilityAction(.escape) { router.pop() }
        .fullScreenCover(isPresented: $isCalling) {
            CallingView(volunteer: volunteer) { isCalling = false }
        }
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
                Text(volunteer.availableUntil)
                    .font(.subheadline)
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
                isCalling = true
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func bubble(_ message: ChatMessage) -> some View {
        HStack {
            if message.isFromMe { Spacer(minLength: 60) }
            Text(message.text)
                .font(.callout)
                .foregroundStyle(.white)
                .padding(12)
                .background(Theme.bubble, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .accessibilityLabel(message.isFromMe ? "You: \(message.text)" : "\(volunteer.name): \(message.text)")
            if !message.isFromMe { Spacer(minLength: 60) }
        }
    }

    private var composer: some View {
        HStack {
            TextField("Message", text: $draft, prompt: Text("Enter message").foregroundStyle(.white.opacity(0.85)), axis: .vertical)
                .font(.title3)
                .foregroundStyle(.white)
                .lineLimit(1...4)
                .submitLabel(.send)
                .onSubmit(send)
            Button(action: send) {
                Image(systemName: "paperplane")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .minimumTapTarget()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Send")
            .disabled(trimmedDraft.isEmpty)
        }
        .padding(.leading, 20)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .overlay(Capsule().strokeBorder(.white, lineWidth: 1.5))
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func send() {
        guard !trimmedDraft.isEmpty else { return }
        messages.append(ChatMessage(text: trimmedDraft, isFromMe: true))
        draft = ""
    }
}

#Preview {
    NavigationStack {
        VolunteerChatView(volunteer: SampleContent.activeVolunteers[0])
    }
    .environment(AppRouter())
    .preferredColorScheme(.dark)
}
