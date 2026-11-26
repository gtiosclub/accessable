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
   - A segment ahead counts only when the fix's nearest point on it is no further along the route than the straight
     line to it from accepted progress, plus 40 m (twice the lateral gate, for the inside of a corner). Where the
     route doubles back, as round a block, its far side is much nearer in a straight line. A user walking across to
     it is measured from the route they left, so they go off route instead of skipping the turns between unheard.
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
5. **Switching source.** When a fix's `source` (GPS or AR) differs from the last used fix's, the step between them
   isn't movement: the two can place someone standing still well apart, perhaps 15 to 25 m, though that is an
   estimate until it is measured on a device.
   - Within 4 s of the last used fix (`LocationFusion.arLifetime` + 1 s, as long as the fusion takes to switch), the
     wrong-way origin and the first fix of the off-route and walking-away runs move by that step, so movement on
     each side of the switch still adds up while the step counts for nothing. The runs keep their start times and
     counts, so a source that keeps switching can't hold off a warning.
   - After a longer gap the step holds walking too, which shifting would erase, so those runs start over from the
     new fix and take their usual time from it.
   - A missed turn's run carries on across a switch, since each of its fixes is judged on where it is. One fix
     short of the turn is forgiven as noise only from the run's own source: a fix from the other source placing the
     user short ends the run, and once a short fix has been forgiven, only the run's own source can confirm it.
   - Progress and a rejoin carry on too; progress's gate already holds off a jump.

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
| Off route, walking away | over `max(20 m, 1.5 × accuracy)` from the route on 3 fixes with a walking direction, spanning 5 s, each walking more than 60° from the route's direction and not 30° or more back toward it, and ending no nearer the route than the first |
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
  - Outdoors a fix is several metres off and one course in a few is too rough to use, so the fast rule is decided by what each fix can tell. A fix without a usable walking direction neither counts nor ends the run. One fix short of the distance doesn't end it; two in a row do. Walking back toward the route is told from the course, since noise alone often puts one fix nearer than another.
  - The route's direction is the leg being walked. A segment behind progress, found by the search behind, can run another way, as the leg before a corner does for someone on its inside.
- **`arrived`** is always alone and last.
- **While paused** (`emitsCues: false`), progress and off-route state still update. Turn cues and crosswalk callouts aren't emitted or used up, so the right one fires on resume. `offRoute`, `backOnRoute` and `arrived` are still emitted.

### Turn types

Valhalla's maneuver types map onto `ManeuverKind`. Types 39 to 43 are elevator, stairs, escalator, enter building and exit building, each with the attention haptic. Merges and roundabouts (25 to 27) are treated as straight; their instruction still names them.

## Location source

`FusedLocationProvider` (AR-3) passes on GPS, or ARKit geo-tracking's position while it is locked on, never both, and marks each fix's `source`. Outside trips the camera doesn't geo-track, so it is GPS alone. `LocationFusion` decides, from reading timestamps only:

