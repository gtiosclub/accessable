import Foundation
import Testing
@testable import AccessAble

struct AppleMapsRouteConversionTests {
    // A short walk north then west, about 11 m between points.
    private static let points = [
        GeoCoordinate(latitude: 33.7750, longitude: -84.3990),
        GeoCoordinate(latitude: 33.7751, longitude: -84.3990),
        GeoCoordinate(latitude: 33.7752, longitude: -84.3990),
        GeoCoordinate(latitude: 33.7752, longitude: -84.3991),
        GeoCoordinate(latitude: 33.7752, longitude: -84.3992),
    ]

    // MARK: - Turn types from instruction text

    private static let kindCases: [(String, ManeuverKind?)] = [
        ("Turn right onto Ferst Dr NW", .turnRight),
        ("Turn left", .turnLeft),
        ("Sharp left onto the path", .turnLeft),
        ("Left onto Atlantic Dr", .turnLeft),
        ("Slight right toward the library", .slightRight),
        ("Keep left at the fork", .slightLeft),
        ("Bear right", .slightRight),
        ("Make a U-turn", .uTurn),
        ("Take the stairs", .stairs),
        ("Turn left and take the steps down", .turnLeft),
        ("Take the steps down", .stairs),
        ("Take the elevator", .elevator),
        ("Take the escalator to level 2", .escalator),
        ("Cross the street", .cross),
        ("Use the crosswalk", .cross),
        ("Continue onto Cherry St", .straight),
        ("Turn right onto Crossland Rd", .turnRight),
        ("Proceed to the route", .straight),
        ("Gire a la izquierda en Ferst Dr", nil),
        ("Tournez à droite", nil),
    ]

    @Test(arguments: kindCases)
    func maneuverKindFromInstruction(_ text: String, _ expected: ManeuverKind?) {
        #expect(NavigationRoute.appleMapsManeuverKind(for: text) == expected)
    }

    // MARK: - Spoken text

    private static let speechCases: [(String, String)] = [
        ("Turn right onto Ferst Dr NW", "Turn right onto Ferst Drive Northwest."),
        ("Turn left onto 4th St", "Turn left onto 4th Street."),
        ("Turn left onto Dr Martin Luther King Jr Dr", "Turn left onto Dr Martin Luther King Jr Drive."),
        ("Head north on Atlantic Dr", "Follow Atlantic Drive."),
        ("Arrive at the destination", "Arrive at the destination."),
        ("Cross the street.", "Cross the street."),
        ("Turn right onto Techwood Dr, then continue", "Turn right onto Techwood Drive, then continue."),
        ("Turn left onto Peachtree St N", "Turn left onto Peachtree Street North."),
        ("Turn right onto Ferst Dr NW toward the library", "Turn right onto Ferst Drive Northwest toward the library."),
        ("Turn left onto E St", "Turn left onto E Street."),
        ("Walk past Building N", "Walk past Building N."),
    ]

    @Test(arguments: speechCases)
    func spokenTextForSpeech(_ text: String, _ expected: String) {
        #expect(NavigationRoute.appleMapsSpokenText(text) == expected)
    }

    private static let arrivalCases: [(String, String)] = [
        ("Arrive at the destination", "You have arrived."),
        ("Arrive at Clough Commons", "You have arrived."),
        ("The destination is on your left", "Your destination is on the left."),
        ("Arrive at the destination, on the right", "Your destination is on the right."),
    ]

    @Test(arguments: arrivalCases)
    func arrivalIsSaidAsValhallaSaysIt(_ text: String, _ expected: String) {
        #expect(NavigationRoute.appleMapsArrivalSpeech(text) == expected)
    }

    // MARK: - Turn types from the route's shape

    /// Bearing changes at the corner of a walk north, positive to the right.
    private static let turnCases: [(Double, ManeuverKind)] = [
        (0, .straight), (15, .straight), (30, .slightRight), (-30, .slightLeft), (90, .turnRight),
        (-90, .turnLeft), (140, .turnRight), (-140, .turnLeft), (170, .uTurn), (-170, .uTurn),
    ]

    @Test(arguments: turnCases)
    func turnKindFromTheChangeOfBearing(_ change: Double, _ expected: ManeuverKind) {
        let start = Self.points[0]
        let corner = TripWalk.destination(from: start, bearing: 0, distance: 30)
        // a kink right at the corner doesn't count
        let kink = TripWalk.destination(from: corner, bearing: change + 60, distance: 2)
        let end = TripWalk.destination(from: corner, bearing: change, distance: 30)
        #expect(NavigationRoute.turnKind(at: 1, in: [start, corner, kink, end]) == expected)
    }

