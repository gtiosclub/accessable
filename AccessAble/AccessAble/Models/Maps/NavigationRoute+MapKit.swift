import MapKit

extension NavigationRoute {
    /// The route's bounds grown by `margin` (a fraction of the bounds) on every side, so the line and its markers
    /// stay clear of the map's edges. Each side is at least `minimumSpan` metres, so a short route isn't zoomed in
    /// to a single building.
    func cameraRect(margin: Double = 0.2, minimumSpan: Double = 200) -> MKMapRect {
        let points = coordinates.map { MKMapPoint($0.clCoordinate) }
        let minX = points.map(\.x).min() ?? 0
        let maxX = points.map(\.x).max() ?? 0
        let minY = points.map(\.y).min() ?? 0
        let maxY = points.map(\.y).max() ?? 0
        let center = MKMapPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)

        // map points per metre grow away from the equator
        let minimumSize = minimumSpan * MKMapPointsPerMeterAtLatitude(center.coordinate.latitude)
        let width = max((maxX - minX) * (1 + 2 * margin), minimumSize)
        let height = max((maxY - minY) * (1 + 2 * margin), minimumSize)
        return MKMapRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
    }
}
