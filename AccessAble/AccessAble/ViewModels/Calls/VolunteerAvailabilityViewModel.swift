import Foundation
import Observation


@MainActor
@Observable
final class VolunteerAvailabilityViewModel {
    private(set) var isOnline = false
    private(set) var isUpdating = false
    private(set) var errorMessage: String?

    @ObservationIgnored private let presence: any PresenceService

    init(presence: any PresenceService) {
        self.presence = presence
    }

    func start() async {
        for await online in presence.onlineStates() {
            isOnline = online
        }
    }

    func setOnline(_ online: Bool) async {
        isUpdating = true
        errorMessage = nil
        defer { isUpdating = false }
        do {
            try await presence.setOnline(online)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? "Couldn't change your status. Check your connection and try again."
        }
    }
}
