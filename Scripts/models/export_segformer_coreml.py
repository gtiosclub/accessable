"""Export a SegFormer semantic-segmentation model to Core ML for `SurfaceReader`.

    source ~/.venvs/accessable-ml/bin/activate
    python Scripts/models/export_segformer_coreml.py --checkpoint nvidia/segformer-b1-finetuned-ade-512-512

Why ADE20K: its 150 classes cover indoor and outdoor scenes seen from a walker's height
(floor, ceiling, road, sidewalk, path, grass, stairs, step, water, railing, pole...), so one
model serves the whole app. Cityscapes models only know a car's view of a street and have no
floor or ceiling, which the indoor checks need.

The package takes an RGB `image` (Vision stretches the frame to the square input), normalises
it inside the graph, and returns `classes`: an Int32 `[H/4, W/4]` map of class indices — the
same shape of output `SurfaceReader` already reads. The class names are stored in the model's
metadata (`classes`, comma-separated, ADE's own names).
"""

from __future__ import annotations

import argparse
import shutil
from pathlib import Path

import coremltools as ct
import numpy as np
import torch
from torch import nn
from transformers import SegformerForSemanticSegmentation

MEAN = (0.485, 0.456, 0.406)
STD = (0.229, 0.224, 0.225)


class ClassMap(nn.Module):
    def __init__(self, model: nn.Module) -> None:
        super().__init__()
        self.model = model
        self.register_buffer("mean", torch.tensor(MEAN).view(1, 3, 1, 1))
        self.register_buffer("std", torch.tensor(STD).view(1, 3, 1, 1))

    def forward(self, image: torch.Tensor) -> torch.Tensor:
        logits = self.model(pixel_values=(image - self.mean) / self.std).logits
        return logits[0].argmax(0).to(torch.int32)


def export(checkpoint: str, size: int, name: str, output: Path) -> Path:
    model = SegformerForSemanticSegmentation.from_pretrained(checkpoint).eval()
    labels = [model.config.id2label[i] for i in range(len(model.config.id2label))]
    wrapped = ClassMap(model).eval()
    example = torch.rand(1, 3, size, size)
    with torch.no_grad():
        traced = torch.jit.trace(wrapped, example)

    mlmodel = ct.convert(
        traced,
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.iOS17,
        compute_precision=ct.precision.FLOAT16,
        inputs=[ct.ImageType(name="image", shape=example.shape, scale=1 / 255.0, color_layout=ct.colorlayout.RGB)],
        outputs=[ct.TensorType(name="classes", dtype=np.int32)],
    )
    mlmodel.short_description = f"{checkpoint} for AccessAble's SurfaceReader, {size}px"
    mlmodel.user_defined_metadata["classes"] = ",".join(label.replace(",", ";") for label in labels)
    mlmodel.user_defined_metadata["source"] = checkpoint

    output.mkdir(parents=True, exist_ok=True)
    package = output / f"{name}.mlpackage"
    if package.exists():
        shutil.rmtree(package)
    mlmodel.save(str(package))
    print(f"saved {package} ({len(labels)} classes, {size}px)")
    return package


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--checkpoint", default="nvidia/segformer-b1-finetuned-ade-512-512")
    parser.add_argument("--size", type=int, default=512)
    parser.add_argument("--name", help="package name; default segformer_<bN>_ade")
    parser.add_argument("--output", type=Path, default=Path("AccessAble/AccessAble/Resources"))
    args = parser.parse_args()
    variant = next((part for part in args.checkpoint.split("-") if part.startswith("b") and part[1:].isdigit()), "b0")
    export(args.checkpoint, args.size, args.name or f"segformer_{variant}_ade", args.output)


if __name__ == "__main__":
    main()
