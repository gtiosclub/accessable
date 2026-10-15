# Exports YOLO11n to Core ML for T13.
#
#   pip install ultralytics coremltools "numpy<2.3"
#   python Scripts/export_yolo.py
#
# nms=True puts non-max suppression in the model so Vision gives back labeled boxes.
# Note: Ultralytics is AGPL, check before shipping to the App Store.

import shutil
from pathlib import Path

from ultralytics import YOLO

dest = Path(__file__).resolve().parent.parent / "AccessAble/AccessAble/Resources/yolo11n.mlpackage"

exported = Path(YOLO("yolo11n.pt").export(format="coreml", nms=True, imgsz=640, half=True))
if dest.exists():
    shutil.rmtree(dest)
shutil.move(str(exported), dest)
print("saved to", dest)
