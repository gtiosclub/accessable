import Foundation
import Testing
@testable import AccessAble

struct TripActivityAttributesTests {
    // ActivityKit sends the state to the widget as JSON
    @Test(arguments: [
        TripActivityAttributes.ContentState(
            status: .active,
            instruction: "Turn left onto Ferst Drive",
            distance: "150 ft",
            spokenDistance: "150 feet",
            symbolName: "arrow.turn.up.left",
            arrival: Date(timeIntervalSinceReferenceDate: 800_000_000)
        ),
        TripActivityAttributes.ContentState(
            status: .offRoute,
            instruction: "Off route. Finding a new route.",
            distance: nil,
            spokenDistance: nil,
            symbolName: "exclamationmark.triangle.fill",
            arrival: nil
        ),
    ])
    func contentStateSurvivesJSON(_ state: TripActivityAttributes.ContentState) throws {
        let data = try JSONEncoder().encode(state)
        #expect(try JSONDecoder().decode(TripActivityAttributes.ContentState.self, from: data) == state)
    }

    // MARK: VoiceOver

    private static let timeZone = TimeZone(identifier: "America/New_York")!
    private static let time = Date.FormatStyle(
        date: .omitted, time: .shortened, locale: Locale(identifier: "en_US"), timeZone: timeZone
    )

    private func label(
        _ status: TripActivityAttributes.ContentState.Status, _ instruction: String = "Turn left onto Ferst Drive",
        distance: (written: String, spoken: String)? = ("150 ft", "150 feet"), arrival: Date? = nil,
        isStale: Bool = false
    ) -> String {
        TripActivityAttributes.ContentState(
            status: status, instruction: instruction, distance: distance?.written, spokenDistance: distance?.spoken,
            symbolName: "arrow.turn.up.left",
            arrival: arrival
        ).accessibilityLabel(destinationName: "Clough Commons", isStale: isStale, arrivalTime: Self.time)
    }

    @Test
    func activeReadsTheTurnDistanceAndArrivalAsOneSentence() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.timeZone
        let afternoon = DateComponents(year: 2026, month: 11, day: 17, hour: 15, minute: 42)
        let arrival = try #require(calendar.date(from: afternoon))
        // en_US puts a narrow no-break space before PM
        #expect(label(.active, arrival: arrival)
            == "Turn left onto Ferst Drive, in 150 feet. Arrive at 3:42\u{202F}PM.")
    }

    @Test
    func activeWithoutAnArrivalTime() {
        #expect(label(.active) == "Turn left onto Ferst Drive, in 150 feet.")
    }

    @Test
    func theDistanceIsReadInWordsNotAbbreviations() {
        #expect(label(.active, distance: ("0.3 mi", "0.3 miles")) == "Turn left onto Ferst Drive, in 0.3 miles.")
    }

    @Test
    func anInstructionsOwnFullStopIsNotDoubled() {
        #expect(label(.active, "Turn left onto Ferst Drive.") == "Turn left onto Ferst Drive, in 150 feet.")
    }

    @Test
    func pausedSaysSoBeforeTheTurn() {
        #expect(label(.paused) == "Paused. Turn left onto Ferst Drive.")
    }

    @Test
    func offRouteReadsTheRecoveryInstruction() {
        #expect(label(.offRoute, "Off route. Finding a new route.", distance: nil) == "Off route. Finding a new route.")
    }

    @Test(arguments: [TripActivityAttributes.ContentState.Status.active, .offRoute])
    func staleSaysGuidanceIsNotUpdatingInsteadOfAnOldTurn(_ status: TripActivityAttributes.ContentState.Status) {
        #expect(label(status, isStale: true) == "Guidance not updating. Open AccessAble.")
    }

    @Test
    func arrivedNamesTheDestination() {
        #expect(label(.arrived, "You have arrived", distance: nil) == "Arrived at Clough Commons.")
    }
}
