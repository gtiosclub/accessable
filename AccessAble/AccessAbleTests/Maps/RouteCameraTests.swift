import MapKit
import Testing
@testable import AccessAble

private func route(_ coordinates: [GeoCoordinate]) throws -> NavigationRoute {
    try NavigationRoute(
        coordinates: coordinates,
        steps: [
            RouteStep(kind: .depart, coordinateIndex: 0, instruction: "Depart", spokenInstruction: "Depart"),
            RouteStep(kind: .arrive, coordinateIndex: coordinates.count - 1, instruction: "Arrive",
                      spokenInstruction: "Arrive"),
        ],
        estimatedDuration: 60
    )
}

/// Width and height of `rect` in metres at its centre.
private func size(_ rect: MKMapRect) -> (width: Double, height: Double) {
    let metresPerPoint = MKMetersPerMapPointAtLatitude(MKMapPoint(x: rect.midX, y: rect.midY).coordinate.latitude)
    return (rect.width * metresPerPoint, rect.height * metresPerPoint)
}

private func bounds(_ coordinates: [GeoCoordinate]) -> MKMapRect {
    coordinates.map { MKMapRect(origin: MKMapPoint($0.clCoordinate), size: MKMapSize(width: 0, height: 0)) }
        .reduce(MKMapRect.null) { $0.union($1) }
}

// The Valhalla fixture's shape: about 570 m of campus walkway.
private let campusWalk = [
    GeoCoordinate(latitude: 33.7750, longitude: -84.3990),
    GeoCoordinate(latitude: 33.7746, longitude: -84.4005),
    GeoCoordinate(latitude: 33.7749, longitude: -84.4020),
    GeoCoordinate(latitude: 33.7752, longitude: -84.4030),
    GeoCoordinate(latitude: 33.7756, longitude: -84.4038),
]

struct RouteCameraTests {
    @Test
    func containsEveryCoordinateWithMargin() throws {
        let rect = try route(campusWalk).cameraRect(margin: 0.2)
        let routeBounds = bounds(campusWalk)

        for coordinate in campusWalk {
            let point = MKMapPoint(coordinate.clCoordinate)
            #expect(point.x - rect.minX >= 0.2 * routeBounds.width * 0.999)
            #expect(rect.maxX - point.x >= 0.2 * routeBounds.width * 0.999)
            #expect(point.y - rect.minY >= 0.2 * routeBounds.height * 0.999)
            #expect(rect.maxY - point.y >= 0.2 * routeBounds.height * 0.999)
        }
    }

    @Test
    func growsBoundsByMarginOnEachSide() throws {
        let rect = try route(campusWalk).cameraRect(margin: 0.2, minimumSpan: 0)
        let routeBounds = bounds(campusWalk)

        #expect(abs(rect.width - routeBounds.width * 1.4) < 1e-6 * rect.width)
        #expect(abs(rect.height - routeBounds.height * 1.4) < 1e-6 * rect.height)
        #expect(abs(rect.midX - routeBounds.midX) < 1e-6)
        #expect(abs(rect.midY - routeBounds.midY) < 1e-6)
    }

    @Test
    func shortRouteKeepsMinimumSpan() throws {
        let start = GeoCoordinate(latitude: 33.7750, longitude: -84.3990)
        let oneMetreNorth = GeoCoordinate(latitude: 33.7750 + 1 / 111_195.0, longitude: -84.3990)
        let (width, height) = size(try route([start, oneMetreNorth]).cameraRect(minimumSpan: 200))

        #expect(abs(width - 200) < 0.01)
        #expect(abs(height - 200) < 0.01)
    }

    @Test
    func straightNorthRouteWidensToMinimum() throws {
        // 0.009° of latitude is about 1 km
        let start = GeoCoordinate(latitude: 33.7700, longitude: -84.3990)
        let end = GeoCoordinate(latitude: 33.7790, longitude: -84.3990)
        let (width, height) = size(try route([start, end]).cameraRect(margin: 0.2, minimumSpan: 200))

        #expect(abs(width - 200) < 0.01)
        #expect(abs(height - 1.4 * GeoMath.distance(from: start, to: end)) < 0.01 * height)
    }

    @Test
    func sampleRouteFitsAroundCampus() {
        let (width, height) = size(MapsSamples.route.cameraRect())

        #expect(width >= 200)
        #expect(height >= 200)
        #expect(MapsSamples.route.cameraRect().contains(MKMapPoint(MapsSamples.origin.clCoordinate)))
        #expect(MapsSamples.route.cameraRect().contains(MKMapPoint(MapsSamples.destination.coordinate.clCoordinate)))
    }
}
