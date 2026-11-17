import ActivityKit
import Foundation

/// Owner: Maps + Location (2.x). Puts the trip on the lock screen and in the Dynamic Island,
/// drawn by the widget extension's `TripLiveActivity`. Updated locally, never by push.
actor ActivityKitTripActivityClient: TripActivityClient {
    enum StartError: LocalizedError {
        case activitiesDisabled

        var errorDescription: String? { "Live Activities are turned off for AccessAble." }
    }

    /// The id rather than the activity, which isn't Sendable and so can't be awaited on from inside the actor.
    private var activityID: String?

    func start(_ attributes: TripActivityAttributes, state: TripActivityAttributes.ContentState) async throws {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { throw StartError.activitiesDisabled }
        // one left by a launch that ended mid-trip would otherwise sit beside this one for hours
        for leftover in Activity<TripActivityAttributes>.activities {
            await leftover.end(nil, dismissalPolicy: .immediate)
        }
        activityID = try Activity.request(
            attributes: attributes, content: ActivityContent(state: state, staleDate: nil), pushType: nil
        ).id
    }

    func update(_ state: TripActivityAttributes.ContentState) async {
        await Self.activity(id: activityID)?.update(ActivityContent(state: state, staleDate: nil))
    }

    func end(_ state: TripActivityAttributes.ContentState, immediately: Bool) async {
        await Self.activity(id: activityID)?.end(
            ActivityContent(state: state, staleDate: nil), dismissalPolicy: immediately ? .immediate : .default
        )
        activityID = nil
    }

    private static func activity(id: String?) -> Activity<TripActivityAttributes>? {
        Activity<TripActivityAttributes>.activities.first { $0.id == id }
    }
}
