#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
STAGED_ROOT="${REPO_ROOT}/.build-resources/Kokoro"

MODE="${READALOUD_KOKORO_RESOURCE_MODE:-production}"

case "${MODE}" in
  production)
    SOURCE_ROOT="${REPO_ROOT}/Resources/Kokoro"
    ;;
  fixture)
    SOURCE_ROOT="${REPO_ROOT}/testfixtures/kokoro"
    ;;
  *)
    echo "error: READALOUD_KOKORO_RESOURCE_MODE must be 'production' or 'fixture' (got '${MODE}')" >&2
    exit 2
    ;;
esac

if [[ "${MODE}" == "fixture" && ! -f "${SOURCE_ROOT}/KokoroRuntimeManifest.json" ]]; then
  echo "error: Kokoro executable fixture is missing." >&2
  echo "Run: bash scripts/download-kokoro-fixture.sh" >&2
  exit 1
fi

bash "${SCRIPT_DIR}/validate-kokoro-assets-for-build.sh"   --mode "${MODE}"   --root "${SOURCE_ROOT}"

TMP_ROOT="${STAGED_ROOT}.staging.$$"
rm -rf "${TMP_ROOT}"
mkdir -p "${TMP_ROOT}"
cp -R "${SOURCE_ROOT}/." "${TMP_ROOT}/"

touch "${TMP_ROOT}/.gitkeep"

python3 - "${TMP_ROOT}/ReadAloudResourceMode.json" "${MODE}" <<'PY'
import json
import sys

path, mode = sys.argv[1:3]
with open(path, "w", encoding="utf-8") as handle:
    json.dump({"mode": mode}, handle, sort_keys=True)
    handle.write("\n")
PY

rm -rf "${STAGED_ROOT}"
mkdir -p "$(dirname "${STAGED_ROOT}")"
mv "${TMP_ROOT}" "${STAGED_ROOT}"

echo "Staged Kokoro resources: ${MODE}"
