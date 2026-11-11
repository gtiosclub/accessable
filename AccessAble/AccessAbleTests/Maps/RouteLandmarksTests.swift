import Foundation
import Testing
@testable import AccessAble

private let start = GeoCoordinate(latitude: 33.7750, longitude: -84.3990)
private let end = TripWalk.destination(from: start, bearing: 0, distance: 200)

/// Straight north 200 m.
private func northRoute() throws -> NavigationRoute {
    try NavigationRoute(coordinates: [start, end], steps: [
        RouteStep(kind: .depart, coordinateIndex: 0, instruction: "Walk north.", spokenInstruction: "Walk north."),
        RouteStep(kind: .arrive, coordinateIndex: 1, instruction: "Arrive", spokenInstruction: "Arrive"),
    ], estimatedDuration: 160)
}

/// A square `size` metres across centred `lateral` metres east of the route (negative is west) at `along`.
private func square(_ name: String, aliases: [String] = [], along: Double, lateral: Double, size: Double = 10,
                    entrances: [CampusEntrance] = []) throws -> CampusBuilding {
    let route = try northRoute()
    let half = size / 2
    let corners = [(-half, -half), (-half, half), (half, half), (half, -half)].map { dAlong, dLateral in
        TripWalk.point(on: route, along: along + dAlong, lateral: lateral + dLateral)
    }
    return CampusBuilding(name: name, aliases: aliases, outlines: [corners], entrances: entrances)
}

struct RouteLandmarksTests {
    @Test
    func buildingsNearTheRouteAreListedInOrderWithTheirSide() throws {
        let east = try square("East Hall", along: 120, lateral: 20)
        let west = try square("West Hall", along: 60, lateral: -30)
        let far = try square("Far Hall", along: 100, lateral: 60)

        let landmarks = RouteLandmarks.along(try northRoute(), destination: nil, buildings: [east, far, west])

        #expect(landmarks.map(\.name) == ["West Hall", "East Hall"])
        // the near wall is 5 m nearer the route than each centre; either of its corners can be the closest
        #expect(abs(landmarks[0].sideOffset - -25) < 0.01)
        #expect((55 - 0.01...65 + 0.01).contains(landmarks[0].distanceAlongRoute))
        #expect(abs(landmarks[1].sideOffset - 15) < 0.01)
        #expect((115 - 0.01...125 + 0.01).contains(landmarks[1].distanceAlongRoute))
        #expect(landmarks.allSatisfy { !$0.isDestination && $0.entrances.isEmpty })
    }

    @Test(arguments: [(39.9, true), (40.1, false)])
    func visibilityLimitIsMeasuredToTheNearestCorner(nearestCorner: Double, isListed: Bool) throws {
        let building = try square("Edge Hall", along: 100, lateral: nearestCorner + 5)

        let landmarks = RouteLandmarks.along(try northRoute(), destination: nil, buildings: [building])

        #expect(landmarks.isEmpty == !isListed)
    }

    @Test
    func destinationBuildingIsMarkedWithItsEntrancesAndTheSearchName() throws {
        let door = CampusEntrance(coordinate: TripWalk.point(on: try northRoute(), along: 205, lateral: 0),
                                  kind: "main", wheelchair: "yes")
        let target = try square("Price Gilbert Memorial Library", aliases: ["Library"], along: 210, lateral: 0,
                                entrances: [door])
        let destination = Destination(name: "Georgia Tech Library", coordinate: TripWalk.point(on: try northRoute(),
                                                                                              along: 210))

        let landmarks = RouteLandmarks.along(try northRoute(), destination: destination, buildings: [target])

        let library = try #require(landmarks.first)
        #expect(landmarks.count == 1)
        #expect(library.isDestination)
        #expect(library.aliases == ["Library", "Georgia Tech Library"])
        #expect(library.entrances == [door])
    }

