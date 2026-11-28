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

    /// A place `metres` from the origin, straight along `bearing`.
    private func place(_ id: String, _ source: PointToScanPlaceSource, metres: Double, bearing: Double = 90) -> PointToScanPlace {
        let radians = bearing * .pi / 180
        let latitude = origin.latitude + metres * cos(radians) / 111_320
        let longitude = origin.longitude + metres * sin(radians) / (111_320 * cos(origin.latitude * .pi / 180))
        return PointToScanPlace(
            id: id,
            name: id,
            coordinate: GeoCoordinate(latitude: latitude, longitude: longitude),
            source: source
        )
    }

    @Test
    func nearerMapKitPlaceBeatsFartherCampusBuilding() {
        let cafe = place("cafe", .mapKit, metres: 50)
        let hall = place("hall", .campus, metres: 300)
        let match = PointToScanSelection.bestMatch(origin: origin, headingDegrees: 90, places: [hall, cafe])
        #expect(match?.id == cafe.id)
    }

    @Test
    func nearSavedPlaceBeatsFarCampusBuilding() {
        let home = place("home", .saved, metres: 10)
        let hall = place("hall", .campus, metres: 390)
        let match = PointToScanSelection.bestMatch(origin: origin, headingDegrees: 90, places: [hall, home])
        #expect(match?.id == home.id)
    }

    @Test
    func campusBuildingWinsWithinTheSlack() {
        let cafe = place("cafe", .mapKit, metres: 100)
        let hall = place("hall", .campus, metres: 100 + PointToScanSelection.preferredSourceSlack - 1)
        let match = PointToScanSelection.bestMatch(origin: origin, headingDegrees: 90, places: [cafe, hall])
        #expect(match?.id == hall.id)
    }

    @Test
    func ignoresPlacesBeyondRange() {
        let far = place("far", .campus, metres: PointToScanSelection.maxDistance + 10)
        #expect(PointToScanSelection.bestMatch(origin: origin, headingDegrees: 90, places: [far]) == nil)
    }

    @Test
    func turnedAwayOnlyWellOutsideTheWindow() {
        let hall = place("hall", .campus, metres: 100, bearing: 90)
        let edge = PointToScanSelection.bearingWindow + PointToScanSelection.turnAwayMargin
        #expect(!PointToScanSelection.isTurnedAway(origin: origin, headingDegrees: 90 + edge - 1, from: hall))
        #expect(PointToScanSelection.isTurnedAway(origin: origin, headingDegrees: 90 + edge + 1, from: hall))
        #expect(PointToScanSelection.isTurnedAway(origin: origin, headingDegrees: 90 - edge - 1, from: hall))
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
        let first = origin
        let nearby = place("nearby", .mapKit, metres: PointToScanSelection.poiRefetchDistance - 5).coordinate
        let far = place("far", .mapKit, metres: PointToScanSelection.poiRefetchDistance + 5).coordinate
        #expect(PointToScanSelection.shouldRefetchPOIs(from: nil, to: first))
        #expect(!PointToScanSelection.shouldRefetchPOIs(from: first, to: nearby))
        #expect(PointToScanSelection.shouldRefetchPOIs(from: first, to: far))
    }
}