import Foundation
import Observation

/// Main screen: quick actions and the most recent announcement.
///
/// Template for every view model in the app:
/// - `@MainActor @Observable final class`
/// - dependencies come in through `init(services:)` as protocols
/// - long-running subscriptions start in `start()`, which the view calls from `.task { }`
///   so they are cancelled automatically when the view disappears
/// - user actions are plain `func`s (async if they call services)
@MainActor
@Observable
final class HomeViewModel {
    private(set) var lastAnnouncement: AnnouncementEvent?
    private(set) var tripState: TripState = .idle
    private(set) var isDescribing = false

    @ObservationIgnored private let services: AppServices

    init(services: AppServices) {
        self.services = services
    }

    func start() async {
        await withDiscardingTaskGroup { group in
            group.addTask { [services] in
                for await event in services.announcements.deliveredEvents() {
                    await self.receive(event)
                }
            }
            group.addTask { [services] in
                for await state in services.trip.tripStates() {
                    await self.receive(state)
                }
            }
        }
    }

    func describeSurroundings() async {
        isDescribing = true
        defer { isDescribing = false }
        let text = await services.sceneDescriber.describeCurrentScene()
        await services.announcements.submit(
            AnnouncementEvent(category: .ambient, priority: .high, text: text, source: .sceneDescription)
        )
    }

    func repeatLast() async {
        await services.announcements.repeatLast()
    }

    private func receive(_ event: AnnouncementEvent) { lastAnnouncement = event }
    private func receive(_ state: TripState) { tripState = state }
}
