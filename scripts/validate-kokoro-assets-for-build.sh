#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${SCRIPT_DIR}/kokoro-pins.sh"
source "${SCRIPT_DIR}/kokoro-fixture-pins.sh"

MODE="production"
ASSET_ROOT="${REPO_ROOT}/Resources/Kokoro"

usage() {
  cat <<'EOF'
Usage: scripts/validate-kokoro-assets-for-build.sh [--mode production|fixture] [--root PATH]

Validates a Kokoro resource root before it is staged into the app bundle.
Production validation preserves the existing ReadAloud production contract.
Fixture validation admits only KokoroCoreML's published fixture-executable-v1
profile and verifies every declared fixture digest.

Options:
  --mode MODE   production (default) or fixture
  --root PATH   resource root to validate
  -h, --help    show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      MODE="${2:-}"
      shift 2
      ;;
    --root)
      ASSET_ROOT="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "${MODE}" in
  production|fixture) ;;
  *)
    echo "error: validation mode must be 'production' or 'fixture'" >&2
    exit 2
    ;;
esac

MANIFEST="${ASSET_ROOT}/KokoroRuntimeManifest.json"
if [[ ! -f "${MANIFEST}" ]]; then
  if [[ "${MODE}" == "fixture" ]]; then
    echo "error: Kokoro fixture assets are missing. Run: bash scripts/download-kokoro-fixture.sh" >&2
  else
    echo "error: Kokoro production assets are missing. Run: bash scripts/download-kokoro-assets.sh" >&2
  fi
  exit 1
fi

python3 - "${ASSET_ROOT}" "${MANIFEST}" "${KOKORO_SDK_COMMIT}" "${KOKORO_FIXTURE_SDK_COMMIT}" "${KOKORO_FIXTURE_VERSION}" "${MODE}" <<'PY'
import hashlib
import json
import os
import sys
from pathlib import Path, PurePosixPath

asset_root = Path(sys.argv[1]).resolve()
manifest_path = Path(sys.argv[2])
expected_production_sdk_commit = sys.argv[3]
expected_fixture_sdk_commit = sys.argv[4]
expected_fixture_version = sys.argv[5]
mode = sys.argv[6]

if Path(sys.argv[1]).is_symlink():
    raise SystemExit("error: Kokoro bundle root must not be a symlink")

with manifest_path.open("r", encoding="utf-8") as handle:
    manifest = json.load(handle)

if manifest.get("schema_version") != 1:
    raise SystemExit("error: unsupported Kokoro runtime manifest schema")

def safe_path(relative_path: str) -> Path:
    if not isinstance(relative_path, str) or not relative_path:
        raise SystemExit("error: invalid empty Kokoro asset path")
    pure = PurePosixPath(relative_path)
    if pure.is_absolute() or "\\" in relative_path or any(part in ("", ".", "..") for part in pure.parts):
        raise SystemExit(f"error: unsafe Kokoro asset path: {relative_path}")
    target = asset_root.joinpath(*pure.parts)
    try:
        resolved = target.resolve()
    except FileNotFoundError:
        resolved = target.parent.resolve() / target.name
    if not resolved.is_relative_to(asset_root):
        raise SystemExit(f"error: Kokoro asset path escapes bundle root: {relative_path}")

    current = asset_root
    for part in pure.parts:
        current = current / part
        if current.is_symlink():
            raise SystemExit(f"error: Kokoro asset path contains symlink: {relative_path}")
    return target

