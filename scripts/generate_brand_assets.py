#!/usr/bin/env python3
# Copyright (C) 2026 ResonChat contributors.
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Regenerate every committed brand asset from the mark geometry below.
#
# The mark is a speech bubble plus one sine period, on a Lawnicons-style
# 192 x 192 grid (12 px strokes, round caps, no fill). See docs/13-branding.md.
#
# Icon colours come from the Material 3 dynamic-colour engine in m3_theme.py,
# using the M3 roles `primaryContainer` (background) and `onPrimaryContainer`
# (glyph). The committed assets use the brand blue as the fallback seed; the
# Linux installer re-renders them from the live system theme colour instead.
#
# Requires: rsvg-convert (librsvg) and Pillow (`python3-pil`).
# Usage (from the repo root):
#   ./scripts/generate_brand_assets.py
#
# The generated files are committed, so a normal build does not need this
# script or its dependencies.

from __future__ import annotations

import os
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from m3_theme import icon_colors  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = os.path.join(ROOT, "app")
ASSETS = os.path.join(APP, "assets", "icons")
RES = os.path.join(APP, "android", "app", "src", "main", "res")

BRAND = "#3D9BD4"  # fallback seed when the OS exposes no theme colour
WHITE = "#FFFFFF"

# M3 roles: primaryContainer / onPrimaryContainer.
LIGHT_BG, LIGHT_FG = icon_colors(BRAND, dark=False)
DARK_BG, DARK_FG = icon_colors(BRAND, dark=True)

BUBBLE = (
    "M50 32H142A28 28 0 0 1 170 60V100A28 28 0 0 1 142 128"
    "H96L56 162L68 128H50A28 28 0 0 1 22 100V60A28 28 0 0 1 50 32Z"
)
WAVE = "M64 80C72 56 88 56 96 80C104 104 120 104 128 80"


def glyph(color: str, scale: float = 1.0, tx: float = 0.0, ty: float = 0.0) -> str:
    return (
        f'<g transform="translate({tx} {ty}) scale({scale})" fill="none" '
        f'stroke="{color}" stroke-width="12" stroke-linecap="round" '
        'stroke-linejoin="round">'
        f'<path d="{BUBBLE}"/><path d="{WAVE}"/></g>'
    )


def glyph_svg(color: str) -> str:
    return (
        '<svg xmlns="http://www.w3.org/2000/svg" width="192" height="192" '
        'viewBox="0 0 192 192" role="img" aria-label="ResonChat">'
        + glyph(color)
        + "</svg>\n"
    )


def tile_svg(background: str, foreground: str) -> str:
    # Circular launcher tile. The mark occupies 50% of the icon width; the
    # 192 grid still keeps the Lawnicons stroke and proportions (the 160
    # figure includes the 12 px stroke, per C02).
    scale = (1024.0 * 0.50) / 160.0
    tx = 512.0 - 96.0 * scale
    ty = 512.0 - 97.0 * scale
    return (
        '<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" '
        'viewBox="0 0 1024 1024" role="img" aria-label="ResonChat">'
        f'<circle cx="512" cy="512" r="512" fill="{background}"/>'
        f'<g transform="translate({tx:.2f} {ty:.2f}) scale({scale:.6f})">'
        + glyph(foreground)
        + "</g></svg>\n"
    )


def maskable_svg(background: str, foreground: str) -> str:
    # Full bleed for the maskable variant. The mask may crop to 80% of the
    # canvas, so 50% of that visible circle is 40% of the full canvas.
    scale = (1024.0 * 0.40) / 160.0
    tx = 512.0 - 96.0 * scale
    ty = 512.0 - 97.0 * scale
    return (
        '<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" '
        'viewBox="0 0 1024 1024" role="img" aria-label="ResonChat">'
        f'<rect width="1024" height="1024" fill="{background}"/>'
        f'<g transform="translate({tx:.2f} {ty:.2f}) scale({scale:.6f})">'
        + glyph(foreground)
        + "</g></svg>\n"
    )


def write(path: str, content: str) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(content)


def render(svg_path: str, png_path: str, size: int) -> None:
    os.makedirs(os.path.dirname(png_path), exist_ok=True)
    subprocess.run(
        ["rsvg-convert", "-w", str(size), "-h", str(size), svg_path, "-o", png_path],
        check=True,
    )


def android_path(d: str) -> str:
    return d.replace(" ", ",")


