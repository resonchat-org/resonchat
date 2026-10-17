#!/usr/bin/env bash
# Copyright (C) 2026 ResonChat contributors.
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Fetch Drift WASM assets into web/ (not committed), then flutter build web
# with Dart→Wasm (--wasm). Pass --no-wasm for JS-only.
#
# Usage (from repo root):
#   ./scripts/build_web.sh
#   ./scripts/build_web.sh --prepare-only
#   ./scripts/build_web.sh --force
#   ./scripts/build_web.sh --no-wasm
#   ./scripts/build_web.sh -- --no-tree-shake-icons

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$(cd "$HERE/../app" && pwd)"
TOOL="$APP/tool"
cd "$APP"

FORCE=0
PREPARE_ONLY=0
USE_WASM=1
FLUTTER_ARGS=()
PASSTHROUGH=0
PREPARE_ARGS=()

for arg in "$@"; do
  if [[ "$PASSTHROUGH" -eq 1 ]]; then
    FLUTTER_ARGS+=("$arg")
    continue
  fi
  case "$arg" in
    --) PASSTHROUGH=1 ;;
    --force)
      FORCE=1
      PREPARE_ARGS+=(--force)
      ;;
    --prepare-only) PREPARE_ONLY=1 ;;
    --no-wasm) USE_WASM=0 ;;
    --wasm) USE_WASM=1 ;;
    -h|--help)
      sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      FLUTTER_ARGS+=("$arg")
      ;;
  esac
done

echo "==> Drift web assets"
"$TOOL/prepare_web_assets.sh" "${PREPARE_ARGS[@]+"${PREPARE_ARGS[@]}"}"

if [[ "$PREPARE_ONLY" -eq 1 ]]; then
  exit 0
fi

BUILD_ARGS=(build web)
if [[ "$USE_WASM" -eq 1 ]]; then
  BUILD_ARGS+=(--wasm)
  echo "==> flutter build web --wasm"
else
  echo "==> flutter build web (JS only)"
fi
exec flutter "${BUILD_ARGS[@]}" "${FLUTTER_ARGS[@]}"
