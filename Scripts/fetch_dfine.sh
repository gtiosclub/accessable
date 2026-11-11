#!/bin/sh
# Fetches the bundled object-detection model for T13/T31.
#
#   Scripts/fetch_dfine.sh
#
# Unlike yolo11n (replaced, see git history / docs/ComputerVision.md "Known limitations"),
# this one isn't exported locally — it's a pre-converted Core ML package, downloaded as-is.
# Source: Peterande/D-FINE (Apache-2.0), nano checkpoint, converted by john-rocky/peaceofcake.
set -eu

dest="$(dirname "$0")/../AccessAble/AccessAble/Resources/dfine_n_coco.mlpackage"
url="https://github.com/john-rocky/peaceofcake/releases/download/v0.2.0/dfine_n_coco.mlpackage.zip"
tmp="$(mktemp -d)"

curl -L -o "$tmp/dfine_n_coco.mlpackage.zip" "$url"
unzip -q "$tmp/dfine_n_coco.mlpackage.zip" -d "$tmp"
rm -rf "$dest"
mv "$tmp/dfine_n_coco.mlpackage" "$dest"
rm -rf "$tmp"
echo "saved to $dest"
