#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$ROOT/Resources/ONNX"
STAGED="$ROOT/.build-resources/ONNX"
python3 "$ROOT/scripts/onnx-assets.py" verify --root "$SOURCE"
TEMP="$STAGED.stage.$$"
trap 'rm -rf "$TEMP"' EXIT
rm -rf "$TEMP"
mkdir -p "$TEMP"
cp -R "$SOURCE/." "$TEMP/"
cp "$ROOT/scripts/onnx-assets.json" "$TEMP/ONNXAssetManifest.json"
python3 "$ROOT/scripts/onnx-assets.py" verify --root "$TEMP"
rm -rf "$STAGED"
mkdir -p "$(dirname "$STAGED")"
mv "$TEMP" "$STAGED"
echo "Staged all Kokoro ONNX and G2P resources for offline app bundle."
