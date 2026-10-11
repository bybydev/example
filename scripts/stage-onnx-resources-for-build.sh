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
python3 - "$ROOT/scripts/onnx-assets.json" "$SOURCE" "$TEMP" <<'PY'
import json
import shutil
import sys
from pathlib import Path

manifest = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
source = Path(sys.argv[2])
staged = Path(sys.argv[3])

# Copy only declared model and voice assets. Cached non-English voice files
# from earlier builds must never be included in the English-only app.
for asset in manifest["resources"]:
    relative = Path(asset["path"])
    target = staged / relative
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source / relative, target)

# Retain attribution and license notices in the signed archive.
for file in source.iterdir():
    if file.is_file() and file.suffix == ".txt":
        shutil.copy2(file, staged / file.name)
PY
cp "$ROOT/scripts/onnx-assets.json" "$TEMP/ONNXAssetManifest.json"
python3 "$ROOT/scripts/onnx-assets.py" verify --root "$TEMP"
rm -rf "$STAGED"
mkdir -p "$(dirname "$STAGED")"
mv "$TEMP" "$STAGED"
echo "Staged all Kokoro ONNX and G2P resources for offline app bundle."
