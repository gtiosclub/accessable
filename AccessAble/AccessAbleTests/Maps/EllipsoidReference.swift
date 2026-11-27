import Foundation

/// Distances on the WGS-84 ellipsoid by Vincenty's inverse formula (1975), accurate to well under a millimetre.
/// Written out rather than taken from CoreLocation, whose answer can differ from run to run, so reference values are
/// the same every time and independent of the code under test.
enum EllipsoidReference {
    /// Semi-major axis in metres.
    static let semiMajorAxis = 6_378_137.0
    static let flattening = 1 / 298.257_223_563

    /// The geodesic distance in metres between two points given in degrees. Doesn't converge for nearly antipodal
    /// points, where it stops the test.
    static func distance(fromLatitude latitude1: Double, longitude longitude1: Double,
                         toLatitude latitude2: Double, longitude longitude2: Double) -> Double {
        let a = semiMajorAxis
        let f = flattening
        let b = (1 - f) * a
        let l = (longitude2 - longitude1) * .pi / 180
        let u1 = atan((1 - f) * tan(latitude1 * .pi / 180))
        let u2 = atan((1 - f) * tan(latitude2 * .pi / 180))
        let (sinU1, cosU1, sinU2, cosU2) = (sin(u1), cos(u1), sin(u2), cos(u2))

        var lambda = l
        var sinSigma = 0.0, cosSigma = 0.0, sigma = 0.0, cosSqAlpha = 0.0, cos2SigmaM = 0.0
        for iteration in 0... {
            precondition(iteration < 200, "Vincenty's formula didn't converge")
            let (sinLambda, cosLambda) = (sin(lambda), cos(lambda))
            sinSigma = ((cosU2 * sinLambda) * (cosU2 * sinLambda)
                + (cosU1 * sinU2 - sinU1 * cosU2 * cosLambda) * (cosU1 * sinU2 - sinU1 * cosU2 * cosLambda)).squareRoot()
            if sinSigma == 0 { return 0 }
            cosSigma = sinU1 * sinU2 + cosU1 * cosU2 * cosLambda
            sigma = atan2(sinSigma, cosSigma)
            let sinAlpha = cosU1 * cosU2 * sinLambda / sinSigma
            cosSqAlpha = 1 - sinAlpha * sinAlpha
            // along the equator cos²α is 0, and so is this term
            cos2SigmaM = cosSqAlpha == 0 ? 0 : cosSigma - 2 * sinU1 * sinU2 / cosSqAlpha
            let c = f / 16 * cosSqAlpha * (4 + f * (4 - 3 * cosSqAlpha))
            let previous = lambda
            lambda = l + (1 - c) * f * sinAlpha
                * (sigma + c * sinSigma * (cos2SigmaM + c * cosSigma * (-1 + 2 * cos2SigmaM * cos2SigmaM)))
            if abs(lambda - previous) < 1e-12 { break }
        }

        let uSq = cosSqAlpha * (a * a - b * b) / (b * b)
        let bigA = 1 + uSq / 16384 * (4096 + uSq * (-768 + uSq * (320 - 175 * uSq)))
        let bigB = uSq / 1024 * (256 + uSq * (-128 + uSq * (74 - 47 * uSq)))
        let deltaSigma = bigB * sinSigma * (cos2SigmaM + bigB / 4 * (cosSigma * (-1 + 2 * cos2SigmaM * cos2SigmaM)
            - bigB / 6 * cos2SigmaM * (-3 + 4 * sinSigma * sinSigma) * (-3 + 4 * cos2SigmaM * cos2SigmaM)))
        return b * bigA * (sigma - deltaSigma)
    }
}
