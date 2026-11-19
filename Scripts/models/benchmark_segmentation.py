"""Compare ground-segmentation models on what `SurfaceReader` uses them for.

    source ~/.venvs/accessable-ml/bin/activate
    python Scripts/models/benchmark_segmentation.py --ade /path/ADEChallengeData2016 \
        --coco /path/coco MODEL.mlpackage [MODEL.mlpackage ...]

Each model's labels and each dataset's labels are folded into the app's ground classes
(`SurfaceKind`: floor, pavement, road, grass, rough, stairs, water, ceiling, outdoors) and
scored per class as IoU over all pixels, on:

- ADE20K validation (SegFormer-ADE's home turf), and
- COCO panoptic val2017 (Apple's DETR's home turf), restricted to images with pavement or road.

Testing on both keeps either model from winning on familiarity alone. Also reported: how
often sidewalk is called road and road sidewalk (the confusion the app must not make outdoors),
and median latency per image on this Mac.
"""

from __future__ import annotations

import argparse
import json
import random
import statistics
import time
from pathlib import Path

import coremltools as ct
import numpy as np
from PIL import Image

GROUPS = ["floor", "pavement", "road", "grass", "rough", "stairs", "water", "ceiling", "outdoors"]


def group_of(raw: str) -> str | None:
    """The app's ground class for a label from any of the three vocabularies, or None."""
    name = raw.strip().lower().replace("-merged", "").replace("-other", "").replace("(", "").replace(")", "")
    name = name.replace("-", " ").strip()
    if name.startswith("floor") or name in {"rug", "carpet"}:
        return "floor"
    if name in {"pavement", "sidewalk", "path"}:
        return "pavement"
    if name in {"road", "runway"}:
        return "road"
    if name in {"grass", "field", "playingfield", "terrain"}:
        return "grass"
    if name in {"dirt", "gravel", "sand", "snow", "earth", "land", "dirt track"}:
        return "rough"
    if name in {"stairs", "stairway", "step", "escalator"}:
        return "stairs"
    if name.startswith("water") or name in {"river", "sea", "lake", "swimming pool", "waterfall"}:
        return "water"
    if name.startswith("ceiling"):
        return "ceiling"
    if name.split(" ")[0] in {"sky", "tree", "building", "house", "mountain", "skyscraper", "palm", "hill"}:
        return "outdoors"
    return None


def model_labels(model: ct.models.MLModel) -> list[str]:
    metadata = model.user_defined_metadata
    if "classes" in metadata:
        return metadata["classes"].split(",")
    return json.loads(metadata["com.apple.coreml.model.preview.params"])["labels"]


def lookup(labels: list[str]) -> np.ndarray:
    """Model class index -> group index (len(GROUPS) for none)."""
    return np.array([GROUPS.index(g) if (g := group_of(l)) else len(GROUPS) for l in labels], dtype=np.int64)


class Model:
    def __init__(self, package: Path) -> None:
        self.name = package.stem
        self.model = ct.models.MLModel(str(package), compute_units=ct.ComputeUnit.ALL)
        spec = self.model.get_spec().description
        image = spec.input[0].type.imageType
        self.size = (image.width, image.height)
        self.output = spec.output[0].name
        self.groups = lookup(model_labels(self.model))
        self.times: list[float] = []

    def predict(self, image: Image.Image) -> np.ndarray:
        resized = image.convert("RGB").resize(self.size, Image.BILINEAR)
        start = time.perf_counter()
        classes = np.asarray(self.model.predict({"image": resized})[self.output]).squeeze().astype(np.int64)
        self.times.append(time.perf_counter() - start)
        classes = np.clip(classes, 0, len(self.groups) - 1)
        return self.groups[classes]


class Score:
    def __init__(self) -> None:
        n = len(GROUPS) + 1
        self.confusion = np.zeros((n, n), dtype=np.int64)

    def add(self, truth: np.ndarray, predicted: np.ndarray) -> None:
        n = len(GROUPS) + 1
        self.confusion += np.bincount(truth.ravel() * n + predicted.ravel(), minlength=n * n).reshape(n, n)

    def iou(self, group: str) -> float | None:
        i = GROUPS.index(group)
        tp = self.confusion[i, i]
        union = self.confusion[i, :].sum() + self.confusion[:, i].sum() - tp
        return None if self.confusion[i, :].sum() == 0 else tp / union

    def called(self, truth: str, predicted: str) -> float:
        row = self.confusion[GROUPS.index(truth)]
        return row[GROUPS.index(predicted)] / max(row.sum(), 1)