- **Into AR:** 3 AR readings in a row (`arEntryReadings`), spanning at least 2 s (`arEntrySpan`), each graded medium or better and within GPS's accuracy + 20 m (`disagreementAllowance`) of a GPS fix at most 5 s from it (`gpsFreshness`). With no fresh GPS fix, AR can't be checked for a lock on the wrong street, so it isn't trusted.
- **Staying on AR:** each such reading trusts AR for 3 s more (`arLifetime`), and GPS fixes in that time are held back. Geo-tracking sends a reading on the first frame at least 1 s after the last (`GeoTrackingUpdate.interval`, which `ARSessionManager` throttles by), so gaps run a frame or so over a second; 3 s outlasts the two gaps after one bad or missing reading. If GPS goes stale meanwhile, AR stays, since it was checked on the way in, but only for 30 s after the last AR reading checked against fresh GPS (`arUncheckedLimit`), which is up to about 35 s after the last GPS fix, since a fix counts as fresh for 5 s; after that it waits for GPS to come back and a new run. A fresh GPS fix still checks every reading.
- **Back to GPS:** at once on any geo-tracking update without a usable position (stopped, localizing, not available); after 2 readings in a row (`arFailedReadingsToLeave`) that are low or disagree with fresh GPS, so one grade flicker or one stray GPS fix near the limit doesn't switch; or when 3 s pass with no good reading. The next GPS fix comes through, and returning to AR takes a whole new run.
- **Speed and course:** geo-tracking has none, so an AR fix borrows them from a GPS fix at most 3 s from it (`HeadingEstimator.maximumSampleAge`); an older one may be from before a turn.
- **Accuracy:** ARKit gives only a grade, mapped to high 5 m, medium 10 m, low 20 m. These are guesses until the AR-6 walk measures them, chosen no sharper than a good GPS fix so a guess doesn't pass gates tuned on GPS (the tracker's 10 m wrong-way limit, rerouting's 20 m) that GPS itself would not.
- **Each subscriber runs its own fusion.** `TripManager`, the trip screen, place search and the debug screen each subscribe and each get their own `LocationFusion`, so their switches can land on slightly different fixes.
- **"Where am I" uses GPS only.** `LocationDescriber` is given the GPS provider, since it is asked outside trips too, where there is no AR.
- The tracker treats a switch of source as no movement; see step 5 of [Each fix](#each-fix).

## Heading

`HeadingEstimator` gives a heading in degrees from true north, or nothing. No direction beats a wrong one.

| Situation | Heading |
| --- | --- |
| Moving at 0.7 m/s or more, with a course accurate to 45° (or of unknown accuracy), from a fix at most 3 s old | the walking direction, or the AR heading if trusted and within 30° of it |
| Moving, but with no usable course | unknown, since a phone swinging in a pocket, or a camera pointed aside, points anywhere |
| Standing still (speed known and under 0.7 m/s), with a trusted AR heading | the AR heading |
| Standing still, speed unknown, or no fix in the last 3 s | the compass, if accurate to 25° and at most 3 s old |
| Anything else | unknown |

**AR heading (AR-4).** During a trip `FusedLocationProvider.headingSamples()` passes on the compass plus the heading of each geo-tracking update that is localized with a known grade: where the back camera faces, from true north. It ends only when the compass does; geo-tracking ending leaves the compass coming.

- **Trusted** only from a reading the trip's own `LocationFusion` passed on: the latest location fix is AR's and at most 3 s old, and the heading is no newer than it. A heading and its fix share their geo-tracking update's timestamp, so a newer heading is from a reading the fusion turned down, such as one disagreeing with GPS. No second fusion runs for headings. The reading itself must be at most 3 s old (`LocationFusion.arLifetime`, so one dropped reading doesn't flip the source) and accurate to 25°, as for the compass.
- **Accuracy:** ARKit grades the position, not the heading, so high 5°, medium 10°, low 30° are guesses until the AR-6 walk measures them. Low is past the 25° limit, a second guard for a low reading that arrives while an earlier one's trust lasts.
- **Walking, the course wins.** Geo-tracking needs building façades in view, so the camera often faces a building beside the path, not the way the user walks; ranked first, a camera pointed east while walking north said "The path is on your left" for a path ahead, and "It is on your right" for a missed turn behind. So the AR heading only refines a course it is within 30° of (`maximumARCourseDisagreement`, also unmeasured until AR-6). This departs from issue #239, which ranks AR as most trusted, for safety.
- **Standing still needs a known speed.** An AR fix has a speed only when a GPS fix at most 3 s from it lends one, and AR stays trusted with older GPS or none. Then the user may be walking with the camera pointed aside, so the compass rules apply instead.

- The compass runs only while something is subscribed to `headingSamples()`: a trip, until it arrives or ends, and the location debug screen.
- Core Location sends every compass reading (`kCLHeadingFilterNone`), not only changes, so a phone held still keeps a reading under 3 s old.
- The system's calibration screen is turned off, because it is a visual prompt. A compass that needs calibrating reports poor accuracy and reads as unknown.
- The debug screen shows the heading and where it came from.
- The 25° compass limit holds for the start too. Directions are 45° sectors, so a reading 25° out names the wrong one only for a path within 25° of a sector's edge; at 45° out any reading can, so a path dead ahead could be called "slightly right", and a user setting off 45° wide is about 30 m off the route before it is noticed. With the heading unknown, the start names the street to follow instead.

