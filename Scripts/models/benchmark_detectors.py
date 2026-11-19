"""Compare Core ML detectors the way the app runs them, on COCO street scenes.

    source ~/.venvs/accessable-ml/bin/activate
    python Scripts/models/benchmark_detectors.py --coco /path/to/coco \
        AccessAble/AccessAble/Resources/dfine_n_coco.mlpackage path/to/rfdetr_n_coco.mlpackage

`--coco` holds `annotations/instances_val2017.json`; images are downloaded into
`<coco>/val2017/` on first use. Every model must have the app's contract: an `image` input and
`confidence` `[queries, classes]` / `coordinates` `[queries, 4]` (cx, cy, w, h, normalised)
outputs, with classes in COCO-80 order or listed in the model's `classes` metadata.

Each image is stretched to the model's square input, as Vision's `.scaleFill` does, and decoded
like `dfineDetections`: best class per query, a score threshold, same-label NMS. Reported:

- COCO AP / AP50 over the street subset (all classes, and the classes the app warns about);
- recall and precision at the app's own thresholds (`DetectionConfidencePolicy.standard`);
- median latency per frame on this Mac (Core ML, all compute units). Phone latency differs, but
  the ranking between models usually holds.
"""

from __future__ import annotations

import argparse
import json
import statistics
import time
import urllib.request
from pathlib import Path

import coremltools as ct
import numpy as np
from PIL import Image
from pycocotools.coco import COCO
from pycocotools.cocoeval import COCOeval

COCO80 = [
    "person", "bicycle", "car", "motorcycle", "airplane", "bus", "train", "truck", "boat",
    "traffic light", "fire hydrant", "stop sign", "parking meter", "bench", "bird", "cat",
    "dog", "horse", "sheep", "cow", "elephant", "bear", "zebra", "giraffe", "backpack",
    "umbrella", "handbag", "tie", "suitcase", "frisbee", "skis", "snowboard", "sports ball",
    "kite", "baseball bat", "baseball glove", "skateboard", "surfboard", "tennis racket",
    "bottle", "wine glass", "cup", "fork", "knife", "spoon", "bowl", "banana", "apple",
    "sandwich", "orange", "broccoli", "carrot", "hot dog", "pizza", "donut", "cake", "chair",
    "couch", "potted plant", "bed", "dining table", "toilet", "tv", "laptop", "mouse",
    "remote", "keyboard", "cell phone", "microwave", "oven", "toaster", "sink", "refrigerator",
    "book", "clock", "vase", "scissors", "teddy bear", "hair drier", "toothbrush",
]
# A scene counts as "street" when it holds any of these.
STREET_CUES = {"bicycle", "car", "motorcycle", "bus", "truck", "traffic light", "fire hydrant", "stop sign", "parking meter"}
# What the app actually warns about or names outdoors (hazardLabels + people + street signals).
APP_CLASSES = [
    "person", "bicycle", "car", "motorcycle", "bus", "truck", "traffic light", "fire hydrant",
    "stop sign", "parking meter", "bench", "potted plant", "chair", "dog", "suitcase", "umbrella",
]
DEFAULT_THRESHOLD, CHAIR_THRESHOLD = 0.6, 0.55
# The outdoor model's names for COCO classes (Scripts/training/taxonomy.json).
ALIASES = {"table": "dining table"}


def street_subset(coco: COCO, count: int) -> list[int]:
    cue_ids = set(coco.getCatIds(catNms=sorted(STREET_CUES)))
    images = sorted({a["image_id"] for a in coco.dataset["annotations"] if a["category_id"] in cue_ids and not a["iscrowd"]})
    return images[:count]


def ensure_image(root: Path, info: dict) -> Path:
    path = root / "val2017" / info["file_name"]
    if not path.exists():
        path.parent.mkdir(parents=True, exist_ok=True)
        urllib.request.urlretrieve(info["coco_url"], path)
    return path


def model_classes(model: ct.models.MLModel) -> list[str]:
    listed = model.user_defined_metadata.get("classes")
    return listed.split(",") if listed else COCO80


def input_size(model: ct.models.MLModel) -> tuple[int, int]:
    image = model.get_spec().description.input[0].type.imageType
    return image.width, image.height


def nms(rows: list[tuple], iou_threshold: float = 0.5) -> list[tuple]:
    kept: list[tuple] = []
    for row in sorted(rows, key=lambda r: -r[1]):
        label, _, box = row
        if all(k[0] != label or iou(k[2], box) <= iou_threshold for k in kept):
            kept.append(row)
    return kept


def iou(a, b) -> float:
    ax0, ay0, aw, ah = a
    bx0, by0, bw, bh = b
    ix = max(0.0, min(ax0 + aw, bx0 + bw) - max(ax0, bx0))
    iy = max(0.0, min(ay0 + ah, by0 + bh) - max(ay0, by0))
    inter = ix * iy
    union = aw * ah + bw * bh - inter
    return inter / union if union > 0 else 0.0


def detect(model, classes, size, image: Image.Image, floor: float) -> tuple[list[tuple], float]:
    resized = image.convert("RGB").resize(size, Image.BILINEAR)
    start = time.perf_counter()
    out = model.predict({"image": resized})
    elapsed = time.perf_counter() - start
    scores = np.asarray(out["confidence"]).reshape(-1, len(classes))
    boxes = np.asarray(out["coordinates"]).reshape(-1, 4)
    best = scores.argmax(1)
    best_scores = scores[np.arange(len(best)), best]
    rows = []
    for q in np.nonzero(best_scores >= floor)[0]:
        cx, cy, w, h = boxes[q]
        rows.append((classes[best[q]], float(best_scores[q]), (float(cx - w / 2), float(cy - h / 2), float(w), float(h))))
    return nms(rows), elapsed


