#!/usr/bin/env bash
# Copyright (C) 2026 ResonChat contributors.
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Build Debian (.deb) and Fedora/RHEL (.rpm) packages from the Flutter Linux
# release bundle.
#
# Usage (from repo root):
#   ./scripts/build_deb_rpm.sh              # flutter build linux --release + pack
#   ./scripts/build_deb_rpm.sh --skip-build # pack an existing release bundle
#   ./scripts/build_deb_rpm.sh --deb-only
#   ./scripts/build_deb_rpm.sh --rpm-only
#
# Linked .so Depends come from dpkg-shlibdeps / rpm AutoReq.
# Manual Depends (linux_pkg_deps.sh) are CLI-only: pipewire-bin, wireplumber,
# ffmpeg, xdg-utils — see linux_runtime_deps.md.
#
# Outputs (under app/build/):
#   ResonChat_<version>_<arch>.deb
#   resonchat-<version>-1.<arch>.rpm

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
APP="$(cd "$REPO/app" && pwd)"
# shellcheck source=linux_pkg_deps.sh
source "$HERE/linux_pkg_deps.sh"
cd "$APP"

SKIP_BUILD=0
DO_DEB=1
DO_RPM=1
for arg in "$@"; do
  case "$arg" in
    --skip-build) SKIP_BUILD=1 ;;
    --deb-only) DO_RPM=0 ;;
    --rpm-only) DO_DEB=0 ;;
    -h|--help)
      sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "unknown argument: $arg" >&2
      exit 2
      ;;
  esac
done

HOST_ARCH="$(uname -m)"
case "$HOST_ARCH" in
  x86_64|amd64)
    FLUTTER_ARCH=x64
    # Debian control still needs Architecture: amd64; filenames use x86_64
    # so Release assets match AppImage/RPM (avoid amd64 vs arm64 look-alikes).
    DEB_ARCH=amd64
    PKG_ARCH=x86_64
    ;;
  aarch64|arm64)
    FLUTTER_ARCH=arm64
    DEB_ARCH=arm64
    PKG_ARCH=aarch64
    ;;
  *)
    echo "unsupported architecture: $HOST_ARCH" >&2
    exit 1
    ;;
esac

VERSION="$(sed -n 's/^version: *\([^+]*\).*/\1/p' pubspec.yaml | head -1)"
if [ -z "$VERSION" ]; then
  echo "could not read version from pubspec.yaml" >&2
  exit 1
fi
VERSION="${VERSION#v}"

BUNDLE="build/linux/${FLUTTER_ARCH}/release/bundle"
OUT_DIR="build"
STAGE="${OUT_DIR}/native-pkg-root"
DESKTOP_SRC="linux/packaging/resonchat.desktop"
METAINFO_SRC="linux/packaging/org.resonchat.resonchat.metainfo.xml"
ICON_SRC="assets/icons/app_icon.png"
WRAPPER_SRC="linux/packaging/resonchat-wrapper.sh"
PARECORD_SHIM_SRC="linux/packaging/parecord-shim.sh"

for f in "$DESKTOP_SRC" "$METAINFO_SRC" "$ICON_SRC" "$WRAPPER_SRC"; do
  if [ ! -e "$f" ]; then
    echo "missing $f" >&2
    exit 1
  fi
done

if [ "$SKIP_BUILD" -eq 0 ]; then
  echo "==> flutter build linux --release (${FLUTTER_ARCH})"
  flutter config --enable-linux-desktop >/dev/null 2>&1 || true
  flutter build linux --release --target-platform "linux-${FLUTTER_ARCH}"
fi

if [ ! -x "${BUNDLE}/resonchat" ]; then
  echo "release bundle missing at ${BUNDLE}/resonchat (run without --skip-build)" >&2
  exit 1
fi

echo "==> staging install tree"
rm -rf "$STAGE"
mkdir -p \
  "$STAGE/usr/lib/resonchat" \
  "$STAGE/usr/bin" \
  "$STAGE/usr/share/applications" \
  "$STAGE/usr/share/metainfo" \
  "$STAGE/usr/share/doc/resonchat"