## Trip map

`CampusMap` on the trip screen follows the user with the way they face at the top, until they pan it; the location button follows again. The compass appears whenever the map is turned, so north can still be found. The user's arrow points the way they face, turned back by however far the map is turned, and is a dot while MapKit has no compass reading. VoiceOver still reads the map as one element.

## Field-test recorder

Developer Tools > Trip recorder turns on `TripRecorder`, off by default and at every launch. While it is on, each trip writes one CSV file to `Documents/TripRecordings/`, which is excluded from backups, so recordings stay on the phone until shared from that screen. The screen can also delete them all.

- A `fix` row for every location fix: time, position, accuracy, where the fix came from (`gps` or `ar`), speed, course and its accuracy, the heading used and where it came from (`ar`, `walkingDirection` or `compass`), the compass accuracy, progress along the route, the tracker's side offset, the next step, whether off route, and the tracker's events.
- An `announcement` row for everything submitted to the announcement engine, whether or not it was then spoken.
- `TripManager` builds no fix row unless the recorder is recording, so it costs nothing while off. Rows are written as they happen, under the recorder's lock. A file that can't be written is logged, stops, and its error shows on the recorder screen; the trip carries on.

## Crosswalks

- `Resources/Maps/campus-crossings.json` holds the campus crossings from OpenStreetMap. `Scripts/CampusCrossings/ExportCampusCrossings.swift` builds it from `Data/AccessibilityExport/accessibility_export.json`, with no network.
- A crossing is on a route when it is within 3 m of it. The route and the crossings are the same map data, so a crossing the route uses lies on it, while one over the road beside the path starts at the curb a few metres away.
- Crossings within 10 m of each other along the route are merged, keeping the most informative details: a signal over marked, marked over unmarked, and an unknown control only when nothing else is known.
- They are worked out when a trip starts and after each reroute.

## Route summary

`RouteSummary` is shown on place details and the route picker when a route is found: "About 6 minutes, 450 feet. 3 turns, 1 flight of stairs, 2 crosswalks." VoiceOver announces it then as "Route ready. {summary}", so the user knows Start is there.

- Minutes are rounded, and at least 1.
- Turns are left, right, slight and U-turns. With none it says "No turns", as in "About 6 minutes, 450 feet. No turns, 2 crosswalks."
- Stairs, elevators, escalators and crosswalks are listed only when there are some.
- Place details counts a route's crossings once, when the route arrives, and words the summary in the user's current units each time it is read.

## Routing servers

`FallbackRoutingService` asks the Valhalla servers named in the `ROUTING_SERVERS` build setting in order, then Apple Maps, which is always last and can't be configured away. Changing the servers needs no code change.

- **Configuration.** `ROUTING_SERVERS` is set to `stadia,fossgis` in `Config/Shared.xcconfig`; a member's `Secrets.xcconfig` can override it. It reaches the app as `RoutingServers` in `Info.plist`, read by `RoutingConfig.servers(from:apiKey:)`.
  - Names are separated by commas; spaces and case don't matter. `stadia` is Stadia Maps' hosted Valhalla, `fossgis` the free FOSSGIS demo server (fair use only, no uptime guarantee).
  - `stadia` is dropped without a usable `STADIA_API_KEY`, and unknown names are ignored; both are logged. If dropping `stadia` leaves no server (`ROUTING_SERVERS = stadia` without a key), FOSSGIS is asked instead and that is logged as an error, so routing never silently becomes Apple Maps only. A name given twice is asked once, at its first place. A value naming no known server gives the default, `stadia,fossgis`.
