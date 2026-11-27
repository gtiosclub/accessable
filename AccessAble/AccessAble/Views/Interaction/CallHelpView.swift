import SwiftUI

/// Owner: User Interaction (3.x). The caller's volunteers: who's online now (Live), starred
/// volunteers and past calls (History), and their own profile (Profile).
struct CallHelpView: View {
    @Environment(AppRouter.self) private var router
    @Environment(AppViewModel.self) private var app
    @State private var tab: Tab = .live
    @State private var model: CallHelpViewModel?
    @State private var profile: CallerProfileViewModel?

    enum Tab: String, CaseIterable {
        case live = "Live"
        case history = "History"
        case profile = "Profile"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ScreenHeader(title: "Call Help") { router.pop() }
                CapsuleTabs(selection: $tab) { tab in
                    switch tab {
                    case .live: "Volunteers available now"
                    case .history: "Saved volunteers and past calls"
                    case .profile: "Your profile"
                    }
                }
                if let model {
                    if let error = model.errorMessage {
                        HStack {
                            Text(error).font(.callout)
                            Spacer()
                            Button("Dismiss") { model.dismissError() }
                                .foregroundStyle(Theme.cyan).minimumTapTarget()
                        }
                        .foregroundStyle(.white)
                    }
                    switch tab {
                    case .live: LiveTab(model: model, router: router)
                    case .history: HistoryTab(model: model, router: router)
                    case .profile:
                        if let profile { CallerProfileTab(model: profile) }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color.black.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .accessibilityAction(.escape) { router.pop() }
        .task {
            if model == nil {
                model = CallHelpViewModel(services: app.services)
                profile = CallerProfileViewModel(auth: app.services.auth, profiles: app.services.userProfiles)
            }
            async let lists: Void = model?.start() ?? ()
            async let me: Void = profile?.load() ?? ()
            _ = await (lists, me)
        }
    }
}

private struct LiveTab: View {
    let model: CallHelpViewModel
    let router: AppRouter

    var body: some View {
        if !model.hasLoadedVolunteers {
            ProgressView("Loading volunteers")
                .tint(.white).foregroundStyle(.white)
                .frame(maxWidth: .infinity).padding(.top, 40)
        } else if model.liveSaved.isEmpty && model.liveOthers.isEmpty {
            Text("No volunteers are online right now.")
                .font(.title3).foregroundStyle(.white)
                .padding(.top, 24)
        } else {
            if !model.liveSaved.isEmpty {
                CallHelpSectionHeader(title: "Saved")
                volunteerCard(model.liveSaved)
            }
            if !model.liveOthers.isEmpty {
                CallHelpSectionHeader(title: model.liveSaved.isEmpty ? "Available now" : "Others")
                volunteerCard(model.liveOthers)
            }
        }
    }

    private func volunteerCard(_ volunteers: [Volunteer]) -> some View {
        CardGroup(items: volunteers) { volunteer in
            PersonRow(name: volunteer.name, subtitle: subtitle(volunteer), isOnline: true,
                      onCall: { router.push(.call(volunteer)) },
                      onMessage: { router.push(.chat(volunteer)) })
        }
    }

    private func subtitle(_ volunteer: Volunteer) -> String {
        if !volunteer.availableUntil.isEmpty { return volunteer.availableUntil }
        if !volunteer.languages.isEmpty {
            return "Speaks " + ListFormatter.localizedString(byJoining: volunteer.languages)
        }
        return "Online now"
    }
}

private struct HistoryTab: View {
    @Bindable var model: CallHelpViewModel
    let router: AppRouter

    var body: some View {
        CallHelpSearchField(text: $model.search)
            .padding(.top, 4)

        CallHelpSectionHeader(title: "Mutually Saved", subtitle: "People who also saved you", starred: true)
        if model.mutuallySaved.isEmpty {
            emptyLine(model.search.isEmpty
                      ? "Save a volunteer with the star in your chat. When they save you too, they show up here."
                      : "No matches.")
        } else {
            CardGroup(items: model.mutuallySaved) { volunteerRow($0) }
        }

        if !model.savedOnly.isEmpty {
            CallHelpSectionHeader(title: "Saved")
            CardGroup(items: model.savedOnly) { volunteerRow($0) }
        }

        CallHelpSectionHeader(title: "Call History")
        if model.pastCalls.isEmpty {
            emptyLine(model.search.isEmpty ? "Your answered calls show up here." : "No matches.")
        } else {
            CardGroup(items: model.pastCalls) { row in
                PersonRow(
                    name: row.name, subtitle: row.call.summary,
                    isOnline: row.volunteer.map(model.isOnline),
                    onCall: row.volunteer.flatMap { volunteer in
                        model.isOnline(volunteer) ? { router.push(.call(volunteer)) } : nil
                    },
                    onMessage: row.volunteer.map { volunteer in { router.push(.chat(volunteer)) } }
                )
                .accessibilityLabel("\(row.name), \(row.call.spokenSummary)")
            }
        }
    }

    private func volunteerRow(_ volunteer: Volunteer) -> some View {
        let online = model.isOnline(volunteer)
        return PersonRow(
            name: volunteer.name, subtitle: online ? "Online now" : "Offline", isOnline: online,
            onCall: online ? { router.push(.call(volunteer)) } : nil,
            onMessage: { router.push(.chat(volunteer)) }
        )
    }

    private func emptyLine(_ text: String) -> some View {
        Text(text).font(.subheadline).foregroundStyle(.white.opacity(0.85))
    }
}

private struct CallerProfileTab: View {
    @Bindable var model: CallerProfileViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ProfileHeader(name: model.displayName.isEmpty ? "Your profile" : model.displayName)
                .padding(.vertical, 8)
            if model.isLoaded {
                ProfileFieldRow(label: "Display name", text: $model.displayName)
                ProfileFieldRow(label: "Location", text: $model.location)
                ProfileFieldRow(label: "Condition", text: $model.condition, axis: .vertical)
                Text("Volunteers see your first name. Your location and condition stay private for now.")
                    .font(.footnote).foregroundStyle(.white.opacity(0.85))
                Button(model.isSaving ? "Saving…" : "Save profile") { Task { await model.save() } }
                    .buttonStyle(.pill(.primary))
                    .disabled(!model.canSave)
            }
            if let message = model.message {
                Text(message).font(.callout).foregroundStyle(.white)
            }
        }
        .onChange(of: model.message) { _, text in
            if let text { AccessibilityNotification.Announcement(text).post() }
        }
    }
}

#Preview {
    NavigationStack {
        CallHelpView()
    }
    .environment(AppRouter())
    .environment(AppViewModel.preview)
    .preferredColorScheme(.dark)
}
