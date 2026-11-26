import SwiftUI

/// Settings persist per Firebase UID; actual Online still requires foreground presence.
struct VolunteerHomeView: View {
    let settings: VolunteerSettingsViewModel
    let signOut: () async throws -> Void
    @State private var signingOut = false
    @State private var signOutError: String?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            Form {
                if !settings.isLoaded {
                    Section {
                        Text("Volunteer settings need to load before going online.")
                        Button("Load settings") { Task { await settings.load() } }.disabled(settings.isBusy)
                    }
                } else if !settings.isInvited {
                    Section {
                        Text("A club invitation is required to volunteer. Contact the club for approval.")
                        Button("Check invitation again") { Task { await settings.load() } }.disabled(settings.isBusy)
                    }
                }
                Section {
                    Toggle("Online by default", isOn: Binding(get: { settings.preferences.onlineByDefault }, set: { value in Task { await settings.setOnlineByDefault(value) } }))
                        .disabled(!settings.isLoaded || settings.isBusy)
                        .accessibilityHint("Automatically restores Online when the app opens, once your club invitation is approved")
                    Toggle("Online", isOn: Binding(get: { settings.isOnline }, set: { value in Task { await settings.setOnline(value) } }))
                        .disabled(!settings.isLoaded || !settings.isInvited || settings.isBusy)
                        .accessibilityHint("Your choice is remembered for the next launch. Online works only while the app is on screen.")
                    Toggle("Keep screen awake while Online", isOn: Binding(get: { settings.preferences.keepScreenAwake }, set: { value in Task { await settings.setKeepAwake(value) } }))
                        .disabled(!settings.isLoaded || settings.isBusy)
                } header: {
                    Text("Availability")
                } footer: {
                    Text("Online is on by default for approved volunteers. Your Online choice is saved. Leaving the app or locking the phone stops incoming calls; returning restores your saved choice.")
                }
                Section("Profile") {
                    TextField("Display name", text: $settings.displayName).textContentType(.name)
                        .disabled(!settings.isLoaded || settings.isBusy)
                    TextField("Languages, separated by commas", text: $settings.languageText)
                        .disabled(!settings.isLoaded || settings.isBusy)
                    Button("Save profile") { Task { await settings.saveProfile() } }
                        .disabled(!settings.isLoaded || !settings.canSaveProfile || settings.isBusy).frame(minHeight: 44)
                }
                if let message = settings.message { Text(message) }
                Section {
                    Button("Sign out", role: .destructive) {
                        signingOut = true
                        Task {
                            defer { signingOut = false }
                            do { settings.shutdown(); try await signOut() }
                            catch { signOutError = "Couldn't sign out. Try again."; await settings.setForeground(scenePhase == .active) }
                        }
                    }.disabled(signingOut || settings.isBusy).frame(minHeight: 44)
                }
                if let signOutError { Text(signOutError) }
            }
            .navigationTitle("Volunteer settings")
            .onChange(of: settings.message) { _, text in if let text { AccessibilityNotification.Announcement(text).post() } }
        }
    }
}
