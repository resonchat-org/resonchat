#!/usr/bin/env bash
# Copyright (C) 2026 resonchat contributors.
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Prepare Android packaging inputs, then flutter build apk:
#   - launcher mipmaps from assets/icons/
#   - liboqs static libs (arm64-v8a + x86_64) via build_liboqs.sh
#
# Usage (from app/):
#   ./tool/build_android.sh
#   ./tool/build_android.sh --release
#   ./tool/build_android.sh --skip-liboqs   # reuse existing build/liboqs
#   ./tool/build_android.sh -- --dart-define=FOO=bar

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$(cd "$HERE/.." && pwd)"
cd "$APP"

MODE=debug
SKIP_LIBOQS=0
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
    --skip-liboqs) SKIP_LIBOQS=1 ;;
    -h|--help)
      sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
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

need_liboqs=0
for abi in arm64-v8a x86_64; do
  if [[ ! -f "build/liboqs/$abi/liboqs.a" ]]; then
    need_liboqs=1
    break
  fi
done
if [[ "$SKIP_LIBOQS" -eq 1 ]]; then
  if [[ "$need_liboqs" -eq 1 ]]; then
    echo "missing build/liboqs/<abi>/liboqs.a (cannot --skip-liboqs)" >&2
    exit 1
  fi
  echo "==> reusing existing liboqs Android libs"
elif [[ "$need_liboqs" -eq 1 ]]; then
  echo "==> liboqs Android static libs"
  "$HERE/build_liboqs.sh" --android-only
else
  echo "==> liboqs Android libs already present"
fi

echo "==> flutter build apk --${MODE}"
exec flutter build apk "--${MODE}" "${FLUTTER_ARGS[@]}"
