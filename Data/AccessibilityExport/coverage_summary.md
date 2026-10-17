# Accessibility Data Coverage Summary

- Test area: Georgia Tech campus, Atlanta GA
- Export date: 2026-10-16T22:36:45Z
- Source: OpenStreetMap contributors, through the Overpass API (https://overpass-api.de/api/interpreter)
- License: ODbL (https://www.openstreetmap.org/copyright)
- Bounding box (south, west, north, east): 33.77, -84.408, 33.782, -84.388
- Total elements found: 1270

## Feature counts

| Feature type | Count |
|---|---|
| crossing | 682 |
| audible_signal | 5 |
| vibrating_signal | 2 |
| tactile_paving | 308 |
| curb | 362 |
| elevator | 10 |
| entrance | 197 |

## Coverage gaps

- crossings with a tactile_paving tag: 94 of 682 (14%)
- crossings with a kerb tag: 0 of 682 (0%)
- entrances with a wheelchair tag: 16 of 197 (8%)
- elevators with a wheelchair tag: 0 of 10 (0%)
- Signalized crossings with sound/vibration tags: 18 of 176 (10%)

## Feature types with nothing found

- None, every feature type has at least one feature

## Notes

- A missing tag means nobody has mapped it yet. It does NOT mean the feature is not accessible.
- Lines (ways) are counted as one feature each. A crossing mapped as both a road node and a footway line is counted twice.
- Curb details are usually on separate kerb nodes at each end of a crossing, so few crossings carry a kerb tag themselves.
- Feature counts skip tags set to "no"; the coverage gaps count any tag, including "no".
- The JSON export leaves out elements whose only matching tag is "no", so it can list fewer features than the total above.
