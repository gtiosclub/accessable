"""Build the outdoor detector's training set, in the COCO layout RF-DETR trains from.

    source ~/.venvs/accessable-ml/bin/activate
    python Scripts/training/build_dataset.py --out ~/accessable-data/outdoor \
        --coco-annotations /path/coco/annotations/instances_train2017.json --coco-images 2500 \
        --photos ~/accessable-data/recordings \
        --mapillary /path/mapillary-vistas

Sources, any combination:

- COCO street scenes (`--coco-annotations`): images with vehicles, traffic lights, hydrants,
  signs or meters. Classes COCO labels (person, car, bench, ...) keep COCO's own human
  labels; the ones COCO has no word for (pole, bollard, trash can, cone, ...) are
  auto-labelled with Grounding DINO. Images are downloaded on demand.
- Your own photos (`--photos`): a folder of folders, one per place or walk
  (`recordings/tech-green/0001.jpg`). Every class is auto-labelled. These are what make the
  model good at a phone held at chest height on a sidewalk, which no public set is. Correct
  the labels afterwards (CVAT or Roboflow import `_annotations.coco.json` directly).
- Mapillary Vistas v2 (`--mapillary`, the unzipped download): its panoptic boxes for the
  classes in `taxonomy.json`'s `mapillary` lists. Needs a free account at mapillary.com.

Splits are by group, never by frame: a COCO image is its own group, a photo folder is one
place. Whole places go to `valid` and `test`, so the score measures new places, not
near-copies of training frames.

Auto-labels are cached next to the output (`autolabels.json`), so a rerun only labels new images.
"""

from __future__ import annotations

import argparse
import json
import random
import shutil
import urllib.request
from collections import defaultdict
from pathlib import Path

from PIL import Image

HERE = Path(__file__).resolve().parent
STREET_CUES = {"bicycle", "car", "motorcycle", "bus", "truck", "traffic light", "fire hydrant", "stop sign", "parking meter"}
IMAGE_SUFFIXES = {".jpg", ".jpeg", ".png", ".heic"}


def download(url: str, path: Path, attempts: int = 8) -> bool:
    """Fetch `url` to `path`, retrying with back-off (about 2 minutes in all): a 3,000-image run
    meets dropped connections and DNS outages. False when it never arrived; the image is skipped."""
    import time
    path.parent.mkdir(parents=True, exist_ok=True)
    for attempt in range(attempts):
        try:
            partial = path.with_suffix(path.suffix + ".part")
            urllib.request.urlretrieve(url, partial)
            partial.rename(path)
            return True
        except OSError:
            time.sleep(min(2 ** attempt, 30))
    print(f"  skipped {url}: could not download", flush=True)
    return False


def load_taxonomy() -> list[dict]:
    return json.loads((HERE / "taxonomy.json").read_text())["classes"]


