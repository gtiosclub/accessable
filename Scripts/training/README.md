# Training the outdoor detector

COCO, which every stock detector learns from, has no pole, bollard, trash can, traffic cone,
tree or barrier, the things a blind pedestrian actually walks into. These scripts fine-tune
RF-DETR on the classes in `taxonomy.json` (the same list as `OutdoorClasses.all` in the app)
and export the result as `rfdetr_s_outdoor`, which `DETRObjectDetector` prefers over the COCO model.

Geometry, not the model, decides what is in the way. A better model means the user hears
"Pole ahead. Go left." instead of "Obstacle ahead. Go left.", vehicles get a distance from 25 m
for approach warnings, and phones without LiDAR warn about street furniture at all.

## Setup (once)

```sh
uv venv ~/.venvs/accessable-ml --python 3.11      # outside iCloud: see the README's swift test note
source ~/.venvs/accessable-ml/bin/activate
uv pip install "rfdetr[coreml,train,loggers]" transformers pycocotools
```

## 1. Record your own data. This matters most.

No public dataset is shot from a phone held at chest height on a sidewalk. Walk the routes
the app will be used on and take a frame every half second or so, in portrait. Vary the
light (day, dusk, rain, glare) and the places. One folder per place or walk:

```
~/accessable-data/recordings/
  tech-green/0001.jpg ...
  north-ave-crossing/0001.jpg ...
```

The folder is the unit of the train/valid/test split, so whole places are held out for testing.

## 2. Build the dataset

```sh
python Scripts/training/build_dataset.py --out ~/accessable-data/outdoor \
  --coco-annotations /path/coco/annotations/instances_train2017.json --coco-images 3000 \
  --photos ~/accessable-data/recordings
```

- **COCO street scenes** keep COCO's human labels for the classes COCO has. Classes it lacks
  are auto-labelled by Grounding DINO. Train images only, so COCO *val* stays clean for benchmarks.
- **Your photos** are auto-labelled for every class.
- **Mapillary Vistas v2** (`--mapillary /path/to/vistas`, free account at mapillary.com) adds
  ~25k street images with human boxes for poles, bollards, bike racks, cones and more. It is
  25 GB, so check your disk first.

Auto-labels are filtered before use: an auto box that duplicates a human box is dropped, and
each class must have a plausible shape and size. Without the filters Grounding DINO called
whole trucks "scooters" and a dog a "bollard". The labels are still machine-made, so **review
them**: import `train/_annotations.coco.json` into CVAT or Roboflow, fix the boxes, export COCO
JSON back over it. An hour of correction is worth more than another thousand auto-labelled images.

## 3. Train

```sh
python Scripts/training/train.py --dataset ~/accessable-data/outdoor --output ~/accessable-data/runs/outdoor-s
```

It starts from RF-DETR Small's COCO weights. **Train on a GPU machine, not a 16 GB Mac:** on an
M4 with 16 GB, RF-DETR Small at batch size 4 filled memory and swap (15 of 16 GB swap) before
its first logged step, and had to be killed. A free Colab T4 works (about 3 minutes an epoch,
8 GB of GPU memory at batch size 8). The COCO images need not be uploaded: send only the labels
and let Colab fetch the photos from cocodataset.org.

```sh
# On the Mac: an 800 KB bundle of the three _annotations.coco.json files and train.py.
mkdir -p /tmp/bundle/outdoor/{train,valid,test}
for s in train valid test; do cp ~/accessable-data/outdoor/$s/_annotations.coco.json /tmp/bundle/outdoor/$s/; done
cp Scripts/training/train.py /tmp/bundle/ && tar czf outdoor_bundle.tgz -C /tmp/bundle outdoor train.py
```

```python
# Colab: Runtime > Change runtime type > T4 GPU. Upload outdoor_bundle.tgz in the Files panel, then:
!tar xzf outdoor_bundle.tgz && pip install -q "rfdetr[train,loggers]"
import json, urllib.request, concurrent.futures as cf
jobs = [(s, i["file_name"]) for s in ["train", "valid", "test"]
        for i in json.load(open(f"outdoor/{s}/_annotations.coco.json"))["images"]]
fetch = lambda j: urllib.request.urlretrieve(
    "http://images.cocodataset.org/train2017/" + j[1].split("-")[-1], f"outdoor/{j[0]}/{j[1]}")
list(cf.ThreadPoolExecutor(32).map(fetch, jobs))   # COCO images only; upload your own photos
!python train.py --dataset outdoor --output run --epochs 20 --batch-size 8 --grad-accum 2 --no-export
# Download run/checkpoint_best_total.pth.
```

Then export on the Mac (the Core ML export only runs on macOS):

```sh
python Scripts/models/export_rfdetr_coreml.py --variant small \
  --checkpoint checkpoint_best_total.pth --name rfdetr_s_outdoor
```


## 4. Check before shipping

```sh
python Scripts/models/benchmark_detectors.py --coco /path/coco \
  AccessAble/AccessAble/Resources/rfdetr_s_coco.mlpackage AccessAble/AccessAble/Resources/rfdetr_s_outdoor.mlpackage
```

The first model trained this way (November 2026, results in `docs/ComputerVision.md`) matches the
COCO model at the app's threshold on people and vehicles, and adds cones, poles, trash cans,
trees and barriers. The outdoor model must not lose to the COCO model on the classes they share (people, vehicles,
benches, hydrants). If it does, delete `rfdetr_s_outdoor.mlpackage` and the app goes back to the
COCO model. Then retune `DetectionConfidencePolicy.rfdetr` with the benchmark's threshold sweep,
and walk the test routes with the developer overlay on.
