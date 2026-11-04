#!/bin/bash
set -euo pipefail

if [[ "${CI_XCODEBUILD_ACTION:-}" != "archive" ]]; then
  exit 0
fi
if [[ "${CI_XCODEBUILD_EXIT_CODE:?CI_XCODEBUILD_EXIT_CODE is required}" != "0" ]]; then
  echo "Archive failed; skipping model verification."
  exit 0
fi

cd "${CI_PRIMARY_REPOSITORY_PATH:?CI_PRIMARY_REPOSITORY_PATH is required}"
python3 scripts/xcode_cloud.py verify \
  --ios-models "${IOS_MODELS:-download}" \
  --archive "${CI_ARCHIVE_PATH:?CI_ARCHIVE_PATH is required}"
