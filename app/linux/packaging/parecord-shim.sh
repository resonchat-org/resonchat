#!/bin/sh
# resonchat-parecord-shim
# Copyright (C) 2026 resonchat contributors.
# SPDX-License-Identifier: GPL-3.0-or-later
#
# record_linux always execs `parecord`. Prefer host `pw-record` (PipeWire);
# otherwise the next real `parecord` on PATH (PulseAudio). Used from the
# package wrapper / AppImage AppRun via PATH — not a Dart package fork.

set -eu
HELPERS_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

rate=48000
channels=2
device=
for arg in "$@"; do
  case "$arg" in
    --rate=*) rate=${arg#--rate=} ;;
    --channels=*) channels=${arg#--channels=} ;;
    --device=*) device=${arg#--device=} ;;
  esac
done

if command -v pw-record >/dev/null 2>&1; then
  if [ -n "$device" ]; then
    exec pw-record --raw --format=s16 --rate="$rate" --channels="$channels" \
      --latency=100ms --target="$device" -
  fi
  exec pw-record --raw --format=s16 --rate="$rate" --channels="$channels" \
    --latency=100ms -
fi

# Fall back to the next parecord on PATH (skip this helpers directory).
old_ifs=$IFS
IFS=:
for d in $PATH; do
  [ -n "$d" ] || continue
  [ "$d" = "$HELPERS_DIR" ] && continue
  if [ -x "$d/parecord" ]; then
    IFS=$old_ifs
    exec "$d/parecord" "$@"
  fi
done
IFS=$old_ifs

echo "resonchat: neither pw-record nor parecord found" >&2
exit 127
