#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PHONE="${PHONE:-iPhone 17 Pro Max}"
IOS_VERSION="${IOS_VERSION:-26}"
THEME="${THEME:-midnight}"
ORIENTATION="${ORIENTATION:-portrait}"
PRESET="${PRESET:-showcase}"

case "${PHONE}" in
  "iPhone 17"|"iPhone 17 Pro"|"iPhone 17 Pro Max"|"iPhone 18 Pro"|"iPhone 18 Pro Max"|"iPhone Duo") ;;
  *)
    echo "error: unsupported phone '${PHONE}'. Expected one of: 'iPhone 17', 'iPhone 17 Pro', 'iPhone 17 Pro Max', 'iPhone 18 Pro', 'iPhone 18 Pro Max', 'iPhone Duo'." >&2
    exit 1
    ;;
esac

case "${IOS_VERSION}" in
  26|27) ;;
  *)
    echo "error: unsupported iOS version '${IOS_VERSION}'. Expected one of: 26, 27." >&2
    exit 1
    ;;
esac

case "${THEME}" in
  midnight|aubergine|obsidian|evergreen|velvet|daylight|paper|iris|sage|sakura) ;;
  *)
    echo "error: unsupported theme '${THEME}'. Expected one of: midnight, aubergine, obsidian, evergreen, velvet, daylight, paper, iris, sage, sakura." >&2
    exit 1
    ;;
esac

case "${ORIENTATION}" in
  portrait|landscape) ;;
  *)
    echo "error: unsupported orientation '${ORIENTATION}'. Expected one of: portrait, landscape." >&2
    exit 1
    ;;
esac

command -v xcodegen >/dev/null 2>&1 || {
  echo "error: xcodegen is required" >&2
  exit 1
}

PHONE_SLUG="$(echo "${PHONE}" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g')"
RUN_SLUG="${PHONE_SLUG}-ios${IOS_VERSION}-${THEME}-${ORIENTATION}"

BUILD_DIR="${BUILD_DIR:-${ROOT_DIR}/.build/app-store-screenshots/${RUN_SLUG}}"
RESULT_BUNDLE="${BUILD_DIR}/BYOKchatScreenshots.xcresult"
ATTACHMENTS_DIR="${BUILD_DIR}/attachments"
OUTPUT_DIR="${OUTPUT_DIR:-${ROOT_DIR}/AppStore/Screenshots/${RUN_SLUG}}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-${BUILD_DIR}/DerivedData}"
SOURCE_PACKAGES_PATH="${SOURCE_PACKAGES_PATH:-}"

# Resolve exact iOS runtime matching the requested major version (fail fast if unavailable).
RUNTIME_ID="$(
  xcrun simctl list runtimes -j | python3 -c '
import json, sys
target_major = sys.argv[1]
data = json.load(sys.stdin)
matches = []
for runtime in data.get("runtimes", []):
    if not runtime.get("isAvailable", False):
        continue
    identifier = runtime.get("identifier", "")
    platform = runtime.get("platform", "")
    version = str(runtime.get("version", ""))
    if platform != "iOS" and "iOS" not in identifier:
        continue
    if version == target_major or version.startswith(target_major + "."):
        parts = tuple(int(p) for p in version.split(".") if p.isdigit())
        matches.append((parts, identifier))
matches.sort(reverse=True)
print(matches[0][1] if matches else "")
' "${IOS_VERSION}"
)"

if [[ -z "${RUNTIME_ID}" ]]; then
  echo "error: no available iOS ${IOS_VERSION} simulator runtime found on this machine." >&2
  echo "Available runtimes:" >&2
  xcrun simctl list runtimes >&2
  exit 1
fi

# Resolve exact device within that runtime; create it if the device type exists and is supported by this runtime.
SIMULATOR_UDID="$(
  xcrun simctl list devices available -j | python3 -c '
import json, sys
runtime_id, device_name = sys.argv[1], sys.argv[2]
data = json.load(sys.stdin)
devices = data.get("devices", {}).get(runtime_id, [])
match = next((d["udid"] for d in devices if d.get("isAvailable", False) and d.get("name") == device_name), "")
print(match)
' "${RUNTIME_ID}" "${PHONE}"
)"

CREATED_SIMULATOR=false
if [[ -z "${SIMULATOR_UDID}" ]]; then
  DEVICE_TYPE_ID="$(
    xcrun simctl list devicetypes -j | python3 -c '
