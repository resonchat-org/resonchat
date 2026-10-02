# Copyright (C) 2026 resonchat contributors.
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Builds libpqbridge.so, the native ML-KEM-768 bridge, linking the
# prebuilt liboqs static library produced by tool/build_liboqs.sh.
#
# liboqs.a is not checked in: run `tool/build_liboqs.sh` first. The build
# fails loudly rather than silently dropping the native backend, because a
# missing bridge would otherwise look like "pure Dart in use" and hide a
# packaging bug.

cmake_minimum_required(VERSION 3.22)
project(pqbridge C)

set(CMAKE_C_STANDARD 11)

# Prebuilt static libs, one per ABI: app/build/liboqs/${ANDROID_ABI}/liboqs.a
# CMake runs with CMAKE_CURRENT_SOURCE_DIR = app/android/app/src/main/cpp,
# so five levels up is the Flutter app root (app/).
get_filename_component(APP_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../../../.." ABSOLUTE)
set(LIBOQS_ROOT "${APP_DIR}/build/liboqs")
set(LIBOQS_A "${LIBOQS_ROOT}/${ANDROID_ABI}/liboqs.a")

if(NOT EXISTS "${LIBOQS_A}")
    message(FATAL_ERROR
            "liboqs.a for ${ANDROID_ABI} not found at ${LIBOQS_A}.\n"
            "Run tool/build_liboqs.sh before building the app.")
endif()

add_library(pqbridge SHARED pq_bridge.c)

target_include_directories(pqbridge PRIVATE "${LIBOQS_ROOT}/include")

target_link_libraries(pqbridge "${LIBOQS_A}" log m)

# Android 15 requires 16 KB page alignment for loaded libraries.
target_link_options(pqbridge PRIVATE
        "-Wl,-z,max-page-size=16384"
        "-Wl,-z,common-page-size=16384")

# Strip release builds; the algorithms are self-contained.
target_compile_options(pqbridge PRIVATE -O2 -fvisibility=hidden)