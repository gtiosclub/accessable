import SwiftUI

/// The volunteer's home: Live (availability, saved callers, messages), History (past calls) and
/// Profile, switched with tabs along the bottom. Settings persist per Firebase UID; actual Online
/// still requires foreground presence.
struct VolunteerHomeView: View {
    let settings: VolunteerSettingsViewModel
    let signOut: () async throws -> Void
    var pastCalls: [CallSafetySummary] = []
    var callSafety: any CallSafetyService = UnavailableCallSettings()
    var dismissPastCall: (String) -> Void = { _ in }
    /// A call is ringing over this screen: close any open report so the ring isn't hidden behind it.
    var isRinging = false
    var listenerError: String? = nil
    var retryListening: () -> Void = {}
    var callMessage: String? = nil
    var dismissCallMessage: () -> Void = {}
    /// Saved callers, chats and past calls; nil hides those sections.
    var callHelp: VolunteerCallHelpViewModel? = nil
    var services: AppServices? = nil

    @State private var tab: Tab = .live
    @State private var openChat: VolunteerChatRoute?
    @State private var signingOut = false
    @State private var signOutError: String?
    @Environment(\.scenePhase) private var scenePhase

    enum Tab: String, CaseIterable {
        case live = "Live"
        case history = "History"
        case profile = "Profile"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch tab {
                    case .live: live
                    case .history: history
                    case .profile: profile
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) {
                CapsuleTabs(selection: $tab) { tab in
                    switch tab {
                    case .live: "Your availability, saved callers and messages"
                    case .history: "Your past calls"
                    case .profile: "Your profile and settings"
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 4)
            }
            .foregroundStyle(.white)
            .background(Color.black.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(item: $openChat) { route in
                if let services { VolunteerChatScreen(route: route, services: services) }
            }
            .onChange(of: signOutError) { _, text in if let text { AccessibilityNotification.Announcement(text).post() } }
            .onChange(of: settings.message) { _, text in if let text { AccessibilityNotification.Announcement(text).post() } }
        }
    }

    // MARK: Live

    @ViewBuilder private var live: some View {
        if let listenerError {
            notice(listenerError, action: "Retry incoming calls", perform: retryListening)
        }
        if let callMessage {
            notice(callMessage, action: "Dismiss", perform: dismissCallMessage)
        }
        availabilityCard
        if let callHelp {
            @Bindable var callHelp = callHelp
            CallHelpSearchField(text: $callHelp.search)
            CallHelpSectionHeader(title: "Mutually Saved", subtitle: "People who also saved you", starred: true)
            if callHelp.mutuallySaved.isEmpty {
                emptyLine(callHelp.search.isEmpty
                          ? "Save a caller with the star in your chat. When they save you too, they show up here."
                          : "No matches.")
            } else {
                CardGroup(items: callHelp.mutuallySaved) { caller in
                    PersonRow(name: caller.name, subtitle: "Saved you too", isOnline: nil, onMessage: {
                        openChat = VolunteerChatRoute(callerID: caller.id, name: caller.name)
                    })
                }
            }
            CallHelpSectionHeader(title: "Messages")
            if let error = callHelp.inbox.errorMessage {
                emptyLine(error)
            } else if callHelp.inbox.threads.isEmpty {
                emptyLine("No messages yet. Callers can message you from Call Help.")
            } else {
                CardGroup(items: callHelp.inbox.threads) { thread in
                    PersonRow(name: thread.callerFirstName,
                              subtitle: thread.updatedAt.formatted(.relative(presentation: .named)),
                              isOnline: nil, onMessage: {
                        if let caller = ChatID.parties(of: thread.id)?.caller {
                            openChat = VolunteerChatRoute(callerID: caller, name: thread.callerFirstName)
                        }
                    })
                }
            }
        }
    }

