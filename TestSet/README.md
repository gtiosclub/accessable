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
      "measuredDistances": { "chair": 2.0 }
    }
  ]
}
```

A prediction counts as correct if the label matches and IoU >= 0.5.
