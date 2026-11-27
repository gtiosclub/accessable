import SwiftUI

/// The volunteer's home: Live (availability, saved callers, messages), History (past calls) and
/// Profile, switched with tabs along the bottom. Settings persist per Firebase UID; actual Online
/// still requires foreground presence.
struct VolunteerHomeView: View {
    let settings: VolunteerSettingsViewModel
    let signOut: () async throws -> Void
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
        if let callHelp {
            @Bindable var callHelp = callHelp
            CallHelpSearchField(text: $callHelp.search)
            CallHelpSectionHeader(title: "Mutually Saved", subtitle: "People who also saved you", starred: true)
            if !callHelp.mutuallySaved.isEmpty {
                CardGroup(items: callHelp.mutuallySaved) { caller in
                    PersonRow(userID: caller.id, name: caller.name, subtitle: "", isOnline: nil, onMessage: {
                        openChat = VolunteerChatRoute(callerID: caller.id, name: caller.name)
                    })
                }
            }
            if let error = callHelp.inbox.errorMessage {
                Text(error).font(.subheadline)
            } else if !callHelp.inbox.threads.isEmpty {
                CallHelpSectionHeader(title: "Messages")
                CardGroup(items: callHelp.inbox.threads) { thread in
                    let caller = ChatID.parties(of: thread.id)?.caller
                    PersonRow(userID: caller, name: thread.callerFirstName,
                              subtitle: thread.updatedAt.formatted(.relative(presentation: .named)),
                              isOnline: nil, onMessage: {
                        if let caller { openChat = VolunteerChatRoute(callerID: caller, name: thread.callerFirstName) }
                    })
                }
            }
        }
    }

    // MARK: History

    @ViewBuilder private var history: some View {
        if let callHelp {
            @Bindable var callHelp = callHelp
            CallHelpSearchField(text: $callHelp.search)
            CallHelpSectionHeader(title: "Call History")
            if !callHelp.pastCalls.isEmpty {
                CardGroup(items: callHelp.pastCalls) { call in
                    let name = call.otherName ?? "Caller"
                    PersonRow(userID: call.otherID, name: name, subtitle: call.summary, isOnline: nil,
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
        ProfileHeader(name: settings.displayName.isEmpty ? "Your profile" : settings.displayName,
                      userID: settings.userID)
            .padding(.vertical, 8)
        Group {
            ProfileFields {
                ProfileFieldRow(label: "Display name", text: $settings.displayName)
                ProfileFieldRow(label: "Location", text: $settings.location)
                ProfileFieldRow(label: "Languages", text: $settings.languageText)
                ProfileMenuRow(label: "Availability", value: settings.isOnline ? "Available" : "Unavailable",
                               choices: ["Available", "Unavailable"]) { choice in
                    Task { await settings.setOnline(choice == "Available") }
                }
                .disabled(!settings.isInvited)
            }
            Button(settings.isBusy ? "Saving…" : "Save profile") { Task { await settings.saveProfile() } }
                .buttonStyle(.pill(.primary))
                .disabled(!settings.canSaveProfile || !settings.canSaveDetails)
        }
        .disabled(!settings.isLoaded || settings.isBusy)

        CallHelpSectionHeader(title: "Availability")
        ChoiceList(choices: VolunteerAvailability.allCases, selection: settings.availability,
                   title: \.title) { choice in Task { await settings.setAvailability(choice) } }
            .disabled(!settings.isLoaded || settings.isBusy)

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
