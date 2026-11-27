import Foundation
import Testing
@testable import AccessAble

@MainActor
struct ChatViewModelTests {
    private let me = PlaceholderChatService.userID

    /// Lets the listening task deliver what the service has sent.
    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    @Test func callerChatIdNamesCallerThenVolunteer() {
        #expect(ChatID.make(callerID: "alice", volunteerID: "vic") == "alice_vic")
        #expect(ChatID.parties(of: "alice_vic").map { [$0.caller, $0.volunteer] } == ["alice", "vic"])
        #expect(ChatID.parties(of: "alice") == nil)
        #expect(ChatID.parties(of: "a_b_c") == nil)
        #expect(ChatID.parties(of: "_vic") == nil)
    }

    @Test func sendableTrimsAndLimitsLength() {
        #expect(ChatMessage.sendable("  hi \n") == "hi")
        #expect(ChatMessage.sendable(" \n ") == nil)
        #expect(ChatMessage.sendable(String(repeating: "x", count: 1000)) != nil)
        #expect(ChatMessage.sendable(String(repeating: "x", count: 1001)) == nil)
    }

    @Test func sentMessageAppearsAsMineAndClearsDraft() async {
        let service = PlaceholderChatService()
        let model = ChatViewModel(service: service, target: .volunteer(id: "vic"), partnerName: "Vic")
        let listening = Task { await model.start() }
        defer { listening.cancel() }
        await settle()
        #expect(model.hasLoaded)
        #expect(model.messages.isEmpty)

        model.draft = "  Can you help at 5?  "
        #expect(model.canSend)
        await model.send()
        await settle()

        #expect(model.draft.isEmpty)
        #expect(model.messages.map(\.text) == ["Can you help at 5?"])
        #expect(model.isFromMe(model.messages[0]))
        #expect(model.lastIncoming == nil)
    }

    @Test func onlyNewMessagesFromThePartnerAreAnnounced() async throws {
        let chatID = ChatID.make(callerID: me, volunteerID: "vic")
        let history = ChatMessage(id: "old", text: "Earlier", senderID: "vic")
        let service = PlaceholderChatService(messages: [chatID: [history]])
        let model = ChatViewModel(service: service, target: .chat(id: chatID), partnerName: "Vic")
        let listening = Task { await model.start() }
        defer { listening.cancel() }
        await settle()
        #expect(model.messages.map(\.id) == ["old"])
        #expect(model.lastIncoming == nil)

        model.draft = "Hi"
        await model.send()
        await settle()
        #expect(model.lastIncoming == nil)
        try await service.injectForTests(ChatMessage(id: "new", text: "On my way", senderID: "vic"), chatID: chatID)
        await settle()
        #expect(model.lastIncoming?.id == "new")
    }

    @Test func emptyOrSignedOutCannotSend() async {
        let model = ChatViewModel(service: PlaceholderChatService(userID: nil), target: .volunteer(id: "vic"), partnerName: "Vic")
        await model.start()
        #expect(model.errorMessage == ChatError.signedOut.localizedDescription)
        model.draft = "Hello"
        #expect(!model.canSend)

        let signedIn = ChatViewModel(service: PlaceholderChatService(), target: .volunteer(id: "vic"), partnerName: "Vic")
        let listening = Task { await signedIn.start() }
        defer { listening.cancel() }
        await settle()
        signedIn.draft = "   "
        #expect(!signedIn.canSend)
    }

    @Test func failedSendKeepsTheDraftAndShowsWhy() async {
        let model = ChatViewModel(service: FailingChatService(), target: .volunteer(id: "vic"), partnerName: "Vic")
        let listening = Task { await model.start() }
        defer { listening.cancel() }
        await settle()
        model.draft = "Hello"
        await model.send()
        #expect(model.draft == "Hello")
        #expect(model.errorMessage == ChatError.offline.localizedDescription)
        #expect(!model.isSending)
    }
}

private struct FailingChatService: ChatService {
    func currentUserID() async -> String? { "me" }
    func messages(chatID: String) -> AsyncThrowingStream<[ChatMessage], Error> {
        AsyncThrowingStream { $0.yield([]) }
    }
    func send(_ text: String, chatID: String) async throws { throw ChatError.offline }
    func volunteerChats() -> AsyncThrowingStream<[ChatThread], Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
