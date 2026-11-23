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

# Resolve matching iOS runtime + simulator for the requested phone & major iOS version.
# Note: Xcode 27+ can ship multiple runtimes with the same version (e.g. standard
# `iOS-27-2` alongside device-specific `iOS-27-2-iPhone19-4` for iPhone Duo), so we
# match runtime + device together using available devices and `supportedDeviceTypes`.
RESOLUTION="$(
  python3 -c '
import json, subprocess, sys

target_major, device_name = sys.argv[1], sys.argv[2]

def simctl_json(*args):
    out = subprocess.check_output(["xcrun", "simctl", *args, "-j"], text=True)
    return json.loads(out)

runtimes_data = simctl_json("list", "runtimes")
devices_data = simctl_json("list", "devices", "available")
devicetypes_data = simctl_json("list", "devicetypes")

candidates = []
for runtime in runtimes_data.get("runtimes", []):
    if not runtime.get("isAvailable", False):
        continue
    identifier = runtime.get("identifier", "")
    platform = runtime.get("platform", "")
    version = str(runtime.get("version", ""))
    if platform != "iOS" and "iOS" not in identifier:
        continue
    if version == target_major or version.startswith(target_major + "."):
        parts = tuple(int(p) for p in version.split(".") if p.isdigit())
        # Prefer highest minor version, and standard runtimes (shorter identifier) over device-specific suffixes on ties.
        candidates.append((parts, -len(identifier), identifier, runtime))

if not candidates:
    print("NO_RUNTIME")
    sys.exit(0)

candidates.sort(key=lambda item: (item[0], item[1]), reverse=True)

# 1. Prefer an existing available simulator matching the exact device name in the best compatible runtime.
all_devices = devices_data.get("devices", {})
for _, _, runtime_id, _ in candidates:
    for device in all_devices.get(runtime_id, []):
        if device.get("isAvailable", False) and device.get("name") == device_name:
            udid = device["udid"]
            print(f"EXISTING|{runtime_id}|{udid}")
            sys.exit(0)

# 2. Otherwise look up the exact device type and pick a runtime that explicitly supports it.
device_type_id = next(
    (dt["identifier"] for dt in devicetypes_data.get("devicetypes", []) if dt.get("name") == device_name),
    ""
)
if not device_type_id:
    print("NO_DEVICETYPE|" + ",".join(item[2] for item in candidates))
    sys.exit(0)

compatible_runtimes = []
for _, _, runtime_id, runtime in candidates:
    supported = runtime.get("supportedDeviceTypes")
    if supported:
        supported_ids = {dt.get("identifier") for dt in supported}
        supported_names = {dt.get("name") for dt in supported}
        if device_type_id in supported_ids or device_name in supported_names:
            compatible_runtimes.append(runtime_id)
    else:
        compatible_runtimes.append(runtime_id)

if not compatible_runtimes:
    print("INCOMPATIBLE|" + ",".join(item[2] for item in candidates))
    sys.exit(0)

print("CREATE|" + device_type_id + "|" + ",".join(compatible_runtimes))
' "${IOS_VERSION}" "${PHONE}"
)"

IFS="|" read -r RES_KIND RES_A RES_B <<< "${RESOLUTION}"
CREATED_SIMULATOR=false
RUNTIME_ID=""
SIMULATOR_UDID=""

case "${RES_KIND}" in
  EXISTING)
    RUNTIME_ID="${RES_A}"
    SIMULATOR_UDID="${RES_B}"
    ;;
  CREATE)
    DEVICE_TYPE_ID="${RES_A}"
    IFS="," read -r -a COMPATIBLE_RUNTIMES <<< "${RES_B}"
    LAST_ERR=""
    for candidate_runtime in "${COMPATIBLE_RUNTIMES[@]}"; do
      if created_udid="$(xcrun simctl create "${PHONE}" "${DEVICE_TYPE_ID}" "${candidate_runtime}" 2>&1)"; then
        RUNTIME_ID="${candidate_runtime}"
        SIMULATOR_UDID="${created_udid}"
        CREATED_SIMULATOR=true
        break
      else
        LAST_ERR="${created_udid}"
      fi
    done
    if [[ -z "${SIMULATOR_UDID}" ]]; then
      echo "error: combination '${PHONE}' + iOS ${IOS_VERSION} is not supported: ${LAST_ERR}" >&2
      echo "Checked runtimes: ${RES_B}" >&2
      exit 1
    fi
    ;;
  NO_RUNTIME)
    echo "error: no available iOS ${IOS_VERSION} simulator runtime found on this machine." >&2
    echo "Available runtimes:" >&2
    xcrun simctl list runtimes >&2
    exit 1
    ;;
  NO_DEVICETYPE)
    echo "error: simulator device type '${PHONE}' is not supported by this Xcode installation." >&2
    echo "Available iPhone device types:" >&2
    xcrun simctl list devicetypes | grep -i "iPhone" >&2 || true
    exit 1
    ;;
  INCOMPATIBLE)
    echo "error: combination '${PHONE}' + iOS ${IOS_VERSION} is not supported by any available iOS ${IOS_VERSION} runtime (${RES_A})." >&2
    echo "Available iPhone devices:" >&2
    xcrun simctl list devices available | grep -E "^-- iOS ${IOS_VERSION}|iPhone" >&2 || true
    exit 1
    ;;
  *)
    echo "error: unexpected simulator resolution output: ${RESOLUTION}" >&2
    exit 1
    ;;
esac

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
  -parallel-testing-enabled NO
  -test-timeouts-enabled YES
  -default-test-execution-time-allowance 180
  -only-testing:BYOKchatUITests/BYOKchatScreenshotTests
)

if [[ -n "${SOURCE_PACKAGES_PATH}" ]]; then
  XCODEBUILD_ARGS+=(-clonedSourcePackagesDirPath "${SOURCE_PACKAGES_PATH}")
fi

# Ad-hoc sign simulator builds (do NOT set CODE_SIGNING_ALLOWED=NO) so the app
# retains its simulator application-identifier entitlement and Keychain calls
# do not fail with errSecMissingEntitlement (-34018).
xcodebuild "${XCODEBUILD_ARGS[@]}" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  DEVELOPMENT_TEAM="" \
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
