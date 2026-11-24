"""Export an RF-DETR detector to a Core ML package the app can run through Vision.

    source ~/.venvs/accessable-ml/bin/activate
    python Scripts/models/export_rfdetr_coreml.py --variant nano
    python Scripts/models/export_rfdetr_coreml.py --variant small
    python Scripts/models/export_rfdetr_coreml.py --checkpoint runs/outdoor/checkpoint_best_total.pth \
        --variant nano --name rfdetr_n_outdoor

RF-DETR's own Core ML exporter takes an ImageNet-normalised float tensor and returns raw logits
in the training label layout. The app feeds models through Vision (`VNCoreMLRequest`), which
hands the model an image, so this wraps the network before conversion:

- input `image`: an RGB image (Vision scales it to the model's square input, `.scaleFill`),
  read as 0...1 and normalised inside the graph;
- output `confidence`: `[queries, classes]` sigmoid scores, columns in `classes.txt` order;
- output `coordinates`: `[queries, 4]` normalised centre-x, centre-y, width, height, top-left
  origin.

That is exactly the contract `DFineObjectDetector` already decodes (`dfineDetections`), so the
Swift side only needs the model name. The class list is stored in the model's metadata
(`classes`, comma-separated), which is where the app reads it from.

The conversion reuses RF-DETR's own Core ML pass pipeline and op patches (iOS15 program,
bilinear-upsample rewrite), because those are what keep the Neural Engine result matching
PyTorch.
"""

from __future__ import annotations

import argparse
import json
import shutil
from pathlib import Path

import coremltools as ct
import numpy as np
import torch
from torch import nn

from rfdetr import RFDETRMedium, RFDETRNano, RFDETRSmall
from rfdetr.assets.coco_classes import COCO_CLASSES
from rfdetr.export._coreml.op_coverage import unsupported_coreml_ops
from rfdetr.export._coreml.passes import rfdetr_pass_pipeline
from rfdetr.export._coreml.torch_ops import ensure_coreml_torch_op_patches
from rfdetr.export.prepare import prepare_export_graph

VARIANTS = {"nano": RFDETRNano, "small": RFDETRSmall, "medium": RFDETRMedium}
SHORT = {"nano": "n", "small": "s", "medium": "m"}
REPO = Path(__file__).resolve().parents[2]
DEFAULT_OUTPUT = REPO / "AccessAble/AccessAble/Resources"
IMAGENET_MEAN = (0.485, 0.456, 0.406)
IMAGENET_STD = (0.229, 0.224, 0.225)


class VisionDetector(nn.Module):
    """RF-DETR with normalisation in front and app-shaped outputs behind."""

    def __init__(self, detector: nn.Module, columns: list[int]) -> None:
        super().__init__()
        self.detector = detector
        self.register_buffer("mean", torch.tensor(IMAGENET_MEAN).view(1, 3, 1, 1))
        self.register_buffer("std", torch.tensor(IMAGENET_STD).view(1, 3, 1, 1))
        self.register_buffer("columns", torch.tensor(columns, dtype=torch.long))

    def forward(self, image: torch.Tensor) -> tuple[torch.Tensor, torch.Tensor]:
        boxes, logits = self.detector((image - self.mean) / self.std)[:2]
        scores = logits[0].sigmoid().index_select(1, self.columns)
        return scores, boxes[0]


def logit_columns(model, num_logits: int) -> tuple[list[str], list[int]]:
    """Which logit column holds each class, in the order the app will list them.

    COCO-pretrained weights have 91 columns indexed by COCO category id (with gaps); a model
    fine-tuned on our own dataset has one column per class in `class_names` order, plus a
    trailing background slot.
    """
    names = list(model.class_names or [])
    if num_logits == 91 and names == [COCO_CLASSES[k] for k in sorted(COCO_CLASSES)]:
        ids = sorted(COCO_CLASSES)
        return [COCO_CLASSES[i] for i in ids], ids
    if not names:
        raise SystemExit("checkpoint has no class names; pass a model trained with rfdetr's train()")
    if len(names) > num_logits:
        raise SystemExit(f"{len(names)} class names but only {num_logits} logit columns")
    return names, list(range(len(names)))


