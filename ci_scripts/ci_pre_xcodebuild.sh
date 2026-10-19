#!/bin/bash
set -euo pipefail

if [[ "${CI_PRODUCT_PLATFORM:-}" != "iOS" ]]; then
  echo "Skipping ONNX Runtime iOS packaging patch for ${CI_PRODUCT_PLATFORM:-unknown}."
  exit 0
fi
if [[ "${CI_XCODEBUILD_ACTION:-}" == "test-without-building" ]]; then
  echo "Using previously built tests; skipping ONNX Runtime packaging patch."
  exit 0
fi

# Follow Spokio's workaround for ITMS-90208. Stamp the resolved binary artifact
# before Xcode embeds/signs it; never mutate frameworks in the signed archive.
# Keep this aligned with ReadAloud's iOS deployment target in project.yml.
# Xcode Cloud does not reliably expose IPHONEOS_DEPLOYMENT_TARGET here.
MIN_IOS="26.0"
ARTIFACTS_ROOT="${CI_DERIVED_DATA_PATH:?CI_DERIVED_DATA_PATH is required}/SourcePackages/artifacts"
stamped=0

# ReadAloud links onnxruntime only, not onnxruntime_extensions.
while IFS= read -r -d '' plist; do
  /usr/libexec/PlistBuddy -c "Delete :MinimumOSVersion" "$plist" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Add :MinimumOSVersion string $MIN_IOS" "$plist"
  stamped=$((stamped + 1))
  echo "Patched ONNX Runtime MinimumOSVersion=$MIN_IOS: $plist"
done < <(find "$ARTIFACTS_ROOT" -type f \
  -path '*/onnxruntime.xcframework/*/onnxruntime.framework/Info.plist' -print0)

if [[ "$stamped" -eq 0 ]]; then
  echo "error: ONNX Runtime framework Info.plist not found under $ARTIFACTS_ROOT" >&2
  exit 1
fi
