#!/bin/sh
# Fetches or builds the models too large for git into the app's Resources folder. Run from the
# repo root:
#   sh Scripts/download-models.sh            # ground segmentation (download)
#   sh Scripts/download-models.sh --rfdetr   # also export RF-DETR Small (needs Python, ~5 min)
# Without them the app still builds and runs; the features that use them switch off, and object
# detection falls back to the D-FINE model that is in git.
set -eu

resources="AccessAble/AccessAble/Resources"

# Ground segmentation (SurfaceReader): Apple's Core ML DETR, COCO-panoptic labels. 86 MB.
name="DETRResnet50SemanticSegmentationF16.mlpackage"
base="https://huggingface.co/apple/coreml-detr-semantic-segmentation/resolve/main/$name"
if [ -d "$resources/$name" ]; then
    echo "$name already present"
else
    for file in Manifest.json Data/com.apple.CoreML/model.mlmodel Data/com.apple.CoreML/weights/weight.bin; do
        mkdir -p "$resources/$name/$(dirname "$file")"
        curl -fL --progress-bar -o "$resources/$name/$file" "$base/$file"
    done
    echo "Downloaded $name"
fi

# Object detection (DETRObjectDetector): RF-DETR Small, COCO weights, exported locally.
# Python 3.11 environment outside iCloud, created once.
if [ "${1:-}" = "--rfdetr" ]; then
    if [ -d "$resources/rfdetr_s_coco.mlpackage" ]; then
        echo "rfdetr_s_coco.mlpackage already present"
    else
        venv="$HOME/.venvs/accessable-ml"
        if [ ! -x "$venv/bin/python" ]; then
            python3 -m venv "$venv" || uv venv "$venv" --python 3.11
            "$venv/bin/python" -m pip install --quiet "rfdetr[coreml,train,loggers]" transformers pycocotools
        fi
        "$venv/bin/python" Scripts/models/export_rfdetr_coreml.py --variant small --output "$resources"
    fi
fi