cp -a "${BUNDLE}/." "$STAGE/usr/lib/resonchat/"
install -m 0755 "$WRAPPER_SRC" "$STAGE/usr/bin/resonchat"
install -d "$STAGE/usr/lib/resonchat/helpers"
install -m 0755 "$PARECORD_SHIM_SRC" "$STAGE/usr/lib/resonchat/helpers/parecord"
install -m 0644 "$DESKTOP_SRC" "$STAGE/usr/share/applications/resonchat.desktop"
install -m 0644 "$METAINFO_SRC" \
  "$STAGE/usr/share/metainfo/org.resonchat.resonchat.metainfo.xml"

if ! grep -q '^Exec=resonchat' "$STAGE/usr/share/applications/resonchat.desktop"; then
  echo "desktop Exec= must be resonchat" >&2
  exit 1
fi

for size in 16 32 48 64 128 256 512; do
  dest="$STAGE/usr/share/icons/hicolor/${size}x${size}/apps/resonchat.png"
  mkdir -p "$(dirname "$dest")"
  if command -v ffmpeg >/dev/null 2>&1; then
    ffmpeg -y -loglevel error -i "$ICON_SRC" -vf "scale=${size}:${size}" "$dest"
  else
    cp "$ICON_SRC" "$dest"
  fi
done

{
  echo "ResonChat ${VERSION}"
  echo
  echo "XMPP client with dual-track OMEMO (standard + post-quantum)."
  echo "Homepage: https://github.com/resonchat-org/resonchat"
  echo
  echo "Runtime CLI dependencies (not linked — see scripts/linux_pkg_deps.sh):"
  echo "  pipewire-bin (pw-record), wireplumber (wpctl), ffmpeg, xdg-utils"
} > "$STAGE/usr/share/doc/resonchat/README"
if [ -f "$REPO/LICENSE" ]; then
  install -m 0644 "$REPO/LICENSE" "$STAGE/usr/share/doc/resonchat/copyright"
fi

build_deb() {
  local deb_root deb_name shlib_depends depends
  deb_root="${OUT_DIR}/deb-root"
  deb_name="resonchat_${VERSION}_${PKG_ARCH}.deb"
  echo "==> building ${deb_name}"
  rm -rf "$deb_root"
  mkdir -p "$deb_root/DEBIAN"
  cp -a "$STAGE/." "$deb_root/"

  chmod -R u+rw,go+r "$deb_root"
  chmod 0755 "$deb_root/usr/bin/resonchat" "$deb_root/usr/lib/resonchat/resonchat"

  # Linked .so → Depends via dpkg-shlibdeps (GTK, libsecret, …).
  # -l points at the private Flutter lib dir so bundled .so resolve locally
  # and do not become package Depends.
  shlib_depends=""
  if command -v dpkg-shlibdeps >/dev/null 2>&1; then
    shlib_depends="$(
      dpkg-shlibdeps \
        -e "$deb_root/usr/lib/resonchat/resonchat" \
        -l "$deb_root/usr/lib/resonchat/lib" \
        --ignore-missing-info \
        -O 2>/dev/null \
        | sed -n 's/^shlibs:Depends=//p' \
        || true
    )"
  else
    echo "warning: dpkg-shlibdeps missing; .deb will only list CLI Depends" >&2
  fi

  if [ -n "$shlib_depends" ]; then
    depends="${shlib_depends}, $(debian_cli_csv)"
  else
    depends="$(debian_cli_csv)"
  fi

  cat > "$deb_root/DEBIAN/control" <<EOF
Package: ResonChat
Version: ${VERSION}
Section: net
Priority: optional
Architecture: ${DEB_ARCH}
Maintainer: ResonChat contributors <noreply@resonchat.org>
Homepage: https://github.com/resonchat-org/resonchat
Depends: ${depends}
Recommends: $(debian_recommends_csv)
Description: XMPP client with dual-track OMEMO
 ResonChat is a Flutter XMPP messenger with standard OMEMO and an optional
 post-quantum track. This package installs the Linux desktop build.
 .
 Linked libraries come from dpkg-shlibdeps. Extra Depends are CLI tools
 (pipewire-bin, wireplumber, ffmpeg, xdg-utils) that ELF scanners cannot see.
