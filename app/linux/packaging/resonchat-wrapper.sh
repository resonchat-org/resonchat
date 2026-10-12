#!/bin/sh
# Copyright (C) 2026 resonchat contributors.
# SPDX-License-Identifier: GPL-3.0-or-later
#
# /usr/bin/resonchat — run the Flutter bundle under /usr/lib/resonchat.

set -eu
LIBDIR=/usr/lib/resonchat
HELPERS="${LIBDIR}/helpers"
export LD_LIBRARY_PATH="${LIBDIR}/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
# parecord-shim.sh → prefer pw-record; else host parecord (AppImage / Pulse hosts).
export PATH="${HELPERS}${PATH:+:$PATH}"
cd "$LIBDIR"
exec "$LIBDIR/resonchat" "$@"
