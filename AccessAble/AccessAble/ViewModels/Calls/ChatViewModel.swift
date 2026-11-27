import Foundation
import Observation

/// One chat screen (CHAT-1), for either party: the caller writing to a volunteer, or the
/// volunteer replying from their inbox.
@MainActor
@Observable
final class ChatViewModel {
    enum Target: Equatable {
        /// The caller's chat with this volunteer, started by the first message.
        case volunteer(id: String)
        /// A chat that already exists, opened from the volunteer's inbox.
        case chat(id: String)
    }

    let partnerName: String
    private(set) var messages: [ChatMessage] = []
    private(set) var myID: String?
    private(set) var isSending = false
    private(set) var hasLoaded = false
    private(set) var errorMessage: String?
    /// The newest message from the other person since the screen opened, for VoiceOver to read out.
    private(set) var lastIncoming: ChatMessage?
    var draft = ""

    @ObservationIgnored private let service: any ChatService
    @ObservationIgnored private let target: Target
    @ObservationIgnored private var chatID: String?

    init(service: any ChatService, target: Target, partnerName: String) {
        self.service = service
        self.target = target
        self.partnerName = partnerName
    }

    var canSend: Bool {
        chatID != nil && !isSending && ChatMessage.sendable(draft) != nil
    }

    func isFromMe(_ message: ChatMessage) -> Bool {
        message.senderID == myID
    }

    func start() async {
        guard let me = await service.currentUserID() else {
            errorMessage = ChatError.signedOut.localizedDescription
            return
        }
        myID = me
        let id: String = switch target {
        case .volunteer(let volunteerID): ChatID.make(callerID: me, volunteerID: volunteerID)
        case .chat(let id): id
        }
        chatID = id
        do {
            for try await list in service.messages(chatID: id) {
                receive(list)
            }
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func send() async {
        guard let chatID, !isSending else { return }
        guard let text = ChatMessage.sendable(draft) else {
            if !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                errorMessage = ChatError.invalidMessage.localizedDescription
            }
            return
        }
        isSending = true
        defer { isSending = false }
        let sent = draft
        draft = ""
        do {
            try await service.send(text, chatID: chatID)
            errorMessage = nil
        } catch {
            // Give the text back unless they've started typing something else.
            if draft.isEmpty { draft = sent }
            errorMessage = error.localizedDescription
        }
    }

    func dismissError() { errorMessage = nil }

    private func receive(_ list: [ChatMessage]) {
        // The first load is history, not news: only announce what arrives while the screen is open.
        if hasLoaded {
            let known = Set(messages.map(\.id))
            if let incoming = list.last(where: { !known.contains($0.id) && !isFromMe($0) }) {
                lastIncoming = incoming
            }
        }
        messages = list
        hasLoaded = true
    }
}

/// The volunteer's inbox of chats callers have started.
@MainActor
@Observable
final class ChatInboxViewModel {
    private(set) var threads: [ChatThread] = []
    private(set) var errorMessage: String?
    @ObservationIgnored let service: any ChatService

    init(service: any ChatService) {
        self.service = service
    }

    func start() async {
        do {
            for try await list in service.volunteerChats() {
                threads = list
                errorMessage = nil
            }
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