    @ViewBuilder private var availabilityCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(get: { settings.isOnline }, set: { value in Task { await settings.setOnline(value) } })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(settings.isOnline ? "You're available" : "You're unavailable").font(.title3.bold())
                    Text(settings.isOnline ? "Callers can ring you while this app is open." : "Turn on to take calls.")
                        .font(.footnote).foregroundStyle(.white.opacity(0.85))
                }
            }
            .tint(Theme.cyan)
            .disabled(!settings.isLoaded || !settings.isInvited || settings.isBusy)
            .accessibilityHint("Your choice is remembered for the next launch. Online works only while the app is on screen.")
            if !settings.isLoaded {
                Text("Volunteer settings need to load before going online.").font(.footnote)
                Button("Load settings") { Task { await settings.load() } }
                    .buttonStyle(.pill(.outline, size: .compact)).disabled(settings.isBusy)
            } else if !settings.isInvited {
                Text("Only volunteer accounts can go online. Sign up as a volunteer to take calls.").font(.footnote)
                Button("Check again") { Task { await settings.load() } }
                    .buttonStyle(.pill(.outline, size: .compact)).disabled(settings.isBusy)
            }
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: History

    @ViewBuilder private var history: some View {
        ForEach(Array(pastCalls.enumerated()), id: \.element.id) { index, call in
            VStack(alignment: .leading, spacing: 10) {
                Text(index == 0 ? "Previous call" : "Earlier call").font(.headline).accessibilityAddTraits(.isHeader)
                CallSafetyActionsView(summary: call, service: callSafety, suspended: isRinging).id(call.id)
                Button(index == 0 ? "Dismiss previous call" : "Dismiss earlier call") { dismissPastCall(call.id) }
                    .foregroundStyle(Theme.cyan).minimumTapTarget()
            }
            .padding(14)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        if let callHelp {
            @Bindable var callHelp = callHelp
            CallHelpSearchField(text: $callHelp.search)
            CallHelpSectionHeader(title: "Call History")
            if callHelp.pastCalls.isEmpty {
                emptyLine(callHelp.search.isEmpty ? "Calls you answer show up here." : "No matches.")
            } else {
                CardGroup(items: callHelp.pastCalls) { call in
                    let name = call.otherName ?? "Caller"
                    PersonRow(name: name, subtitle: call.summary, isOnline: nil,
                              onMessage: callHelp.canMessage(callerID: call.otherID) ? {
                                  openChat = VolunteerChatRoute(callerID: call.otherID, name: name)
                              } : nil)
                    .accessibilityLabel("\(name), \(call.spokenSummary)")
                }
            }
        }
    }

    // MARK: Profile

    @ViewBuilder private var profile: some View {
        @Bindable var settings = settings
        ProfileHeader(name: settings.displayName.isEmpty ? "Your profile" : settings.displayName)
            .padding(.vertical, 8)
        Group {
            ProfileFieldRow(label: "Display name", text: $settings.displayName)
            ProfileFieldRow(label: "Location", text: $settings.location)
            ProfileFieldRow(label: "Languages", text: $settings.languageText)
            HStack {
                Text("Availability:").font(.subheadline.bold())
                Text(settings.isOnline ? "Available" : "Unavailable")
                    .font(.subheadline).foregroundStyle(Theme.cyan)
            }
            .accessibilityElement(children: .combine)
            Button(settings.isBusy ? "Saving…" : "Save profile") { Task { await settings.saveProfile() } }
                .buttonStyle(.pill(.primary))
                .disabled(!settings.canSaveProfile || !settings.canSaveDetails)
        }
        .disabled(!settings.isLoaded || settings.isBusy)

        CallHelpSectionHeader(title: "Availability")
        ChoiceList(choices: VolunteerAvailability.allCases, selection: settings.availability,
                   title: \.title) { choice in Task { await settings.setAvailability(choice) } }
            .disabled(!settings.isLoaded || settings.isBusy)
        Text("Online works only while the app is on screen. Leaving the app or locking the phone stops incoming calls.")
            .font(.footnote).foregroundStyle(.white.opacity(0.85))

        Toggle("Keep screen awake while available", isOn: Binding(
            get: { settings.preferences.keepScreenAwake },
            set: { value in Task { await settings.setKeepAwake(value) } }))
            .tint(Theme.cyan)
            .disabled(!settings.isLoaded || settings.isBusy)
            .padding(.top, 8)

        if let message = settings.message { Text(message).font(.callout) }

        Button("Sign out", role: .destructive) {
            signingOut = true
            Task {
                defer { signingOut = false }
                do { await settings.shutdownBeforeSignOut(); try await signOut() }
                catch { signOutError = "Couldn't sign out. Try again."; await settings.setForeground(scenePhase == .active) }
            }
        }
        .buttonStyle(.pill(.destructive))
        .disabled(signingOut || settings.isBusy)
        .padding(.top, 8)
        if let signOutError { Text(signOutError).font(.callout) }
    }

    // MARK: Pieces

    private func notice(_ text: String, action: String, perform: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text).font(.callout)
            Button(action, action: perform).foregroundStyle(Theme.cyan).minimumTapTarget()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func emptyLine(_ text: String) -> some View {
        Text(text).font(.subheadline).foregroundStyle(.white.opacity(0.85))
    }
}

#Preview {
    VolunteerHomeView(
        settings: VolunteerSettingsViewModel(
            profile: UserProfile(userID: "placeholder-volunteer", role: .volunteer, displayName: "Catherine",
                                 languages: ["English"], createdAt: .now),
            store: PlaceholderVolunteerSettings(), profiles: PlaceholderUserProfileStore(),
            presence: PlaceholderPresenceService(), screen: ScreenAwakeController()),
        signOut: {}, callHelp: VolunteerCallHelpViewModel(services: .preview), services: .preview
    )
    .preferredColorScheme(.dark)
}