import json, sys
device_name = sys.argv[1]
data = json.load(sys.stdin)
match = next((dt["identifier"] for dt in data.get("devicetypes", []) if dt.get("name") == device_name), "")
print(match)
' "${PHONE}"
  )"

  if [[ -z "${DEVICE_TYPE_ID}" ]]; then
    echo "error: simulator device type '${PHONE}' is not supported by this Xcode installation." >&2
    echo "Available iPhone device types:" >&2
    xcrun simctl list devicetypes | grep -i "iPhone" >&2 || true
    echo "Available devices for ${RUNTIME_ID}:" >&2
    xcrun simctl list devices available "${RUNTIME_ID}" >&2 || true
    exit 1
  fi

  if ! SIMULATOR_UDID="$(xcrun simctl create "${PHONE}" "${DEVICE_TYPE_ID}" "${RUNTIME_ID}" 2>&1)"; then
    echo "error: combination '${PHONE}' + '${RUNTIME_ID}' is not supported: ${SIMULATOR_UDID}" >&2
    exit 1
  fi
  CREATED_SIMULATOR=true
fi

echo "Selected runtime: ${RUNTIME_ID}"
echo "Selected device:  ${PHONE} (${SIMULATOR_UDID})"
echo "Theme:            ${THEME}"
echo "Orientation:      ${ORIENTATION}"
echo "Preset:           ${PRESET}"

cleanup() {
  xcrun simctl status_bar "${SIMULATOR_UDID}" clear >/dev/null 2>&1 || true
  if [[ "${CREATED_SIMULATOR}" == "true" ]]; then
    xcrun simctl shutdown "${SIMULATOR_UDID}" >/dev/null 2>&1 || true
    xcrun simctl delete "${SIMULATOR_UDID}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

xcrun simctl boot "${SIMULATOR_UDID}" >/dev/null 2>&1 || true
xcrun simctl bootstatus "${SIMULATOR_UDID}" -b

xcrun simctl status_bar "${SIMULATOR_UDID}" override \
  --time "9:41" \
  --dataNetwork wifi \
  --wifiMode active \
  --wifiBars 3 \
  --cellularMode active \
  --cellularBars 4 \
  --batteryState charged \
  --batteryLevel 100

rm -rf "${RESULT_BUNDLE}" "${ATTACHMENTS_DIR}" "${OUTPUT_DIR}"
mkdir -p "${BUILD_DIR}" "${OUTPUT_DIR}"

cd "${ROOT_DIR}"
xcodegen generate

XCODEBUILD_ARGS=(
  -project BYOKchat.xcodeproj
  -scheme BYOKchat
  -configuration Debug
  -destination "platform=iOS Simulator,id=${SIMULATOR_UDID}"
  -derivedDataPath "${DERIVED_DATA_PATH}"
  -resultBundlePath "${RESULT_BUNDLE}"
  -only-testing:BYOKchatUITests/BYOKchatScreenshotTests
)

if [[ -n "${SOURCE_PACKAGES_PATH}" ]]; then
  XCODEBUILD_ARGS+=(-clonedSourcePackagesDirPath "${SOURCE_PACKAGES_PATH}")
fi

xcodebuild "${XCODEBUILD_ARGS[@]}" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  "TEST_RUNNER_SCREENSHOT_THEME=${THEME}" \
  "TEST_RUNNER_SCREENSHOT_ORIENTATION=${ORIENTATION}" \
  "TEST_RUNNER_SCREENSHOT_PRESET=${PRESET}" \
  test

xcrun xcresulttool export attachments \
  --path "${RESULT_BUNDLE}" \
  --output-path "${ATTACHMENTS_DIR}"

export ATTACHMENTS_DIR OUTPUT_DIR
python3 <<'PY'
import json
import os
import pathlib
import re
import shutil
import sys

attachments = pathlib.Path(os.environ["ATTACHMENTS_DIR"])
output = pathlib.Path(os.environ["OUTPUT_DIR"])
expected = [
    "01_Chat_Hero",
    "02_Chat_RichRender",
    "03_Providers",
    "04_Model_Picker",
    "05_MCP_Servers",
    "06_Project_Detail",
    "07_Analytics",
    "08_Sidebar",
    "09_Library",
    "10_Home_NewChat",
    "11_Projects_List",
    "12_Chat_Tools",
    "13_Reasoning_Sheet",
    "14_Message_Info",
    "15_Settings_Themes",
    "16_Paywall",
]
expected_set = set(expected)

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
            display = next((s for s in strings if s in expected_set), None)
            filename = next((s for s in strings if s.lower().endswith(".png")), None)
            if display and filename and display not in renamed:
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

pattern = re.compile(r"(" + "|".join(re.escape(name) for name in expected) + r")")
for source in pngs:
    match = pattern.search(source.stem)
    if match and match.group(1) not in renamed:
        name = match.group(1)
        shutil.copy2(source, output / f"{name}.png")
        renamed.add(name)

missing = [name for name in expected if name not in renamed]
if missing:
    print("error: missing expected screenshots:", file=sys.stderr)
    for name in missing:
        print(f"  - {name}", file=sys.stderr)
    print(f"Raw attachments directory: {attachments}", file=sys.stderr)
    sys.exit(1)

print(f"Saved {len(renamed)} screenshots to {output}:")
for name in expected:
    print(f"  {output / (name + '.png')}")
PY
