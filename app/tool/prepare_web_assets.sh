#!/usr/bin/env bash
# Copyright (C) 2026 resonchat contributors.
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Fetch Drift WASM assets into web/ (not committed). Required before
# `flutter build web` / `flutter run -d chrome` — no scripts/ dependency.
#
# Usage (from app/):
#   ./tool/prepare_web_assets.sh
#   ./tool/prepare_web_assets.sh --force

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$(cd "$HERE/.." && pwd)"
cd "$APP"

WEB="$APP/web"
LOCK="$APP/pubspec.lock"
FORCE=0

for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    -h|--help)
      sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "unknown argument: $arg" >&2
      exit 2
      ;;
  esac
done

if [[ ! -f "$LOCK" ]]; then
  echo "missing $LOCK — run flutter pub get first" >&2
  exit 1
fi

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

if [[ "$FORCE" -eq 0 && -f "$WASM_OUT" && -f "$WORKER_OUT" ]]; then
  echo "web Drift assets already present (drift $DRIFT_VERSION); use --force to refresh"
  exit 0
fi

pub_cache="${PUB_CACHE:-${HOME}/.pub-cache}"
drift_pkg="$pub_cache/hosted/pub.dev/drift-${DRIFT_VERSION}"

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
  echo "run: flutter pub get" >&2
  exit 1
fi

if ! copy_or_empty \
    "$drift_pkg/extension/devtools/build/sqlite3.wasm" "$WASM_OUT" \
  && ! copy_or_empty "$drift_pkg/web/sqlite3.wasm" "$WASM_OUT"
then
  url="https://github.com/simolus3/drift/releases/download/drift-${DRIFT_VERSION}/sqlite3.wasm"
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

magic="$(od -An -t x1 -N 4 "$WASM_OUT" | tr -d ' \n')"
if [[ "$magic" != "0061736d" ]]; then
  echo "sqlite3.wasm does not look like a WebAssembly module (magic=$magic)" >&2
  rm -f "$WASM_OUT"
  exit 1
fi

echo "web Drift assets ready for drift $DRIFT_VERSION"
