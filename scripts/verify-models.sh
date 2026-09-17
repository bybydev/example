#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec swift run --package-path "$ROOT/Packages/InkribeModelAssets" ModelAssetTool verify --output "$ROOT/Models"