def adaptive_xml(mono: bool, color: str) -> str:
    if mono:
        color = "#000000"
    return f"""<?xml version="1.0" encoding="utf-8"?>
<!-- Generated from the ResonChat brand mark. 108dp canvas, content kept
     inside the 66dp safe zone. The launcher tints the monochrome layer. -->
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="108dp"
    android:height="108dp"
    android:viewportWidth="108"
    android:viewportHeight="108">

    <group
        android:scaleX="0.225"
        android:scaleY="0.225"
        android:translateX="32.4"
        android:translateY="32.18">

        <path
            android:pathData="{android_path(BUBBLE)}"
            android:strokeColor="{color}"
            android:strokeWidth="12"
            android:strokeLineCap="round"
            android:strokeLineJoin="round"
            android:fillColor="@android:color/transparent" />

        <path
            android:pathData="{android_path(WAVE)}"
            android:strokeColor="{color}"
            android:strokeWidth="12"
            android:strokeLineCap="round"
            android:strokeLineJoin="round"
            android:fillColor="@android:color/transparent" />
    </group>
</vector>
"""


def color_resource(value: str) -> str:
    return (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        "<resources>\n"
        f'    <color name="ic_launcher_background">{value}</color>\n'
        "</resources>\n"
    )


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="resonchat-brand-") as tmp:
        tile = os.path.join(tmp, "tile.svg")
        maskable = os.path.join(tmp, "maskable.svg")
        write(tile, tile_svg(LIGHT_BG, LIGHT_FG))
        write(maskable, maskable_svg(LIGHT_BG, LIGHT_FG))

        write(os.path.join(ASSETS, "resonchat_logo.svg"), glyph_svg(BRAND))
        write(os.path.join(ASSETS, "resonchat_logo_white.svg"), glyph_svg(WHITE))
        # Lawnicons submission variant: pure black, no fill, 192 canvas.
        write(os.path.join(ASSETS, "resonchat_logo_black.svg"), glyph_svg("#000000"))

        for name, size, src in [
            ("app_icon.png", 512, tile),
            ("app_icon_192.png", 192, tile),
            ("favicon.png", 64, tile),
            ("app_icon_maskable_192.png", 192, maskable),
            ("app_icon_maskable_512.png", 512, maskable),
        ]:
            render(src, os.path.join(ASSETS, name), size)

        ico_src = os.path.join(tmp, "ico-256.png")
        render(tile, ico_src, 256)
        from PIL import Image

        Image.open(ico_src).convert("RGBA").save(
            os.path.join(ASSETS, "app_icon.ico"),
            sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)],
        )

        for folder, size in [
            ("mipmap-mdpi", 48),
            ("mipmap-hdpi", 72),
            ("mipmap-xhdpi", 96),
            ("mipmap-xxhdpi", 144),
            ("mipmap-xxxhdpi", 192),
        ]:
            render(tile, os.path.join(RES, folder, "ic_launcher.png"), size)

        anydpi = os.path.join(RES, "mipmap-anydpi-v26")
        adaptive = """<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/ic_launcher_background" />
    <foreground android:drawable="@drawable/ic_launcher_foreground" />
    <monochrome android:drawable="@drawable/ic_launcher_monochrome" />
</adaptive-icon>
"""
        write(os.path.join(anydpi, "ic_launcher.xml"), adaptive)
        write(os.path.join(anydpi, "ic_launcher_round.xml"), adaptive)

        # API < 31: static M3 roles derived from the fallback seed, plus a
        # night variant so dark mode keeps the inverted container/glyph pair.
        write(
            os.path.join(RES, "drawable", "ic_launcher_foreground.xml"),
            adaptive_xml(mono=False, color=LIGHT_FG),
        )
        write(
            os.path.join(RES, "drawable-night", "ic_launcher_foreground.xml"),
            adaptive_xml(mono=False, color=DARK_FG),
        )
        write(
            os.path.join(RES, "drawable", "ic_launcher_monochrome.xml"),
            adaptive_xml(mono=True, color="#000000"),
        )

        # Android 12+: map the same M3 roles to the system tonal resources.
        # primaryContainer = accent1_100 (light) / accent1_700 (dark);
        # onPrimaryContainer = accent1_900 (light) / accent1_100 (dark).
        write(
            os.path.join(RES, "drawable-v31", "ic_launcher_foreground.xml"),
            adaptive_xml(mono=False, color="@android:color/system_accent1_900"),
        )
        write(
            os.path.join(RES, "drawable-night-v31", "ic_launcher_foreground.xml"),
            adaptive_xml(mono=False, color="@android:color/system_accent1_100"),
        )

        write(os.path.join(RES, "values", "colors.xml"), color_resource(LIGHT_BG))
        write(
            os.path.join(RES, "values-night", "colors.xml"), color_resource(DARK_BG)
        )
        write(
            os.path.join(RES, "values-v31", "colors.xml"),
            color_resource("@android:color/system_accent1_100"),
        )
        write(
            os.path.join(RES, "values-night-v31", "colors.xml"),
            color_resource("@android:color/system_accent1_700"),
        )

    print(
        "brand assets regenerated "
        f"(light {LIGHT_BG}/{LIGHT_FG}, dark {DARK_BG}/{DARK_FG})"
    )


if __name__ == "__main__":
    main()