EOF

  local size_kb
  size_kb="$(du -sk "$deb_root" | awk '{print $1}')"
  echo "Installed-Size: ${size_kb}" >> "$deb_root/DEBIAN/control"

  dpkg-deb --root-owner-group --build "$deb_root" "${OUT_DIR}/${deb_name}"
  echo "    → ${APP}/${OUT_DIR}/${deb_name}"
}

build_rpm() {
  if ! command -v rpmbuild >/dev/null 2>&1; then
    echo "rpmbuild not found; install rpm-build (Fedora) or rpm (Debian) to produce .rpm" >&2
    return 1
  fi

  local rpm_top spec rpm_name
  rpm_top="${OUT_DIR}/rpmbuild"
  rpm_name="resonchat-${VERSION}-1.${PKG_ARCH}.rpm"
  echo "==> building ${rpm_name}"
  rm -rf "$rpm_top"
  mkdir -p "$rpm_top"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}

  tar -C "$STAGE" -czf "$rpm_top/SOURCES/resonchat-${VERSION}.tar.gz" .

  spec="$rpm_top/SPECS/resonchat.spec"
  {
    cat <<EOF
Name:           ResonChat
Version:        ${VERSION}
Release:        1%{?dist}
Summary:        XMPP client with dual-track OMEMO
License:        AGPL-3.0-or-later
URL:            https://github.com/resonchat-org/resonchat
Source0:        resonchat-${VERSION}.tar.gz
BuildArch:      ${PKG_ARCH}
# AutoReq → linked system libs (gtk3, libsecret, …). Skip private Flutter
# libs under /usr/lib/resonchat/lib (bundled; would invent fake Requires).
AutoReq:        yes
AutoProv:       no
%global __requires_exclude_from ^/usr/lib/resonchat/lib/.*\$

EOF
    rpm_manual_requires_lines
    cat <<EOF

%description
ResonChat is a Flutter XMPP messenger with standard OMEMO and an optional
post-quantum track. This package installs the Linux desktop build.

Linked libraries come from rpm AutoReq. Extra Requires are CLI tools
(pipewire-utils, wireplumber, ffmpeg-free/ffmpeg, xdg-utils) that ELF scanners miss.

%prep
%setup -c -n resonchat-${VERSION}

%install
rm -rf %{buildroot}
mkdir -p %{buildroot}
cp -a . %{buildroot}/

%files
/usr/bin/resonchat
/usr/lib/resonchat
/usr/share/applications/resonchat.desktop
/usr/share/metainfo/org.resonchat.resonchat.metainfo.xml
/usr/share/icons/hicolor/*/apps/resonchat.png
/usr/share/doc/resonchat

%changelog
* $(date -u '+%a %b %d %Y') ResonChat contributors <noreply@resonchat.org> - ${VERSION}-1
- Packaged Flutter Linux release bundle.
EOF
  } > "$spec"

  rpmbuild \
    --define "_topdir $(cd "$rpm_top" && pwd)" \
    --define "_build_id_links none" \
    -bb "$spec"

  local built
  # rpmbuild names its output after the spec's `Name:` field (ResonChat →
  # `ResonChat-<version>-1.<arch>.rpm`), so matching the lowercased name we
  # ship with a case-sensitive find never hit anything and the package was
  # reported as "not produced" even though rpmbuild had just written it.
  built="$(find "$rpm_top/RPMS" -type f -iname 'resonchat-*.rpm' | head -1)"
  if [ -z "$built" ]; then
    echo "rpmbuild produced no package" >&2
    return 1
  fi
  cp "$built" "${OUT_DIR}/${rpm_name}"
  echo "    → ${APP}/${OUT_DIR}/${rpm_name}"
}

if [ "$DO_DEB" -eq 1 ]; then
  if ! command -v dpkg-deb >/dev/null 2>&1; then
    echo "dpkg-deb not found; install dpkg to produce .deb" >&2
    exit 1
  fi
  build_deb
fi

if [ "$DO_RPM" -eq 1 ]; then
  build_rpm || {
    echo "warning: RPM build skipped/failed" >&2
    if [ "$DO_DEB" -eq 0 ]; then
      exit 1
    fi
  }
fi

echo "done."
if [ -d "$REPO/.git" ]; then
  echo "artifacts under app/build/ (from repo root: app/build/)"
fi
