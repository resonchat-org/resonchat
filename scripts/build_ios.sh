#!/usr/bin/env bash
# Copyright (C) 2026 ResonChat contributors.
# SPDX-License-Identifier: GPL-3.0-or-later
#
# CI/packaging wrapper: one 1024 icon from assets/icons/app_icon.png, then
# flutter build ios. Xcode generates the smaller iOS slots from that image.
#
# Usage (from repo root):
#   ./scripts/build_ios.sh
#   ./scripts/build_ios.sh --release
#   ./scripts/build_ios.sh --prepare-only
#   ./scripts/build_ios.sh -- --no-codesign

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$(cd "$HERE/../app" && pwd)"
cd "$APP"

MODE=debug
PREPARE_ONLY=0
FLUTTER_ARGS=()
PASSTHROUGH=0
for arg in "$@"; do
  if [[ "$PASSTHROUGH" -eq 1 ]]; then
    FLUTTER_ARGS+=("$arg")
    continue
  fi
  case "$arg" in
    --) PASSTHROUGH=1 ;;
    --release) MODE=release ;;
    --profile) MODE=profile ;;
    --debug) MODE=debug ;;
    --prepare-only) PREPARE_ONLY=1 ;;
    -h|--help)
      sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      FLUTTER_ARGS+=("$arg")
      ;;
  esac
done

SRC="assets/icons/app_icon.png"
if [[ ! -f "$SRC" ]]; then
  echo "missing $SRC" >&2
  exit 1
fi

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "ffmpeg required to generate the iOS icon from $SRC" >&2
  exit 1
fi

OUT="assets/icons/ios/AppIcon.xcassets/AppIcon.appiconset/Icon-App-1024x1024@1x.png"
echo "==> ios app icon from $SRC"
mkdir -p "$(dirname "$OUT")"
ffmpeg -y -loglevel error -i "$SRC" -vf "scale=1024:1024" "$OUT"

if [[ "$PREPARE_ONLY" -eq 1 ]]; then
  exit 0
fi

echo "==> flutter build ios --${MODE}"
exec flutter build ios "--${MODE}" "${FLUTTER_ARGS[@]}"
