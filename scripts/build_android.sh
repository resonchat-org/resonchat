#!/usr/bin/env bash
# Copyright (C) 2026 ResonChat contributors.
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# CI/packaging wrapper: launcher mipmaps + flutter build apk.
# Without this script: cd app && flutter build apk
#
# Usage (from repo root):
#   ./scripts/build_android.sh
#   ./scripts/build_android.sh --release
#   ./scripts/build_android.sh --release --abi arm    # arm64-v8a only
#   ./scripts/build_android.sh --release --abi x86    # x86_64 only
#   ./scripts/build_android.sh -- --dart-define=FOO=bar

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$(cd "$HERE/../app" && pwd)"
cd "$APP"

MODE=debug
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
    TARGET_PLATFORM=""
    ;;
  arm|arm64|android-arm64)
    ANDROID_ABIS="arm64-v8a"
    TARGET_PLATFORM="android-arm64"
    ;;
  x86|x64|x86_64|android-x64)
    ANDROID_ABIS="x86_64"
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
