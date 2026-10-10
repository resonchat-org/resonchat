#!/usr/bin/env bash
# Copyright (C) 2026 resonchat contributors.
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Builds the native ML-KEM-768 pieces this project needs (ADR-006):
#
#   1. a host-side reference binary that emits deterministic KAT vectors
#      (skipped with --android-only)
#   2. Android static libraries (arm64-v8a and/or x86_64) for the FFI backend
#
# Usage:
#   ./tool/build_liboqs.sh                 # host ref + Android ABIs
#   ./tool/build_liboqs.sh --android-only  # APK packaging path
#   ./tool/build_liboqs.sh --android-only --abis="arm64-v8a"
#   ./tool/build_liboqs.sh [liboqs-source-dir]
#
# Requires: Android NDK, cmake, ninja, a C compiler (host build only).

set -euo pipefail

export ANDROID_HOME="${ANDROID_HOME:-$HOME/Android/Sdk}"
# Prefer ANDROID_NDK_HOME (CI / sdkmanager), then ANDROID_NDK, then newest NDK.
if [[ -z "${ANDROID_NDK:-}" ]]; then
  if [[ -n "${ANDROID_NDK_HOME:-}" ]]; then
    ANDROID_NDK="$ANDROID_NDK_HOME"
  else
    ANDROID_NDK="$(ls -d "$ANDROID_HOME"/ndk/* 2>/dev/null | sort -V | tail -1 || true)"
  fi
fi
export ANDROID_NDK

HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$(cd "$HERE/.." && pwd)"
ALGORITHMS="KEM_ml_kem_768;SIG_ml_dsa_65"
ANDROID_ONLY=0
LIBOQS="$APP/third_party/liboqs"
ANDROID_ABIS=(arm64-v8a x86_64)

for arg in "$@"; do
  case "$arg" in
    --android-only) ANDROID_ONLY=1 ;;
    --abis=*)
      # shellcheck disable=SC2206
      ANDROID_ABIS=(${arg#--abis=})
      ;;
    -h|--help)
      sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      LIBOQS="$arg"
      ;;
  esac
done

if [[ ! -d "$LIBOQS" ]]; then
  echo "==> cloning liboqs into $LIBOQS"
  git clone --depth 1 https://github.com/open-quantum-safe/liboqs "$LIBOQS"
fi

if [[ ! -d "$ANDROID_NDK" ]]; then
  echo "error: Android NDK not found (set ANDROID_NDK or ANDROID_NDK_HOME)" >&2
  exit 1
fi
if ! command -v cmake >/dev/null 2>&1 || ! command -v ninja >/dev/null 2>&1; then
  echo "error: cmake and ninja are required to build liboqs" >&2
  exit 1
fi
echo "==> NDK: $ANDROID_NDK"

if [[ "$ANDROID_ONLY" -eq 0 ]]; then
  echo "==> building host reference binary"
  cmake -GNinja -S "$LIBOQS" -B "$LIBOQS/build-host" \
    -DOQS_BUILD_ONLY_LIB=ON \
    -DOQS_USE_OPENSSL=OFF \
    -DOQS_MINIMAL_BUILD="$ALGORITHMS" \
    -DCMAKE_BUILD_TYPE=Release >/dev/null
  ninja -C "$LIBOQS/build-host" >/dev/null

  mkdir -p "$APP/build/liboqs-ref"
  cc -O2 -I "$LIBOQS/build-host/include" \
     "$HERE/native/mlkem_ref.c" -o "$APP/build/liboqs-ref/mlkem_ref" \
     "$LIBOQS/build-host/lib/liboqs.a" -lm -lpthread
  echo "    → $APP/build/liboqs-ref/mlkem_ref"
fi

for abi in "${ANDROID_ABIS[@]}"; do
  echo "==> building liboqs for $abi"
  cmake -GNinja -S "$LIBOQS" -B "$LIBOQS/build-$abi" \
    -DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI="$abi" \
    -DANDROID_PLATFORM=android-23 \
    -DOQS_BUILD_ONLY_LIB=ON \
    -DOQS_USE_OPENSSL=OFF \
    -DOQS_DIST_BUILD=ON \
    -DBUILD_SHARED_LIBS=OFF \
    -DOQS_MINIMAL_BUILD="$ALGORITHMS" \
    -DCMAKE_BUILD_TYPE=Release >/dev/null
  ninja -C "$LIBOQS/build-$abi" >/dev/null
  mkdir -p "$APP/build/liboqs/$abi"
  cp "$LIBOQS/build-$abi/lib/liboqs.a" "$APP/build/liboqs/$abi/"
  mkdir -p "$APP/build/liboqs/include"
  cp -r "$LIBOQS/build-$abi/include/oqs" "$APP/build/liboqs/include/"
  du -h "$APP/build/liboqs/$abi/liboqs.a"
done

echo "==> done"
if [[ "$ANDROID_ONLY" -eq 0 ]]; then
  echo "    reference binary: app/build/liboqs-ref/mlkem_ref"
fi
echo "    android libs:     app/build/liboqs/<abi>/liboqs.a"
