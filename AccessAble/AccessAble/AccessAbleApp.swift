import FirebaseCore
import SwiftUI

@main
struct AccessAbleApp: App {
    @State private var app = AppViewModel()

    init() {
        FirebaseApp.configure()
        _app = State(initialValue: AppViewModel())
    }
    
    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
        }
    }
}