    @Test
    func destinationBuildingCanBeANearbyOneWhenTheDestinationIsOutside() throws {
        // search results often sit on the street in front of the building
        let target = try square("Skiles", along: 150, lateral: 30)
        let next = try square("Howey", along: 150, lateral: -60)
        let destination = Destination(name: "Skiles", coordinate: TripWalk.point(on: try northRoute(), along: 150,
                                                                                 lateral: 5))

        let landmarks = RouteLandmarks.along(try northRoute(), destination: destination, buildings: [next, target])

        #expect(landmarks.map(\.name) == ["Skiles"])
        #expect(landmarks.first?.isDestination == true)
        // its own name isn't added twice
        #expect(landmarks.first?.aliases == [])
    }

    @Test
    func destinationFarFromEveryBuildingHasNoBuilding() throws {
        let building = try square("Skiles", along: 150, lateral: 25)
        let destination = Destination(name: "Bench", coordinate: TripWalk.point(on: try northRoute(), along: 200,
                                                                               lateral: -40))

        #expect(RouteLandmarks.along(try northRoute(), destination: destination, buildings: [building])
            .allSatisfy { !$0.isDestination })
    }

    @Test
    func containsUsesTheOutline() throws {
        let building = try square("Skiles", along: 100, lateral: 0, size: 20)
        let route = try northRoute()

        #expect(building.contains(TripWalk.point(on: route, along: 100)))
        #expect(building.contains(TripWalk.point(on: route, along: 109, lateral: 9)))
        #expect(!building.contains(TripWalk.point(on: route, along: 111)))
        #expect(!building.contains(TripWalk.point(on: route, along: 100, lateral: -11)))
    }
}

/// The bundled export from Scripts/CampusLandmarks.
struct CampusLandmarksTests {
    @Test
    func bundledCampusDataLoads() throws {
        let buildings = CampusLandmarks.buildings

        #expect(buildings.count > 250)
        let clough = try #require(buildings.first { $0.aliases.contains("CULC") })
        #expect(clough.name == "G. Wayne Clough Undergraduate Learning Commons")
        #expect(clough.entrances.contains { $0.kind == "main" })
        let techTower = try #require(buildings.first { $0.aliases.contains("Tech Tower") })
        #expect(techTower.contains(GeoCoordinate(latitude: 33.77247, longitude: -84.39468)))
        // relations' split outer ways are joined into closed rings by the export
        #expect(buildings.allSatisfy { building in
            !building.outlines.isEmpty && building.outlines.allSatisfy { $0.count >= 4 && $0.first == $0.last }
        })
        let library = try #require(buildings.first { $0.name == "Price Gilbert Memorial Library" })
        #expect(library.outlines.count == 1)
        #expect(library.contains(GeoCoordinate(latitude: 33.77434, longitude: -84.39572)))
    }

    @Test(arguments: [(true, 1.0), (false, -1.0)])
    func walkPastCloughFindsItOnTheRightSide(northbound: Bool, side: Double) throws {
        // about 30 m west of Clough's west wall; the Library, joined to Clough's east side, is out of view
        let south = GeoCoordinate(latitude: 33.77400, longitude: -84.39700)
        let north = GeoCoordinate(latitude: 33.77520, longitude: -84.39700)
        let route = try NavigationRoute(coordinates: northbound ? [south, north] : [north, south], steps: [
            RouteStep(kind: .depart, coordinateIndex: 0, instruction: "Walk.", spokenInstruction: "Walk."),
            RouteStep(kind: .arrive, coordinateIndex: 1, instruction: "Arrive", spokenInstruction: "Arrive"),
        ], estimatedDuration: 100)

        let landmarks = RouteLandmarks.along(route, destination: nil)

        let clough = try #require(landmarks.first { $0.aliases.contains("CULC") })
        #expect(clough.sideOffset * side > 25)
        #expect(clough.sideOffset * side < 35)
        #expect(!landmarks.contains { $0.name == "Price Gilbert Memorial Library" })
        #expect(landmarks.map(\.distanceAlongRoute) == landmarks.map(\.distanceAlongRoute).sorted())
    }
}
