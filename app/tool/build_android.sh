#!/usr/bin/env bash
# Copyright (C) 2026 resonchat contributors.
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Prepare Android packaging inputs, then flutter build apk:
#   - launcher mipmaps from assets/icons/
#   - liboqs static libs via build_liboqs.sh
#
# Usage (from app/):
#   ./tool/build_android.sh
#   ./tool/build_android.sh --release
#   ./tool/build_android.sh --release --abi arm    # arm64-v8a only
#   ./tool/build_android.sh --release --abi x86    # x86_64 only
#   ./tool/build_android.sh --skip-liboqs   # reuse existing build/liboqs
#   ./tool/build_android.sh -- --dart-define=FOO=bar

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$(cd "$HERE/.." && pwd)"
cd "$APP"

MODE=debug
SKIP_LIBOQS=0
# all | arm | x86  — CD splits arm vs x86 into two APKs.
ABI_SET=all
FLUTTER_ARGS=()
PASSTHROUGH=0
ARGS=("$@")
i=0
while [[ $i -lt ${#ARGS[@]} ]]; do
  arg="${ARGS[$i]}"
  if [[ "$PASSTHROUGH" -eq 1 ]]; then
    FLUTTER_ARGS+=("$arg")
    i=$((i + 1))
    continue
  fi
  case "$arg" in
    --) PASSTHROUGH=1 ;;
    --release) MODE=release ;;
    --profile) MODE=profile ;;
    --debug) MODE=debug ;;
    --skip-liboqs) SKIP_LIBOQS=1 ;;
    --abi=*)
      ABI_SET="${arg#--abi=}"
      ;;
    --abi)
      i=$((i + 1))
      if [[ $i -ge ${#ARGS[@]} ]]; then
        echo "error: --abi requires arm|x86|all" >&2
        exit 1
      fi
      ABI_SET="${ARGS[$i]}"
      ;;
    -h|--help)
      sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      FLUTTER_ARGS+=("$arg")
      ;;
  esac
  i=$((i + 1))
done

case "$ABI_SET" in
  all)
    ANDROID_ABIS="arm64-v8a,x86_64"
    LIBOQS_ABIS=(arm64-v8a x86_64)
    TARGET_PLATFORM=""
    ;;
  arm|arm64|android-arm64)
    ANDROID_ABIS="arm64-v8a"
    LIBOQS_ABIS=(arm64-v8a)
    TARGET_PLATFORM="android-arm64"
    ;;
  x86|x64|x86_64|android-x64)
    ANDROID_ABIS="x86_64"
    LIBOQS_ABIS=(x86_64)
    TARGET_PLATFORM="android-x64"
    ;;
  *)
    echo "error: unknown --abi=$ABI_SET (want arm|x86|all)" >&2
    exit 1
    ;;
esac

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
for abi in "${LIBOQS_ABIS[@]}"; do
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
  echo "==> liboqs Android static libs (${LIBOQS_ABIS[*]})"
  "$HERE/build_liboqs.sh" --android-only --abis="${LIBOQS_ABIS[*]}"
else
  echo "==> liboqs Android libs already present (${LIBOQS_ABIS[*]})"
fi

echo "==> flutter build apk --${MODE} (abis=$ANDROID_ABIS)"
export RESONCHAT_ANDROID_ABIS="$ANDROID_ABIS"
BUILD_CMD=(flutter build apk "--${MODE}")
if [[ -n "$TARGET_PLATFORM" ]]; then
  BUILD_CMD+=(--target-platform "$TARGET_PLATFORM")
fi
if [[ ${#FLUTTER_ARGS[@]} -gt 0 ]]; then
  BUILD_CMD+=("${FLUTTER_ARGS[@]}")
fi
exec "${BUILD_CMD[@]}"