- **Each Valhalla server** gets 6 s to answer, and all of them together 8 s (`FallbackRoutingService.chainBudget`): a server waits at most what is left, and once the 8 s are spent no later server is asked. So the worst case, Stadia and FOSSGIS both hanging (common on weak cellular), is 8 s of silence after "Finding a new route" before Apple Maps is asked, not 12 s, plus however long Apple Maps takes. With exclusions the request is rejected at 8 s instead (see below). A server cut short by the 8 s (FOSSGIS here, after 2 s) only fails that request and isn't remembered, since it never had its full 6 s: the next request within 2 minutes (a staged report try or a reroute) skips Stadia and gives FOSSGIS its full 6 s, so a trip whose servers both hang waits at most 8 s once and then 6 s once more before every request goes straight to Apple Maps. After a timeout of the full 6 s, a rejected key (`.notAuthorized`) or an exhausted usage limit (`.usageLimitReached`), that server is skipped for 2 minutes, so each staged report try and each reroute doesn't wait on it or spend the request again. An answer from it clears that.
- **Exclusions.** A request that avoids reported places never reaches Apple Maps, which can't avoid them. When every Valhalla server fails it throws `.noRouteFound` if one found no route, else `.exclusionsRejected`, so `ReportAwareRoutingService` (which wraps the chain) tries again with fewer exclusions. Its last try has none, so a route from Apple Maps still lists the reports it passes.
- **Errors.** When every server fails, the most informative error wins: no route, then rejected exclusions, then unavailable, then usage limit, then rejected key, then a bad response.
- **Cancellation** by the caller cancels the request in flight and asks no later server.
- **Speech.** Moving from Stadia to FOSSGIS is silent: both are Valhalla, with the same step-free routing. Only a route from Apple Maps (`source` `.appleMaps`) is announced, as backup directions that may include stairs. The routing layer itself never speaks.
- **Stadia credits.** Every Stadia route request spends the team's credits, and one trip can send about 27 requests or more (see `ValhallaEndpoint.stadia`). FOSSGIS and Apple Maps cost none.

## TripManager

- **Starting.**
  - The first state is published at once, with the first step after departure.
  - The start announcement waits 0.75 s, so VoiceOver moving focus off the Start button doesn't cut it off.
- **Generations.**
  - `startTrip` and `endTrip` bump a generation.
  - Each task and handler carries the generation it started for. It checks the generation before changing state or speaking after an `await`, so an ended or replaced trip can't act.
  - Reroutes bump a separate route version, which drops answers and cue checks for a replaced route.
- **Rerouting.**
  - On `offRoute` or `missedTurn`, the first fix accurate to 20 m asks for a new route, starting with the fix that found it, since the public server is slow enough without waiting a second more. A later fix doesn't ask if it brings the user back.
  - Requests are at least 30 s apart until one succeeds, then 15 s. There are at most 5 per trip.
  - A failure allows a retry after the same wait.
  - The user can also ask for one ("find another way"). It starts from the latest fix accurate to 20 m and is refused while the signal is weak.
  - There is no rerouting while paused. An answer that lands during a pause is applied without being announced.
  - An answer is dropped if, by the time it lands, the user is back on the route, has arrived, or the trip has ended or been replaced.
- **Next step.** `TripState.nextManeuver` is the next step after departing, with its instruction as `RouteStep.withoutCompassDirection` gives it, so the screen, and anything else that shows the state, never says "north".
- **Off-route state.** While off route, `TripState.isOffRoute` is true and `TripState.nextManeuver` keeps the next step's kind and coordinate, but its instruction is status text ("Off route. Finding a new route." or "Off route. Head back toward the path."). `distanceToNextManeuver` is nil.
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
  - An arrival while paused stays paused, with `TripState.hasArrived` true, and is announced on resume.

### Wording

Distances are spoken by `DistanceFormatter` in the user's units: feet rounded to 25 ft, then tenths of a mile from 500 ft; or metres rounded to 10 m, then tenths of a kilometre from 1 km. `{d}` below is that phrase, such as "about 150 feet".

