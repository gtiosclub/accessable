# Campus Landmarks Export

Exports the named buildings on the Georgia Tech campus from OpenStreetMap, with their nicknames (`short_name`, `loc_name`, `alt_name`, `official_name`, `old_name`), outlines and mapped entrances. The app bundles the result as `AccessAble/AccessAble/Resources/Maps/campus-landmarks.json`. Trips use it to know which buildings a route passes, so a sign the camera reads can be matched to one of them (LAND-2, LAND-3).

The test area is the same box as `Scripts/AccessibilityExport`.

## How to regenerate

From the repository root:

```bash
swift Scripts/CampusLandmarks/ExportCampusLandmarks.swift
```

It prints how many buildings, nicknames and entrances it found. The public Overpass server is sometimes busy; the script waits and retries a few times before giving up.

## What's in the file

- `buildings`: one entry per named building (OSM `building=*` ways and multipolygon relations), sorted by name.
  - `name`, `aliases`, and `osmType`/`osmId` to find it on openstreetmap.org.
  - `outlines`: outer rings as `[latitude, longitude]` pairs. A relation's outer ring split across several ways is joined back into one closed ring.
  - `entrances`: `entrance=*` nodes on the outline, with the entrance kind (`main`, `yes`, `exit`...), `wheelchair` and `automatic_door` when mapped.
- `exportDate`, `boundingBox`, `source` and `license` (ODbL, OpenStreetMap contributors).

A building missing nicknames or entrances means nobody has mapped them yet. Fixing them in OpenStreetMap and re-running the script improves matching for everyone.