    // MARK: - Route

    @Test
    func convertsStepsWithKindsIndicesAndArrival() throws {
        let steps = [
            AppleMapsStep(instructions: "", start: Self.points[0]),
            AppleMapsStep(instructions: "Turn left onto Ferst Dr NW", start: Self.points[2]),
            AppleMapsStep(instructions: "Take the stairs", start: Self.points[3]),
            AppleMapsStep(instructions: "Arrive at the destination", start: Self.points[4]),
        ]
        let route = try NavigationRoute(appleMapsCoordinates: Self.points, steps: steps, estimatedDuration: 40)

        #expect(route.coordinates == Self.points)
        #expect(route.steps.map(\.kind) == [.depart, .turnLeft, .stairs, .arrive])
        #expect(route.steps.map(\.coordinateIndex) == [0, 2, 3, 4])
        #expect(route.steps[0].instruction == "Follow the path")
        #expect(route.steps[1].instruction == "Turn left onto Ferst Dr NW")
        #expect(route.steps[1].spokenInstruction == "Turn left onto Ferst Drive Northwest.")
        #expect(route.steps[3].spokenInstruction == "You have arrived.")
        #expect(route.estimatedDuration == 40)
        #expect(route.source == .appleMaps)
    }

    @Test
    func theFirstStepIsSpelledOutForTheTripToSay() throws {
        let steps = [AppleMapsStep(instructions: "Head north on Atlantic Dr", start: Self.points[0])]
        let route = try NavigationRoute(appleMapsCoordinates: Self.points, steps: steps, estimatedDuration: 40)

        #expect(route.steps[0].instruction == "Head north on Atlantic Drive")
        #expect(route.steps[0].spokenInstruction == "Follow Atlantic Drive.")
    }

    @Test
    func turnsInAnotherLanguageComeFromTheRouteShape() throws {
        let steps = [
            AppleMapsStep(instructions: "", start: Self.points[0]),
            AppleMapsStep(instructions: "Gire a la izquierda en Ferst Dr NW", start: Self.points[2]),
            AppleMapsStep(instructions: "Llegada al destino", start: Self.points[4]),
        ]
        let route = try NavigationRoute(appleMapsCoordinates: Self.points, steps: steps, estimatedDuration: 40)

        #expect(route.steps.map(\.kind) == [.depart, .turnLeft, .arrive])
        #expect(route.steps.map(\.coordinateIndex) == [0, 2, 4])
        #expect(route.steps[2].spokenInstruction == "You have arrived.")
    }

    @Test
    func addsArrivalWhenAppleEndsOnATurn() throws {
        let steps = [
            AppleMapsStep(instructions: "Head north", start: Self.points[0]),
            AppleMapsStep(instructions: "Turn left", start: Self.points[2]),
        ]
        let route = try NavigationRoute(appleMapsCoordinates: Self.points, steps: steps, estimatedDuration: 40)

        #expect(route.steps.map(\.kind) == [.depart, .turnLeft, .arrive])
        #expect(route.steps.last?.coordinateIndex == Self.points.count - 1)
    }

    @Test
    func buildsDepartAndArriveWhenAppleGivesNoSteps() throws {
        let route = try NavigationRoute(appleMapsCoordinates: Self.points, steps: [], estimatedDuration: 40)
        #expect(route.steps.map(\.kind) == [.depart, .arrive])
    }

    @Test
    func dropsRepeatedPointsWhereStepsMeet() throws {
        let doubled = [Self.points[0], Self.points[1], Self.points[1], Self.points[2]]
        let route = try NavigationRoute(appleMapsCoordinates: doubled, steps: [], estimatedDuration: 10)
        #expect(route.coordinates == Array(Self.points[0...2]))
    }

    @Test
    func stepsNeverGoBackwards() throws {
        // a later step whose start is nearest an earlier point still comes after the step before it
        let steps = [
            AppleMapsStep(instructions: "", start: Self.points[0]),
            AppleMapsStep(instructions: "Turn left", start: Self.points[3]),
            AppleMapsStep(instructions: "Turn right", start: Self.points[1]),
        ]
        let route = try NavigationRoute(appleMapsCoordinates: Self.points, steps: steps, estimatedDuration: 40)
        #expect(route.steps.map(\.coordinateIndex) == [0, 3, 3, 4])
    }

    @Test
    func rejectsARouteWithOnePoint() {
        #expect(throws: NavigationRoute.ValidationError.tooFewCoordinates) {
            try NavigationRoute(appleMapsCoordinates: [Self.points[0], Self.points[0]], steps: [],
                                estimatedDuration: 0)
        }
    }
}
