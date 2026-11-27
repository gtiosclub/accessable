import SwiftUI

/// The volunteer's inbox on their home screen (CHAT-1): one row per caller who has messaged them.
struct VolunteerMessagesSection: View {
    let model: ChatInboxViewModel

    var body: some View {
        Section("Messages") {
            if let error = model.errorMessage {
                Text(error)
            } else if model.threads.isEmpty {
                Text("No messages yet. Callers can message you from Call Help.")
            }
            ForEach(model.threads) { thread in
                NavigationLink {
                    VolunteerReplyView(thread: thread, service: model.service)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(thread.callerFirstName)
                        Text(thread.updatedAt, format: .relative(presentation: .named))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityHint("Opens your chat")
                }
            }
        }
    }
}

private struct VolunteerReplyView: View {
    @State private var model: ChatViewModel

    init(thread: ChatThread, service: any ChatService) {
        _model = State(initialValue: ChatViewModel(
            service: service, target: .chat(id: thread.id), partnerName: thread.callerFirstName))
    }

    var body: some View {
        ChatConversationView(model: model)
            .navigationTitle(model.partnerName)
            .navigationBarTitleDisplayMode(.inline)
    }
}
