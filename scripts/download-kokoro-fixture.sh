#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
FIXTURE_ROOT="${REPO_ROOT}/testfixtures/kokoro"
CACHE_ROOT="${REPO_ROOT}/.cache/kokoro-fixtures"

source "${SCRIPT_DIR}/kokoro-fixture-pins.sh"

MODE="download"

usage() {
  cat <<'EOF'
Usage: scripts/download-kokoro-fixture.sh [--verify-only]

Downloads the KokoroCoreML executable fixture archive pinned by ReadAloud,
verifies its published SHA-256, and extracts the kokoro/ resource root under
testfixtures/kokoro.

Options:
  --verify-only   Validate the already-extracted fixture without downloading.
  -h, --help      Show this help.
EOF
}

case "${1:-}" in
  "") ;;
  --verify-only) MODE="verify" ;;
  -h|--help) usage; exit 0 ;;
  *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
esac

if [[ "${MODE}" == "verify" ]]; then
  exec bash "${SCRIPT_DIR}/validate-kokoro-assets-for-build.sh"     --mode fixture     --root "${FIXTURE_ROOT}"
fi

for command in curl shasum python3 mktemp; do
  if ! command -v "${command}" >/dev/null 2>&1; then
    echo "error: required command not found: ${command}" >&2
    exit 1
  fi
done

mkdir -p "${CACHE_ROOT}"
ARCHIVE_PATH="${CACHE_ROOT}/${KOKORO_FIXTURE_ARCHIVE}"
ARCHIVE_URL="${KOKORO_FIXTURE_RELEASE_BASE}/${KOKORO_FIXTURE_ARCHIVE}"

if [[ ! -f "${ARCHIVE_PATH}" ]]; then
  curl     --fail     --location     --http1.1     --show-error     --progress-bar     --retry 8     --retry-all-errors     --retry-delay 2     --connect-timeout 30     --output "${ARCHIVE_PATH}"     "${ARCHIVE_URL}"
fi

ACTUAL_SHA="$(shasum -a 256 "${ARCHIVE_PATH}" | awk '{ print $1 }')"
if [[ "${ACTUAL_SHA}" != "${KOKORO_FIXTURE_ARCHIVE_SHA256}" ]]; then
  echo "error: Kokoro fixture archive checksum mismatch" >&2
  echo "expected: ${KOKORO_FIXTURE_ARCHIVE_SHA256}" >&2
  echo "actual:   ${ACTUAL_SHA}" >&2
  exit 1
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/readaloud-kokoro-fixture.XXXXXX")"
trap 'rm -rf "${TMP_DIR}"' EXIT

python3 - "${ARCHIVE_PATH}" "${TMP_DIR}" <<'PY'
import shutil
import sys
import tarfile
from pathlib import Path, PurePosixPath

archive = Path(sys.argv[1])
destination = Path(sys.argv[2]).resolve()

with tarfile.open(archive, "r:gz") as handle:
    for member in handle.getmembers():
        path = PurePosixPath(member.name)
        if path.is_absolute() or not path.parts or path.parts[0] != "kokoro":
            raise SystemExit(f"error: unexpected fixture archive path: {member.name}")
        if any(part in ("", ".", "..") for part in path.parts):
            raise SystemExit(f"error: unsafe fixture archive path: {member.name}")
        if member.issym() or member.islnk() or member.isdev():
            raise SystemExit(f"error: fixture archive contains unsupported link/device: {member.name}")

        output = destination.joinpath(*path.parts)
        if not output.resolve().is_relative_to(destination):
            raise SystemExit(f"error: fixture archive escapes extraction root: {member.name}")

        if member.isdir():
            output.mkdir(parents=True, exist_ok=True)
            continue
        if not member.isfile():
            raise SystemExit(f"error: unsupported fixture archive entry: {member.name}")

        output.parent.mkdir(parents=True, exist_ok=True)
        source = handle.extractfile(member)
        if source is None:
            raise SystemExit(f"error: cannot read fixture archive entry: {member.name}")
        with source, output.open("wb") as target:
            shutil.copyfileobj(source, target)
PY

bash "${SCRIPT_DIR}/validate-kokoro-assets-for-build.sh"   --mode fixture   --root "${TMP_DIR}/kokoro"

rm -rf "${FIXTURE_ROOT}"
mkdir -p "$(dirname "${FIXTURE_ROOT}")"
mv "${TMP_DIR}/kokoro" "${FIXTURE_ROOT}"
touch "${FIXTURE_ROOT}/.gitkeep"

echo
echo "Installed Kokoro executable fixture ${KOKORO_FIXTURE_VERSION}"
echo "Archive SHA-256: ${KOKORO_FIXTURE_ARCHIVE_SHA256}"
echo "Fixture root: ${FIXTURE_ROOT}"
