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
