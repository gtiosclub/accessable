import FirebaseFirestore
import Foundation
import Testing
@testable import AccessAble

@MainActor
struct CallHelpTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func settle() async {
        for _ in 0..<30 { await Task.yield() }
    }

    private func volunteer(_ id: String, online: Bool) -> Volunteer {
        Volunteer(id: id, name: id.capitalized, availableUntil: "", isOnline: online, lastSeen: now)
    }

    // MARK: Availability schedule

    @Test func weekdayScheduleIsOnlyMondayToFridayNineToFive() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        func at(_ weekday: Int, _ hour: Int) throws -> Date {
            // 2026-11-23 is a Monday.
            try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 22 + weekday - 1, hour: hour, minute: 30)))
        }
        let weekdays = VolunteerAvailability.weekdays
        #expect(weekdays.isScheduledOnline(at: try at(2, 9), calendar: calendar) == true)
        #expect(weekdays.isScheduledOnline(at: try at(6, 16), calendar: calendar) == true)
        #expect(weekdays.isScheduledOnline(at: try at(2, 8), calendar: calendar) == false)
        #expect(weekdays.isScheduledOnline(at: try at(4, 17), calendar: calendar) == false)
        #expect(weekdays.isScheduledOnline(at: try at(7, 12), calendar: calendar) == false)
        #expect(weekdays.isScheduledOnline(at: try at(1, 12), calendar: calendar) == false)
        #expect(VolunteerAvailability.always.isScheduledOnline(at: now) == true)
        #expect(VolunteerAvailability.manual.isScheduledOnline(at: now) == nil)
    }

    // MARK: Caller's Call Help

    @Test func liveSplitsOnlineVolunteersIntoSavedAndOthers() async throws {
        var services = AppServices.preview
        services.volunteers = PlaceholderVolunteerDirectory(volunteers: [
            volunteer("ana", online: true), volunteer("bo", online: true), volunteer("cy", online: false),
        ])
        services.saves = PlaceholderSavesService(saved: [
            SavedPerson(id: "ana", name: "Ana", isMutual: true),
            SavedPerson(id: "cy", name: "Cy", isMutual: false),
        ])
        let model = CallHelpViewModel(services: services, now: { self.now })
        let loading = Task { await model.start() }
        defer { loading.cancel() }
        await settle()

        #expect(model.liveSaved.map(\.id) == ["ana"])
        #expect(model.liveOthers.map(\.id) == ["bo"])
        #expect(model.mutuallySaved.map(\.id) == ["ana"])
        #expect(model.savedOnly.map(\.id) == ["cy"])
        #expect(model.isSaved(volunteer("ana", online: true)))

        model.search = "an"
        #expect(model.mutuallySaved.map(\.id) == ["ana"])
        model.search = "zz"
        #expect(model.mutuallySaved.isEmpty)
    }

    @Test func pastCallsTakeNamesFromTheDirectory() async {
        var services = AppServices.preview
        services.volunteers = PlaceholderVolunteerDirectory(volunteers: [volunteer("ana", online: false)])
        services.callHistory = PlaceholderCallHistory(calls: [
            PastCall(id: "c1", otherID: "ana", startedAt: now, duration: 56 * 60),
            PastCall(id: "c2", otherID: "gone", startedAt: now, duration: 30),
        ])
        let model = CallHelpViewModel(services: services, now: { self.now })
        let loading = Task { await model.start() }
        defer { loading.cancel() }
        await settle()

        #expect(model.pastCalls.map(\.name) == ["Ana", "Volunteer"])
        #expect(model.pastCalls[0].call.summary.hasSuffix("· 56 minutes"))
        #expect(model.pastCalls[1].call.summary.hasSuffix("· 1 minute"))
    }

    @Test func starTogglesAndFollowsTheService() async {
        let service = PlaceholderSavesService(names: ["ana": "Ana"])
        let star = SaveStarModel(service: service, personID: "ana")
        let listening = Task { await star.start() }
        defer { listening.cancel() }
        await settle()
        #expect(!star.isSaved)
        await star.toggle()
        await settle()
        #expect(star.isSaved)
        await star.toggle()
        await settle()
        #expect(!star.isSaved)
    }

    // MARK: Volunteer side

    @Test func volunteerMayMessageOnlyMutualSavesOrCallersWhoWrote() async {
        var services = AppServices.preview
        services.saves = PlaceholderSavesService(saved: [
            SavedPerson(id: "alice", name: "Alice", isMutual: true),
            SavedPerson(id: "bob", name: "Bob", isMutual: false),
        ])
        let model = VolunteerCallHelpViewModel(services: services)
        let loading = Task { await model.start() }
        defer { loading.cancel() }
        await settle()

        #expect(model.mutuallySaved.map(\.id) == ["alice"])
        #expect(model.canMessage(callerID: "alice"))
        #expect(!model.canMessage(callerID: "bob"))
    }

    // MARK: Firestore parsing

    @Test func onlyAnsweredAndEndedCallsBecomeHistory() {
        let accepted = Timestamp(date: now)
        let ended = Timestamp(date: now.addingTimeInterval(125))
        let base: [String: Any] = [
            "callerId": "alice", "volunteerId": "vic", "status": "ended",
            "acceptedAt": accepted, "updatedAt": ended, "callerFirstName": "Alice",
        ]
        let asVolunteer = PastCall(id: "c", firestoreData: base, role: .volunteer)
        #expect(asVolunteer?.otherID == "alice")
        #expect(asVolunteer?.otherName == "Alice")
        #expect(asVolunteer?.duration == 125)
        let asCaller = PastCall(id: "c", firestoreData: base, role: .caller)
        #expect(asCaller?.otherID == "vic")
        #expect(asCaller?.otherName == nil)

        var declined = base; declined["status"] = "declined"
        #expect(PastCall(id: "c", firestoreData: declined, role: .caller) == nil)
        var legacy = base; legacy.removeValue(forKey: "acceptedAt")
        #expect(PastCall(id: "c", firestoreData: legacy, role: .caller) == nil)
    }

    @Test func profileDetailsLimitsMatchTheRules() {
        #expect(ProfileDetails(location: String(repeating: "x", count: 80)).isValid)
        #expect(!ProfileDetails(location: String(repeating: "x", count: 81)).isValid)
        #expect(ProfileDetails(condition: String(repeating: "x", count: 200)).isValid)
        #expect(!ProfileDetails(condition: String(repeating: "x", count: 201)).isValid)
    }

    @Test func savingCallerProfileKeepsNameAndStoresDetails() async throws {
        let profile = UserProfile(userID: PlaceholderAuthService.sampleUser.id, role: .caller,
                                  displayName: "Alice", languages: ["English"], createdAt: now)
        let store = PlaceholderUserProfileStore(profiles: [profile])
        let model = CallerProfileViewModel(auth: PlaceholderAuthService(), profiles: store)
        await model.load()
        #expect(model.isLoaded)
        model.location = "Atlanta, GA"
        model.condition = "Partially sighted, right eye"
        #expect(model.canSave)
        await model.save()
        let saved = try await store.load(userID: profile.userID)
        #expect(saved?.details.location == "Atlanta, GA")
        #expect(saved?.details.condition == "Partially sighted, right eye")
        #expect(saved?.displayName == "Alice")
        #expect(model.message == "Profile saved.")
    }
}

struct VideoBrightnessMeterTests {
    @Test func switchesOnlyPastEitherThreshold() {
        #expect(!VideoBrightnessMeter.isBright(luma: 140, wasBright: false))
        #expect(VideoBrightnessMeter.isBright(luma: 160, wasBright: false))
        // Between the thresholds it keeps what it was, so the glow doesn't flicker.
        #expect(VideoBrightnessMeter.isBright(luma: 130, wasBright: true))
        #expect(!VideoBrightnessMeter.isBright(luma: 110, wasBright: true))
    }
}
