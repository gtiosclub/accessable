"""Fine-tune RF-DETR on the outdoor dataset, then export it for the app.

    source ~/.venvs/accessable-ml/bin/activate
    python Scripts/training/train.py --dataset ~/accessable-data/outdoor --output ~/accessable-data/runs/outdoor-s

Starts from RF-DETR's COCO weights. The classification head is rebuilt by class *name*: a class
COCO already has (person, car, bench, ...) starts from COCO's own row for it, and only the new ones
(pole, bollard, trash can, ...) start fresh. rfdetr on its own just truncates COCO's 91-row head to
the first rows, which hands "person" COCO's empty row 0, "bicycle" COCO's person row and so on, and
the shared classes lose accuracy relearning what COCO already knew.

Train on a CUDA machine (Colab, a lab server); a 16 GB Mac runs out of memory. When training
finishes, the best checkpoint is exported to Core ML as `rfdetr_s_outdoor` (`--export-to`, default
the app's Resources), which `DETRObjectDetector` prefers over the COCO model. Check it first:
`Scripts/models/benchmark_detectors.py` on COCO val must not fall below `rfdetr_s_coco` for the
shared classes, and the dataset's test split shows the new ones.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

import torch
from rfdetr import RFDETRMedium, RFDETRNano, RFDETRSmall
from rfdetr.assets.coco_classes import COCO_CLASSES

VARIANTS = {"nano": RFDETRNano, "small": RFDETRSmall, "medium": RFDETRMedium}
# The repo root when run from Scripts/training; on Colab train.py is copied alone, so fall back
# to its own folder (export needs the repo and the Mac anyway, so --no-export is used there).
_here = Path(__file__).resolve()
REPO = _here.parents[2] if len(_here.parents) > 2 else _here.parent
# Our class name -> COCO's name for it, where they differ.
COCO_ALIASES = {"table": "dining table"}
HEAD_KEYS = ("class_embed.", "transformer.enc_out_class_embed.")


def coco_head_checkpoint(variant: str, dataset: Path, output: Path) -> Path:
    """COCO weights with the classification head re-ordered to the dataset's classes.

    The dataset's category ids are the head's row indices (0..n-1, plus one spare row, as rfdetr
    lays it out). A class COCO has gets COCO's row for it; a new class gets the mean of COCO's
    object rows, a generic "something is here" start that fine-tuning then specialises.
    """
    categories = json.loads((dataset / "train" / "_annotations.coco.json").read_text())["categories"]
    names = [c["name"] for c in sorted(categories, key=lambda c: c["id"])]
    if [c["id"] for c in sorted(categories, key=lambda c: c["id"])] != list(range(len(names))):
        sys.exit("dataset category ids must be 0..n-1 (build_dataset.py writes them so)")
    coco_row = {name: row for row, name in COCO_CLASSES.items()}

    coco = VARIANTS[variant]().model.model.state_dict()  # loads (and downloads) the COCO weights
    object_rows = sorted(COCO_CLASSES)
    state, reused = {}, []
    for key, value in coco.items():
        if not key.startswith(HEAD_KEYS):
            state[key] = value
            continue
        rows = []
        for name in names:
            row = coco_row.get(COCO_ALIASES.get(name, name))
            rows.append(value[row] if row is not None else value[object_rows].mean(0))
            if row is not None and key == "class_embed.bias":
                reused.append(name)
        rows.append(value[0])  # the spare row
        state[key] = torch.stack(rows)
    print(f"head from COCO for {len(reused)} classes: {', '.join(reused)}")
    print(f"fresh: {', '.join(n for n in names if n not in reused)}")
    path = output / "coco_head_init.pth"
    output.mkdir(parents=True, exist_ok=True)
    torch.save({"model": state, "args": {"class_names": names}}, path)
    return path


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--dataset", type=Path, required=True, help="folder with train/ valid/ test/ (build_dataset.py)")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--variant", choices=sorted(VARIANTS), default="small")
    parser.add_argument("--epochs", type=int, default=30)
    parser.add_argument("--batch-size", type=int, default=4)
    parser.add_argument("--grad-accum", type=int, default=4, help="effective batch = batch-size x grad-accum")
    parser.add_argument("--lr", type=float, default=5e-5, help="decoder and head")
    parser.add_argument("--lr-encoder", type=float, default=5e-5, help="DINOv2 backbone; low keeps COCO's features")
    parser.add_argument("--patience", type=int, default=10, help="epochs without improvement before stopping")
    parser.add_argument("--no-coco-head", action="store_true", help="let rfdetr truncate COCO's head (not advised)")
    parser.add_argument("--resume", type=Path, help="checkpoint to continue from")
    parser.add_argument("--export-to", type=Path, default=REPO / "AccessAble/AccessAble/Resources")
    parser.add_argument("--name", default=None, help="exported package name; default rfdetr_<n|s|m>_outdoor")
    parser.add_argument("--no-export", action="store_true")
    args = parser.parse_args()

    if args.no_coco_head or args.resume:
        model = VARIANTS[args.variant]()
    else:
        start = coco_head_checkpoint(args.variant, args.dataset, args.output)
        model = VARIANTS[args.variant](pretrain_weights=str(start))
    model.train(
        dataset_dir=str(args.dataset),
        output_dir=str(args.output),
        epochs=args.epochs,
        batch_size=args.batch_size,
        grad_accum_steps=args.grad_accum,
        lr=args.lr,
        lr_encoder=args.lr_encoder,
        resume=str(args.resume) if args.resume else None,
        early_stopping=True,
        early_stopping_patience=args.patience,
    )

    if args.no_export:
        return
    checkpoints = [args.output / "checkpoint_best_total.pth", args.output / "checkpoint_best_ema.pth",
                   args.output / "checkpoint_best_regular.pth", args.output / "checkpoint.pth"]
    best = next((c for c in checkpoints if c.exists()), None)
    if best is None:
        sys.exit(f"no checkpoint found in {args.output}")
    name = args.name or f"rfdetr_{args.variant[0]}_outdoor"
    subprocess.run([
        sys.executable, str(REPO / "Scripts/models/export_rfdetr_coreml.py"),
        "--variant", args.variant, "--checkpoint", str(best), "--name", name, "--output", str(args.export_to),
    ], check=True)


if __name__ == "__main__":
    main()