def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while True:
            chunk = handle.read(1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()

def require_file(relative_path: str, expected_bytes: int, expected_sha=None) -> None:
    path = safe_path(relative_path)
    if not path.is_file():
        raise SystemExit(f"error: missing Kokoro asset: {relative_path}")
    actual_bytes = path.stat().st_size
    if actual_bytes != expected_bytes:
        raise SystemExit(
            f"error: Kokoro asset size mismatch: {relative_path} "
            f"(expected {expected_bytes}, got {actual_bytes})"
        )
    if expected_sha is not None and sha256_file(path) != expected_sha:
        raise SystemExit(f"error: Kokoro asset checksum mismatch: {relative_path}")

def package_files(package_root: Path) -> list[tuple[str, Path]]:
    files: list[tuple[str, Path]] = []
    for root, directories, filenames in os.walk(package_root):
        root_path = Path(root)
        for name in list(directories):
            child = root_path / name
            if child.is_symlink():
                raise SystemExit(f"error: Kokoro model package contains symlink: {child}")
        for name in filenames:
            child = root_path / name
            if child.is_symlink():
                raise SystemExit(f"error: Kokoro model package contains symlink: {child}")
            if not child.is_file():
                continue
            files.append((child.relative_to(package_root).as_posix(), child))
    return sorted(files)

def validate_package(package: dict, verify_hashes: bool) -> None:
    relative_path = package.get("path")
    package_root = safe_path(relative_path)
    if not package_root.is_dir():
        raise SystemExit(f"error: missing Kokoro model package: {relative_path}")

    declared_files = package.get("files") or []
    for entry in declared_files:
        require_file(
            f"{relative_path}/{entry['path']}",
            int(entry["bytes"]),
            entry.get("sha256") if verify_hashes else None,
        )

    if not verify_hashes:
        return

    files = package_files(package_root)
    if len(files) != int(package.get("file_count", -1)):
        raise SystemExit(f"error: Kokoro model package file-count mismatch: {relative_path}")

    total_bytes = 0
    tree = hashlib.sha256()
    for path_string, path in files:
        byte_count = path.stat().st_size
        file_sha = sha256_file(path)
        total_bytes += byte_count
        tree.update(path_string.encode())
        tree.update(b"\0")
        tree.update(str(byte_count).encode())
        tree.update(b"\0")
        tree.update(file_sha.encode())
        tree.update(b"\0")

    if total_bytes != int(package.get("bytes", -1)):
        raise SystemExit(f"error: Kokoro model package byte-count mismatch: {relative_path}")
    if tree.hexdigest() != package.get("tree_sha256"):
        raise SystemExit(f"error: Kokoro model package tree checksum mismatch: {relative_path}")

expected_voices = [
    "voices/af_heart.bin",
    "voices/af_bella.bin",
    "voices/am_michael.bin",
]

if mode == "production":
    if manifest.get("sdk_commit") != expected_production_sdk_commit:
        raise SystemExit("error: production Kokoro SDK commit does not match the pinned runtime contract")
    expected_buckets = [3, 7, 10, 15, 30]
    if manifest.get("bundle_profile") != "custom":
        raise SystemExit("error: production Kokoro manifest must use the custom profile")
    if manifest.get("synthetic_fixture") is not None:
        raise SystemExit("error: production Kokoro manifest contains a synthetic fixture marker")
    if manifest.get("hf_provenance_verified") is not True:
        raise SystemExit("error: production Kokoro manifest provenance is not verified")
    if len(manifest.get("readaloud_source_manifest_sha256", "")) != 64:
        raise SystemExit("error: missing ReadAloud production source manifest digest")
    if manifest.get("buckets") != expected_buckets:
        raise SystemExit("error: production Kokoro manifest has unexpected bucket set")
    if manifest.get("duration_token_sizes") != [128]:
        raise SystemExit("error: production Kokoro manifest has unexpected duration token set")

    expected_packages = ["coreml/kokoro_duration_t128.mlpackage"]
    for bucket in expected_buckets:
        expected_packages.extend(
            [
                f"coreml/kokoro_f0ntrain_t{bucket * 40}.mlpackage",
                f"coreml/kokoro_decoder_pre_{bucket}s.mlpackage",
                f"coreml/kokoro_decoder_har_post_{bucket}s.mlpackage",
            ]
        )

    package_paths = [entry.get("path") for entry in manifest.get("model_packages", [])]
    if package_paths != expected_packages:
        raise SystemExit("error: production Kokoro manifest has unexpected model package set")

    for package in manifest.get("model_packages", []):
        validate_package(package, verify_hashes=False)
        spec = safe_path(f"{package['path']}/Data/com.apple.CoreML/model.mlmodel")
        if spec.is_file() and b"kokoro.synthetic" in spec.read_bytes():
            raise SystemExit(f"error: synthetic Core ML metadata rejected from production asset: {package['path']}")

else:
    if manifest.get("sdk_commit") != expected_fixture_sdk_commit:
        raise SystemExit("error: fixture Kokoro SDK commit does not match the pinned fixture contract")
    fixture = manifest.get("synthetic_fixture")
    expected_packages = [
        "coreml/kokoro_duration_t128.mlpackage",
        "coreml/kokoro_f0ntrain_t600.mlpackage",
        "coreml/kokoro_decoder_pre_15s.mlpackage",
        "coreml/kokoro_decoder_har_post_15s.mlpackage",
    ]

    if manifest.get("bundle_profile") != "fixture-executable-v1":
        raise SystemExit("error: fixture Kokoro manifest has unexpected profile")
    if manifest.get("hf_provenance_verified") is not False:
        raise SystemExit("error: fixture Kokoro provenance must remain explicitly unverified")
    for key in ("hf_repo_id", "hf_revision", "hf_download_manifest_sha256"):
        if manifest.get(key) not in ("", None):
            raise SystemExit(f"error: fixture Kokoro manifest must not claim production provenance: {key}")
    if manifest.get("buckets") != [15]:
        raise SystemExit("error: fixture Kokoro manifest must expose only the 15-second bucket")
    if manifest.get("duration_token_sizes") != [128]:
        raise SystemExit("error: fixture Kokoro manifest has unexpected duration token set")
    if not isinstance(fixture, dict):
        raise SystemExit("error: fixture Kokoro manifest is missing synthetic_fixture")
    if fixture.get("kind") != "synthetic-coreml" or fixture.get("contract_version") != 1:
        raise SystemExit("error: fixture Kokoro manifest has unexpected synthetic contract")
    if fixture.get("artifact_version") != expected_fixture_version:
        raise SystemExit("error: fixture Kokoro artifact version does not match the pinned KokoroCoreML release")
    if fixture.get("generator_revision") != expected_fixture_sdk_commit:
        raise SystemExit("error: fixture Kokoro generator revision does not match the pinned release")

    package_paths = [entry.get("path") for entry in manifest.get("model_packages", [])]
    if package_paths != expected_packages:
        raise SystemExit("error: fixture Kokoro manifest has unexpected model package set")

    for required in (
        "KokoroFixtureContract.json",
        "FixtureProvenance.json",
        "FixtureValidation.json",
        "ProductionContractInspection.json",
    ):
        path = safe_path(required)
        if not path.is_file():
            raise SystemExit(f"error: missing Kokoro fixture contract/provenance report: {required}")

    validation_path = safe_path("FixtureValidation.json")
    with validation_path.open("r", encoding="utf-8") as handle:
        validation = json.load(handle)
    if validation.get("artifact_version") != expected_fixture_version:
        raise SystemExit("error: fixture validation report version does not match the pinned release")
    if validation.get("validated_commit") != expected_fixture_sdk_commit:
        raise SystemExit("error: fixture validation report commit does not match the pinned release")
    if validation.get("status") != "passed":
        raise SystemExit("error: fixture validation report does not record a passing release")

    for package in manifest.get("model_packages", []):
        validate_package(package, verify_hashes=True)

voice_paths = [entry.get("path") for entry in manifest.get("voices", [])]
if voice_paths != expected_voices:
    raise SystemExit("error: Kokoro runtime manifest has unexpected voice set")

verify_declared_hashes = mode == "fixture"
for entry in manifest.get("voices", []):
    require_file(
        entry["path"],
        int(entry["bytes"]),
        entry.get("sha256") if verify_declared_hashes else None,
    )

runtime_assets = manifest.get("runtime_assets", {})
for key in ("vocab", "hnsf_weights"):
    entry = runtime_assets.get(key)
    if not entry:
        raise SystemExit(f"error: missing runtime asset declaration: {key}")
    require_file(
        entry["path"],
        int(entry["bytes"]),
        entry.get("sha256") if verify_declared_hashes else None,
    )

print(f"Kokoro {mode} assets valid")
PY
