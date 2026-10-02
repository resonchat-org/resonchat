#!/usr/bin/env bash
# M2 acceptance: does a real Conversations install display a message we
# encrypted?
#
# Why a script and not just a test: the proof lives in the *other* app. This
# sends one uniquely marked, standard-OMEMO message from our client and then
# reads Conversations' own view hierarchy looking for the marker. A passing
# run therefore means Conversations parsed our bundle, built a session with
# us and decrypted our ciphertext — nothing else can produce that.
#
# The direction is deliberate. Of the two accounts, conversations.im refuses
# stanzas that are not inside a mutual subscription ("auth/forbidden: Access
# denied by service policy"), so a message from conversations.im never
# reaches Conversations on jabber.fr. The reverse direction works, and
# Conversations still has to decrypt it.
#
# Usage:
#   tool/m2_verify_conversations.sh <ourJid> <ourPass> <peerJid>

set -euo pipefail

JID="${1:?usage: m2_verify_conversations.sh <ourJid> <ourPass> <peerJid>}"
PASS="${2:?missing password}"
PEER="${3:?missing peer jid}"
PKG="${CONVERSATIONS_PKG:-eu.siacs.conversations}"

export ANDROID_HOME="${ANDROID_HOME:-$HOME/Android/Sdk}"
export PATH="$HOME/development/flutter/bin:$ANDROID_HOME/platform-tools:$PATH"

cd "$(dirname "$0")/.."

echo "==> sending one encrypted message from $JID to $PEER"
OUT=$(mktemp)
trap 'rm -f "$OUT"' EXIT

flutter test integration_test/interop_send_test.dart -d emulator-5554 \
  --dart-define="RESONCHAT_SEND_JID=$JID" \
  --dart-define="RESONCHAT_SEND_PASS=$PASS" \
  --dart-define="RESONCHAT_SEND_PEER=$PEER" 2>&1 | tee "$OUT"

MARKER=$(grep -oE 'MARKER:interop-[0-9]+-[0-9]+' "$OUT" | tail -1 | cut -d: -f2)
if [ -z "$MARKER" ]; then
  echo "FAIL  the send produced no marker"
  exit 1
fi
echo "==> marker: $MARKER"

# Read Conversations' own view hierarchy. It must be running and on the
# chat list, which is where a received message becomes visible.
ACT=$(adb shell cmd package resolve-activity --brief "$PKG" | tail -1 | tr -d '\r')
adb shell am start -n "$ACT" >/dev/null 2>&1
sleep 6

UI=/tmp/opencode/m2_verify_ui.xml
adb shell uiautomator dump /sdcard/m2.xml >/dev/null 2>&1
adb shell cat /sdcard/m2.xml > "$UI"

if grep -qF "$MARKER" "$UI"; then
  echo "PASS  Conversations displayed our encrypted message: $MARKER"
  exit 0
fi

# The message may sit one level down; walk the chat list entries.
echo "-- marker not on the current screen, listing what is visible:"
python3 - "$UI" <<'PY'
import re, sys
s = open(sys.argv[1], encoding='utf-8', errors='replace').read()
for m in re.finditer(r'text="([^"]+)"', s):
    t = m.group(1).strip()
    if t:
        print('   ', t[:80])
PY
echo "FAIL  Conversations did not display our encrypted message"
exit 1