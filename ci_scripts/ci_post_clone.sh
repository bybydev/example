#!/bin/bash
set -euo pipefail

cd "${CI_PRIMARY_REPOSITORY_PATH:?CI_PRIMARY_REPOSITORY_PATH is required}"

# Match Spokio: trust the repository's pinned macros/package plugins in CI.
defaults write com.apple.dt.Xcode IDESkipMacroFingerprintValidation -bool YES
defaults write com.apple.dt.Xcode IDESkipPackagePluginFingerprintValidation -bool YES

scheme="${CI_XCODE_SCHEME:-ReadAloud}"
if [[ "$scheme" != "ReadAloud" ]]; then
  echo "error: unsupported Xcode Cloud scheme: $scheme" >&2
  exit 1
fi
for file in \
  ReadAloud.xcodeproj/project.pbxproj \
  ReadAloud.xcodeproj/xcshareddata/xcschemes/ReadAloud.xcscheme \
  ReadAloud.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved; do
  if [[ ! -f "$file" ]]; then
    echo "error: missing committed Xcode Cloud input: $file" >&2
    exit 1
  fi
done

# Test execution restores built products, not the source model cache.
if [[ "${CI_XCODEBUILD_ACTION:-}" == "test-without-building" ]]; then
  echo "Using previously built test products; skipping resource preparation."
  exit 0
fi

# Use exactly the production asset path used by .github/workflows/release.yml:
# INT8 Kokoro, Misaki G2P model/lexicon, and all 28 English voices.
python3 scripts/onnx-assets.py download
bash scripts/stage-onnx-resources-for-build.sh

# Use the committed project and lockfile. Xcode Cloud resolves dependencies
# before this hook; do not run XcodeGen or resolve/update packages here.
