import Foundation
import Observation

/// Owner: Calls (MATCH-x). Lists the volunteers a user can call. Uses placeholders until the backend lands.
@MainActor
@Observable
final class CallsViewModel {
    private(set) var volunteers: [Volunteer] = []
    private let directory: any VolunteerDirectory

    init(directory: any VolunteerDirectory) {
        self.directory = directory
    }

    convenience init(services: AppServices) {
        self.init(directory: services.volunteers)
    }

    /// Runs until the view disappears.
    func listen() async {
        for await list in directory.onlineVolunteers() {
            volunteers = list
        }
    }
}
