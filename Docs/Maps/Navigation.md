# Maps navigation reference

How a trip is guided, in `AccessAble/AccessAble/Models/Maps/`:
- `RouteProgressTracker` turns location fixes into progress along one `NavigationRoute`, and decides which guidance is due.
- `TripManager` speaks that guidance, reroutes, warns about weak GPS, and publishes `TripState`.

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
| Off route | over `max(30 m, 1.5 × accuracy)` from the route on 3 fixes spanning 10 s, having moved 8 m |
| Back on route | within 15 m on 2 fixes at least 2 s apart |
| Missed turn | turns of 60° or more only; at least 15 m beyond the vertex along the straight-on line and 15 m from the route, on 2 fixes at least 2 s apart |
| Wrong way | in the first 40 m: moved 10 m from a fix accurate to 10 m, 5 m further from the route, progress under 3 m, current fix accurate to 10 m |
| Arrival | within 10 m of the end by progress, or a fix accurate to 15 m within `max(10 m, accuracy)` of the last vertex once progress is within 50 m of the end |

### Events

The events are `prepare`, `now`, `passedTurnConfirmation`, `missedTurn`, `wrongWay`, `offRoute`, `backOnRoute` and `arrived`.

- **`prepare`** is skipped when:
  - the start announcement covers it (a first step within 40 m);
  - the step says "Continue";
  - the previous step already said it (Valhalla's `verbal_multi_cue`).
- **`now`** is skipped for "Continue" after a multi-cue step.
  - Steps each within 8 m of the one before come up too quickly for a cue at each, so they are cued in the same update as the first, in order.
  - Only steps within 16 m of the group's first step join it. The rest are cued as they are reached, even before the earlier steps count as passed.
  - A step that a spoken multi-cue sentence already named gets no separate cue.
  - Grouped steps never get a confirmation.
- **`passedTurnConfirmation`** replaces a `now` that never fired. It is never a late turn instruction, which would make the user turn twice.
  - When several steps pass in one fix, only the last gets one.
  - There is none when the same update already cues a later step.
- **`arrived`** is always alone and last.
- **While paused** (`emitsCues: false`), progress and off-route state still update. Cues aren't emitted or used up, so the right cue fires on resume. `offRoute`, `backOnRoute` and `arrived` are still emitted.

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
  - Requests are at least 30 s apart, and there are at most 5 per trip.
  - A failure allows a retry after 30 s.
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
- **Background location** is on only from start to end or arrival. The Trip screen's other location subscriptions stay open in the background, so leaving it on would track the user whenever the app is open.
- **Pausing and arrival.**
  - Resuming says "In about {d} metres, …" for the next step, and tells the tracker so the next fix doesn't say the same prepare again.
  - Within 8 m of the step, or with a missed turn pending, resuming says nothing more than "Trip resumed.". The user may already be past the turn, so the next fix's turn cue, confirmation or missed turn says the right thing.
  - Resume speech is dropped if a reroute lands while "Trip resumed." is being said.
  - A turn cue that a pause stopped before it was submitted is given again by the tracker after resuming.
  - An arrival while paused stays paused and is announced on resume.

### Wording

Distances are rounded to 10 m, minimum 10.

| Event | Text | Priority | Expiry |
| --- | --- | --- | --- |
| start | "Starting directions to {name}, about {total} metres. {first instruction}" | high | 15 s |
| prepare | "In about {d} metres, {instruction}" | normal | 8 s |
| now | "{instruction}", with the maneuver's haptic | high | dynamic |
| passed turn | "Continue for about {d} metres." | normal | 6 s |
| missed turn | "You may have passed the turn. Finding a new route." while a reroute is in flight or allowed; otherwise "…Turn around and walk back about {d} metres, then {instruction}" | high | 12 s |
| wrong way | "You seem to be walking away from the route. Turn around." | high | 10 s |
| off route | "You're off the route. Finding a new route.", or "…Head back toward the path." once no reroutes are left or in flight | high | 10 s |
| back on route | "Back on the route." | normal | 6 s |
| new route | "New route. {first instruction}" | high | 15 s |
| reroute failed | "Couldn't get a new route. Walk back the way you came.", or after the fifth: "Off route. End the trip and choose your destination again." | high | 10 s |
| arrived | "Arriving at {name}. {arrive instruction}" | high | 15 s |
| weak / back | "GPS signal is weak. Directions may be delayed." / "GPS signal is back." (system category) | high / normal | 10 s / 6 s |
| pause, resume, end | "Trip paused." / "Trip resumed." / "Trip ended.", with no dedup key, so the engine merges them with the voice command's | high | none |

## Known limits

- **No compass.** "Walk south" can't be checked against where the phone points.
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
- **Re-entering the Trip screen mid-trip** shows no route line, though guidance keeps working.
- **After a reroute,** the Trip screen still draws the old route line, though guidance follows the new route.
- **Speech needs the UI team's real `AnnouncementEngine`** (#117). Until it merges, cues go to the placeholder engine's log and Home banner and are not spoken.
