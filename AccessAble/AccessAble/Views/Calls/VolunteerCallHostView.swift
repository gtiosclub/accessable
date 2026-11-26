import SwiftUI

/// Above volunteer navigation, so pushing another app screen does not lose the ring listener.
struct VolunteerCallHostView: View {
    let profile: UserProfile
    let services: AppServices
    let signOut: () async throws -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: IncomingCallViewModel
    @State private var settings: VolunteerSettingsViewModel

    init(profile: UserProfile, services: AppServices, signOut: @escaping () async throws -> Void) {
        self.profile = profile
        self.services = services
        self.signOut = signOut
        _settings = State(initialValue: VolunteerSettingsViewModel(
            profile: profile, store: services.volunteerSettings, profiles: services.userProfiles,
            presence: services.presence, screen: ScreenAwakeController()
        ))
        _model = State(initialValue: IncomingCallViewModel(
            volunteerID: profile.userID, source: services.incomingCalls,
            signaling: services.callSignaling, video: services.videoCall,
            announcements: services.announcements, alerts: IncomingCallAlerts(haptics: services.haptics)
        ))
    }

    private struct ListenKey: Equatable {
        let active: Bool
        let attempt: Int
    }

    var body: some View {
        ZStack {
            VolunteerHomeView(settings: settings, signOut: signOut)
                .safeAreaInset(edge: .bottom) {
                    if let summary = model.lastCallForSafety, model.call == nil {
                        VStack {
                            Text("Previous call").font(.headline)
                            CallSafetyActionsView(summary: summary, service: services.callSafety).id(summary.id)
                            Button("Dismiss previous call") { model.dismissSafetySummary() }.frame(minHeight: 44)
                        }.padding().background(.black)
                    }
                    if let error = model.listenerError {
                        VStack {
                            Text(error)
                            Button("Retry incoming calls") { model.retryListening() }.frame(minHeight: 44)
                        }.padding().background(.black)
                    }
                    if let message = model.message {
                        VStack {
                            Text(message)
                            Button("Dismiss") { model.dismissMessage() }.frame(minHeight: 44)
                        }.padding().background(.black)
                    }
                }
                .allowsHitTesting(model.call == nil)
                .accessibilityHidden(model.call != nil)
            if model.call != nil {
                IncomingVolunteerCallView(model: model, video: services.videoCall)
                    .zIndex(1)
            }
        }
        .task(id: ListenKey(active: scenePhase == .active, attempt: model.listenerAttempt)) {
            if scenePhase == .active { await model.listen() }
            else { model.suspendListening() }
        }
        .task { await settings.load() }
        .task { await settings.observePresence() }
        .task(id: scenePhase) { await settings.setForeground(scenePhase == .active) }
        .onDisappear { model.shutdown(); settings.shutdown() }
    }
}

#Preview("Incoming call (placeholders)") {
    VolunteerCallHostView(
        profile: UserProfile(userID: "placeholder-volunteer", role: .volunteer,
                             displayName: "Sam", languages: ["English"], createdAt: .now),
        services: incomingCallPreviewServices(), signOut: {}
    ).preferredColorScheme(.dark)
}

@MainActor
private func incomingCallPreviewServices() -> AppServices {
    var services = AppServices.preview
    services.incomingCalls = PlaceholderIncomingCalls(
        call: IncomingCall(id: "preview-incoming", callerFirstName: "Alex", ringingSince: .now)
    )
    return services
}
