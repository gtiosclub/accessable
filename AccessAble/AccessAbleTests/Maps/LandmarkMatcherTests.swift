import Foundation
import Testing
@testable import AccessAble

private func landmark(_ name: String, aliases: [String] = [], along: Double, side: Double = 10,
                      destination: Bool = false) -> RouteLandmark {
    RouteLandmark(name: name, aliases: aliases, isDestination: destination,
                  coordinate: GeoCoordinate(latitude: 33.775, longitude: -84.399), distanceAlongRoute: along,
                  sideOffset: side, entrances: [])
}

private func sign(_ text: String, kind: LandmarkObservation.Kind = .signText, confidence: Float = 0.9,
                  announced: Bool = false) -> LandmarkObservation {
    LandmarkObservation(kind: kind, text: text, key: text, confidence: confidence, wasAnnounced: announced)
}

private let clough = landmark("G. Wayne Clough Undergraduate Learning Commons",
                              aliases: ["CULC", "Clough Undergraduate Learning Commons"], along: 100)
private let vanLeer = landmark("Van Leer Building", aliases: ["Van Leer (EE+CE)"], along: 120)

struct LandmarkMatcherTests {
    @Test(arguments: [
        ("CULC", "CULC"),
        ("G. Wayne Clough Undergraduate Learning Commons", "G. Wayne Clough Undergraduate Learning Commons"),
        // the most complete name the sign matches is the one spoken
        ("Clough Undergraduate Learning Commons", "Clough Undergraduate Learning Commons"),
        // OCR drops a word of a long plate
        ("CLOUGH LEARNING COMMONS", "Clough Undergraduate Learning Commons"),
        ("WAYNE CLOUGH UNDERGRADUATE LEARNING COMMONS", "G. Wayne Clough Undergraduate Learning Commons"),
        // and misreads a letter
        ("Clough Undergraduate Learnlng Commons Room 102", "Clough Undergraduate Learning Commons"),
    ])
    func signsMatchTheBuildingByAnyOfItsNames(text: String, spokenName: String) {
        var matcher = LandmarkMatcher(landmarks: [clough, vanLeer])

        let event = matcher.match(sign(text), progress: 80, remaining: 300)

        #expect(event == .passing(clough, spokenName: spokenName, wasAnnounced: false))
    }

    @Test(arguments: ["CLOUGH", "LEARNING COMMONS", "CUL", "VAN", "Klaus Advanced Computing", "Exit", "Room 102"])
    func partialOrUnrelatedTextDoesNotMatch(text: String) {
        var matcher = LandmarkMatcher(landmarks: [clough, vanLeer])

        // both buildings are in range here, so only the text decides
        #expect(matcher.match(sign(text), progress: 100, remaining: 300) == nil)
    }

