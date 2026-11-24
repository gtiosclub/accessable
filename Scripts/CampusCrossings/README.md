# Campus Crossings Export

Exports the street crossings on the Georgia Tech campus, with how each one is controlled and whether its signal is audible. The app bundles the result as `AccessAble/AccessAble/Resources/Maps/campus-crossings.json`. Trips use it to say "Crosswalk ahead" before each crossing on the route (NAV-6).

It reads the OpenStreetMap export in `Data/AccessibilityExport/accessibility_export.json` and makes no network requests, so it covers the same area as `Scripts/AccessibilityExport`.

## How to regenerate

From the repository root, after refreshing the accessibility export if needed:

```bash
swift Scripts/CampusCrossings/ExportCampusCrossings.swift
```

It prints how many crossings it found of each kind. Running it again on the same input gives an identical file.

## What's in the file

- `crossings`: one entry per crossing in the export (`highway=crossing` nodes, and `footway=crossing` ways as their centre points), sorted by latitude then longitude.
  - `latitude`, `longitude`.
  - `control`, from the first rule that matches:
    - `signals`: `crossing=traffic_signals` or `crossing:signals=yes`.
    - `unmarked`: `crossing=unmarked` or `crossing:markings=no`.
    - `marked`: `crossing=marked`, `zebra` or `uncontrolled`, or any other `crossing:markings` value.
    - `unknown`: none of these.
  - `audibleSignal`: true only when `traffic_signals:sound=yes`.
- `exportDate` (copied from the accessibility export), `source` and `license` (ODbL, OpenStreetMap contributors).

A node and a way often describe the same crossing; the app merges entries that close together on a route. A crossing marked `unknown`, or a signal without `traffic_signals:sound`, means nobody has mapped it yet. Fixing it in OpenStreetMap and re-running both exports improves the callouts for everyone.
