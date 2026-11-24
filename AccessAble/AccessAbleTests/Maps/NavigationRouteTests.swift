import Foundation
import Testing
@testable import AccessAble

private let coordinates = [
    GeoCoordinate(latitude: 33.775, longitude: -84.399),
    GeoCoordinate(latitude: 33.7755, longitude: -84.3985),
    GeoCoordinate(latitude: 33.7761, longitude: -84.3972),
]

private func step(_ kind: ManeuverKind, at coordinateIndex: Int) -> RouteStep {
    RouteStep(kind: kind, coordinateIndex: coordinateIndex, instruction: "\(kind)", spokenInstruction: "\(kind)")
}

private let validSteps = [step(.depart, at: 0), step(.turnLeft, at: 1), step(.arrive, at: 2)]

struct NavigationRouteTests {
    @Test
    func derivesDistancesFromGeoMath() throws {
        let route = try NavigationRoute(coordinates: coordinates, steps: validSteps, estimatedDuration: 120)
        #expect(route.cumulativeDistances == GeoMath.cumulativeDistances(along: coordinates))
        #expect(route.totalDistance == route.cumulativeDistances[coordinates.count - 1])
    }

    @Test
    func rejectsTooFewCoordinates() {
        #expect(throws: NavigationRoute.ValidationError.tooFewCoordinates) {
            try NavigationRoute(coordinates: [coordinates[0]], steps: [step(.arrive, at: 0)], estimatedDuration: 0)
        }
    }

    @Test(arguments: [
        GeoCoordinate(latitude: 90.1, longitude: 0),
        GeoCoordinate(latitude: 0, longitude: -180.1),
        GeoCoordinate(latitude: .nan, longitude: 0),
        GeoCoordinate(latitude: 0, longitude: .infinity),
    ])
    func rejectsInvalidCoordinates(_ invalid: GeoCoordinate) {
        #expect(throws: NavigationRoute.ValidationError.invalidCoordinate(index: 1)) {
            try NavigationRoute(coordinates: [coordinates[0], invalid, coordinates[2]], steps: validSteps,
                                estimatedDuration: 120)
        }
    }

    @Test
    func rejectsRoutesWithoutArrival() {
        #expect(throws: NavigationRoute.ValidationError.missingArrival) {
            try NavigationRoute(coordinates: coordinates, steps: [step(.depart, at: 0)], estimatedDuration: 120)
        }
    }

    @Test
    func rejectsStepIndexOutOfRange() {
        #expect(throws: NavigationRoute.ValidationError.stepIndexOutOfRange(stepIndex: 1)) {
            try NavigationRoute(coordinates: coordinates, steps: [step(.depart, at: 0), step(.arrive, at: 3)],
                                estimatedDuration: 120)
        }
    }

    @Test
    func rejectsStepsOutOfOrder() {
        #expect(throws: NavigationRoute.ValidationError.stepsOutOfOrder(stepIndex: 2)) {
            try NavigationRoute(coordinates: coordinates,
                                steps: [step(.depart, at: 0), step(.turnLeft, at: 2), step(.arrive, at: 1)],
                                estimatedDuration: 120)
        }
    }

    @Test(arguments: [-1, Double.nan, .infinity])
    func rejectsInvalidDuration(_ duration: Double) {
        #expect(throws: NavigationRoute.ValidationError.invalidDuration) {
            try NavigationRoute(coordinates: coordinates, steps: validSteps, estimatedDuration: duration)
        }
    }

    @Test
    func survivesACodableRoundTrip() throws {
        let route = try NavigationRoute(coordinates: coordinates, steps: validSteps, estimatedDuration: 120)
        let decoded = try JSONDecoder().decode(NavigationRoute.self, from: JSONEncoder().encode(route))
        #expect(decoded == route)
    }

    @Test
    func keepsMultiCueFlagThroughACodableRoundTrip() throws {
        var steps = validSteps
        steps[0].announcesNextStep = true
        let route = try NavigationRoute(coordinates: coordinates, steps: steps, estimatedDuration: 120)
        let decoded = try JSONDecoder().decode(NavigationRoute.self, from: JSONEncoder().encode(route))
        #expect(decoded.steps.map(\.announcesNextStep) == [true, false, false])
    }

    @Test
    func decodesStepsSavedBeforeTheMultiCueFlag() throws {
        let json = """
            {"kind":"turnLeft","coordinateIndex":1,"instruction":"Turn left","spokenInstruction":"Turn left."}
            """
        let step = try JSONDecoder().decode(RouteStep.self, from: Data(json.utf8))
        #expect(step == RouteStep(kind: .turnLeft, coordinateIndex: 1, instruction: "Turn left",
                                  spokenInstruction: "Turn left."))
    }

    @Test(arguments: [
        ("Take the stairs up.", "stairs going up"),
        ("Take the stairs DOWN to the plaza.", "stairs going down"),
        ("Walk upstairs.", "stairs going up"),
        ("Head downstairs to Level 1.", "stairs going down"),
        ("Take the stairs.", "stairs"),
        ("Take the stairs by the support column to the underpass.", "stairs"),
        ("Take the stairs onto Down Street.", "stairs"),
        ("Take the stairs. Then turn up the ramp.", "stairs"),
        ("Go up the stairs.", "stairs going up"),
    ])
    func stairsPhraseSaysWhichWayWhenTheTextDoes(_ text: String, _ phrase: String) {
        let step = RouteStep(kind: .stairs, coordinateIndex: 1, instruction: text, spokenInstruction: text)
        #expect(step.stairsPhrase == phrase)
    }

    @Test
    func stairsPhraseReadsTheSpokenInstructionToo() {
        let step = RouteStep(kind: .stairs, coordinateIndex: 1, instruction: "Take the stairs.",
                             spokenInstruction: "Take the stairs down.")
        #expect(step.stairsPhrase == "stairs going down")
    }

    @Test(arguments: [
        // Valhalla's start phrases, displayed and spoken
        ("Walk north on Ferst Drive.", "Follow Ferst Drive."),
        ("Walk southwest on the walkway. Continue on Tech Walkway.", "Follow the walkway. Continue on Tech Walkway."),
        ("Head East on North Avenue.", "Follow North Avenue."),
        ("Walk northeast.", "Follow the path."),
        ("Walk south for 50 meters. Then Turn right onto Ferst Drive.",
         "Follow the path for 50 meters. Then Turn right onto Ferst Drive."),
        ("Head north", "Follow the path"),
        // anything else is left alone, street names and all
        ("Turn left onto North Avenue.", "Turn left onto North Avenue."),
        ("Walk to Westside Hall.", "Walk to Westside Hall."),
        ("Head northbound.", "Head northbound."),
        // a compass word that starts a street name, not a direction
        ("Walk North Ave.", "Walk North Ave."),
        ("Walk east Ferst Dr", "Walk east Ferst Dr"),
        ("Walk north toward the plaza.", "Follow the path toward the plaza."),
    ])
    func withoutCompassDirectionDropsTheStartsDirection(_ text: String, _ expected: String) {
        #expect(RouteStep.withoutCompassDirection(text) == expected)
    }

    @Test(arguments: [
        ("Turn left. Then Turn left.", "Turn left. Then turn left."),
        ("Keep right to take the walkway. Then Keep left to take the walkway.",
         "Keep right to take the walkway. Then keep left to take the walkway."),
        ("Turn right onto Ferst Drive.", "Turn right onto Ferst Drive."),
    ])
    func theJoinedStepStartsLowercase(_ text: String, _ expected: String) {
        #expect(RouteStep.withLowercaseThen(text) == expected)
    }

    @Test
    func buildsTheSampleRoute() {
        let route = MapsSamples.route
        #expect(route.coordinates.count == 2)
        // The sample's two points are 0.001° of latitude apart.
        #expect(abs(route.totalDistance - SphereReference.metresPerDegree * 0.001) <= 1e-6)
    }
}
