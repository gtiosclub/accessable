import SwiftUI

/// Volunteer landing screen. Availability and incoming calls are added by MATCH tasks.
struct VolunteerHomeView: View {
    let profile: UserProfile
    let signOut: () async throws -> Void
    @State private var errorMessage: String?
    @State private var signingOut = false

    var body: some View {
        NavigationStack {
            List {
                Section("Your volunteer account") {
                    Text(profile.displayName).font(.headline)
                    Text(profile.languages.joined(separator: ", "))
                    Label("Volunteer", systemImage: "person.fill")
                }
                Section {
                    Text("You're signed in as a volunteer. Call availability will be added in the matching feature.")
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
        }
    }
}
