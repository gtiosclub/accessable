import Foundation
import Testing
@testable import AccessAble

private func isClose(_ actual: Double, _ expected: Double, within tolerance: Double) -> Bool {
    abs(actual - expected) <= tolerance
}

private func jsonData(status: Int, legs: String) -> Data {
    Data(#"{"trip":{"status":\#(status),"legs":\#(legs)}}"#.utf8)
}

struct ValhallaGeometryDecoderTests {
    private static func sampleShape() throws -> String {
        let url = try #require(Bundle.main.url(forResource: "valhalla-route-sample", withExtension: "json"))
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let trip = try #require(object?["trip"] as? [String: Any])
        let legs = try #require(trip["legs"] as? [[String: Any]])
        return try #require(legs.first?["shape"] as? String)
    }

    // Google's published polyline example is an independent reference. It is documented at precision 5, and this
    // decoder uses precision 6, so every value comes out a factor of 10 smaller.
    @Test func decodesPublishedReferencePolylineAtPrecisionSix() throws {
        let decoded = try ValhallaGeometryDecoder.decodePolyline("_p~iF~ps|U_ulLnnqC_mqNvxq`@")
        let expected = [(3.85, -12.02), (4.07, -12.095), (4.3252, -12.6453)]
        #expect(decoded.count == expected.count)
        for (point, reference) in zip(decoded, expected) {
            #expect(isClose(point.latitude, reference.0, within: 1e-9))
            #expect(isClose(point.longitude, reference.1, within: 1e-9))
        }
    }

    @Test func decodesRealRouteSample() throws {
        let url = try #require(Bundle.main.url(forResource: "valhalla-route-sample", withExtension: "json"))
        let legs = try ValhallaGeometryDecoder.decodeLegs(from: Data(contentsOf: url))
        #expect(legs.count == 1)
        let leg = try #require(legs.first)
        #expect(leg.count == 35)

        let first = try #require(leg.first)
        let last = try #require(leg.last)
        #expect(isClose(first.latitude, 33.775, within: 1e-9))
        #expect(isClose(first.longitude, -84.398961, within: 1e-9))
        #expect(isClose(last.latitude, 33.775995, within: 1e-9))
        #expect(isClose(last.longitude, -84.403765, within: 1e-9))

        // The response summary says 0.573 km; Valhalla rounds that to whole metres.
        let total = GeoMath.cumulativeDistances(along: leg).last ?? 0
        #expect(isClose(total, 573, within: 1))

        // A precision-5 decode would put latitudes near 337, so a loose campus bound catches a wrong scale.
        for point in leg {
            #expect(isClose(point.latitude, 33.775, within: 0.01))
            #expect(isClose(point.longitude, -84.4, within: 0.01))
        }
    }

    @Test func rejectsEmptyShape() {
        #expect(throws: ValhallaGeometryDecoder.DecodeError.missingGeometry) {
            try ValhallaGeometryDecoder.decodePolyline("")
        }
    }

    // "oxml_A" and "`vh~_D" are 33775000 and -84398961, the first sample vertex at precision 6, derived with the
    // standard polyline encoder. A route needs a start and an end, so one vertex is not geometry.
    @Test func rejectsSinglePoint() {
        #expect(throws: ValhallaGeometryDecoder.DecodeError.missingGeometry) {
            try ValhallaGeometryDecoder.decodePolyline("oxml_A`vh~_D")
        }
    }

    @Test func rejectsTruncatedShape() throws {
        let shape = try Self.sampleShape()
        #expect(throws: ValhallaGeometryDecoder.DecodeError.malformedPolyline) {
            try ValhallaGeometryDecoder.decodePolyline(String(shape.dropLast()))
        }
    }

    @Test func rejectsCharacterOutsideEncodingAlphabet() throws {
        var shape = try Self.sampleShape()
        shape.insert(" ", at: shape.index(shape.startIndex, offsetBy: 5))
        #expect(throws: ValhallaGeometryDecoder.DecodeError.malformedPolyline) {
            try ValhallaGeometryDecoder.decodePolyline(shape)
        }
    }

    // One full vertex followed by a lone latitude delta ("?" is zero), leaving no longitude to pair with it.
    @Test func rejectsLatitudeWithoutLongitude() {
        #expect(throws: ValhallaGeometryDecoder.DecodeError.malformedPolyline) {
            try ValhallaGeometryDecoder.decodePolyline("oxml_A`vh~_D?")
        }
    }

    // "_keqlD" is 91000000 at precision 6, i.e. 91 degrees of latitude, with a zero longitude delta after it.
    @Test func rejectsLatitudeAboveNinety() {
        #expect(throws: ValhallaGeometryDecoder.DecodeError.invalidCoordinate) {
            try ValhallaGeometryDecoder.decodePolyline("_keqlD?")
        }
    }

    @Test func rejectsUnsuccessfulStatus() {
        let data = jsonData(status: 442, legs: #"[{"shape":"oxml_A`vh~_D"}]"#)
        #expect(throws: ValhallaGeometryDecoder.DecodeError.unsuccessfulRoute) {
            try ValhallaGeometryDecoder.decodeLegs(from: data)
        }
    }

    @Test func rejectsResponseWithoutLegs() {
        #expect(throws: ValhallaGeometryDecoder.DecodeError.missingGeometry) {
            try ValhallaGeometryDecoder.decodeLegs(from: jsonData(status: 0, legs: "[]"))
        }
    }

    @Test func rejectsInvalidJSON() {
        #expect(throws: (any Error).self) {
            try ValhallaGeometryDecoder.decodeLegs(from: Data("not json".utf8))
        }
    }
}
