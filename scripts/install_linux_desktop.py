#!/usr/bin/env python3
# Copyright (C) 2026 ResonChat contributors.
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Install a per-user Linux desktop entry + launcher icon for ResonChat.
#
# The icon colours come from the Material 3 dynamic-colour engine in
# m3_theme.py: a seed colour is taken from the live desktop theme and the
# icon uses the M3 roles `primaryContainer` (background) and
# `onPrimaryContainer` (glyph). There is no hard-coded palette.
#
# Why a script: launcher icons are static image files. Android 13+ can tint
# the adaptive icon's monochrome layer, but Linux docks/panels cannot recolour
# an app icon on their own. This script reads the theme colour and writes
# matching hicolor icons into ~/.local/share. With --service it also installs
# a systemd user service that re-renders them whenever the theme changes.
#
# Usage (from the repo root):
#   ./scripts/install_linux_desktop.py                 # auto-find AppImage
#   ./scripts/install_linux_desktop.py --appimage PATH
#   ./scripts/install_linux_desktop.py --exec PATH
#   ./scripts/install_linux_desktop.py --accent '#3584E4'
#   ./scripts/install_linux_desktop.py --scheme light   # force light/dark
#   ./scripts/install_linux_desktop.py --no-accent      # fallback seed
#   ./scripts/install_linux_desktop.py --service        # + auto-follow theme
#   ./scripts/install_linux_desktop.py --watch          # foreground watcher
#   ./scripts/install_linux_desktop.py --uninstall
#
# Requires: rsvg-convert (librsvg) for the rendered icons.

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from m3_theme import icon_colors  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ASSETS = os.path.join(ROOT, "app", "assets", "icons")
LOGO_WHITE = os.path.join(ASSETS, "resonchat_logo_white.svg")
APP_ID = "org.resonchat.resonchat"
FALLBACK_ACCENT = "#3D9BD4"
SIZES = (16, 32, 48, 64, 128, 256, 512)
SERVICE_NAME = "resonchat-icon.service"

# Same geometry as scripts/generate_brand_assets.py: circular tile, mark at
# 50% of the icon width.
TILE = 1024
SCALE = (TILE * 0.50) / 160.0
GLYPH_CENTER = 96.0
GLYPH_CENTER_Y = 97.0


def data_home() -> str:
    return os.environ.get(
        "XDG_DATA_HOME", os.path.join(os.path.expanduser("~"), ".local", "share")
    )


def config_home() -> str:
    return os.environ.get(
        "XDG_CONFIG_HOME", os.path.join(os.path.expanduser("~"), ".config")
    )


# ---------------------------------------------------------------------------
# Live theme colour
# ---------------------------------------------------------------------------