def resize_truth(truth: np.ndarray, shape: tuple[int, int]) -> np.ndarray:
    return np.asarray(Image.fromarray(truth.astype(np.uint8)).resize((shape[1], shape[0]), Image.NEAREST)).astype(np.int64)


def ade_samples(root: Path, count: int, seed: int):
    images = sorted((root / "images" / "validation").glob("*.jpg"))
    random.Random(seed).shuffle(images)
    from transformers import AutoConfig
    names = AutoConfig.from_pretrained("nvidia/segformer-b0-finetuned-ade-512-512").id2label
    table = np.full(151, len(GROUPS), dtype=np.int64)  # 0 = unlabelled
    for i in range(150):
        if group := group_of(names[i]):
            table[i + 1] = GROUPS.index(group)
    for path in images[:count]:
        annotation = np.asarray(Image.open(root / "annotations" / "validation" / (path.stem + ".png")))
        yield Image.open(path), table[annotation]


def coco_samples(root: Path, count: int, seed: int):
    panoptic = json.loads((root / "annotations" / "panoptic_val2017.json").read_text())
    category_group = {c["id"]: group_of(c["name"]) for c in panoptic["categories"]}
    street = [a for a in panoptic["annotations"]
              if any(category_group.get(s["category_id"]) in {"pavement", "road"} for s in a["segments_info"])]
    random.Random(seed).shuffle(street)
    import urllib.request
    for annotation in street[:count]:
        image_path = root / "val2017" / annotation["file_name"].replace(".png", ".jpg")
        if not image_path.exists():
            image_path.parent.mkdir(parents=True, exist_ok=True)
            urllib.request.urlretrieve(f"http://images.cocodataset.org/val2017/{image_path.name}", image_path)
        rgb = np.asarray(Image.open(root / "annotations" / "panoptic_val2017" / annotation["file_name"]).convert("RGB")).astype(np.int64)
        ids = rgb[..., 0] + 256 * rgb[..., 1] + 256 * 256 * rgb[..., 2]
        truth = np.full(ids.shape, len(GROUPS), dtype=np.int64)
        for segment in annotation["segments_info"]:
            if group := category_group.get(segment["category_id"]):
                truth[ids == segment["id"]] = GROUPS.index(group)
        yield Image.open(image_path), truth


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("models", nargs="+", type=Path)
    parser.add_argument("--ade", type=Path)
    parser.add_argument("--coco", type=Path)
    parser.add_argument("--images", type=int, default=300)
    parser.add_argument("--seed", type=int, default=0)
    args = parser.parse_args()

    models = [Model(p) for p in args.models]
    for model in models:  # warm-up, so the first image's time is inference, not compilation
        for _ in range(3):
            model.predict(Image.new("RGB", (64, 64)))
        model.times.clear()

    datasets = []
    if args.ade:
        datasets.append(("ADE20K val", ade_samples(args.ade, args.images, args.seed)))
    if args.coco:
        datasets.append(("COCO street", coco_samples(args.coco, args.images, args.seed)))

    for title, samples in datasets:
        scores = {m.name: Score() for m in models}
        for image, truth in samples:
            for model in models:
                predicted = model.predict(image)
                scores[model.name].add(resize_truth(truth, predicted.shape), predicted)
        print(f"\n{title}: IoU % per ground class (higher is better)")
        print("model".ljust(40) + "".join(g[:8].rjust(9) for g in GROUPS) + "   side→road  road→side")
        for model in models:
            s = scores[model.name]
            cells = "".join(("-" if (v := s.iou(g)) is None else f"{v * 100:.1f}").rjust(9) for g in GROUPS)
            print(model.name.ljust(40) + cells
                  + f"{s.called('pavement', 'road') * 100:10.1f}%{s.called('road', 'pavement') * 100:10.1f}%")

    print("\nmedian ms per image on this Mac:")
    for model in models:
        print(f"  {model.name}: {statistics.median(model.times) * 1000:.1f}")


if __name__ == "__main__":
    main()
