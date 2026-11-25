import SwiftUI

/// Owner: Calls (VOLUNTEER-7). Every way into a call comes through here: the Home button, a
/// volunteer row's Call action, and the "call a volunteer" voice command. So the consent screen
/// can't be skipped, whichever way a call starts.
struct CallFlowView: View {
    @Environment(AppViewModel.self) private var app
    @Environment(AppRouter.self) private var router
    @State private var hasAgreed: Bool?
    @State private var saving = false
    @State private var errorMessage: String?
    let volunteer: Volunteer?

    var body: some View {
        Group {
            if hasAgreed == true {
                CallView(services: app.services, volunteer: volunteer) { router.pop() }
            } else if hasAgreed == false {
                CallConsentView(announcements: app.services.announcements, onAgree: {
                    saving = true
                    Task {
                        defer { saving = false }
                        do { try await app.services.callSafety.acceptConsent(); hasAgreed = true; errorMessage = nil }
                        catch { errorMessage = "Couldn't save your consent. Check your connection and try again." }
                    }
                }, onCancel: { router.pop() })
                .disabled(saving)
                .overlay { if saving { ProgressView("Saving consent").padding().background(.regularMaterial) } }
            } else {
                VStack(spacing: 20) {
                    if let errorMessage { Text(errorMessage) }
                    else { ProgressView("Checking call consent") }
                    if errorMessage != nil { Button("Retry") { Task { await loadConsent() } }.frame(minHeight: 44) }
                    Button("Back") { router.pop() }.frame(minHeight: 44)
                }.padding()
            }
        }
        .safeAreaInset(edge: .bottom) {
            if hasAgreed == false, let errorMessage { Text(errorMessage).padding().background(.black) }
        }
        .task { await loadConsent() }
        .onChange(of: errorMessage) { _, text in if let text { AccessibilityNotification.Announcement(text).post() } }
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden()
    }

    private func loadConsent() async {
        errorMessage = nil
        do { hasAgreed = try await app.services.callSafety.hasConsent() }
        catch { errorMessage = "Couldn't check call consent. Connect to the internet and retry." }
    }
}

/// Shown before the caller's first call. It's at the start of the feature, not added at the end,
/// so it can't be cut.
struct CallConsentView: View {
    /// Legacy key retained for compatibility; only server-recorded consent now authorizes calling.
    static let agreedKey = "calls.hasAgreedToCallConsent"

    let announcements: any AnnouncementEngineProtocol
    let onAgree: () -> Void
    let onCancel: () -> Void
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Before your first call")
                    .font(.largeTitle.bold())
                    .accessibilityAddTraits(.isHeader)

                point(
                    systemImage: "eye.fill",
                    title: "A volunteer will see your camera",
                    detail: "Volunteers are club-approved helpers you may not know. During a call, they see what your back camera shows and hear you."
                )
                // True because LiveKit only records with its recording (egress) feature, which we never turn on.
                point(
                    systemImage: "record.circle",
                    title: "AccessAble does not record calls",
                    detail: "AccessAble doesn't record or save the video or audio from any call."
                )
                point(
                    systemImage: "phone.down.fill",
                    title: "You're in control",
                    detail: "You can hang up at any time. After the call, you can report a concern or block the volunteer from matching with you again."
                )

                AccessibleActionButton(title: "I understand", systemImage: "checkmark",
                                       hint: "Agrees and starts calling a volunteer", action: onAgree)
                AccessibleActionButton(title: "Not now", systemImage: "xmark",
                                       hint: "Goes back without calling", action: onCancel)
            }
            .padding(24)
        }
        .foregroundStyle(.white)
        .background(Color.black.ignoresSafeArea())
        .accessibilityAction(.escape, onCancel)
        .task {
            // Someone who said "call a volunteer" may not be looking at the screen. VoiceOver users
            // hear the screen itself, so this is only for everyone else.
            guard !voiceOverEnabled else { return }
            await announcements.submit(AnnouncementEvent(
                category: .system, priority: .high,
                text: "Before your first call: a club-approved volunteer will see your camera and hear you. "
                    + "Calls are never recorded. You can hang up at any time. "
                    + "Choose I understand to continue, or Not now to go back.",
                source: .userInteraction
            ))
        }
    }

    private func point(systemImage: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: systemImage)
                .font(.title2)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title3.bold())
                Text(detail)
                    .font(.body)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview("Consent") {
    CallConsentView(announcements: PlaceholderAnnouncementEngine(), onAgree: {}, onCancel: {})
}