def _gsettings(key: str) -> str | None:
    try:
        out = subprocess.run(
            ["gsettings", "get", "org.gnome.desktop.interface", key],
            capture_output=True,
            text=True,
            timeout=1.5,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if out.returncode != 0:
        return None
    return out.stdout.strip().strip("'")


def _portal_read(namespace: str, key: str) -> str | None:
    try:
        out = subprocess.run(
            [
                "gdbus",
                "call",
                "--session",
                "--dest",
                "org.freedesktop.portal.Desktop",
                "--object-path",
                "/org/freedesktop/portal/desktop",
                "--method",
                "org.freedesktop.portal.Settings.Read",
                namespace,
                key,
            ],
            capture_output=True,
            text=True,
            timeout=1.5,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if out.returncode != 0:
        return None
    return out.stdout


def portal_accent() -> str | None:
    stdout = _portal_read("org.freedesktop.appearance", "accent-color")
    if stdout is None:
        return None
    match = re.search(
        r"\(\s*([0-9]*\.?[0-9]+)\s*,\s*([0-9]*\.?[0-9]+)\s*,\s*([0-9]*\.?[0-9]+)\s*\)",
        stdout,
    )
    if not match:
        return None
    rgb = [round(float(match.group(i)) * 255) for i in (1, 2, 3)]
    return "#{:02X}{:02X}{:02X}".format(*(max(0, min(255, c)) for c in rgb))


def portal_scheme() -> str | None:
    stdout = _portal_read("org.freedesktop.appearance", "color-scheme")
    if stdout is None:
        return None
    match = re.search(r"uint32\s+([0-9]+)", stdout)
    if not match:
        return None
    value = int(match.group(1))
    if value == 2:
        return "light"
    if value == 1:
        return "dark"
    return None


def gtk_theme_name() -> str | None:
    """Name of the active GTK theme, without the :dark suffix."""
    theme = _gsettings("gtk-theme")
    if not theme:
        theme = os.environ.get("GTK_THEME", "")
    if not theme:
        return None
    return theme.split(":", 1)[0]


def _theme_dirs(name: str) -> list[str]:
    dirs: list[str] = []
    for base in (
        os.path.join(os.path.expanduser("~"), ".themes"),
        os.path.join(data_home(), "themes"),
    ):
        dirs.append(os.path.join(base, name))
    for base in os.environ.get(
        "XDG_DATA_DIRS", "/usr/local/share:/usr/share"
    ).split(":"):
        if base:
            dirs.append(os.path.join(base, "themes", name))
    return dirs


def _css_defines(css: str) -> dict[str, str]:
    return {
        name: value.strip()
        for name, value in re.findall(
            r"@define-color\s+([A-Za-z0-9_]+)\s+([^;]+);", css
        )
    }


def _resolve_color(
    expr: str, defines: dict[str, str], depth: int = 0
) -> str | None:
    expr = expr.strip()
    direct = re.search(r"#[0-9a-fA-F]{6}\b", expr)
    if direct:
        return direct.group(0).upper()
    alias = re.fullmatch(r"@([A-Za-z0-9_]+)", expr)
    if alias and depth < 16:
        target = defines.get(alias.group(1))
        if target:
            return _resolve_color(target, defines, depth + 1)
    return None


def _css_accent_define(css: str, scheme: str) -> str | None:
    """Pick the accent_bg_color that belongs to the requested colour scheme.

    GTK themes commonly declare one value in a light media block and another
    in a dark block, so taking the last definition would always return the
    dark seed.
    """
    defines = _css_defines(css)
    media = [
        (match.start(), match.group(1))
        for match in re.finditer(
            r"@media\s*\(\s*prefers-color-scheme:\s*(dark|light)\s*\)", css
        )
    ]
    chosen: str | None = None
    for match in re.finditer(r"@define-color\s+accent_bg_color\s+([^;]+);", css):
        section = None
        for position, name in media:
            if position < match.start():
                section = name
            else:
                break
        if section in (None, scheme):
            chosen = match.group(1)
    if chosen is None:
        raw = defines.get("accent_bg_color")
    else:
        raw = chosen
    return _resolve_color(raw, defines) if raw else None


def gtk_accent(scheme: str) -> str | None:
    """Read @accent_bg_color from the active GTK theme CSS.

    This is the colour the desktop actually paints (for example adw-gtk3's
    blue, or a user override), which can differ from the portal accent on
    non-GNOME sessions.
    """
    name = gtk_theme_name()
    candidates: list[str] = []
    # User overrides win, then the theme itself.
    for base in (config_home(),):
        for version in ("gtk-4.0", "gtk-3.0"):
            candidates.append(os.path.join(base, version, "gtk.css"))
    if name:
        for theme_dir in _theme_dirs(name):
            for version in ("gtk-4.0", "gtk-3.0"):
                candidates.append(os.path.join(theme_dir, version, "gtk.css"))
    for path in candidates:
        try:
            with open(path, encoding="utf-8", errors="ignore") as f:
                css = f.read()
        except OSError:
            continue
        color = _css_accent_define(css, scheme)
        if color:
            return color
    return None


def theme_accent(scheme: str) -> str:
    """Live theme colour: GTK theme -> portal -> brand fallback."""
    return (gtk_accent(scheme) or portal_accent() or FALLBACK_ACCENT).upper()


def theme_scheme() -> str:
    scheme = portal_scheme()
    if scheme:
        return scheme
    color_scheme = _gsettings("color-scheme")
    if color_scheme == "prefer-dark":
        return "dark"
    if color_scheme == "prefer-light":
        return "light"
    if os.environ.get("GTK_THEME", "").endswith(":dark"):
        return "dark"
    return "light"


# ---------------------------------------------------------------------------
# Icon rendering
# ---------------------------------------------------------------------------


def glyph_markup() -> str:
    with open(LOGO_WHITE, encoding="utf-8") as f:
        svg = f.read()
    match = re.search(r"<g\b.*?</g>", svg, re.S)
    if not match:
        raise SystemExit(f"could not read the glyph from {LOGO_WHITE}")
    return match.group(0)


def tile_svg(background: str, foreground: str) -> str:
    tx = TILE / 2 - GLYPH_CENTER * SCALE
    ty = TILE / 2 - GLYPH_CENTER_Y * SCALE
    group = glyph_markup()
    group = re.sub(
        r'transform="[^"]*"',
        f'transform="translate({tx:.2f} {ty:.2f}) scale({SCALE:.6f})"',
        group,
        count=1,
    )
    group = group.replace('stroke="#FFFFFF"', f'stroke="{foreground}"')
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{TILE}" height="{TILE}" '
        f'viewBox="0 0 {TILE} {TILE}" role="img" aria-label="ResonChat">'
        f'<circle cx="{TILE // 2}" cy="{TILE // 2}" r="{TILE // 2}" '
        f'fill="{background}"/>'
        f"{group}</svg>\n"
    )


def render_icons(accent: str, scheme: str, target: str) -> tuple[str, str]:
    if not shutil.which("rsvg-convert"):
        raise SystemExit("rsvg-convert is required (install librsvg)")
    background, foreground = icon_colors(accent, scheme == "dark")
    with tempfile.TemporaryDirectory(prefix="resonchat-icon-") as tmp:
        svg = os.path.join(tmp, "icon.svg")
        with open(svg, "w", encoding="utf-8") as f:
            f.write(tile_svg(background, foreground))
        for size in SIZES:
            dest = os.path.join(target, f"{size}x{size}", "apps", f"{APP_ID}.png")
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            subprocess.run(
                ["rsvg-convert", "-w", str(size), "-h", str(size), svg, "-o", dest],
                check=True,
            )
    return background, foreground


def refresh_caches(apps_dir: str) -> None:
    if shutil.which("update-desktop-database"):
        subprocess.run(
            ["update-desktop-database", apps_dir],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    icons = os.path.join(data_home(), "icons", "hicolor")
    if shutil.which("gtk-update-icon-cache"):
        subprocess.run(
            ["gtk-update-icon-cache", "-f", "-t", icons],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )


# ---------------------------------------------------------------------------
# Desktop entry + service
# ---------------------------------------------------------------------------


def default_exec() -> str:
    build = os.path.join(ROOT, "app", "build")
    candidates = []
    try:
        for name in os.listdir(build):
            if name.startswith("resonchat-") and name.endswith(".AppImage"):
                candidates.append(os.path.join(build, name))
    except OSError:
        pass
    if candidates:
        return max(candidates, key=os.path.getmtime)
    bundle = os.path.join(build, "linux", "x64", "release", "bundle", "resonchat")
    if os.path.exists(bundle):
        return bundle
    raise SystemExit("no AppImage/bundle found; pass --appimage or --exec")


def desktop_entry(exec_path: str) -> str:
    quoted = exec_path.replace("\\", "\\\\").replace('"', '\\"')
    return (
        "[Desktop Entry]\n"
        "Type=Application\n"
        "Name=ResonChat\n"
        "GenericName=XMPP Client\n"
        "Comment=XMPP client with dual-track OMEMO (standard + post-quantum)\n"
        f'Exec="{quoted}" %U\n'
        f"Icon={APP_ID}\n"
        "Terminal=false\n"
        "Categories=Network;InstantMessaging;Chat;\n"
        f"StartupWMClass={APP_ID}\n"
        "Keywords=XMPP;OMEMO;chat;messaging;\n"
        "SingleMainWindow=true\n"
    )


def service_path() -> str:
    return os.path.join(config_home(), "systemd", "user", SERVICE_NAME)


def service_unit() -> str:
    script = os.path.abspath(__file__)
    return (
        "[Unit]\n"
        "Description=ResonChat launcher icon theme sync\n"
        "PartOf=graphical-session.target\n"
        "After=graphical-session.target\n"
        "\n"
        "[Service]\n"
        "Type=simple\n"
        f'ExecStart="{sys.executable}" "{script}" --watch\n'
        "Restart=on-failure\n"
        "RestartSec=3\n"
        "\n"
        "[Install]\n"
        "WantedBy=default.target\n"
    )


def install_service() -> None:
    path = service_path()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(service_unit())
    subprocess.run(
        ["systemctl", "--user", "daemon-reload"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    subprocess.run(
        ["systemctl", "--user", "enable", "--now", SERVICE_NAME],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    print(f"icon watcher installed: {path}")


def remove_service() -> None:
    subprocess.run(
        ["systemctl", "--user", "disable", "--now", SERVICE_NAME],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    path = service_path()
    if os.path.exists(path):
        os.remove(path)
    subprocess.run(
        ["systemctl", "--user", "daemon-reload"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def watch() -> int:
    icons = os.path.join(data_home(), "icons", "hicolor")
    last: tuple[str, str] | None = None
    while True:
        scheme = theme_scheme()
        accent = theme_accent(scheme)
        if (accent, scheme) != last:
            try:
                background, foreground = render_icons(accent, scheme, icons)
                refresh_caches(os.path.join(data_home(), "applications"))
                print(
                    f"icon updated: seed {accent} / {scheme} -> "
                    f"{background} + {foreground}",
                    flush=True,
                )
            except Exception as exc:  # keep the service alive
                print(f"icon update failed: {exc}", file=sys.stderr, flush=True)
            last = (accent, scheme)
        time.sleep(3)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def uninstall() -> None:
    remove_service()
    apps_dir = os.path.join(data_home(), "applications")
    entry = os.path.join(apps_dir, f"{APP_ID}.desktop")
    if os.path.exists(entry):
        os.remove(entry)
    for size in SIZES:
        path = os.path.join(
            data_home(), "icons", "hicolor", f"{size}x{size}", "apps", f"{APP_ID}.png"
        )
        if os.path.exists(path):
            os.remove(path)
    refresh_caches(apps_dir)
    print("removed ResonChat desktop entry and icons")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--appimage", help="AppImage to launch")
    parser.add_argument("--exec", help="executable to launch instead of the AppImage")
    parser.add_argument("--accent", help="seed colour as #RRGGBB")
    parser.add_argument(
        "--scheme",
        choices=("auto", "light", "dark"),
        default="auto",
        help="tile scheme (default: follow the desktop)",
    )
    parser.add_argument(
        "--no-accent", action="store_true", help="use the fallback seed colour"
    )
    parser.add_argument(
        "--service", action="store_true", help="install the systemd user watcher"
    )
    parser.add_argument("--watch", action="store_true", help="re-render on change")
    parser.add_argument("--uninstall", action="store_true")
    args = parser.parse_args()

    if args.uninstall:
        uninstall()
        return 0

    if args.watch:
        return watch()

    if args.appimage and args.exec:
        parser.error("use either --appimage or --exec, not both")
    exec_path = args.exec or args.appimage or default_exec()
    exec_path = os.path.abspath(exec_path)
    if not os.path.exists(exec_path):
        raise SystemExit(f"launcher target does not exist: {exec_path}")

    scheme = args.scheme if args.scheme != "auto" else theme_scheme()

    if args.no_accent:
        accent = FALLBACK_ACCENT
    else:
        accent = (args.accent or theme_accent(scheme)).upper()
    if not re.fullmatch(r"#[0-9A-F]{6}", accent):
        raise SystemExit(f"invalid seed colour: {accent}")

    apps_dir = os.path.join(data_home(), "applications")
    os.makedirs(apps_dir, exist_ok=True)
    entry = os.path.join(apps_dir, f"{APP_ID}.desktop")
    with open(entry, "w", encoding="utf-8") as f:
        f.write(desktop_entry(exec_path))

    background, foreground = render_icons(
        accent, scheme, os.path.join(data_home(), "icons", "hicolor")
    )
    refresh_caches(apps_dir)

    if args.service:
        install_service()

    print(f"installed {entry}")
    print(f"launcher target: {exec_path}")
    print(f"seed: {accent} / {scheme}")
    print(f"M3 primaryContainer {background}, onPrimaryContainer {foreground}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
