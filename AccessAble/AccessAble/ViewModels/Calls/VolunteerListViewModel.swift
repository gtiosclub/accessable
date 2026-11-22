import Foundation
import Observation

@MainActor
@Observable
final class VolunteerListViewModel {
    struct Row: Identifiable, Equatable {
        let id: String
        let name: String
        let isOnline: Bool
        let languages: String
        let accessibilityLabel: String
    }

    private(set) var rows: [Row] = []
    private(set) var hasLoaded = false

    @ObservationIgnored private let services: AppServices

    init(services: AppServices) {
        self.services = services
    }

    var summary: String {
        let online = rows.filter(\.isOnline).count
        return "\(online) of \(rows.count) online"
    }

    func start() async {
        for await volunteers in services.volunteers.allVolunteers() {
            receive(volunteers)
        }
    }

    private func receive(_ volunteers: [Volunteer]) {
        let now = Date()
        rows = volunteers.map { Row(volunteer: $0, now: now) }
        hasLoaded = true
    }
}

extension VolunteerListViewModel.Row {
    init(volunteer: Volunteer, now: Date) {
        let online = volunteer.isReachable(at: now)
        let languages = ListFormatter.localizedString(byJoining: volunteer.languages)
        var label = "\(volunteer.name), \(online ? "online" : "offline")"
        if !languages.isEmpty { label += ", speaks \(languages)" }
        self.init(id: volunteer.id, name: volunteer.name, isOnline: online,
                  languages: languages, accessibilityLabel: label)
    }
}