class AutoLabeller:
    """Grounding DINO, asked for each class by its prompt, boxes kept above a threshold."""

    def __init__(self, prompts: dict[str, str], box_threshold: float, text_threshold: float, model_id: str) -> None:
        import torch
        from transformers import AutoModelForZeroShotObjectDetection, AutoProcessor

        self.torch = torch
        self.device = "mps" if torch.backends.mps.is_available() else "cuda" if torch.cuda.is_available() else "cpu"
        self.processor = AutoProcessor.from_pretrained(model_id)
        self.model = AutoModelForZeroShotObjectDetection.from_pretrained(model_id).to(self.device).eval()
        self.prompts = prompts  # class name -> prompt
        self.box_threshold = box_threshold
        self.text_threshold = text_threshold

    def label(self, image: Image.Image, classes: list[str]) -> list[tuple[str, float, list[float]]]:
        """(class, score, [x, y, w, h] pixels) for `classes`, asked a few at a time."""
        found: list[tuple[str, float, list[float]]] = []
        # One query holds up to 16 phrases (well inside the text encoder's 256 tokens); one
        # forward pass per image instead of three made labelling ~3x faster for the same boxes.
        for start in range(0, len(classes), 16):
            chunk = classes[start:start + 16]
            text = " . ".join(self.prompts[c] for c in chunk) + " ."
            inputs = self.processor(images=image, text=text, return_tensors="pt").to(self.device)
            with self.torch.no_grad():
                outputs = self.model(**inputs)
            result = self.processor.post_process_grounded_object_detection(
                outputs, inputs.input_ids, threshold=self.box_threshold, text_threshold=self.text_threshold,
                target_sizes=[image.size[::-1]],
            )[0]
            labels = result.get("text_labels", result.get("labels"))
            for box, score, phrase in zip(result["boxes"].tolist(), result["scores"].tolist(), labels):
                name = self.class_for(str(phrase), chunk)
                if name is None:
                    continue
                x0, y0, x1, y1 = box
                found.append((name, float(score), [x0, y0, x1 - x0, y1 - y0]))
        return found

    def class_for(self, phrase: str, chunk: list[str]) -> str | None:
        phrase = phrase.strip().lower()
        exact = [c for c in chunk if self.prompts[c] == phrase]
        if exact:
            return exact[0]
        # A phrase can come back partial ("trash" for "trash can") or merged; take the best overlap.
        scored = [(len(set(phrase.split()) & set(self.prompts[c].split())), c) for c in chunk]
        best = max(scored, default=(0, None))
        return best[1] if best[0] > 0 else None


def iou(a: list[float], b: list[float]) -> float:
    ix = max(0.0, min(a[0] + a[2], b[0] + b[2]) - max(a[0], b[0]))
    iy = max(0.0, min(a[1] + a[3], b[1] + b[3]) - max(a[1], b[1]))
    inter = ix * iy
    union = a[2] * a[3] + b[2] * b[3] - inter
    return inter / union if union > 0 else 0.0


# Grounding DINO calls a whole truck a "scooter" and a dog a "bollard" when asked for those
# words. These hold its boxes to the shapes and scores the classes plausibly have; checked by
# drawing the labels onto sample images (see the contact sheet in the dataset README).
MIN_SCORE = {"scooter": 0.5, "stroller": 0.5, "wheelchair": 0.5, "bike rack": 0.45, "barrier": 0.4}
# Height / width the class must have at least (tall, thin things).
MIN_ASPECT = {"pole": 2.5, "bollard": 1.0, "tree": 1.5, "traffic cone": 0.9}
# Largest share of the image one box of the class may cover.
MAX_AREA = {"bollard": 0.05, "traffic cone": 0.08, "trash can": 0.15, "pole": 0.25}


def plausible(name: str, score: float, box: list[float], image_size: tuple[int, int], labelled: list[list[float]]) -> bool:
    """Whether an auto-label is believable: score, shape, size, and not a duplicate of a real label."""
    x, y, w, h = box
    if w <= 0 or h <= 0 or score < MIN_SCORE.get(name, 0):
        return False
    if h / w < MIN_ASPECT.get(name, 0):
        return False
    area = (w * h) / (image_size[0] * image_size[1])
    if area > MAX_AREA.get(name, 0.6):
        return False
    for other in labelled:
        ix = max(0.0, min(x + w, other[0] + other[2]) - max(x, other[0]))
        iy = max(0.0, min(y + h, other[1] + other[3]) - max(y, other[1]))
        inter = ix * iy
        # The same thing a human already labelled, or a box swallowing most of one.
        if iou(box, other) > 0.4 or inter > 0.6 * other[2] * other[3]:
            return False
    return True


def suppress(boxes: list[tuple[str, float, list[float]]], threshold: float = 0.5) -> list[tuple[str, float, list[float]]]:
    kept: list[tuple[str, float, list[float]]] = []
    for box in sorted(boxes, key=lambda b: -b[1]):
        if all(k[0] != box[0] or iou(k[2], box[2]) <= threshold for k in kept):
            kept.append(box)
    return kept


