# Maps navigation reference

How a trip is guided, in `AccessAble/AccessAble/Models/Maps/`:
- `RouteProgressTracker` turns location fixes into progress along one `NavigationRoute`, and decides which guidance is due.
- `TripManager` speaks that guidance, reroutes, warns about weak GPS, and publishes `TripState`.
- `HeadingEstimator` works out which way the user is facing, so guidance can say "ahead" or "on your left".
- `RouteCrossings` places the bundled campus crossings on a route, for the crosswalk callouts and the route summary.
- `RouteSummary` words what a walk involves before the user starts it.

The doc comments and the constants in the code are the source of truth. Distances are metres along the route unless
stated otherwise.

## Tracker

The tracker is a pure struct. All time comes from fix timestamps, so a recorded walk always replays the same way. A
reroute replaces the tracker, since every window and flag refers to one route's geometry.

### Each fix

1. **Admit.** A fix is ignored when:
   - it is NaN or infinite;
   - it is no newer than the last fix;
   - it is more than 5 s older than the trip's start (a cached position);
   - its accuracy is worse than 25 m.
2. **Project ahead first.**
   - The search starts at the segment holding accepted progress and covers at least 100 m and 10 segments.
   - It looks up to 3 segments back only when the fix is more than 25 m from everything ahead.
   - While off route, it searches the whole route.
   - On identical geometry, such as an out-and-back leg, the leg ahead wins a tie only once it is in walking reach. That reach counts at most 10 s of standing, so waiting on the way out can't jump onto the way back.
3. **Gate progress.** Progress moves forward only, and only when all of these hold:
   - the fix is within `max(20 m, accuracy)` of the route;
   - the user is not off route;
   - the gain is at most `3 m/s × time since progress last moved + min(accuracy, 20 m)`.

   Past a turn of 60° or more, progress is also held while the fix looks like walking straight on. That means it is beyond the vertex, nearer the straight-on line than the route, and further from the route than its accuracy.
4. **Pass steps.**
   - A step is passed once two accepted fixes in a row are at least 5 m past its vertex.
   - The next step index never decreases, and the arrive step is never passed.

### Thresholds

| What | Value |
| --- | --- |
| Prepare cue | 40 m before the step |
| Now cue | 8 m before the step, and not once past its vertex |
| Leg needing a prepare at 40 m | at least 25 m |
| Short-leg prepare | on first sight, 8–20 m out |
| Stairs prepare | always, once the stairs are within 40 m, even with other steps before them |
| Crosswalk callout | 20 m before the crossing |
| Off route | over `max(30 m, 1.5 × accuracy)` from the route on 3 fixes spanning 10 s, having moved 8 m |
| Off route, walking away | over `max(20 m, 1.5 × accuracy)` from the route on 3 fixes spanning 5 s, with a walking direction more than 60° from the route's and no nearer the route than when the 5 s began |
| Back on route | within 15 m on 2 fixes at least 2 s apart |
| Missed turn | turns of 60° or more only; at least 15 m beyond the vertex along the straight-on line and 15 m from the route, on 2 fixes at least 2 s apart |
| Wrong way | in the first 40 m: moved 10 m from a fix accurate to 10 m, 5 m further from the route, progress under 3 m, current fix accurate to 10 m |
| Arrival | within 10 m of the end by progress, or a fix accurate to 15 m within `max(10 m, accuracy)` of the last vertex once progress is within 50 m of the end |

### Events

The events are `prepare`, `now`, `passedTurnConfirmation`, `missedTurn`, `crossing`, `wrongWay`, `offRoute`, `backOnRoute` and `arrived`.

