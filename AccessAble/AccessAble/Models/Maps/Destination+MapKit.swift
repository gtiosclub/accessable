import MapKit

extension Destination {
    // MapKit can return a place without a name; fall back to the suggestion title the user tapped
    init(mapItem: MKMapItem, fallbackName: String) {
        self.init(
            name: mapItem.name ?? fallbackName,
            coordinate: GeoCoordinate(mapItem.location.coordinate),
            address: mapItem.address?.shortAddress ?? mapItem.address?.fullAddress
        )
    }
}
