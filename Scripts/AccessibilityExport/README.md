# Accessibility Data Export

This script retrieves accessibility features from OpenStreetMap (OSM) for the Georgia Tech campus test area. It generates a JSON export and a Markdown coverage summary.

## What it collects

The script uses the Overpass API to retrieve these accessibility feature types:

| Feature type | OSM tags used |
|---|---|
| crossing | `highway=crossing` for nodes and `footway=crossing` for ways |
| audible_signal | `traffic_signals:sound` |
| vibrating_signal | `traffic_signals:vibration` |
| tactile_paving | `tactile_paving` |
| curb | `barrier=kerb` or any `kerb` tag |
| elevator | `highway=elevator` |
| entrance | `entrance` |

An OSM element can match more than one feature type if it has multiple relevant tags. A tag set to `no` (for example `tactile_paving=no`) means the feature is absent, so it doesn't make the element match that type. Elements the query returns that match no type this way are left out of the JSON export.

## Test area

The default test area is the Georgia Tech campus in Atlanta, Georgia.

The rectangular area is defined near the top of `ExportAccessibilityData.swift` using these coordinates:

- `southLat`: southern boundary
- `westLon`: western boundary
- `northLat`: northern boundary
- `eastLon`: eastern boundary

The bounding-box order is south, west, north, east. Change these four values if a different test area is needed.

## Requirements

- A Mac with Swift installed.
- An internet connection to access the Overpass API.
- A local copy of the `accessable` repository.

Check that Swift is installed by running:

```bash
swift --version
```

## How to regenerate the export

1. Open Terminal in the repository root, which is the `accessable` folder.
2. Run the export script:

   ```bash
   swift Scripts/AccessibilityExport/ExportAccessibilityData.swift
   ```

3. The script prints the test-area information and generated Overpass query.
4. It requests the matching OSM data, counts the feature types, and calculates coverage gaps.
5. It writes the coverage summary and JSON export to `Data/AccessibilityExport/`.
6. It prints representative features with OpenStreetMap links and their original tags so that the exported information can be checked against the source.

The script creates the output directory if it does not already exist.

## Output files

The script generates these files in `Data/AccessibilityExport/`:

| File | Description |
|---|---|
| `accessibility_export.json` | Accessibility features, coordinates, original tags, normalized attributes, and export metadata |
| `coverage_summary.md` | Feature counts, coverage gaps, missing feature types, and source information |

### JSON export

The top-level JSON object includes:

- `source`: OpenStreetMap attribution and data source.
- `license`: ODbL license information.
- `endpoint`: Overpass API endpoint.
- `exportDate`: Date and time when the export was generated.
- `testArea`: Name of the test area.
- `boundingBox`: South, west, north, and east coordinates.
- `featureCount`: Number of exported features.
- `features`: The exported feature records.

Each feature contains its OSM element type and ID, matching feature types, latitude, longitude, normalized attributes, and original `tags`.

The normalized attributes are `tactilePaving`, `audibleSignal`, `vibratingSignal`, `kerb`, and `wheelchair`. When a corresponding tag is missing, its normalized field is set to `"unknown"`. The original OSM `tags` dictionary is retained.

For ways (for example a crossing drawn as a short line), the exported coordinates are the center point returned by `out center`, not the full line.

`accessibility_export.json` and `coverage_summary.md` are committed, so the app and other members can use the data without running the script. Regenerate both together so their export dates match.

## The Overpass query

The query is constructed by `makeQuery()` in `ExportAccessibilityData.swift` and printed in Terminal when the script runs.

To inspect the query results on a map, copy the printed query into [Overpass Turbo](https://overpass-turbo.eu).

The script sends the query to the Overpass API endpoint:

`https://overpass-api.de/api/interpreter`

## Checking the results

After running the script, inspect the generated files:

```bash
ls -lh Data/AccessibilityExport/
head -n 12 Data/AccessibilityExport/coverage_summary.md
```

To check that the JSON file is valid, run:

```bash
python3 -m json.tool Data/AccessibilityExport/accessibility_export.json > /dev/null
```

The command should finish without a JSON parsing error.

The script also prints up to three representative features per feature type, along with their OpenStreetMap URLs and original tags. Open the links and compare the tags on OpenStreetMap with the tags printed in Terminal.

### Last spot check

For the export dated 2026-10-16, one feature of each type from the printed spot check was compared by hand with its live OpenStreetMap record (tags, latitude and longitude):

| Feature type | OSM element | Result |
|---|---|---|
| crossing | node 69168333 | Tags and coordinates match |
| audible_signal | node 5674288136 | Tags and coordinates match |
| vibrating_signal | node 2048209351 | Tags and coordinates match |
| tactile_paving | node 69259142 | Tags and coordinates match |
| curb | node 523399947 | Tags and coordinates match |
| elevator | node 3078123263 | Tags and coordinates match |
| entrance | node 523233177 | Tags and coordinates match |

Across all 1254 exported features, every normalized attribute equals its original tag, or `"unknown"` when the tag is missing, and every feature has coordinates.

## Troubleshooting

If the Overpass request fails or returns a non-200 HTTP status, wait briefly and run the script again. The Overpass service may be temporarily busy.

Run the script from the repository root. The output path is relative, so running it anywhere else quietly creates a new `Data/AccessibilityExport/` folder in that directory instead of updating the committed files.

If a feature type has a count of zero, check the coverage summary. A missing feature type is a finding to investigate, not necessarily a script failure.

## Things to know

- `"unknown"` means that the corresponding tag is missing. It does not mean the physical feature is inaccessible.
- Nodes and ways are counted as individual OSM elements.
- The test area and query determine which features appear in the export.
- Loading the data into the app, caching it, and adding proximity callouts are separate tasks.
- OpenStreetMap data is licensed under ODbL. Credit: OpenStreetMap contributors.
