#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec swift run --package-path "$ROOT/Packages/InkribeModelAssets" ModelAssetTool download --output "$ROOT/Models"
