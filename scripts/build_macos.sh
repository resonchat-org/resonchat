#!/usr/bin/env bash
# Copyright (C) 2026 ResonChat contributors.
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# CI/packaging wrapper: macOS icon slots from assets/icons/app_icon.png, then
# flutter build macos, then a compressed DMG for this machine's CPU.
# Apple silicon produces resonchat-arm64.dmg; Intel produces
# resonchat-x86_64.dmg. The asset catalog still lists every size; this
# script scales them. Only the 1024 source is designed.
#
# Usage (from repo root):
#   ./scripts/build_macos.sh
#   ./scripts/build_macos.sh --release
#   ./scripts/build_macos.sh --prepare-only
#   ./scripts/build_macos.sh -- --dart-define=FOO=bar

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
      sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      FLUTTER_ARGS+=("$arg")
      ;;
  esac
done

SRC="assets/icons/app_icon.png"
SET="assets/icons/macos/AppIcon.xcassets/AppIcon.appiconset"
if [[ ! -f "$SRC" ]]; then
  echo "missing $SRC" >&2
  exit 1
fi

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "ffmpeg required to generate macOS icons from $SRC" >&2
  exit 1
fi

echo "==> macos app icons from $SRC"
mkdir -p "$SET"
scale() {
  local size="$1" name="$2"
  ffmpeg -y -loglevel error -i "$SRC" -vf "scale=${size}:${size}" "$SET/$name"
}
scale 16   app_icon_16.png
scale 32   app_icon_32.png
scale 64   app_icon_64.png
scale 128  app_icon_128.png
scale 256  app_icon_256.png
scale 512  app_icon_512.png
scale 1024 app_icon_1024.png

if [[ "$PREPARE_ONLY" -eq 1 ]]; then
  exit 0
fi

echo "==> flutter build macos --${MODE}"
# ${arr[@]+...} keeps an empty array from tripping `set -u` on macOS bash 3.2.
flutter build macos "--${MODE}" ${FLUTTER_ARGS[@]+"${FLUTTER_ARGS[@]}"}

case "$(uname -m)" in
  arm64) ARCH_NAME=arm64 ;;
  x86_64) ARCH_NAME=x86_64 ;;
  *)
    echo "unsupported macOS arch: $(uname -m)" >&2
    exit 1
    ;;
esac
case "$MODE" in
  release) CONFIG=Release ;;
  profile) CONFIG=Profile ;;
  debug) CONFIG=Debug ;;
esac

BUNDLE="build/macos/Build/Products/${CONFIG}/resonchat.app"
if [[ ! -d "$BUNDLE" ]]; then
  echo "missing $BUNDLE" >&2
  exit 1
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$BUNDLE" "$STAGE/resonchat.app"
ln -s /Applications "$STAGE/Applications"

OUT="build/resonchat-${ARCH_NAME}.dmg"
rm -f "$OUT"
echo "==> $OUT"
hdiutil create -volname ResonChat -srcfolder "$STAGE" -ov -format UDZO "$OUT"