Valhalla starts every route with a compass direction ("Walk north on Ferst Drive."), which a blind user can't act on, so its first instruction is never said or shown as it is. `RouteStep.withoutCompassDirection` turns it into "Follow Ferst Drive.", or "Follow the path." when it names no street; place details lists the steps that way too.

Where two texts are given for one event, the first is used when the heading is known and the second when it isn't. `{direction}` is one of eight: "ahead", "slightly right", "on your right", "behind you on your right", "behind you", "behind you on your left", "on your left", "slightly left". It comes from the bearing to the target relative to the heading, in 45° sectors centred on straight ahead.

A direction is said only from the latest fix, when it is accurate to 20 m and at most 5 s old (a late fix older than the one before it is ignored), and only to a target at least twice the fix's accuracy away. Otherwise the heading-unknown text is used. Before the first fix, the user is taken to be at the route's start.

The path sentence is "The path is {direction}.", or "Turn around, the path is behind you." It points at the route `max(15 m, 2 × accuracy)` beyond the user's progress.

| Event | Text | Priority | Expiry |
| --- | --- | --- | --- |
| start | "Starting directions to {name}, {d}. {setting off}". Setting off is "{path sentence}", or with the heading unknown "Follow {street}. You'll be warned if it's the wrong way.", where the tracker's wrong-way and off-route rules keep that promise. Then "In {d}, {instruction}" for a first step within 40 m (not stairs, which the first fix warns of, nor the arrive step) | high | 15 s |
| prepare | "In {d}, {instruction}". For stairs: "In {d}, stairs going up.", "…stairs going down.", or "…stairs." when the instruction doesn't say which way | normal; high for stairs, so "Important only" still says them | 8 s; 15 s for stairs, to outlast a long start sentence |
| now | "{instruction}", with the maneuver's haptic | high | dynamic |
| passed turn | "Continue for {d}." | normal | 6 s |
| crosswalk | "Crosswalk ahead, with audible signal." / "Crosswalk ahead, with a traffic signal." / "Crosswalk ahead." (marked) / "Road crossing ahead, unmarked." / "Road crossing ahead." (not tagged either way), with the attention haptic | high | 8 s |
| missed turn | "You may have passed the turn. Finding a new route." while a reroute is in flight or allowed. Otherwise "…It is {direction}, {d} away.", or with the heading unknown "…Turn around and walk back {d}." The turn itself isn't said: walking back reaches it from the other side, which swaps its left and right | high | 12 s |
| wrong way | "You're walking away from the route. {path sentence}". Heading unknown: "You seem to be walking away from the route. Turn around." | high | 10 s |
| off route | "You're off the route. Finding a new route.", or "…Head back toward the path." once no reroutes are left or in flight | high | 10 s |
| back on route | "Back on the route." | normal | 6 s |
| new route | "New route. {setting off}", as at the start | high | 15 s |
| reroute asked for | "Finding a new route from here.", or "Couldn't find where you are precisely enough for a new route. Try again in a moment." | high | 10 s |
| reroute failed | "Couldn't get a new route. Walk back the way you came."; after the fifth: "Off route. End the trip and choose your destination again."; asked for while still on the route: "Couldn't get a new route. Keep following the current one." | high | 10 s |
| arrived | "Arriving at {name}. {name} is {direction}.", when the latest fix is at least `max(5 m, 2 × accuracy)` from the destination. Otherwise, or with the heading unknown: "Arriving at {name}. {arrive instruction}" | high | 15 s |
| weak / back | "Location signal is weak. Directions may be delayed." / "Location signal is back." (system category) | high / normal | 10 s / 6 s |
| pause, resume, end | "Trip paused." / "Trip resumed." / "Trip ended.", with no dedup key, so the engine merges them with the voice command's | high | none |

## Live Activity

`TripActivityController` puts the trip on the lock screen and in the Dynamic Island, through `TripActivityPlanner`'s rules. It's updated locally, never by push.

