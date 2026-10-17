# Maps geometry reference

Inputs and outputs of `GeoMath` and the route types in `NavigationModels.swift` (both in
`AccessAble/AccessAble/Models/Maps/`), for whoever turns Valhalla responses into `NavigationRoute`s and whoever builds
the trip tracker on top of `projection(of:segments:)`. The doc comments in the code are the source of truth.

All of it treats the Earth as a sphere. Coordinates are WGS84 degrees (`GeoCoordinate(latitude:longitude:)`),
distances are metres, and bearings are degrees clockwise from true north. The sphere is within 0.5% of the WGS84
ellipsoid, far below GPS error. Route distances and projection use the same sphere, so they agree with each other.

## `GeoMath.earthRadius`

Mean Earth radius, `6_371_008.8` metres. Every distance below is measured on a sphere of this radius.

```swift
let halfCircumference = GeoMath.earthRadius * .pi
```

## `GeoMath.distance(from:to:)`

Great-circle distance between two points.

- **Inputs:** two coordinates in degrees, assumed valid (latitude -90...90, longitude -180...180). They are not
  checked; `NavigationRoute` is what validates route data.
- **Output:** metres, from 0 up to `earthRadius * .pi` (about 20,015 km). Symmetric.
- **Same point:** exactly 0.
- **Short distances:** accurate at walking distances, down to centimetres.
- **Antipodes:** close to `earthRadius * .pi` and never above it; rounding there costs tenths of a metre.
- **Poles and the dateline:** handled; longitudes either side of ±180 give the short way round.
- **NaN or infinite input:** returns NaN instead of trapping.

```swift
let metres = GeoMath.distance(from: fix.coordinate, to: destination.coordinate)
```

## `GeoMath.bearing(from:to:)`

Initial direction to head from `start` to reach `end` along the great circle.

- **Inputs:** two coordinates in degrees, assumed valid.
- **Output:** degrees clockwise from true north, `0..<360`.
- **Same point:** exactly 0.
- **Under about a micrometre apart:** rounding noise dominates, so check `distance` first.
- **From a pole, or between antipodal points:** undefined; the result is finite and in range but arbitrary.
- **NaN or infinite input:** returns NaN.

```swift
let heading = GeoMath.bearing(from: fix.coordinate, to: route.coordinates[nextIndex])
```

## `GeoMath.normalizedBearing(_:)`

Wraps any angle in degrees into `0..<360`.

- **Input:** any finite angle in degrees, negative or past 360.
- **Output:** `0..<360`, never -0. Exactly -360, 360 and tiny negatives such as -1e-14 all give 0.
- **NaN or infinite input:** returns NaN.
- For a signed turn in -180...180 relative to the user's facing, use `RelativeBearing` instead.

```swift
let opposite = GeoMath.normalizedBearing(heading + 180)
```

## `GeoMath.cumulativeDistances(along:)`

Metres from the first coordinate to each coordinate along a path.

- **Input:** coordinates in path order, assumed valid.
- **Output:** same count as the input, starts at 0, never decreases.
- **Empty input:** empty output. **One coordinate:** `[0]`.
- **Repeated coordinate (zero-length segment):** adds 0, so neighbouring entries are equal.
- **NaN or infinite coordinate:** every entry from that coordinate on is NaN.

```swift
let distances = GeoMath.cumulativeDistances(along: coordinates)
```

`NavigationRoute` calls this for you; you rarely need it directly.

## `NavigationRoute`

A route that is always valid: it can only be created, or decoded, through the throwing init, which also derives the
distances.

```swift
let route = try NavigationRoute(coordinates: coordinates, steps: steps, estimatedDuration: seconds)
```

### What validation rejects

Checked in this order; the first failure is thrown as `NavigationRoute.ValidationError`:

| Error | Rejected input |
| --- | --- |
| `tooFewCoordinates` | fewer than 2 coordinates |
| `invalidCoordinate(index:)` | first coordinate whose latitude is not in -90...90 or longitude not in -180...180 |
| `missingArrival` | `steps` empty, or its last step's `kind` is not `.arrive` |
| `invalidDuration` | `estimatedDuration` (seconds) NaN, infinite or negative |
| `stepIndexOutOfRange`/`stepsOutOfOrder` | then each step in order: out of range, or before the previous step's index |

