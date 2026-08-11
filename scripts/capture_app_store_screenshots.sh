#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/.build/app-store-screenshots"
RESULT_BUNDLE="${BUILD_DIR}/BYOKchatScreenshots.xcresult"
ATTACHMENTS_DIR="${BUILD_DIR}/attachments"
OUTPUT_DIR="${ROOT_DIR}/AppStore/Screenshots"
DESTINATION="${SCREENSHOT_DESTINATION:-platform=iOS Simulator,name=iPhone 17 Pro Max}"

command -v xcodegen >/dev/null 2>&1 || {
  echo "error: xcodegen is required"
  exit 1
}

rm -rf "${RESULT_BUNDLE}" "${ATTACHMENTS_DIR}"
mkdir -p "${BUILD_DIR}" "${OUTPUT_DIR}"

cd "${ROOT_DIR}"
xcodegen generate

xcodebuild \
  -project BYOKchat.xcodeproj \
  -scheme BYOKchatScreenshots \
  -destination "${DESTINATION}" \
  -resultBundlePath "${RESULT_BUNDLE}" \
  -only-testing:BYOKchatUITests/BYOKchatScreenshotTests \
  test

xcrun xcresulttool export attachments \
  --path "${RESULT_BUNDLE}" \
  --output-path "${ATTACHMENTS_DIR}"

find "${OUTPUT_DIR}" -maxdepth 1 -type f -name '[0-9][0-9]_*.png' -delete

export ATTACHMENTS_DIR OUTPUT_DIR
python3 <<'PY'
import json
import os
import pathlib
import re
import shutil

attachments = pathlib.Path(os.environ["ATTACHMENTS_DIR"])
output = pathlib.Path(os.environ["OUTPUT_DIR"])
expected = {
    "01_Home",
    "02_Sidebar",
    "03_Chat",
    "04_Projects",
    "05_Providers",
    "06_MCP",
    "07_Themes",
    "08_Paywall",
}

pngs = list(attachments.rglob("*.png"))
manifest_paths = list(attachments.rglob("manifest.json"))
renamed = set()

for manifest_path in manifest_paths:
    try:
        manifest = json.loads(manifest_path.read_text())
    except Exception:
        continue

    def walk(value):
        if isinstance(value, dict):
            strings = [v for v in value.values() if isinstance(v, str)]
            display = next((s for s in strings if s in expected), None)
            filename = next((s for s in strings if s.lower().endswith(".png")), None)
            if display and filename:
                source = attachments / filename
                if not source.exists():
                    matches = list(attachments.rglob(pathlib.Path(filename).name))
                    source = matches[0] if matches else None
                if source and source.exists():
                    shutil.copy2(source, output / f"{display}.png")
                    renamed.add(display)
            for child in value.values():
                walk(child)
        elif isinstance(value, list):
            for child in value:
                walk(child)

    walk(manifest)

for source in pngs:
    stem = source.stem
    match = re.search(r"(0[1-8]_(?:Home|Sidebar|Chat|Projects|Providers|MCP|Themes|Paywall))", stem)
    if match and match.group(1) not in renamed:
        name = match.group(1)
        shutil.copy2(source, output / f"{name}.png")
        renamed.add(name)

missing = expected - renamed
if missing:
    print("warning: xcresult attachments were exported, but these names were not normalized:")
    for name in sorted(missing):
        print(f"  - {name}")
    print(f"Raw attachments are available in: {attachments}")
else:
    print("Saved screenshots:")
    for name in sorted(renamed):
        print(f"  {output / (name + '.png')}")
PY
