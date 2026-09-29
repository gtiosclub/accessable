import SwiftUI

@main
struct AccessAbleApp: App {
    @State private var app = AppViewModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
        }
    }
}
