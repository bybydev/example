#!/bin/bash
set -euo pipefail

cd "${CI_PRIMARY_REPOSITORY_PATH:?CI_PRIMARY_REPOSITORY_PATH is required}"

if [[ "${CI_XCODE_SCHEME:-Inkribe}" != "Inkribe" ]]; then
  echo "error: this Xcode Cloud setup supports the Inkribe iOS scheme." >&2
  exit 1
fi
for file in \
  Inkribe.xcodeproj/project.pbxproj \
  Inkribe.xcodeproj/xcshareddata/xcschemes/Inkribe.xcscheme \
  Inkribe.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved \
  Inkribe/Resources/Info.plist; do
  if [[ ! -f "$file" ]]; then
    echo "error: missing committed Xcode Cloud input: $file" >&2
    exit 1
  fi
done

# Read this workflow variable directly. Unset or empty uses download.
ios_models="${IOS_MODELS:-download}"
case "$ios_models" in
  download|bundled) ;;
  *) echo "error: IOS_MODELS must be download or bundled." >&2; exit 1 ;;
esac

if [[ "${CI_XCODEBUILD_ACTION:-}" == "test-without-building" ]]; then
  echo "Using previously built test products; skipping model preparation."
  exit 0
fi

# Match Spokio/ReadAloud's trust settings for pinned repository dependencies.
defaults write com.apple.dt.Xcode IDESkipMacroFingerprintValidation -bool YES
defaults write com.apple.dt.Xcode IDESkipPackagePluginFingerprintValidation -bool YES

python3 scripts/release_models.py --platform iOS --ios-models "$ios_models" --download
python3 scripts/xcode_cloud.py configure --ios-models "$ios_models"

# Xcode Cloud already resolved packages from the committed project and lockfile.
# Model selection updates only the iOS resource and existing bundled-only flag.
