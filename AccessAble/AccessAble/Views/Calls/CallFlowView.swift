import SwiftUI

/// Owner: Calls (VOLUNTEER-7). Every way into a call comes through here: the Home button, a
/// volunteer row's Call action, and the "call a volunteer" voice command. So the consent screen
/// can't be skipped, whichever way a call starts.
struct CallFlowView: View {
    @Environment(AppViewModel.self) private var app
    @Environment(AppRouter.self) private var router
    @AppStorage(CallConsentView.agreedKey) private var hasAgreed = false
    /// Rung first; nil rings whoever is free.
    let volunteer: Volunteer?

    var body: some View {
        Group {
            if hasAgreed {
                CallView(services: app.services, volunteer: volunteer) { router.pop() }
            } else {
                CallConsentView(
                    announcements: app.services.announcements,
                    onAgree: { hasAgreed = true },
                    onCancel: { router.pop() }
                )
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden()
    }
}

/// Shown before the caller's first call. It's at the start of the feature, not added at the end,
/// so it can't be cut.
struct CallConsentView: View {
    /// Remembered on this phone once agreed.
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
                    detail: "Volunteers are strangers who signed up to help. During a call, they see what your back camera shows and hear you."
                )
                // True because LiveKit only records with its recording (egress) feature, which we never turn on.
                point(
                    systemImage: "record.circle",
                    title: "Calls are never recorded",
                    detail: "AccessAble doesn't record or save the video or audio from any call."
                )
                point(
                    systemImage: "phone.down.fill",
                    title: "You're in control",
                    detail: "You can hang up at any time."
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
                text: "Before your first call: a volunteer, who is a stranger, will see your camera and hear you. "
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
