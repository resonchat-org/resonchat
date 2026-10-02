#!/usr/bin/env bash
# Builds the native ML-KEM-768 pieces this project needs (ADR-006):
#
#   1. a host-side reference binary that emits deterministic KAT vectors,
#      used by test/mlkem_interop_test.dart to prove the pure-Dart backend
#      and liboqs agree byte-for-byte
#   2. Android static libraries (arm64-v8a + x86_64) for the FFI backend
#
# Usage: tool/build_liboqs.sh [liboqs-source-dir]
#
# Requires: Android NDK, cmake, ninja, a C compiler.

set -euo pipefail

export ANDROID_HOME="${ANDROID_HOME:-$HOME/Android/Sdk}"
export ANDROID_NDK="${ANDROID_NDK:-$(ls -d "$ANDROID_HOME"/ndk/* 2>/dev/null | head -1)}"

HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$(cd "$HERE/.." && pwd)"
LIBOQS="${1:-$APP/third_party/liboqs}"
ALGORITHMS="KEM_ml_kem_768;SIG_ml_dsa_65"

if [ ! -d "$LIBOQS" ]; then
  echo "==> cloning liboqs into $LIBOQS"
  git clone --depth 1 https://github.com/open-quantum-safe/liboqs "$LIBOQS"
fi

if [ ! -d "$ANDROID_NDK" ]; then
  echo "error: Android NDK not found (set ANDROID_NDK)" >&2
  exit 1
fi
echo "==> NDK: $ANDROID_NDK"

# --- host reference binary -------------------------------------------
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

# --- Android static libraries ----------------------------------------
for abi in arm64-v8a x86_64; do
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
  # Headers travel with the library so the FFI build can compile later.
  mkdir -p "$APP/build/liboqs/include"
  cp -r "$LIBOQS/build-$abi/include/oqs" "$APP/build/liboqs/include/"
  du -h "$APP/build/liboqs/$abi/liboqs.a"
done

echo "==> done"
echo "    reference binary: app/build/liboqs-ref/mlkem_ref"
echo "    android libs:     app/build/liboqs/<abi>/liboqs.a"