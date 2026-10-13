#!/usr/bin/env bash
# Copyright (C) 2026 resonchat contributors.
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Fetch Drift WASM assets into web/ (not committed), then flutter build web
# with Dart→Wasm (--wasm). Pass --no-wasm for JS-only.
#
# Usage (from app/):
#   ./tool/build_web.sh
#   ./tool/build_web.sh --prepare-only          # assets only (e.g. before flutter run -d chrome)
#   ./tool/build_web.sh --force                 # re-fetch assets even if present
#   ./tool/build_web.sh --no-wasm               # JS compile only
#   ./tool/build_web.sh -- --no-tree-shake-icons

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$(cd "$HERE/.." && pwd)"
cd "$APP"

WEB="$APP/web"
LOCK="$APP/pubspec.lock"
FORCE=0
PREPARE_ONLY=0
USE_WASM=1
FLUTTER_ARGS=()
PASSTHROUGH=0

for arg in "$@"; do
  if [[ "$PASSTHROUGH" -eq 1 ]]; then
    FLUTTER_ARGS+=("$arg")
    continue
  fi
  case "$arg" in
    --) PASSTHROUGH=1 ;;
    --force) FORCE=1 ;;
    --prepare-only) PREPARE_ONLY=1 ;;
    --no-wasm) USE_WASM=0 ;;
    --wasm) USE_WASM=1 ;;
    -h|--help)
      sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      FLUTTER_ARGS+=("$arg")
      ;;
  esac
done

if [[ ! -f "$LOCK" ]]; then
  echo "missing $LOCK — run flutter pub get first" >&2
  exit 1
fi

# Parse: drift: … version: "2.35.2"
DRIFT_VERSION="$(
  awk '
    /^  drift:$/ { in_drift=1; next }
    in_drift && /^    version:/ {
      gsub(/"/, "", $2)
      print $2
      exit
    }
    in_drift && /^  [a-zA-Z]/ { exit }
  ' "$LOCK"
)"

if [[ -z "${DRIFT_VERSION:-}" ]]; then
  echo "could not read drift version from pubspec.lock" >&2
  exit 1
fi

mkdir -p "$WEB"
WASM_OUT="$WEB/sqlite3.wasm"
WORKER_OUT="$WEB/drift_worker.js"

prepare_drift_assets() {
  if [[ "$FORCE" -eq 0 && -f "$WASM_OUT" && -f "$WORKER_OUT" ]]; then
    echo "web Drift assets already present (drift $DRIFT_VERSION); use --force to refresh"
    return 0
  fi

  local pub_cache="${PUB_CACHE:-${HOME}/.pub-cache}"
  local drift_pkg="$pub_cache/hosted/pub.dev/drift-${DRIFT_VERSION}"

  copy_or_empty() {
    local src="$1" dest="$2"
    if [[ -f "$src" ]]; then
      cp -f "$src" "$dest"
      echo "copied $(basename "$dest") ← $src"
      return 0
    fi
    return 1
  }

  if ! copy_or_empty "$drift_pkg/drift_worker.js" "$WORKER_OUT"; then
    echo "drift_worker.js not in pub-cache at $drift_pkg" >&2
    echo "run: cd app && flutter pub get" >&2
    exit 1
  fi

  if ! copy_or_empty \
      "$drift_pkg/extension/devtools/build/sqlite3.wasm" "$WASM_OUT" \
    && ! copy_or_empty "$drift_pkg/web/sqlite3.wasm" "$WASM_OUT"
  then
    local url="https://github.com/simolus3/drift/releases/download/drift-${DRIFT_VERSION}/sqlite3.wasm"
    echo "downloading sqlite3.wasm from $url"
    if command -v curl >/dev/null 2>&1; then
      curl -fsSL -o "$WASM_OUT" "$url"
    elif command -v wget >/dev/null 2>&1; then
      wget -q -O "$WASM_OUT" "$url"
    else
      echo "need curl or wget to fetch sqlite3.wasm" >&2
      exit 1
    fi
    echo "wrote $WASM_OUT"
  fi

  local magic
  magic="$(od -An -t x1 -N 4 "$WASM_OUT" | tr -d ' \n')"
  if [[ "$magic" != "0061736d" ]]; then
    echo "sqlite3.wasm does not look like a WebAssembly module (magic=$magic)" >&2
    rm -f "$WASM_OUT"
    exit 1
  fi

  echo "web Drift assets ready for drift $DRIFT_VERSION"
}

echo "==> Drift web assets"
prepare_drift_assets

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
