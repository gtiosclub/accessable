/// Written out rather than read from `GeoMath` so reference values stay independent of the code under test.
enum SphereReference {
    /// Mean Earth radius in metres.
    static let radius = 6_371_008.8
    /// Arc length of one degree along a great circle.
    static let metresPerDegree = Double.pi * radius / 180
}