def export(variant: str, checkpoint: str | None, name: str, output: Path, precision: str) -> Path:
    cls = VARIANTS[variant]
    model = cls(pretrain_weights=checkpoint) if checkpoint else cls()
    resolution = int(model.model.resolution)
    detector = model.model.model
    detector.eval()

    # Freezes the DINOv2 position embeddings to the export shape and switches every module to
    # its export forward (plain tensors in, (boxes, logits) out).
    detector.export()
    prepare_export_graph(detector, model.model_config, shape=(resolution, resolution), device="cpu")

    class_names, columns = logit_columns(model, detector.class_embed.out_features)
    wrapped = VisionDetector(detector, columns).eval()
    example = torch.rand(1, 3, resolution, resolution)

    ensure_coreml_torch_op_patches()
    with torch.no_grad():
        program = torch.export.export(wrapped, (example,), strict=False).run_decompositions({})
    gaps = unsupported_coreml_ops(program)
    if gaps:
        raise SystemExit(f"ops Core ML can't convert: {dict(gaps)}")

    mlmodel = ct.convert(
        program,
        convert_to="mlprogram",
        # iOS15, as RF-DETR's exporter does: the iOS16 program loses ~3 AP on the Neural Engine.
        minimum_deployment_target=ct.target.iOS15,
        compute_precision=ct.precision.FLOAT16 if precision == "fp16" else ct.precision.FLOAT32,
        inputs=[ct.ImageType(name="image", shape=example.shape, scale=1 / 255.0, color_layout=ct.colorlayout.RGB)],
        outputs=[ct.TensorType(name="confidence"), ct.TensorType(name="coordinates")],
        pass_pipeline=rfdetr_pass_pipeline(),
    )
    mlmodel.short_description = f"RF-DETR {variant} ({len(class_names)} classes), {resolution}px, for AccessAble"
    mlmodel.user_defined_metadata["classes"] = ",".join(class_names)
    mlmodel.user_defined_metadata["resolution"] = str(resolution)
    mlmodel.user_defined_metadata["source"] = checkpoint or f"rf-detr-{variant} COCO"

    output.mkdir(parents=True, exist_ok=True)
    package = output / f"{name}.mlpackage"
    if package.exists():
        shutil.rmtree(package)
    mlmodel.save(str(package))
    # Everything the app needs is in the package's metadata. A side file goes next to it only
    # outside the app's Resources folder, where anything would be bundled into the app.
    if output.resolve() != DEFAULT_OUTPUT.resolve():
        (output / f"{name}.json").write_text(json.dumps(
            {"variant": variant, "resolution": resolution, "classes": class_names, "precision": precision}, indent=2
        ))

    # Sanity check: the package must agree with PyTorch on a real-ish input.
    with torch.no_grad():
        reference_scores, reference_boxes = wrapped(example)
    from PIL import Image
    pixels = (example[0].permute(1, 2, 0).numpy() * 255).round().astype(np.uint8)
    predicted = ct.models.MLModel(str(package)).predict({"image": Image.fromarray(pixels)})
    score_error = np.abs(predicted["confidence"].squeeze() - reference_scores.numpy()).max()
    box_error = np.abs(predicted["coordinates"].squeeze() - reference_boxes.numpy()).max()
    print(f"saved {package}  ({len(class_names)} classes, {resolution}px)")
    print(f"max |coreml - torch|: scores {score_error:.4f}, boxes {box_error:.4f}")
    return package


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--variant", choices=sorted(VARIANTS), default="nano")
    parser.add_argument("--checkpoint", help="fine-tuned .pth; COCO weights when omitted")
    parser.add_argument("--name", help="package name; default rfdetr_<n|s|m>_coco")
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--precision", choices=["fp16", "fp32"], default="fp16")
    args = parser.parse_args()
    name = args.name or f"rfdetr_{SHORT[args.variant]}_coco"
    export(args.variant, args.checkpoint, name, args.output, args.precision)


if __name__ == "__main__":
    main()
