import Foundation
import Testing
@testable import AccessAble

struct PointToScanSelectionTests {
    private let origin = GeoCoordinate(latitude: 33.7756, longitude: -84.3963)

    private let clough = PointToScanPlace(
        id: "campus:Clough",
        name: "Clough Commons",
        coordinate: GeoCoordinate(latitude: 33.7752, longitude: -84.3942),
        source: .campus
    )

    private let library = PointToScanPlace(
        id: "campus:Library",
        name: "Library",
        coordinate: GeoCoordinate(latitude: 33.7743, longitude: -84.3957),
        source: .campus
    )

    @Test
    func picksNearestInBearingWindow() {
        let heading = GeoMath.bearing(from: origin, to: clough.coordinate)
        let match = PointToScanSelection.bestMatch(
            origin: origin,
            headingDegrees: heading,
            places: [library, clough]
        )
        #expect(match?.id == clough.id)
    }

    @Test
    func ignoresPlacesOutsideBearingWindow() {
        let heading = GeoMath.bearing(from: origin, to: clough.coordinate)
        let turnedAway = heading + 90
        let match = PointToScanSelection.bestMatch(
            origin: origin,
            headingDegrees: turnedAway,
            places: [clough]
        )
        #expect(match == nil)
    }

    @Test
    func campusBeatsMapKitAtSimilarDistance() {
        let mapKit = PointToScanPlace(
            id: "mapkit:Tower",
            name: "Tower",
            coordinate: clough.coordinate,
            source: .mapKit
        )
        let heading = GeoMath.bearing(from: origin, to: clough.coordinate)
        let match = PointToScanSelection.bestMatch(origin: origin, headingDegrees: heading, places: [mapKit, clough])
        #expect(match?.source == .campus)
    }

    @Test
    func dropsMapKitPlaceNearCampus() {
        let nearDuplicate = PointToScanPlace(
            id: "mapkit:duplicate",
            name: "Commons Cafe",
            coordinate: GeoCoordinate(
                latitude: clough.coordinate.latitude + 0.00005,
                longitude: clough.coordinate.longitude
            ),
            source: .mapKit
        )
        let campus = CampusNicknameDictionary(places: [
            CampusNicknamePlace(name: clough.name, nicknames: [], coordinate: clough.coordinate, address: nil)
        ])
        let merged = PointToScanSelection.mergedPlaces(campus: campus, saved: [], mapKit: [nearDuplicate])
        #expect(merged.contains(where: { $0.name == clough.name && $0.source == .campus }))
        #expect(!merged.contains(where: { $0.id == nearDuplicate.id }))
    }

    @Test
    func refetchesPOIsAfterMoving() {
        let first = GeoCoordinate(latitude: 1, longitude: 1)
        let nearby = GeoCoordinate(latitude: 1.0002, longitude: 1)
        let far = GeoCoordinate(latitude: 1.001, longitude: 1)
        #expect(PointToScanSelection.shouldRefetchPOIs(from: nil, to: first))
        #expect(!PointToScanSelection.shouldRefetchPOIs(from: first, to: nearby))
        #expect(PointToScanSelection.shouldRefetchPOIs(from: first, to: far))
    }
}