#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
rm -rf "$ROOT/Models"
mkdir -p "$ROOT/Models"
cp -R "$ROOT/testfixtures/Models/." "$ROOT/Models/"
printf 'Installed path fixtures into %s\n' "$ROOT/Models"
