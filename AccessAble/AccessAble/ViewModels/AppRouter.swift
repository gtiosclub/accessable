import Foundation
import Observation

/// Screens reachable from the landing page.
enum AppRoute: Hashable {
    case search
    case place(SamplePlace)
    case routes(SamplePlace, RoutePlanMode)
    case trip(TripPlan)
    case settings
    case callHelp
    case chat(Volunteer)
    /// The pre-redesign feature screens: computer vision, maps, haptics, commands.
    case developerTools
    /// The original feature screens (camera guidance, live trip), opened by App Shortcuts.
    case feature(AppDestination)
}

/// Navigation path for the main flow. Injected with `.environment(router)`.
@MainActor
@Observable
final class AppRouter {
    var path: [AppRoute] = []

    func push(_ route: AppRoute) {
        path.append(route)
    }

    func pop() {
        _ = path.popLast()
    }

    func popToRoot() {
        path.removeAll()
    }
}
