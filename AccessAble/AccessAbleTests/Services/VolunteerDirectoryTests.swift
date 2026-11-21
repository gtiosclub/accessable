import Foundation
import Testing
@testable import AccessAble

@MainActor
struct VolunteerDirectoryTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func reachableVolunteersComeFirstThenByNameIgnoringCase() {
        let volunteers = [
            Volunteer(id: "zoe", name: "zoe", availableUntil: "", isOnline: false, lastSeen: now),
            Volunteer(id: "stale", name: "Amy", availableUntil: "", isOnline: true,
                      lastSeen: now.addingTimeInterval(-120)),
            Volunteer(id: "bea", name: "Bea", availableUntil: "", isOnline: true, lastSeen: now),
            Volunteer(id: "al", name: "al", availableUntil: "", isOnline: true, lastSeen: now),
            Volunteer(id: "cy", name: "Cy", availableUntil: "", isOnline: false, lastSeen: now),
        ]

        let sorted = volunteers.sortedForDirectory(at: now)

        #expect(sorted.map(\.id) == ["al", "bea", "stale", "cy", "zoe"])
    }

    @Test func onlineRowLabelIncludesLanguages() {
        let volunteer = Volunteer(id: "sam", name: "Sam", availableUntil: "", isOnline: true,
                                  lastSeen: now, languages: ["English"])

        let row = VolunteerListViewModel.Row(volunteer: volunteer, now: now)

        #expect(row.isOnline)
        #expect(row.accessibilityLabel == "Sam, online, speaks English")
    }

    @Test func offlineRowLabelWithoutLanguages() {
        let volunteer = Volunteer(id: "sam", name: "Sam", availableUntil: "", isOnline: false, lastSeen: now)

        let row = VolunteerListViewModel.Row(volunteer: volunteer, now: now)

        #expect(!row.isOnline)
        #expect(row.accessibilityLabel == "Sam, offline")
    }
}
