import SwiftUI

/// Volunteer landing screen. Availability and incoming calls are added by MATCH tasks.
struct VolunteerHomeView: View {
    let profile: UserProfile
    let signOut: () async throws -> Void
    @State private var errorMessage: String?
    @State private var signingOut = false
    @State private var availability: VolunteerAvailabilityViewModel
    
    init(profile: UserProfile, presence: any PresenceService, signOut: @escaping () async throws -> Void) {
        self.profile = profile
        self.signOut = signOut
        _availability = State(initialValue: VolunteerAvailabilityViewModel(presence: presence))
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Your volunteer account") {
                    Text(profile.displayName).font(.headline)
                    Text(profile.languages.joined(separator: ", "))
                    Label("Volunteer", systemImage: "person.fill")
                }
                Section {
                    Toggle("Online", isOn: Binding(
                        get: { availability.isOnline },
                        set: { newValue in Task { await availability.setOnline(newValue) } }
                    ))
                    .disabled(availability.isUpdating)
                    .minimumTapTarget()
                    .accessibilityHint("When on, callers can see and call you while AccessAble is open on screen")
                    if let message = availability.errorMessage {
                        Text(message).foregroundStyle(.red)
                    }
                } footer: {
                    Text("You stay online only while AccessAble is open on an unlocked phone. Leaving the app or locking your phone turns this off.")
                }
                Section {
                    Button("Sign out") {
                        signingOut = true
                        Task {
                            defer { signingOut = false }
                            do { try await signOut() }
                            catch { errorMessage = "Couldn't sign out. Please try again." }
                        }
                    }
                    .disabled(signingOut)
                    .frame(minHeight: 44)
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
            .navigationTitle("Volunteer home")
            .task { await availability.start() }
        }
        .onChange(of: availability.errorMessage) { _, message in
            if let message { AccessibilityNotification.Announcement(message).post() }
        }
    }
}
