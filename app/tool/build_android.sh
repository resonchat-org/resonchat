#!/usr/bin/env bash
# Copyright (C) 2026 resonchat contributors.
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sync launcher mipmaps from assets/icons/, then flutter build apk.
#
# Usage (from app/):
#   ./tool/build_android.sh
#   ./tool/build_android.sh --release
#   ./tool/build_android.sh -- --dart-define=FOO=bar   # extra flutter args after --

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$(cd "$HERE/.." && pwd)"
cd "$APP"

MODE=debug
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
    -h|--help)
      sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
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
  echo "ffmpeg required to generate Android mipmaps from $SRC" >&2
  exit 1
fi

echo "==> android mipmaps from $SRC"
scale() {
  local size="$1" out="$2"
  mkdir -p "$(dirname "$out")"
  ffmpeg -y -loglevel error -i "$SRC" -vf "scale=${size}:${size}" "$out"
}
scale 48  android/app/src/main/res/mipmap-mdpi/ic_launcher.png
scale 72  android/app/src/main/res/mipmap-hdpi/ic_launcher.png
scale 96  android/app/src/main/res/mipmap-xhdpi/ic_launcher.png
scale 144 android/app/src/main/res/mipmap-xxhdpi/ic_launcher.png
scale 192 android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png

echo "==> flutter build apk --${MODE}"
exec flutter build apk "--${MODE}" "${FLUTTER_ARGS[@]}"
