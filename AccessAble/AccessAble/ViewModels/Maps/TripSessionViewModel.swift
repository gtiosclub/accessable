import Foundation
import Observation

/// Owner: Maps (2.x) + Interaction (3.x). State for the redesigned trip screen.
/// Front end only: announcements come from `SampleContent` and voice commands are simulated.
@MainActor
@Observable
final class TripSessionViewModel {
    let plan: TripPlan
    private(set) var announcements: [TripAnnouncement]
    var isMicMuted = true
    var isPaused = false
    var isRouteBlocked = false
    var showsMap = false

    /// How many announcements stay on screen; older ones scroll off.
    static let visibleAnnouncementLimit = 3

    init(plan: TripPlan, announcements: [TripAnnouncement] = SampleContent.initialAnnouncements) {
        self.plan = plan
        self.announcements = Array(announcements.suffix(Self.visibleAnnouncementLimit))
    }

    var latestAnnouncement: TripAnnouncement? { announcements.last }

    func add(_ announcement: TripAnnouncement) {
        announcements.append(announcement)
        if announcements.count > Self.visibleAnnouncementLimit {
            announcements.removeFirst(announcements.count - Self.visibleAnnouncementLimit)
        }
    }

    /// Shows the sample response for a command. Returns false for commands that open other UI.
    @discardableResult
    func run(_ command: VoiceCommandHint) -> Bool {
        switch command {
        case .pauseTrip:
            pause()
            return true
        case .callHelp:
            return false
        default:
            guard let response = command.sampleResponse else { return false }
            add(response)
            return true
        }
    }

    func pause() {
        isRouteBlocked = false
        isPaused = true
    }

    func resume() {
        isPaused = false
        isRouteBlocked = false
    }

    func simulateBlockedRoute() {
        isPaused = false
        isRouteBlocked = true
    }

    func reroute() {
        isRouteBlocked = false
        add(TripAnnouncement(text: "New route: turn right in 20 ft, then walk straight", kind: .info))
    }

    var destinationName: String { plan.place.name }
}