- **`prepare`** is skipped when:
  - the start announcement covers it (a first step within 40 m);
  - the step says "Continue";
  - the previous step already said it (Valhalla's `verbal_multi_cue`).
  - None of these apply to stairs. A stairs step gets its `prepare` as soon as it is within 40 m, whatever comes before it, because a missed flight of stairs is a fall. Inside 8 m it comes just before the `now`.
- **`now`** is skipped for "Continue" after a multi-cue step.
  - Steps each within 8 m of the one before come up too quickly for a cue at each, so they are cued in the same update as the first, in order.
  - Only steps within 16 m of the group's first step join it. The rest are cued as they are reached, even before the earlier steps count as passed.
  - A step that a spoken multi-cue sentence already named gets no separate cue.
  - Grouped steps never get a confirmation.
- **`passedTurnConfirmation`** replaces a `now` that never fired. It is never a late turn instruction, which would make the user turn twice.
  - When several steps pass in one fix, only the last gets one.
  - There is none when the same update already cues a later step.
- **`crossing`** fires once per crossing, when it is 20 m or less ahead. A crossing already behind the user when first seen is skipped. In the same update it comes after any turn cue.
- **`offRoute`** has two rules, and either can fire.
  - The slow one needs no direction: far from the route for 10 s while moving.
  - A `wrongWay` due on the same fix is dropped, since off route says the same and more.
  - The fast one needs a walking direction, so standing at a crosswalk while GPS drifts can never trigger it. Walking the opposite way along a parallel path 20 m or more from the route does count.
- **`arrived`** is always alone and last.
- **While paused** (`emitsCues: false`), progress and off-route state still update. Turn cues and crosswalk callouts aren't emitted or used up, so the right one fires on resume. `offRoute`, `backOnRoute` and `arrived` are still emitted.

### Turn types

Valhalla's maneuver types map onto `ManeuverKind`. Types 39 to 43 are elevator, stairs, escalator, enter building and exit building, each with the attention haptic. Merges and roundabouts (25 to 27) are treated as straight; their instruction still names them.

## Heading

`HeadingEstimator` gives a heading in degrees from true north, or nothing. No direction beats a wrong one.

| Situation | Heading |
| --- | --- |
| Moving at 0.7 m/s or more, with a course accurate to 45° (or of unknown accuracy), from a fix at most 3 s old | the walking direction |
| Moving, but with no usable course | unknown, since a phone swinging in a pocket points anywhere |
| Standing still, speed unknown, or no fix in the last 3 s | the compass, if accurate to 25° and at most 3 s old |
| Anything else | unknown |

- The compass runs only while something is subscribed to `headingSamples()`: a trip, until it arrives or ends, and the location debug screen.
- The system's calibration screen is turned off, because it is a visual prompt. A compass that needs calibrating reports poor accuracy and reads as unknown.
- The debug screen shows the heading and where it came from.

## Crosswalks

- `Resources/Maps/campus-crossings.json` holds the campus crossings from OpenStreetMap. `Scripts/CampusCrossings/ExportCampusCrossings.swift` builds it from `Data/AccessibilityExport/accessibility_export.json`, with no network.
- A crossing is on a route when it is within 3 m of it. The route and the crossings are the same map data, so a crossing the route uses lies on it, while one over the road beside the path starts at the curb a few metres away.
- Crossings within 10 m of each other along the route are merged, keeping the most informative details.
- They are worked out when a trip starts and after each reroute.

## Route summary

`RouteSummary` is shown and announced on place details and the route picker when a route is found: "About 6 minutes, 450 feet. 3 turns, 1 flight of stairs, 2 crosswalks."

- Minutes are rounded, and at least 1.
- Turns are left, right, slight and U-turns.
- Stairs, elevators, escalators and crosswalks are listed only when there are some. With nothing to list it says "No turns."

## TripManager

- **Starting.**
  - The first state is published at once, with the first step after departure.
  - The start announcement waits 0.75 s, so VoiceOver moving focus off the Start button doesn't cut it off.
- **Generations.**
  - `startTrip` and `endTrip` bump a generation.
  - Each task and handler carries the generation it started for. It checks the generation before changing state or speaking after an `await`, so an ended or replaced trip can't act.
  - Reroutes bump a separate route version, which drops answers and cue checks for a replaced route.
- **Rerouting.**
  - On `offRoute` or `missedTurn`, the next fix accurate to 20 m asks for a new route, unless that fix brings the user back.
  - Requests are at least 30 s apart until one succeeds, then 15 s. There are at most 5 per trip.
  - A failure allows a retry after the same wait.
  - The user can also ask for one ("find another way"). It starts from the latest fix accurate to 20 m and is refused while the signal is weak.
  - There is no rerouting while paused. An answer that lands during a pause is applied without being announced.
  - An answer is dropped if, by the time it lands, the user is back on the route, has arrived, or the trip has ended or been replaced.
- **Off-route state.** While off route, `TripState.nextManeuver` keeps the next step's kind and coordinate, but its instruction is status text ("Off route. Finding a new route." or "Off route. Head back toward the path."). `distanceToNextManeuver` is nil.
- **Turn cues.**
  - `now` cues expire after `clamp((d + 5) / 1.3, 4, 15)` s.
  - A cue that was actually submitted, but not delivered by then, is resubmitted once. That needs the turn still ahead, no missed turn there, and the same route.
  - A cue held back by a pause isn't resubmitted; resuming speaks the next step instead.
  - Every dedup key starts with the trip ID and route version.
- **Weak signal.**
  - The watchdog checks every 5 s, after the first 5 s of a trip.
  - It warns when no fix accurate to 30 m and timestamped in the last 10 s has arrived. That's once per weak spell; a good fix ends the spell and is announced.
- **Trip tracking** (`CoreLocationProvider.setTripTracking`) is on only from start to end or arrival. It asks Core Location for navigation-grade accuracy (`kCLLocationAccuracyBestForNavigation`, activity type `.otherNavigation`) and for fixes with the screen locked. Outside a trip the app uses `kCLLocationAccuracyBest` with `.fitness`, which costs less battery. Each switch logs the latest fix's accuracy (category `Location`), to compare the two on a device. The Trip screen's other location subscriptions stay open in the background, so leaving it on would track the user whenever the app is open.
- **Pausing and arrival.**
  - Resuming says "In {distance}, …" for the next step, and tells the tracker so the next fix doesn't say the same prepare again.
  - Within 8 m of the step, or with a missed turn pending, resuming says nothing more than "Trip resumed.". The user may already be past the turn, so the next fix's turn cue, confirmation or missed turn says the right thing.
  - Resume speech is dropped if a reroute lands while "Trip resumed." is being said.
  - A turn cue that a pause stopped before it was submitted is given again by the tracker after resuming.
  - An arrival while paused stays paused and is announced on resume.

### Wording

Distances are spoken by `DistanceFormatter` in the user's units: feet rounded to 25 ft, then tenths of a mile from 500 ft; or metres rounded to 10 m, then tenths of a kilometre from 1 km. `{d}` below is that phrase, such as "about 150 feet".

Where two texts are given for one event, the first is used when the heading is known and the second when it isn't. `{direction}` is one of eight: "ahead", "slightly right", "on your right", "behind you on your right", "behind you", "behind you on your left", "on your left", "slightly left". It comes from the bearing to the target relative to the heading, in 45° sectors centred on straight ahead.

The path sentence is "The path is {direction}.", or "Turn around, the path is behind you." It points at the route 15 m beyond the user's progress. Before the first fix, the user is taken to be at the route's start.

| Event | Text | Priority | Expiry |
| --- | --- | --- | --- |
| start | "Starting directions to {name}, {d}. {path sentence}", then "In {d}, {instruction}" for a first step within 40 m (not stairs, which the first fix warns of). Heading unknown: "Starting directions to {name}, {d}. {first instruction}" | high | 15 s |
| prepare | "In {d}, {instruction}". For stairs: "In {d}, stairs going up.", "…stairs going down.", or "…stairs." when the instruction doesn't say which way | normal | 8 s |
| now | "{instruction}", with the maneuver's haptic | high | dynamic |
| passed turn | "Continue for {d}." | normal | 6 s |
| crosswalk | "Crosswalk ahead, with audible signal." / "Crosswalk ahead, with a traffic signal." / "Crosswalk ahead." / "Road crossing ahead, unmarked.", with the attention haptic | high | 8 s |
| missed turn | "You may have passed the turn. Finding a new route." while a reroute is in flight or allowed. Otherwise "…It is {direction}, {d} away. From there, {instruction}", or with the heading unknown "…Turn around and walk back {d}, then {instruction}" | high | 12 s |
| wrong way | "You're walking away from the route. {path sentence}". Heading unknown: "You seem to be walking away from the route. Turn around." | high | 10 s |
| off route | "You're off the route. Finding a new route.", or "…Head back toward the path." once no reroutes are left or in flight | high | 10 s |
| back on route | "Back on the route." | normal | 6 s |
| new route | "New route. {first instruction}" | high | 15 s |
| reroute asked for | "Finding a new route from here.", or "Couldn't find where you are precisely enough for a new route. Try again in a moment." | high | 10 s |
| reroute failed | "Couldn't get a new route. Walk back the way you came."; after the fifth: "Off route. End the trip and choose your destination again."; asked for while still on the route: "Couldn't get a new route. Keep following the current one." | high | 10 s |
| arrived | "Arriving at {name}. {name} is {direction}.", when the latest fix is at least 5 m from the destination. Otherwise, or with the heading unknown: "Arriving at {name}. {arrive instruction}" | high | 15 s |
| weak / back | "GPS signal is weak. Directions may be delayed." / "GPS signal is back." (system category) | high / normal | 10 s / 6 s |
| pause, resume, end | "Trip paused." / "Trip resumed." / "Trip ended.", with no dedup key, so the engine merges them with the voice command's | high | none |

## Known limits

- **The compass says where the phone points, not where the user faces.** Standing still with the phone in a pocket or a bag, a compass reading that looks accurate can still give the wrong "ahead". Once the user is walking, the walking direction takes over.
- **Not checked on a device yet:** navigation-grade accuracy, the compass, the faster off-route rule and the crosswalk callouts have only run in tests and the simulator, which has no compass.
- **Crosswalk callouts only exist on campus,** inside the area the bundled export covers, and are as good as OpenStreetMap's tagging there. Only 5 crossings are tagged with an audible signal.
- **A crossing within about 10 m of the destination** may not be announced, because arriving ends guidance first.
- **Stairs direction is rarely known.** Valhalla usually says "Take the stairs" without up or down. Only "stairs up", "up the stairs", "upstairs" and their "down" forms count.
- **A crossing right at a street corner** that the route passes without using could still be within 3 m and be announced. This needs checking on real campus routes.
- **Valhalla's turn-type numbers and stairs wording** haven't been checked against a live route through a building.
- **Wrong way is strict.**
  - It needs a fix accurate to 10 m at both ends of the movement.
  - With none in the first 40 m, there is no warning, which beats a false "turn around".
- **Missed-turn detection covers turns of 60° or more only.**
  - Walking straight past a gentler bend relies on off-route detection.
  - At 30°, that can take about 60 m.
- **Out-and-back routes with identical legs.** Reach onto the return leg counts at most 10 s.
  - A GPS dropout of more than about 10 s right at the turnaround can leave progress stuck there, with no further
    cues. The return leg is on the route, so off-route detection doesn't catch it.
  - Ending and restarting the trip recovers.
