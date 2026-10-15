#!/usr/bin/env bash
# Unattended login smoke test against a real XMPP server (M1/M2 check).
#
# Builds a debug APK with credentials baked in via --dart-define (the
# login page only honours them in debug mode), installs it on the running
# emulator, and reports what the app managed to do.
#
# Usage (from repo root):
#   ./scripts/smoke_test.sh <jid> <password> [host]
#
# Example:
#   ./scripts/smoke_test.sh you@example.org 'secret'   # host optional

set -euo pipefail

JID="${1:?usage: smoke_test.sh <jid> <password> [host]}"
PASS="${2:?missing password}"
HOST="${3:-}"

export ANDROID_HOME="${ANDROID_HOME:-$HOME/Android/Sdk}"
export PATH="$HOME/development/flutter/bin:$ANDROID_HOME/platform-tools:$PATH"

HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$(cd "$HERE/../app" && pwd)"

echo "==> building debug APK with smoke credentials"
"$HERE/build_android.sh" --debug -- \
  --dart-define="RESONCHAT_SMOKE=${JID}:${PASS}" 2>&1 | tail -2

APK="$APP/build/app/outputs/flutter-apk/app-debug.apk"

echo "==> waiting for a device"
adb wait-for-device
for _ in $(seq 1 60); do
  [ "$(adb -e shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ] && break
  sleep 2
done

echo "==> (re)installing"
adb -e install -r "$APK" 2>&1 | tail -1

# Keep the OMEMO device from the previous run so repeated logins do not
# pile up device ids on the account's PEP node.
echo "==> launching"
adb -e shell am force-stop org.resonchat.resonchat || true
adb -e logcat -c
adb -e shell am start -n org.resonchat.resonchat/.MainActivity >/dev/null

sleep "${SMOKE_WAIT:-25}"

echo "==> app state"
adb -e shell dumpsys activity activities 2>&1 \
  | grep -m1 'topResumedActivity' | tr -d '\r' || true

echo "==> app log"
adb -e logcat -d 2>&1 \
  | grep -iE 'resonchat|flutter|XmppService|Omemo|OMEMO|sasl|auth' \
  | tail -40 || true

echo "==> screenshot"
OUT="${SMOKE_SHOT:-/tmp/opencode/smoke.png}"
mkdir -p "$(dirname "$OUT")"
adb -e exec-out screencap -p > "$OUT"
echo "wrote $OUT"