NaN and infinite coordinates fail the range check. Both step checks run per step, so the first bad step wins, and
two steps may share an index. Repeated coordinates (zero-length segments) are allowed. Only `coordinates`, `steps`
and `estimatedDuration` are encoded; decoding re-runs validation and throws `DecodingError.dataCorrupted` wrapping
the validation error. The routing client reports a response that fails validation as `RoutingError.invalidResponse`.

### `cumulativeDistances` and `totalDistance`

- `cumulativeDistances`: metres from the start to each coordinate, same count as `coordinates`, starting at 0 and
  never decreasing. Always finite, since validation rejects non-finite coordinates.
- `totalDistance`: metres, the last entry of `cumulativeDistances`.

```swift
let remaining = route.totalDistance - projection.distanceAlongRoute
let toStep = route.cumulativeDistances[step.coordinateIndex] - projection.distanceAlongRoute
```

### `projection(of:segments:)`

The closest point on the route to `point`, exact on the sphere. Segment `i` joins `coordinates[i]` to
`coordinates[i + 1]`.

- **`point`:** any coordinate, typically a GPS fix.
- **`segments`:** segment indices to search; defaults to the whole route, `0..<coordinates.count - 1`. It must be
  non-empty and within that range, or the call traps.
- **Before the start or past the end** of the searched segments, the projection clamps to that endpoint.
- **Foot within about 1 mm of a vertex:** the projection is the vertex itself. `distanceAlongRoute` equals its
  `cumulativeDistances` entry exactly, and `sideOffset` is the distance to it.
- **Zero-length segments** (under about 1 mm): count as their start point and have no side, so their offset is never
  negative.
- **Ties:** only exactly equal distances (identical geometry, such as a shared vertex or an out-and-back leg) tie, and
  they go to the lowest segment index. Near-ties go to whichever segment rounding favours.
- **Point at or near the pole of a segment's great circle** (about 90° from every point on it): the candidates are
  equally far to within rounding, so which segment and foot win is arbitrary.
- **NaN or infinite point:** `distanceAlongRoute` and `sideOffset` are NaN, `originalCoordinate` and `coordinate` are
  the point, and `segmentIndex` is the first searched segment.

```swift
let projection = route.projection(of: fix.coordinate)
let nearby = route.projection(of: fix.coordinate, segments: 3..<6)
```

## `RouteProjection`

| Field | Meaning |
| --- | --- |
| `originalCoordinate` | the point that was projected, unchanged, even after snapping, clamping or vertex rounding |
| `coordinate` | closest point on the route (the foot) |
| `segmentIndex` | segment holding `coordinate`, from `coordinates[segmentIndex]` to `coordinates[segmentIndex + 1]` |
| `distanceAlongRoute` | metres from the route start to `coordinate`, 0...`totalDistance` for a finite point |
| `sideOffset` | metres from `coordinate` to the original point: **negative left** of travel, positive right |

`abs(sideOffset)` equals `GeoMath.distance(from: point, to: coordinate)` exactly. Its sign comes from which side of
the chosen segment's great circle the point is on, even when the projection is clamped to an endpoint.

```swift
let side = projection.sideOffset < 0 ? "on your left" : "on your right"
```

## Using projection in the trip tracker

- **Check that `distanceAlongRoute` and `sideOffset` are both finite before use.** A NaN or infinite fix gives NaN
  progress and offset rather than trapping, and an absurd but finite latitude can make only the offset NaN.
- **Compare arrival with a tolerance.** Past the end of a route whose last segment is under about 1 mm,
  `distanceAlongRoute` can be up to 1 mm short of `totalDistance`, so `==` may never be true.
- **Treat the side as unreliable when `abs(sideOffset)` is tiny or the projection is on a vertex.** At a corner the
  sign comes from whichever segment won, and on a zero-length segment it is never negative.
- **Clamp `segments:` to `0..<coordinates.count - 1` before calling.** An empty or out-of-range range is a
  precondition failure, not an error.
- **Restrict `segments:` for continuity.** On switchbacks and out-and-back paths the whole-route closest point can be
  on a leg the user has not reached, so search a window around the last known segment. That `previous` projection
  must come from the same route: on a reroute, drop it and search the whole new route.

```swift
guard projection.distanceAlongRoute.isFinite, projection.sideOffset.isFinite else { return }
let arrived = route.totalDistance - projection.distanceAlongRoute <= arrivalRadius
```

```swift
let segmentCount = route.coordinates.count - 1
let window = max(previous.segmentIndex - 1, 0)..<min(previous.segmentIndex + 3, segmentCount)
let projection = route.projection(of: fix.coordinate, segments: window)
```
