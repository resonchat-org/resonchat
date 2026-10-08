#!/usr/bin/env bash
# Copyright (C) 2026 resonchat contributors.
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Build a Linux x86_64 AppImage from the Flutter release bundle.
#
# Usage (from repo root or app/):
#   ./tool/build_appimage.sh              # flutter build linux --release + pack
#   ./tool/build_appimage.sh --skip-build # pack an existing release bundle
#
# Requires: Flutter Linux desktop toolchain (clang, cmake, ninja, GTK 3, …).
# Downloads appimagetool into build/appimage-tools/ on first run.
#
# Output: app/build/resonchat-<version>-x86_64.AppImage

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$(cd "$HERE/.." && pwd)"
REPO="$(cd "$APP/.." && pwd)"
cd "$APP"

SKIP_BUILD=0
for arg in "$@"; do
  case "$arg" in
    --skip-build) SKIP_BUILD=1 ;;
    -h|--help)
      sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "unknown argument: $arg" >&2
      exit 2
      ;;
  esac
done

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64) ARCH=x86_64; FLUTTER_ARCH=x64 ;;
  aarch64|arm64) ARCH=aarch64; FLUTTER_ARCH=arm64 ;;
  *)
    echo "unsupported architecture: $ARCH" >&2
    exit 1
    ;;
esac

VERSION="$(sed -n 's/^version: *\([^+]*\).*/\1/p' pubspec.yaml | head -1)"
if [ -z "$VERSION" ]; then
  echo "could not read version from pubspec.yaml" >&2
  exit 1
fi

BUNDLE="build/linux/${FLUTTER_ARCH}/release/bundle"
OUT_DIR="build"
APPDIR="${OUT_DIR}/AppDir"
TOOL_DIR="${OUT_DIR}/appimage-tools"
APPIMAGETOOL="${TOOL_DIR}/appimagetool-${ARCH}.AppImage"
OUTPUT="${OUT_DIR}/resonchat-${VERSION}-${ARCH}.AppImage"
DESKTOP_SRC="linux/packaging/resonchat.desktop"
METAINFO_SRC="linux/packaging/org.resonchat.resonchat.metainfo.xml"
# Desktop/AppImage need files under usr/share/icons; source is assets/icons/.
ICON_SRC="assets/icons/app_icon.png"

if [ ! -f "$DESKTOP_SRC" ]; then
  echo "missing $DESKTOP_SRC" >&2
  exit 1
fi
if [ ! -f "$ICON_SRC" ]; then
  echo "missing launcher icon at $ICON_SRC" >&2
  exit 1
fi
if [ ! -f "$METAINFO_SRC" ]; then
  echo "missing $METAINFO_SRC" >&2
  exit 1
fi

if [ "$SKIP_BUILD" -eq 0 ]; then
  echo "==> flutter build linux --release (${FLUTTER_ARCH})"
  flutter config --enable-linux-desktop >/dev/null 2>&1 || true
  flutter build linux --release --target-platform "linux-${FLUTTER_ARCH}"
fi

if [ ! -x "${BUNDLE}/resonchat" ]; then
  echo "release bundle missing at ${BUNDLE}/resonchat (run without --skip-build)" >&2
  exit 1
fi

echo "==> assembling AppDir"
rm -rf "$APPDIR"
mkdir -p "$APPDIR"
cp -a "${BUNDLE}/." "$APPDIR/"
cp "$DESKTOP_SRC" "$APPDIR/resonchat.desktop"
cp "$ICON_SRC" "$APPDIR/resonchat.png"

# Icon theme entries for menus / appimagetool (generated from assets at pack time).
for size in 16 32 48 64 128 256 512; do
  dest="$APPDIR/usr/share/icons/hicolor/${size}x${size}/apps/resonchat.png"
  mkdir -p "$(dirname "$dest")"
  if command -v ffmpeg >/dev/null 2>&1; then
    ffmpeg -y -loglevel error -i "$ICON_SRC" -vf "scale=${size}:${size}" "$dest"
  else
    cp "$ICON_SRC" "$dest"
  fi
done
mkdir -p "$APPDIR/usr/share/applications"
cp "$DESKTOP_SRC" "$APPDIR/usr/share/applications/resonchat.desktop"
mkdir -p "$APPDIR/usr/share/metainfo"
cp "$METAINFO_SRC" "$APPDIR/usr/share/metainfo/org.resonchat.resonchat.metainfo.xml"

cat > "$APPDIR/AppRun" <<'EOF'
#!/bin/bash
set -euo pipefail
HERE="$(dirname "$(readlink -f "$0")")"
export LD_LIBRARY_PATH="${HERE}/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
cd "$HERE"
exec "$HERE/resonchat" "$@"
EOF
chmod +x "$APPDIR/AppRun"

# appimagetool expects Exec= to match a file inside AppDir; Flutter already
# ships ./resonchat next to AppRun.
if ! grep -q '^Exec=resonchat' "$APPDIR/resonchat.desktop"; then
  echo "desktop Exec= must be resonchat" >&2
  exit 1
fi

if [ ! -x "$APPIMAGETOOL" ]; then
  echo "==> downloading appimagetool (${ARCH})"
  mkdir -p "$TOOL_DIR"
  url="https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-${ARCH}.AppImage"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL -o "$APPIMAGETOOL" "$url"
  else
    wget -q -O "$APPIMAGETOOL" "$url"
  fi
  chmod +x "$APPIMAGETOOL"
fi

echo "==> packing ${OUTPUT}"
rm -f "$OUTPUT"
# CI / containers often lack FUSE; extract-and-run avoids mounting the tool.
APPIMAGE_EXTRACT_AND_RUN=1 ARCH="$ARCH" VERSION="$VERSION" \
  "$APPIMAGETOOL" "$APPDIR" "$OUTPUT"
chmod +x "$OUTPUT"

echo "    → ${APP}/${OUTPUT#"$APP"/}"
echo "    run: chmod +x ${OUTPUT} && ./${OUTPUT}"
# Hint for docs / CI when invoked from the mono-repo root.
if [ -d "$REPO/.git" ]; then
  echo "    path from repo root: app/${OUTPUT}"
fi
