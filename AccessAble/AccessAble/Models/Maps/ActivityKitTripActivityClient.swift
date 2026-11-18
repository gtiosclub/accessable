import ActivityKit
import Foundation
import os

private let log = Logger(subsystem: "AccessAble", category: "LiveActivity")

/// Owner: Maps + Location (2.x). Puts the trip on the lock screen and in the Dynamic Island,
/// drawn by the widget extension's `TripLiveActivity`. Updated locally, never by push.
actor ActivityKitTripActivityClient: TripActivityClient {
    /// Long enough to read "Arrived" after putting the phone away, without the system default of
    /// up to four hours of an arrived trip on the lock screen.
    private static let arrivedDismissalDelay: TimeInterval = 5 * 60

    /// The id rather than the activity: `Activity` isn't Sendable, so one stored here couldn't be
    /// awaited on from inside the actor. Kept after a delayed end, so ending the trip can still dismiss it.
    private var activityID: String?

    func start(
        _ attributes: TripActivityAttributes, state: TripActivityAttributes.ContentState, staleDate: Date?
    ) async throws {
        // a new trip straight after arriving replaces the arrived card rather than sitting beside it, and clears it
        // even when Live Activities have since been turned off
        await Self.activity(id: activityID)?.end(nil, dismissalPolicy: .immediate)
        activityID = nil
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { throw TripActivityStartError.activitiesDisabled }
        do {
            activityID = try Activity.request(
                attributes: attributes, content: ActivityContent(state: state, staleDate: staleDate), pushType: nil
            ).id
        } catch ActivityAuthorizationError.visibility {
            throw TripActivityStartError.notInForeground
        }
    }

    func update(_ state: TripActivityAttributes.ContentState, staleDate: Date?) async {
        guard let activity = Self.activity(id: activityID) else {
            forgetDismissed()
            return
        }
        await activity.update(ActivityContent(state: state, staleDate: staleDate))
    }

    func end(_ state: TripActivityAttributes.ContentState, immediately: Bool) async {
        let policy: ActivityUIDismissalPolicy = immediately
            ? .immediate : .after(.now.addingTimeInterval(Self.arrivedDismissalDelay))
        guard let activity = Self.activity(id: activityID) else {
            forgetDismissed()
            return
        }
        await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: policy)
        if immediately { activityID = nil }
    }

    func endAll() async {
        for activity in Activity<TripActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        activityID = nil
    }

    /// The user swiped it off the lock screen, or the system dismissed it; nothing to update until the next trip.
    private func forgetDismissed() {
        guard activityID != nil else { return }
        log.info("The trip's Live Activity was dismissed")
        activityID = nil
    }

    /// Static, so the activity it returns isn't tied to the actor and can be awaited on.
    private static func activity(id: String?) -> Activity<TripActivityAttributes>? {
        Activity<TripActivityAttributes>.activities.first { $0.id == id }
    }
}
