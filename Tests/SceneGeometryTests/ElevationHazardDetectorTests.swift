import Foundation
import Testing
@testable import SceneGeometry

@Suite("T12 — curbs, drop-offs and elevation changes")
struct ElevationHazardDetectorTests {
    @Test("the task sheet's 18 cm drop")
    func sheetExample() throws {
        let samples = [
            GroundSample(forwardDistance: 0.5, height: 0.00),
            GroundSample(forwardDistance: 1.0, height: 0.01),
            GroundSample(forwardDistance: 1.5, height: 0.00),
            GroundSample(forwardDistance: 2.0, height: -0.18),
        ]

        let hazards = detectElevationHazards(samples: samples)

        #expect(hazards.count == 1)
        let hazard = try #require(hazards.first)
        #expect(hazard.type == .stepDown)
        #expect(abs(hazard.heightChange + 0.18) < 0.01)
        // 1.5 m, not the 2.0 m of the sheet's own worked example: 1.5 m is the last
        // distance the ground was confirmed level, and the edge is somewhere after it.
        // Announcing the near side is the only safe rounding direction for a blind user.
        #expect(abs(hazard.distance - 1.5) < 0.01)
        // The 1 cm wobble at 1.0 m is noise, and does not become a hazard of its own.
    }

    @Test("a 60 cm fall is a drop-off, not a step")
    func dropOff() throws {
        let samples = groundProfile(from: 0.2, to: 3.0) { $0 < 2.0 ? 0 : -0.6 }

        let hazards = detectElevationHazards(samples: samples)

        #expect(hazards.count == 1)
        let hazard = try #require(hazards.first)
        #expect(hazard.type == .dropOff)
        #expect(abs(hazard.heightChange + 0.6) < 0.02)
        #expect(abs(hazard.distance - 1.95) < 0.2)
    }

    @Test("a 15 cm rise is a step up")
    func stepUp() throws {
        let samples = groundProfile(from: 0.2, to: 3.0) { $0 < 1.5 ? 0 : 0.15 }

        let hazards = detectElevationHazards(samples: samples)

        #expect(hazards.count == 1)
        let hazard = try #require(hazards.first)
        #expect(hazard.type == .stepUp)
        #expect(abs(hazard.heightChange - 0.15) < 0.02)
    }

    @Test("a 1:12 ramp is not a hazard")
    func rampIsNotAStep() {
        // Rises 25 cm over 3 m — more total height than the drop-off above, but spread
        // out. Height alone would flag it; the slope test is what doesn't.
        let samples = groundProfile(from: 0.2, to: 3.2) { ($0 - 0.2) / 12 }

        #expect(detectElevationHazards(samples: samples).isEmpty)
    }

    @Test("a flight of stairs reports every riser")
    func staircase() {
        let samples = groundProfile(from: 0.2, to: 1.8) { distance in
            guard distance >= 0.5 else { return 0 }
            return min(0.68, 0.17 * (((distance - 0.5) / 0.3).rounded(.down) + 1))
        }

        let hazards = detectElevationHazards(samples: samples)

        #expect(hazards.count == 4)
        #expect(hazards.allSatisfy { $0.type == .stepUp })
        #expect(hazards.allSatisfy { abs($0.heightChange - 0.17) < 0.02 })
    }

    @Test("a single depth spike does not invent a step")
    func noiseSpikeRejected() {
        let samples = groundProfile(from: 0.2, to: 2.0) { _ in 0 }
            .map { abs($0.forwardDistance - 1.0) < 0.001
                ? GroundSample(forwardDistance: $0.forwardDistance, height: 0.3)
                : $0
            }

        #expect(detectElevationHazards(samples: samples).isEmpty)
    }

    @Test("a hole in coverage is reported as unknown, not guessed at")
    func interiorGap() throws {
        let samples = groundProfile(from: 0.2, to: 1.0) { _ in 0 }
            + groundProfile(from: 2.0, to: 3.0) { _ in 0 }

        let hazards = detectElevationHazards(samples: samples)

        #expect(hazards.count == 1)
        let hazard = try #require(hazards.first)
        #expect(hazard.type == .unknown)
        #expect(hazard.heightChange == 0)
        #expect(abs(hazard.distance - 1.0) < 0.1)
    }

    @Test("coverage that simply stops is a drop-off")
    func trailingCliff() throws {
        // The real signature of a kerb edge: nothing past it reflects anything back.
        var tuning = ElevationTuning.default
        tuning.expectedMaxDistance = 4.0
        let samples = groundProfile(from: 0.2, to: 2.0) { _ in 0 }

        let hazards = detectElevationHazards(samples: samples, tuning: tuning)

        #expect(hazards.count == 1)
        let hazard = try #require(hazards.first)
        #expect(hazard.type == .dropOff)
        // 0 because the depth of the drop is exactly what the sensor could not see.
        #expect(hazard.heightChange == 0)
        #expect(abs(hazard.distance - 2.0) < 0.1)
    }

    @Test("without a sensor range, a short profile is not assumed to be a cliff")
    func noRangeMeansNoTrailingGuess() {
        #expect(detectElevationHazards(samples: groundProfile(from: 0.2, to: 2.0) { _ in 0 }).isEmpty)
    }

    @Test("too little data yields nothing")
    func insufficientSamples() {
        #expect(detectElevationHazards(samples: []).isEmpty)
        #expect(detectElevationHazards(samples: [GroundSample(forwardDistance: 1, height: 0)]).isEmpty)
    }

    @Test("non-finite samples are dropped, not propagated")
    func nonFiniteSamples() throws {
        var samples = groundProfile(from: 0.2, to: 3.0) { $0 < 1.5 ? 0 : -0.3 }
        samples.append(GroundSample(forwardDistance: .nan, height: 0))
        samples.append(GroundSample(forwardDistance: 1.0, height: .infinity))

        let hazards = detectElevationHazards(samples: samples)

        #expect(hazards.count == 1)
        #expect(try #require(hazards.first).type == .dropOff)
    }

    @Test("samples arriving out of order are sorted first")
    func unorderedInput() throws {
        let ordered = groundProfile(from: 0.2, to: 3.0) { $0 < 1.5 ? 0 : -0.18 }

        let fromShuffled = detectElevationHazards(samples: ordered.reversed())
        let fromOrdered = detectElevationHazards(samples: ordered)

        #expect(fromShuffled == fromOrdered)
        #expect(try #require(fromOrdered.first).type == .stepDown)
    }
}
