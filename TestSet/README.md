# CV test set (T20)

Put frames in `frames/<scenario>/` and label them in `annotations.json`.
Scenario names are in `TestSet.swift` (chair-ahead, person-crossing, stairs-down, ...).

Recording tips: phone at chest height in portrait, grab a frame every ~0.5 s, 10-30 per
scenario. For distance, tape-measure to the object.

Boxes are normalized 0-1 with the origin at the top-left, same as `Detection`.

```json
{
  "version": 1,
  "frames": [
    {
      "scenario": "chair-ahead",
      "image": "frames/chair-ahead/0001.jpg",
      "objects": [{ "label": "chair", "x": 0.38, "y": 0.42, "width": 0.24, "height": 0.4 }],
      "measuredDistances": { "chair": 2.0 },
      "estimatedDistances": { "chair": 1.93 },
      "conditions": { "lighting": "dim", "setting": "indoor", "note": "hallway, lights half off" }
    }
  ]
}
```

`estimatedDistances` (what the app said on the phone) and `conditions` are optional.
A saved photo has no LiDAR depth, so distance error is only scored for frames that have
both a measured and an estimated distance. `lighting` is `bright`, `normal`, `dim` or
`dark`; `setting` is `indoor` or `outdoor`.

Boxes are in the upright picture, as you see it. Phone photos usually store the
orientation in EXIF; the runner reads it, so don't rotate the files yourself.

A prediction counts as correct if the label matches and IoU >= 0.5.

## Running it

```bash
swift test --scratch-path /tmp/accessable-build --filter recordedTestSet
```

This runs the app's object model (T13) and people detection (T14) on every frame and
prints precision and recall overall, per scenario and per lighting, distance error, and
detection time. The detection time comes from the Mac running the test, so it's only
useful for comparing runs on the same Mac, not for phone FPS. The test is skipped while
`annotations.json` has no frames.
