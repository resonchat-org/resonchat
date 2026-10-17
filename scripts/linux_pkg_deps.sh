# Copyright (C) 2026 ResonChat contributors.
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Manual runtime Depends / Requires — only what packaging tools cannot infer.
# Sourced by build_deb_rpm.sh — do not execute directly.
#
# Linked .so dependencies (libgtk-3-0, libsecret-1-0, …) are left to:
#   Debian: dpkg-shlibdeps
#   RPM:    rpmbuild AutoReq (with private Flutter libs excluded from the scan)
#
# This file lists CLI binaries started via Process.run / Process.start — they
# never appear in ELF NEEDED and are easy to miss.
#
# Evidence (app + plugins, Linux desktop; deb/rpm declare PipeWire only):
#   wpctl     — lib/platform/voice_mic_check_io.dart (wireplumber)
#   pw-record — record_linux via linux/packaging/parecord-shim.sh
#   ffmpeg    — record_linux CapturePipeline (encode capture → file)
#   xdg-open  — open_filex (default linuxDesktopName = "xdg")
#
# AppImage may fall back to host PulseAudio (pactl / real parecord); that is
# not a deb/rpm Depends.
#
# See also: linux_runtime_deps.md

# --- Command-line tools (NOT linked; must be declared explicitly) ---
DEBIAN_CLI=(
  pipewire-bin # /usr/bin/pw-record (pulled by pipewire; explicit for clarity)
  wireplumber  # /usr/bin/wpctl
  ffmpeg       # /usr/bin/ffmpeg
  xdg-utils    # /usr/bin/xdg-open
)

# ffmpeg-free is in Fedora; rpmfusion's ffmpeg also satisfies the binary.
# Fedora: pw-* live in pipewire-utils; wpctl in wireplumber.
RPM_CLI=(
  pipewire-utils
  wireplumber
  '(ffmpeg-free or ffmpeg)'
  xdg-utils
)

# Soft deps: a Secret Service provider for flutter_secure_storage / libsecret
# (libsecret itself comes from shlibdeps / AutoReq).
DEBIAN_RECOMMENDS=(
  gnome-keyring
)

RPM_RECOMMENDS=(
  gnome-keyring
)

debian_cli_csv() {
  local IFS=', '
  echo "${DEBIAN_CLI[*]}"
}

debian_recommends_csv() {
  local IFS=', '
  echo "${DEBIAN_RECOMMENDS[*]}"
}

# Manual Requires only (CLI). Linked libs come from AutoReq.
rpm_manual_requires_lines() {
  local p
  for p in "${RPM_CLI[@]}"; do
    printf 'Requires: %s\n' "$p"
  done
  for p in "${RPM_RECOMMENDS[@]}"; do
    printf 'Recommends: %s\n' "$p"
  done
}
