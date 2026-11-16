import FirebaseCore
import SwiftUI

@main
struct AccessAbleApp: App {
    @State private var app: AppViewModel

    init() {
        // The config file is kept out of git, so a checkout without it runs on the placeholder
        // sign-in instead of crashing here.
        if Bundle.main.url(forResource: "GoogleService-Info", withExtension: "plist") != nil {
            FirebaseApp.configure()
        }
        _app = State(initialValue: AppViewModel())
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
        }
    }
}
