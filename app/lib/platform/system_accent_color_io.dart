// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Desktop accent colour.
//
// Linux compositors expose the user's accent through the freedesktop settings
// portal (`org.freedesktop.appearance` / `accent-color`). `dynamic_color`'s
// Linux plugin only reads GTK's `theme_selected_bg_color`, which on non-GNOME
// shells (niri, sway, KDE, …) is often the stock Adwaita blue rather than the
// user's accent. Prefer the portal, then the plugin (Windows / macOS / GTK).

import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Color;

import 'package:dynamic_color/dynamic_color.dart';

/// Returns the platform accent, or null when unavailable.
Future<Color?> readSystemAccentColor() async {
  if (Platform.environment.containsKey('FLUTTER_TEST')) return null;

  if (Platform.isLinux) {
    final portal = await _readPortalAccent();
    if (portal != null) return portal;
  }

  try {
    return await DynamicColorPlugin.getAccentColor();
  } catch (_) {
    return null;
  }
}

/// Reads `org.freedesktop.appearance` `accent-color` via `gdbus`.
///
/// Output looks like:
///   (<<(0.43529412150382996, 0.51372551918029785, 0.58823531866073608)>>,)
Future<Color?> _readPortalAccent() async {
  try {
    final result = await Process.run(
      'gdbus',
      const [
        'call',
        '--session',
        '--dest',
        'org.freedesktop.portal.Desktop',
        '--object-path',
        '/org/freedesktop/portal/desktop',
        '--method',
        'org.freedesktop.portal.Settings.Read',
        'org.freedesktop.appearance',
        'accent-color',
      ],
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    ).timeout(const Duration(milliseconds: 900));
    if (result.exitCode != 0) return null;
    final match = RegExp(
      r'\(\s*([0-9]*\.?[0-9]+)\s*,\s*([0-9]*\.?[0-9]+)\s*,\s*([0-9]*\.?[0-9]+)\s*\)',
    ).firstMatch(result.stdout as String);
    if (match == null) return null;
    final r = (double.parse(match.group(1)!) * 255).round().clamp(0, 255);
    final g = (double.parse(match.group(2)!) * 255).round().clamp(0, 255);
    final b = (double.parse(match.group(3)!) * 255).round().clamp(0, 255);
    return Color.fromARGB(255, r, g, b);
  } catch (_) {
    return null;
  }
}