- **Start.** The first active or paused state with a next maneuver starts one. A trip to a new destination starts a new one.
- **Update.** An update is pushed at a new step or status, when the written distance changes and the user has moved 25 ft since the last push, and when the arrival time moves by a minute. Until arrival, one is also pushed at least once a minute, standing still or paused included.
- **Stale.** Until arrival, each start and update sets a stale date 3 minutes on. If the app stops updating it, because it was closed or has had no location fix for that long, the widget says "Guidance not updating. Open AccessAble." instead of a turn that may be long past. An arrived activity never goes stale.
- **Paused.** "Paused" with the turn below it and no distance; off route has no distance either.
- **End.** Arrival, including during a pause, ends it with an arrived card that stays 5 minutes. Ending the trip removes it, or the arrived card, at once. At launch, any activity left by a launch that ended mid-trip is removed.
- **Failed start.** A Live Activity can only start while the app is in the foreground, and not at all when the user has turned Live Activities off. A failed start is tried again at the next step or status, and when the app comes to the foreground.

## Known limits

- **The compass says where the phone points, not where the user faces.** Standing still with the phone in a pocket or a bag, a compass reading that looks accurate can still give the wrong "ahead". Once the user is walking, the walking direction takes over.
- **The AR heading's rules are unmeasured until AR-6.** Within 30° of the course it replaces the course rather than blending with it; there is no hysteresis, so a heading near the limit can flip between AR and the course from one reading to the next; and the change from walking to standing switches from the course to the camera at once.
- **Not checked on a device yet:** navigation-grade accuracy, the compass, the heading-up trip map, the faster off-route rule and the crosswalk callouts have only run in tests and the simulator, which has no compass.
- **Crosswalk callouts only exist on campus,** inside the area the bundled export covers, and are as good as OpenStreetMap's tagging there. Only 5 crossings are tagged with an audible signal.
- **A crossing near the destination can go unannounced.** A fix accurate to 15 m near the last vertex arrives once progress is within 50 m of the end, so progress can still be short of the callout point, 20 m before the crossing, of one up to about 30 m before the destination.
- **Crossings are matched by distance only.** On a road without mapped sidewalks the route runs along the road itself, so crossing nodes on that road, for side streets or driveways, are within 3 m and can be announced.
- **A crossing re-mapped in OpenStreetMap after the export** can move more than 3 m from the route and stop matching until the export is rebuilt.
- **Stairs direction is rarely known.** Valhalla usually says "Take the stairs" without up or down. Only "stairs up", "up the stairs", "upstairs" and their "down" forms count.
- **A crossing right at a street corner** that the route passes without using could still be within 3 m and be announced. This needs checking on real campus routes.
- **Valhalla's turn-type numbers and stairs wording** haven't been checked against a live route through a building.
- **Wrong way is strict.**
  - It needs a fix accurate to 10 m at both ends of the movement.
  - With none in the first 40 m, there is no warning, which beats a false "turn around".
- **Off route is slower with rough fixes.** With fixes accurate to 15 to 20 m, the limits grow to 22.5 to 30 m and GPS noise near them ends runs, so walking straight off the route takes 15 to 38 s in simulated walks, against 16 to 24 s with fixes accurate to 5 to 10 m. Walking beside the route 12 to 18 m out with fixes accurate to 10 to 25 m can still be called off route now and then.
- **Cutting across near the end of a U is within GPS error.** Crossing a U or switchback within about 20 m of its end gains no more along the route, beyond the straight line, than cutting the inside of a corner does, so it counts as walking it: its turns go unsaid, with only "Continue for …" or the next step's warning. Crossing further from its end is off route.
- **Missed-turn detection covers turns of 60° or more only.**
  - Walking straight past a gentler bend relies on off-route detection.
  - At 30°, that can take about 60 m.
- **Out-and-back routes with identical legs.** Reach onto the return leg counts at most 10 s.
  - A GPS dropout of more than about 10 s right at the turnaround can leave progress stuck there, with no further
    cues. The return leg is on the route, so off-route detection doesn't catch it.
  - Ending and restarting the trip recovers.
