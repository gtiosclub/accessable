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
            symbolName: "arrow.turn.up.left",
            arrival: Date(timeIntervalSinceReferenceDate: 800_000_000)
        ),
        TripActivityAttributes.ContentState(
            status: .offRoute,
            instruction: "Off route. Finding a new way",
            distance: nil,
            symbolName: "exclamationmark.triangle.fill",
            arrival: nil
        ),
    ])
    func contentStateSurvivesJSON(_ state: TripActivityAttributes.ContentState) throws {
        let data = try JSONEncoder().encode(state)
        #expect(try JSONDecoder().decode(TripActivityAttributes.ContentState.self, from: data) == state)
    }
}
