#!/usr/bin/env python3
# Copyright (C) 2026 ResonChat contributors.
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Material 3 dynamic colour helpers for the brand assets and the Linux
# launcher icon. The colour engine is a vendored copy of materialyoucolor
# (MIT, see scripts/_vendor/materialyoucolor/LICENSE), so builds do not need
# any extra Python packages.
#
# Everything here is derived from a seed colour at call time: there is no
# hard-coded palette. The icon uses the M3 roles
# `primaryContainer` (background) and `onPrimaryContainer` (glyph).

from __future__ import annotations

import os
import sys

_VENDOR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "_vendor")
if _VENDOR not in sys.path:
    sys.path.insert(0, _VENDOR)

from materialyoucolor.dynamiccolor.material_dynamic_colors import (  # noqa: E402
    MaterialDynamicColors,
)
from materialyoucolor.hct.hct import Hct  # noqa: E402
from materialyoucolor.scheme.scheme_tonal_spot import SchemeTonalSpot  # noqa: E402
from materialyoucolor.utils.color_utils import argb_from_rgb, hex_from_argb  # noqa: E402

# Android 12 shipped the 2021 M3 spec; using it keeps the desktop icon in the
# same family as the Android system colour resources.
SPEC = "2021"

# The roles used for the launcher icon (folder-like light container + dark
# glyph in light mode, inverted in dark mode).
ICON_BG_ROLE = "primaryContainer"
ICON_FG_ROLE = "onPrimaryContainer"

_COLORS = MaterialDynamicColors(SPEC)


def argb_from_hex(color: str) -> int:
    value = color.lstrip("#")
    return argb_from_rgb(
        int(value[0:2], 16), int(value[2:4], 16), int(value[4:6], 16)
    )


def scheme_for(seed: str, dark: bool):
    """Build a Material 3 tonal-spot scheme from a #RRGGBB seed."""
    return SchemeTonalSpot(
        Hct.from_int(argb_from_hex(seed)), dark, 0.0, spec_version=SPEC
    )


def role_color(seed: str, dark: bool, role: str) -> str:
    """Resolve one M3 role (for example `primary` or `surfaceContainerHigh`)."""
    value = getattr(_COLORS, role).get_argb(scheme_for(seed, dark))
    hex_value = hex_from_argb(value)
    # hex_from_argb returns #RRGGBBAA; icons need #RRGGBB.
    return hex_value[1:7]


def icon_colors(seed: str, dark: bool) -> tuple[str, str]:
    """Return (background, glyph) for the launcher icon."""
    scheme = scheme_for(seed, dark)
    bg = hex_from_argb(getattr(_COLORS, ICON_BG_ROLE).get_argb(scheme))[1:7]
    fg = hex_from_argb(getattr(_COLORS, ICON_FG_ROLE).get_argb(scheme))[1:7]
    return f"#{bg}", f"#{fg}"


def contrast(a: str, b: str) -> float:
    """WCAG contrast ratio between two #RRGGBB colours."""
    def luminance(color: str) -> float:
        c = [int(color[i : i + 2], 16) / 255 for i in (1, 3, 5)]
        c = [v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4 for v in c]
        return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]

    la, lb = sorted((luminance(a), luminance(b)), reverse=True)
    return (la + 0.05) / (lb + 0.05)


if __name__ == "__main__":
    # Small CLI for previews: m3_theme.py '#3584E4'
    seed = sys.argv[1] if len(sys.argv) > 1 else "#3584E4"
    print(f"seed {seed}")
    for dark in (False, True):
        bg, fg = icon_colors(seed, dark)
        print(
            ("dark " if dark else "light"),
            f"bg {bg} fg {fg} contrast {contrast(bg, fg):.2f}",
        )
