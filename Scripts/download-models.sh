#!/bin/sh
# Fetches models too large for git into the app's Resources folder. Run from the repo root:
#   sh Scripts/download-models.sh
# Without them the app still builds and runs; the features that use them switch off.
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