    @Test
    func buildingWordAndPunctuationAreOptional() {
        var matcher = LandmarkMatcher(landmarks: [vanLeer])

        #expect(matcher.match(sign("VAN LEER"), progress: 100, remaining: 300)
            == .passing(vanLeer, spokenName: "Van Leer Building", wasAnnounced: false))
    }

    @Test
    func abbreviationsAndAccentsAreNormalized() {
        let student = landmark("John Lewis Student Center", aliases: ["Student Center"], along: 50)
        let cafe = landmark("Café Bldg", along: 60)
        var matcher = LandmarkMatcher(landmarks: [student, cafe])

        #expect(matcher.match(sign("STUDENT CTR."), progress: 50, remaining: 300)
            == .passing(student, spokenName: "Student Center", wasAnnounced: false))
        #expect(matcher.match(sign("CAFE BUILDING"), progress: 50, remaining: 300)
            == .passing(cafe, spokenName: "Café Bldg", wasAnnounced: false))
    }

    @Test(arguments: [
        (39.9, false), (40.0, true), (100.0, true), (125.0, true), (125.1, false),
    ])
    func signsCountOnlyNearWhereTheRoutePassesTheBuilding(progress: Double, matches: Bool) {
        // Clough is 100 m along: from 60 m before it to 25 m after
        var matcher = LandmarkMatcher(landmarks: [clough])

        #expect((matcher.match(sign("CULC"), progress: progress, remaining: 300) != nil) == matches)
    }

    @Test
    func eachBuildingMatchesOnce() {
        var matcher = LandmarkMatcher(landmarks: [clough])

        #expect(matcher.match(sign("CULC"), progress: 90, remaining: 300) != nil)
        #expect(matcher.match(sign("CULC"), progress: 95, remaining: 300) == nil)
        #expect(matcher.match(sign("Clough Commons Learning"), progress: 95, remaining: 300) == nil)
    }

    @Test
    func rerouteKeepsMatchedBuildingsMatched() {
        var matcher = LandmarkMatcher(landmarks: [clough])
        _ = matcher.match(sign("CULC"), progress: 90, remaining: 300)

        var movedClough = clough
        movedClough.distanceAlongRoute = 30
        matcher.replaceLandmarks([movedClough, vanLeer])

        #expect(matcher.match(sign("CULC"), progress: 30, remaining: 300) == nil)
        #expect(matcher.landmarks == [movedClough, vanLeer])
    }

    @Test
    func theMoreCompleteNameWinsOverTheNearerBuilding() {
        let library = landmark("Price Gilbert Memorial Library", aliases: ["Library"], along: 100)
        let libraryEast = landmark("Dorothy Murray Crosland Tower", aliases: ["Library East"], along: 130)
        var matcher = LandmarkMatcher(landmarks: [library, libraryEast])

        // "LIBRARY EAST" also contains "Library"
        #expect(matcher.match(sign("LIBRARY EAST"), progress: 100, remaining: 300)
            == .passing(libraryEast, spokenName: "Library East", wasAnnounced: false))
    }

    @Test
    func betweenEquallyGoodNamesTheNearerBuildingWins() {
        let behind = landmark("Price Gilbert Memorial Library", aliases: ["Library"], along: 80)
        let ahead = landmark("Engineering Library", aliases: ["Library"], along: 110)
        var matcher = LandmarkMatcher(landmarks: [behind, ahead])

        #expect(matcher.match(sign("LIBRARY"), progress: 100, remaining: 300)
            == .passing(ahead, spokenName: "Library", wasAnnounced: false))
    }

    @Test
    func destinationMatchesOnlyNearTheEnd() {
        let destination = landmark("Skiles", along: 90, destination: true)
        var matcher = LandmarkMatcher(landmarks: [destination])

        #expect(matcher.match(sign("SKILES"), progress: 90, remaining: 60.1) == nil)
        #expect(matcher.match(sign("SKILES"), progress: 90, remaining: 60)
            == .destination(destination, spokenName: "Skiles", wasAnnounced: false))
    }

    @Test
    func announcedFlagIsPassedOn() {
        var matcher = LandmarkMatcher(landmarks: [clough])

        #expect(matcher.match(sign("CULC", announced: true), progress: 90, remaining: 300)
            == .passing(clough, spokenName: "CULC", wasAnnounced: true))
    }

    @Test
    func entranceSignsCountButOtherKindsAndWeakReadsDont() {
        var matcher = LandmarkMatcher(landmarks: [clough])

        #expect(matcher.match(sign("CULC", kind: .crosswalk), progress: 90, remaining: 300) == nil)
        #expect(matcher.match(sign("CULC", confidence: 0.49), progress: 90, remaining: 300) == nil)
        #expect(matcher.match(LandmarkObservation(kind: .entrance, key: "door", confidence: 0.9),
                              progress: 90, remaining: 300) == nil)
        #expect(matcher.match(sign("CULC", kind: .entrance), progress: 90, remaining: 300) != nil)
    }

    @Test
    func passingWordingUsesTheSideAndSkipsTheNameCVAlreadySaid() {
        let left = landmark("Skiles", along: 50, side: -12)
        let right = landmark("Skiles", along: 50, side: 12)
        let onPath = landmark("Skiles", along: 50, side: 2.9)

        #expect(TripManager.landmarkText(.passing(left, spokenName: "Skiles", wasAnnounced: false))
            == "Passing Skiles on your left.")
        #expect(TripManager.landmarkText(.passing(right, spokenName: "Skiles", wasAnnounced: false))
            == "Passing Skiles on your right.")
        #expect(TripManager.landmarkText(.passing(onPath, spokenName: "Skiles", wasAnnounced: false))
            == "Passing Skiles.")
        #expect(TripManager.landmarkText(.passing(left, spokenName: "Skiles", wasAnnounced: true))
            == "You're on track.")
        #expect(TripManager.landmarkText(.destination(left, spokenName: "Skiles", wasAnnounced: false))
            == "This is Skiles, your destination.")
        #expect(TripManager.landmarkText(.destination(left, spokenName: "Skiles", wasAnnounced: true))
            == "That's your destination.")
    }
}