def evaluate(coco: COCO, results: list[dict], image_ids: list[int], category_names: list[str] | None) -> tuple[float, float]:
    if not results:
        return 0.0, 0.0
    detections = coco.loadRes(results)
    evaluator = COCOeval(coco, detections, "bbox")
    evaluator.params.imgIds = image_ids
    if category_names:
        evaluator.params.catIds = coco.getCatIds(catNms=category_names)
    import contextlib
    import io
    with contextlib.redirect_stdout(io.StringIO()):
        evaluator.evaluate()
        evaluator.accumulate()
        evaluator.summarize()
    return float(evaluator.stats[0]), float(evaluator.stats[1])


def at_app_threshold(
    coco: COCO, results: list[dict], image_ids: list[int], names: list[str], threshold: float | None = None
) -> tuple[float, float]:
    """Recall and precision at the app's thresholds (or one `threshold` for all), IoU 0.5, over `names`."""
    cat = {coco.getCatIds(catNms=[n])[0]: n for n in names}
    true_positive = false_positive = ground_truth = 0
    by_image: dict[int, list[dict]] = {}
    fixed = threshold
    for r in results:
        if fixed is not None:
            threshold = fixed
        else:
            threshold = CHAIR_THRESHOLD if cat.get(r["category_id"]) == "chair" else DEFAULT_THRESHOLD
        if r["category_id"] in cat and r["score"] >= threshold:
            by_image.setdefault(r["image_id"], []).append(r)
    for image_id in image_ids:
        truths = [a for a in coco.loadAnns(coco.getAnnIds(imgIds=image_id, catIds=list(cat), iscrowd=False))]
        ground_truth += len(truths)
        used = set()
        for r in sorted(by_image.get(image_id, []), key=lambda r: -r["score"]):
            match = next((i for i, t in enumerate(truths)
                          if i not in used and t["category_id"] == r["category_id"] and iou(t["bbox"], r["bbox"]) >= 0.5), None)
            if match is None:
                false_positive += 1
            else:
                used.add(match)
                true_positive += 1
    recall = true_positive / ground_truth if ground_truth else 0.0
    precision = true_positive / (true_positive + false_positive) if true_positive + false_positive else 0.0
    return recall, precision


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("models", nargs="+", type=Path)
    parser.add_argument("--coco", type=Path, required=True)
    parser.add_argument("--images", type=int, default=300)
    parser.add_argument("--json", type=Path, help="write the table here as JSON too")
    args = parser.parse_args()

    coco = COCO(str(args.coco / "annotations" / "instances_val2017.json"))
    image_ids = street_subset(coco, args.images)
    infos = coco.loadImgs(image_ids)
    paths = [ensure_image(args.coco, info) for info in infos]
    name_to_id = {c["name"]: c["id"] for c in coco.loadCats(coco.getCatIds())}
    print(f"{len(image_ids)} street images")

    table = []
    for package in args.models:
        model = ct.models.MLModel(str(package), compute_units=ct.ComputeUnit.ALL)
        classes = model_classes(model)
        size = input_size(model)
        results, times = [], []
        for _ in range(3):  # warm-up
            detect(model, classes, size, Image.open(paths[0]), 0.01)
        for info, path in zip(infos, paths):
            image = Image.open(path)
            rows, elapsed = detect(model, classes, size, image, 0.01)
            times.append(elapsed)
            for label, score, (x, y, w, h) in rows:
                label = ALIASES.get(label, label)
                if label in name_to_id:
                    results.append({
                        "image_id": info["id"], "category_id": name_to_id[label], "score": score,
                        "bbox": [x * info["width"], y * info["height"], w * info["width"], h * info["height"]],
                    })
        ap, ap50 = evaluate(coco, results, image_ids, None)
        app_ap, app_ap50 = evaluate(coco, results, image_ids, APP_CLASSES)
        recall, precision = at_app_threshold(coco, results, image_ids, APP_CLASSES)
        sweep = {
            f"{t:.2f}": [round(v * 100, 1) for v in at_app_threshold(coco, results, image_ids, APP_CLASSES, t)]
            for t in (0.3, 0.35, 0.4, 0.45, 0.5, 0.55, 0.6)
        }
        print(f"  {package.stem} recall/precision by threshold: {sweep}")
        size_mb = sum(f.stat().st_size for f in package.rglob("*") if f.is_file()) / 1e6
        row = {
            "model": package.stem, "input": f"{size[0]}px", "size_mb": round(size_mb, 1),
            "AP": round(ap * 100, 1), "AP50": round(ap50 * 100, 1),
            "app_AP": round(app_ap * 100, 1), "app_AP50": round(app_ap50 * 100, 1),
            "recall@app": round(recall * 100, 1), "precision@app": round(precision * 100, 1),
            "ms_median": round(statistics.median(times) * 1000, 1),
        }
        table.append(row)
        print(json.dumps(row))

    print()
    header = list(table[0])
    print(" | ".join(header))
    for row in table:
        print(" | ".join(str(row[h]) for h in header))
    if args.json:
        args.json.write_text(json.dumps(table, indent=2))


if __name__ == "__main__":
    main()
