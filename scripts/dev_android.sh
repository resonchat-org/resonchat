#!/usr/bin/env bash
# Copyright (C) 2026 ResonChat contributors.
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Development build for the real-device test loop.
#
# Differs from build_android.sh in the one way that matters: the APK reports
# `0.0.4-dev` with a version code that only ever goes up, so it installs over
# the previous dev build without an uninstall — the account and its message
# history survive a rebuild, which is the reason to test on the device at all.
#
# The version *name* is deliberately frozen: every dev build reads `0.0.4-dev`.
# The number that moves is the version code. Android refuses to install a lower
# one (INSTALL_FAILED_VERSION_DOWNGRADE), so "always the same version" cannot
# mean a frozen code as well.
#
# Usage (from repo root):
#   ./scripts/dev_android.sh                 # build only
#   ./scripts/dev_android.sh --install       # build, then adb install -r
#   ./scripts/dev_android.sh --publish       # build, then upload to the `dev` prerelease
#   ./scripts/dev_android.sh --install --publish
#
# `--publish` replaces the APK asset on the existing `dev` prerelease. It never
# moves a tag and never deletes a release, and it does not go near the released
# 0.0.X tags.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

DO_INSTALL=0
DO_PUBLISH=0
PASSTHROUGH=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install) DO_INSTALL=1 ;;
    --publish) DO_PUBLISH=1 ;;
    -h|--help)
      sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) PASSTHROUGH+=("$1") ;;
  esac
  shift
done

# One version code per minute, chosen here rather than inside Gradle so the
# build and the release notes cannot disagree about which build this is.
# Gradle falls back to its own clock when this is unset — a plain
# `flutter build apk` with RESONCHAT_DEV_BUILD set by hand.
DEV_VERSION_CODE=$(( $(date +%s) / 60000 ))
export RESONCHAT_DEV_BUILD=1
export RESONCHAT_DEV_VERSION_CODE="$DEV_VERSION_CODE"

echo "==> dev build: 0.0.4-dev (versionCode $DEV_VERSION_CODE)"
"$HERE/build_android.sh" --release --abi arm "${PASSTHROUGH[@]}"

APK="$ROOT/app/build/app/outputs/flutter-apk/app-release.apk"
if [[ ! -f "$APK" ]]; then
  echo "expected $APK after the build" >&2
  exit 1
fi
SHA="$(cd "$ROOT" && git rev-parse --short HEAD)"
echo "==> $APK ($(du -h "$APK" | cut -f1)) @ $SHA"

if [[ "$DO_INSTALL" -eq 1 ]]; then
  ADB="${ADB:-$(command -v adb || true)}"
  if [[ -z "$ADB" ]]; then
    for candidate in \
      "${ANDROID_HOME:-}/platform-tools/adb" \
      "${ANDROID_SDK_ROOT:-}/platform-tools/adb" \
      "$HOME/Android/Sdk/platform-tools/adb"; do
      if [[ -x "$candidate" ]]; then
        ADB="$candidate"
        break
      fi
    done
  fi
  if [[ -z "$ADB" || ! -x "$ADB" ]]; then
    echo "adb not found; set ADB=/path/to/adb" >&2
    exit 1
  fi
  if ! "$ADB" install -r "$APK"; then
    cat >&2 <<'HINT'

Install failed. The usual cause is a signature mismatch with what is already
on the device: a build made elsewhere signs with a different debug key, and
Android will not update across keys. Uninstall once — this clears the app's
data — and install again:

  adb uninstall org.resonchat.resonchat
HINT
    exit 1
  fi
fi

if [[ "$DO_PUBLISH" -eq 1 ]]; then
  if ! command -v gh >/dev/null 2>&1; then
    echo "gh required for --publish" >&2
    exit 1
  fi
  ASSET="$ROOT/app/build/app/outputs/flutter-apk/resonchat-dev-arm64.apk"
  cp "$APK" "$ASSET"
  printf -v NOTES \
    'Dev build for device testing.\n\nversionName 0.0.4-dev\nversionCode %s\ncommit %s\n\nEnable Developer log mode in Settings, reproduce, then Export log to Downloads.' \
    "$DEV_VERSION_CODE" "$SHA"
  if gh release view dev >/dev/null 2>&1; then
    # One asset slot, replaced in place: the tag is not moved and the release
    # is not deleted.
    gh release upload dev "$ASSET" --clobber
    gh release edit dev --notes "$(printf '%b' "$NOTES")" >/dev/null
  else
    gh release create dev "$ASSET" --prerelease \
      --title "Dev builds (0.0.4-dev)" \
      --notes "$(printf '%b' "$NOTES")"
  fi
  echo "==> published https://github.com/resonchat-org/resonchat/releases/tag/dev"
fi
