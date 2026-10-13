// ExportAccessibilityData.swift.
// M5 - ACCESS-1: Audit and export OSM accessibility features.
// Step 1: define the test area.

import Foundation

// Set the name of the test area
let testAreaName = "Georgia Tech campus, Atlanta GA"

// The test area is a rectangle.
// The Overpass API is strict, so the edges are in this order: south, west, north, east
let southLat = 33.7700   // bottom edge of the box
let westLon = -84.4080   // left edge of the box
let northLat = 33.7820   // top edge of the box
let eastLon = -84.3880   // right edge of the box

// These are just safety checks.
// I'm making sure that the box even makes sense.
if southLat >= northLat {
    print("Problem: southLat should be smaller than northLat")
    exit(1)
}
if westLon >= eastLon {
    print("Problem: westLon should be smaller than eastLon")
    exit(1)
}

// I'm finding the center so we can look at it on a map
let centerLat = (southLat + northLat) / 2
let centerLon = (westLon + eastLon) / 2

// I'm figuring out how big the box is.
// You multiply by 111 since 1 latitude degree is about 111km.
// Longitude gets shorter as you move away from the equator, so we
// multiply by the cosine of the latitude.
let heightKm = (northLat - southLat) * 111.0
let widthKm = (eastLon - westLon) * 111.0 * cos(centerLat * Double.pi / 180)

// Printing the values so I can check them
print("Test area: \(testAreaName)")
print("South: \(southLat)  West: \(westLon)  North: \(northLat)  East: \(eastLon)")
print("Center: \(centerLat), \(centerLon)")
print("Size: about \(String(format: "%.1f", widthKm)) km wide by \(String(format: "%.1f", heightKm)) km tall")
print("See it on a map: https://www.openstreetmap.org/?minlon=\(westLon)&minlat=\(southLat)&maxlon=\(eastLon)&maxlat=\(northLat)&box=yes")


// Step 2: Overpass query

// Builds the text of the Overpass query.
// Overpass is the tool that lets us ask OpenStreetMap for specific features.
func makeQuery() -> String {
    // Overpass needs the box in this format: south, west, north, east
    let box = "\(southLat),\(westLon),\(northLat),\(eastLon)"

    // This is the JSON query.
    // ( ) is a union, so we get anything as long as it matches any line.
    // [ ] are filters on the tags of each OSM element.
    // node is a single point, while way is a line.
    let query = """
    [out:json][timeout:60];
    (
      // Crossings: points tagged highway=crossing, and lines tagged footway=crossing
      node["highway"="crossing"](\(box));
      way["footway"="crossing"](\(box));
      // Audible signals: any node that has the traffic_signals:sound tag
      node["traffic_signals:sound"](\(box));
      // Tactile paving: any node or way that has the tactile_paving tag
      node["tactile_paving"](\(box));
      way["tactile_paving"](\(box));
      // Curbs: nodes tagged barrier=kerb, or any node with a kerb tag
      node["barrier"="kerb"](\(box));
      node["kerb"](\(box));
      // Elevators: nodes tagged highway=elevator
      node["highway"="elevator"](\(box));
      // Entrances: any node with the entrance tag
      node["entrance"](\(box));
    );
    out center;
    """
    return query
}

// Build the query and print it so we can copy it into overpass-turbo.eu to test it
let query = makeQuery()
print("")
print("Overpass query:")
print(query)
