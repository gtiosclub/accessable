import Foundation
import Testing
@testable import AccessAble

struct ValhallaUnitsTests {
    private func fixture() throws -> Data {
        let url = try #require(Bundle.main.url(forResource: "valhalla-route-sample", withExtension: "json"))
            return try Data(contentsOf: url)
    }

    private func modifiedTrip(_ edit: (inout [String: Any]) -> Void) throws -> Data {
        var response = try #require(JSONSerialization.jsonObject(with: fixture()) as? [String: Any])
        var trip = try #require(response["trip"] as? [String: Any])
        edit(&trip)
        response["trip"] = trip
        return try JSONSerialization.data(withJSONObject: response)
    }

    @Test
    func normalizesFixtureAtEveryLevel() throws {
        let trip = try ValhallaGeometryDecoder.decodeNormalizedTrip(from: fixture())
        #expect(abs(trip.metrics.distanceMetres - 573) < 0.000001)
        #expect(trip.metrics.durationSeconds == 417.444)
        #expect(abs(trip.legs[0].metrics.distanceMetres - 573) < 0.000001)
        #expect(trip.legs[0].maneuverMetrics.count == trip.legs[0].geometry.steps.count)
        #expect(trip.legs[0].maneuverMetrics[0].distanceMetres == 26)
        #expect(trip.legs[0].maneuverMetrics[0].durationSeconds == 20.317)
    }

    @Test
    func convertsMilesAndPreservesSeconds() throws {
        // Synthetic units variant: one source distance unit now represents one mile.
        let data = try modifiedTrip { $0["units"] = "miles" }
        let trip = try ValhallaGeometryDecoder.decodeNormalizedTrip(from: data)
        #expect(abs(trip.metrics.distanceMetres - 0.573 * 1609.344) < 0.000001)
        #expect(abs(trip.legs[0].metrics.distanceMetres - 0.573 * 1609.344) < 0.000001)
        #expect(abs(trip.legs[0].maneuverMetrics[0].distanceMetres - 0.026 * 1609.344) < 0.000001)
        #expect(trip.metrics.durationSeconds == 417.444)
    }

    @Test(arguments: ["meters", "unknown"])
    func rejectsUnsupportedUnits(_ units: String) throws {
        let data = try modifiedTrip { $0["units"] = units }
        #expect(throws: ValhallaGeometryDecoder.DecodeError.unsupportedUnits) {
            try ValhallaGeometryDecoder.decodeNormalizedTrip(from: data)
        }
    }

    @Test
    func rejectsMissingSummary() throws {
        let data = try modifiedTrip { $0.removeValue(forKey: "summary") }
        #expect(throws: ValhallaGeometryDecoder.DecodeError.missingMetrics) {
            try ValhallaGeometryDecoder.decodeNormalizedTrip(from: data)
        }
    }

    @Test(arguments: [-1.0, Double.greatestFiniteMagnitude])
    func rejectsNegativeOrOverflowingLength(_ length: Double) throws {
        let data = try modifiedTrip { $0["summary"] = ["length": length, "time": 10] }
        #expect(throws: ValhallaGeometryDecoder.DecodeError.invalidMetrics) {
            try ValhallaGeometryDecoder.decodeNormalizedTrip(from: data)
        }
    }

    @Test
    func acceptsZeroValues() throws {
        let data = try modifiedTrip { $0["summary"] = ["length": 0, "time": 0] }
        let trip = try ValhallaGeometryDecoder.decodeNormalizedTrip(from: data)
        #expect(trip.metrics.distanceMetres == 0)
        #expect(trip.metrics.durationSeconds == 0)
    }

    @Test
    func rejectsNegativeDuration() throws {
        let data = try modifiedTrip { $0["summary"] = ["length": 1, "time": -1] }
        #expect(throws: ValhallaGeometryDecoder.DecodeError.invalidMetrics) {
            try ValhallaGeometryDecoder.decodeNormalizedTrip(from: data)
        }
    }
}
