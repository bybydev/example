#!/bin/bash
set -euo pipefail

if [[ "${CI_XCODEBUILD_ACTION:-}" != "archive" ]]; then
  echo "No archive to verify for ${CI_XCODEBUILD_ACTION:-unknown}."
  exit 0
fi
# This hook also runs when xcodebuild fails. Preserve the original build failure.
if [[ "${CI_XCODEBUILD_EXIT_CODE:?CI_XCODEBUILD_EXIT_CODE is required}" != "0" ]]; then
  echo "Archive failed; skipping resource verification."
  exit 0
fi

cd "${CI_PRIMARY_REPOSITORY_PATH:?CI_PRIMARY_REPOSITORY_PATH is required}"
archive="${CI_ARCHIVE_PATH:?CI_ARCHIVE_PATH is required}"
shopt -s nullglob
apps=("$archive"/Products/Applications/*.app)
if [[ "${#apps[@]}" -ne 1 ]]; then
  echo "error: expected exactly one archived app, found ${#apps[@]}" >&2
  exit 1
fi
app="${apps[0]}"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")"
if [[ "$bundle_id" != "com.hoangbkit.readaloud" ]]; then
  echo "error: unexpected archived bundle identifier: $bundle_id" >&2
  exit 1
fi

# Check the actual embedded framework without modifying the signed archive.
# A valid field in the downloaded XCFramework alone did not prevent ITMS-90208.
app_min="$(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$app/Info.plist")"
framework_min="$(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' \
  "$app/Frameworks/onnxruntime.framework/Info.plist")"
if [[ "$framework_min" != "$app_min" ]]; then
  echo "error: archived ONNX Runtime MinimumOSVersion=$framework_min; expected app minimum $app_min" >&2
  exit 1
fi
echo "Verified archived ONNX Runtime MinimumOSVersion=$framework_min."

# Verify the actual archive with the same validator as the GitHub release flow.
python3 scripts/onnx-assets.py verify --root "$app/ONNX"
cmp scripts/onnx-assets.json "$app/ONNX/ONNXAssetManifest.json"
for notice in LICENSE-APACHE-2.0.txt LICENSE-MIT-PHONEMIZER.txt THIRD_PARTY_NOTICES.txt; do
  test -s "$app/ONNX/$notice"
done
unexpected="$(find "$app" \( -name '*.mlmodelc' -o -name '*.mlpackage' \) -print -quit)"
if [[ -n "$unexpected" ]]; then
  echo "error: unexpected Core ML model in ONNX-only archive: $unexpected" >&2
  exit 1
fi
echo "Verified offline ONNX resources, manifest, and notices in $app."