class Builder:
    def __init__(self, out: Path, labeller: AutoLabeller | None) -> None:
        self.out = out
        self.taxonomy = load_taxonomy()
        self.names = [c["name"] for c in self.taxonomy]
        self.labeller = labeller
        self.cache_path = out / "autolabels.json"
        self.cache: dict[str, list] = json.loads(self.cache_path.read_text()) if self.cache_path.exists() else {}
        # (group, image path, [(class, [x, y, w, h])])
        self.items: list[tuple[str, Path, list[tuple[str, list[float]]]]] = []

    def autolabel(
        self, key: str, path: Path, classes: list[str], labelled: list[list[float]] | None = None
    ) -> list[tuple[str, list[float]]]:
        """Auto-labels for `classes`, filtered by `plausible` against the human `labelled` boxes."""
        if not classes:
            return []
        cache_key = f"{key}|{','.join(classes)}"
        if cache_key not in self.cache:
            if self.labeller is None:
                raise SystemExit("auto-labelling needed but --no-autolabel was given")
            image = Image.open(path).convert("RGB")
            self.cache[cache_key] = suppress(self.labeller.label(image, classes))
            if len(self.cache) % 25 == 0:
                self.save_cache()
        size = Image.open(path).size
        return [(name, box) for name, score, box in self.cache[cache_key]
                if plausible(name, score, box, size, labelled or [])]

    def save_cache(self) -> None:
        self.cache_path.parent.mkdir(parents=True, exist_ok=True)
        self.cache_path.write_text(json.dumps(self.cache))

    def add_coco(self, annotations: Path, count: int, image_dir: Path, seed: int) -> None:
        coco = json.loads(annotations.read_text())
        cats = {c["id"]: c["name"] for c in coco["categories"]}
        coco_to_ours = {c["coco"]: c["name"] for c in self.taxonomy if "coco" in c}
        prompted = [c["name"] for c in self.taxonomy if "prompt" in c]
        by_image = defaultdict(list)
        for a in coco["annotations"]:
            by_image[a["image_id"]].append(a)
        street = [i for i in coco["images"] if any(cats[a["category_id"]] in STREET_CUES for a in by_image[i["id"]])]
        random.Random(seed).shuffle(street)
        for n, info in enumerate(street[:count]):
            path = image_dir / info["file_name"]
            if not path.exists() and not download(info["coco_url"], path):
                continue
            boxes = [(coco_to_ours[cats[a["category_id"]]], a["bbox"]) for a in by_image[info["id"]]
                     if not a["iscrowd"] and cats[a["category_id"]] in coco_to_ours]
            # Every human box, not just the classes kept: a pseudo "scooter" on a COCO
            # motorcycle is still a duplicate.
            human = [a["bbox"] for a in by_image[info["id"]] if not a["iscrowd"]]
            boxes += self.autolabel(f"coco:{info['id']}", path, prompted, human)
            self.items.append((f"coco-{info['id']}", path, boxes))
            if n % 100 == 0:
                print(f"  coco {n}/{min(count, len(street))}", flush=True)

    def add_photos(self, root: Path) -> None:
        for path in sorted(p for p in root.rglob("*") if p.suffix.lower() in IMAGE_SUFFIXES):
            group = path.relative_to(root).parts[0] if len(path.relative_to(root).parts) > 1 else "photos"
            boxes = self.autolabel(f"photo:{path.relative_to(root)}", path, self.names)
            self.items.append((f"place-{group}", path, boxes))

    def add_mapillary(self, root: Path) -> None:
        to_ours = {m: c["name"] for c in self.taxonomy for m in c.get("mapillary", [])}
        for split in ("training", "validation"):
            panoptic = root / split / "v2.0" / "panoptic" / "panoptic_2020.json"
            if not panoptic.exists():
                continue
            data = json.loads(panoptic.read_text())
            cats = {c["id"]: c["name"] for c in data["categories"]}
            for a in data["annotations"]:
                boxes = [(to_ours[cats[s["category_id"]]], s["bbox"]) for s in a["segments_info"]
                         if cats.get(s["category_id"]) in to_ours]
                if boxes:
                    path = root / split / "images" / (Path(a["file_name"]).stem + ".jpg")
                    self.items.append((f"mapillary-{a['image_id']}", path, boxes))

    def write(self, valid: float, test: float, seed: int) -> None:
        self.save_cache()
        groups = sorted({g for g, _, _ in self.items})
        random.Random(seed).shuffle(groups)
        n_test = max(1, round(len(groups) * test))
        n_valid = max(1, round(len(groups) * valid))
        split_of = {g: "test" for g in groups[:n_test]}
        split_of |= {g: "valid" for g in groups[n_test:n_test + n_valid]}
        categories = [{"id": i, "name": n, "supercategory": n} for i, n in enumerate(self.names)]
        index = {n: i for i, n in enumerate(self.names)}
        for split in ("train", "valid", "test"):
            folder = self.out / split
            if folder.exists():
                shutil.rmtree(folder)
            folder.mkdir(parents=True)
            images, annotations = [], []
            for group, path, boxes in self.items:
                if split_of.get(group, "train") != split:
                    continue
                image_id = len(images)
                name = f"{group}-{path.stem}{path.suffix.lower()}"
                width, height = Image.open(path).size
                shutil.copy(path, folder / name)
                images.append({"id": image_id, "file_name": name, "width": width, "height": height})
                for label, (x, y, w, h) in boxes:
                    if w < 2 or h < 2:
                        continue
                    annotations.append({
                        "id": len(annotations), "image_id": image_id, "category_id": index[label],
                        "bbox": [x, y, w, h], "area": w * h, "iscrowd": 0,
                    })
            (folder / "_annotations.coco.json").write_text(json.dumps(
                {"images": images, "annotations": annotations, "categories": categories}
            ))
            counts = defaultdict(int)
            for a in annotations:
                counts[self.names[a["category_id"]]] += 1
            print(f"{split}: {len(images)} images, {len(annotations)} boxes; {dict(sorted(counts.items(), key=lambda kv: -kv[1]))}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--coco-annotations", type=Path)
    parser.add_argument("--coco-images", type=int, default=2500)
    parser.add_argument("--coco-image-dir", type=Path, help="where COCO images are cached; default <out>/../coco-images")
    parser.add_argument("--photos", type=Path, action="append", default=[])
    parser.add_argument("--mapillary", type=Path)
    parser.add_argument("--valid", type=float, default=0.1)
    parser.add_argument("--test", type=float, default=0.1)
    parser.add_argument("--seed", type=int, default=0)
    parser.add_argument("--box-threshold", type=float, default=0.35)
    parser.add_argument("--text-threshold", type=float, default=0.25)
    parser.add_argument("--labeller", default="IDEA-Research/grounding-dino-tiny")
    parser.add_argument("--no-autolabel", action="store_true", help="fail rather than run Grounding DINO (cache only)")
    args = parser.parse_args()

    taxonomy = load_taxonomy()
    prompts = {c["name"]: c.get("prompt", c["name"]) for c in taxonomy}
    labeller = None if args.no_autolabel else AutoLabeller(prompts, args.box_threshold, args.text_threshold, args.labeller)
    builder = Builder(args.out, labeller)
    if args.coco_annotations:
        builder.add_coco(args.coco_annotations, args.coco_images, args.coco_image_dir or args.out.parent / "coco-images", args.seed)
    for folder in args.photos:
        builder.add_photos(folder)
    if args.mapillary:
        builder.add_mapillary(args.mapillary)
    if not builder.items:
        raise SystemExit("no images: give --coco-annotations, --photos or --mapillary")
    builder.write(args.valid, args.test, args.seed)


if __name__ == "__main__":
    main()
