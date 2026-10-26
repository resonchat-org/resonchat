// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The design token set.
//
// ## PROVENANCE — read before trusting a number in here
//
// These values are **principled defaults, not extracted from any reference
// project.** An attempt was made to read them from the Forkgram source
// (Telegram-Android fork) and it could not be done from this environment:
// `git clone`, `git ls-remote`, the GitHub API, `raw.githubusercontent.com` and
// an independent browser egress all returned 404 for every repository not owned
// by this account, including `TelegramMessenger/Telegram-Android`, which
// unquestionably exists. That is egress filtering, not a wrong URL.
//
// So this file deliberately encodes *approach* rather than *measurements*:
// Material 3's colour roles, its type scale and its shape scale, tuned dark
// first. Every number is defensible from first principles and none of it is
// claimed to be anybody's. When the reference becomes reachable, replace the
// values and delete this section — do not leave both, and do not describe
// values that were never measured as if they had been.
//
// ## Why a separate file
//
// Sixteen files reference the old token names. Keeping the new set in its own
// file means the rename is one mechanical pass at integration time rather than
// sixteen concurrent edits — and sixteen concurrent edits to files that other
// work is patching is exactly how a merge becomes unrecoverable.
//
// ## Why these roles and not the previous ones
//
// The previous palette sampled Telegram Android's `ThemeColors.java` field by
// field and, deliberately, avoided Telegram's own blue "so the apps are not
// confusable". That reasoning does not survive a decision to look like a
// Telegram client: if the target *is* Telegram-like, avoiding its blue buys
// nothing and costs recognisability. So the accent is now free to be
// recognisable, and the one thing that must stay distinct is the track badge
// colours — those carry meaning, not decoration.

import 'package:flutter/material.dart';

/// Colour roles.
///
/// A [ThemeExtension] rather than a bare palette so it participates in
/// `Theme.of(context)` and survives a `Theme` copy, which a plain static class
/// does not.
@immutable
class XColors extends ThemeExtension<XColors> {
  const XColors({
    required this.accent,
    required this.onAccent,
    required this.accentContainer,
    required this.onAccentContainer,
    required this.canvas,
    required this.surface,
    required this.surfaceRaised,
    required this.surfaceSunken,
    required this.ownBubble,
    required this.peerBubble,
    required this.onOwnBubble,
    required this.onPeerBubble,
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
    required this.separator,
    required this.danger,
    required this.online,
    required this.unreadBadge,
    required this.shadow,
  });

  /// Material 3's primary role. Not fixed: `ColorScheme.fromSeed` supplies it,
  /// which is what makes Android 12 dynamic colour work with no code here.
  final Color accent;
  final Color onAccent;
  final Color accentContainer;
  final Color onAccentContainer;

  /// The page behind a conversation list or a transcript.
  final Color canvas;

  /// Cards, sheets, the input bar: anything raised off [canvas].
  final Color surface;

  /// One step further forward than [surface] — a selected row, a chip.
  final Color surfaceRaised;

  /// One step back — the input field inside a sheet.
  final Color surfaceSunken;

  final Color ownBubble;
  final Color peerBubble;
  final Color onOwnBubble;
  final Color onPeerBubble;

  final Color textPrimary;
  final Color textSecondary;

  /// Reserved for text that is deliberately de-emphasised to the point of
  /// being non-essential — a placeholder, a "sent" tick. Not for readable
  /// content; contrast with the canvas is kept legible in both themes.
  final Color textTertiary;

  final Color separator;
  final Color danger;
  final Color online;
  final Color unreadBadge;

  /// Bubble shadow. Kept as a role because a shadow that is a slightly darker
  /// black in light mode has to be a slightly *lighter* black in dark mode, or
  /// it reads as a smear rather than a lift.
  final Color shadow;

  /// Dark palette.
  ///
  /// Dark first because a messenger is used at night more often than not, and
  /// because every light-mode value is trivially derived from a dark one by
  /// the same surface-elevation logic.
  factory XColors.dark(ColorScheme scheme) {
    return XColors(
      accent: scheme.primary,
      onAccent: scheme.onPrimary,
      accentContainer: scheme.primaryContainer,
      onAccentContainer: scheme.onPrimaryContainer,
      // Near-black rather than black: pure #000 on an OLED smears text at the
      // edges, and it makes a dark shadow invisible so bubbles lose their
      // separation entirely.
      canvas: const Color(0xFF0B0F14),
      surface: const Color(0xFF121821),
      surfaceRaised: const Color(0xFF1A222D),
      surfaceSunken: const Color(0xFF080B0F),
      ownBubble: const Color(0xFF1E3A5F),
      peerBubble: const Color(0xFF1A222D),
      onOwnBubble: const Color(0xFFE8EEF5),
      onPeerBubble: const Color(0xFFE8EEF5),
      textPrimary: const Color(0xFFE8EEF5),
      textSecondary: const Color(0xFF9AA7B4),
      textTertiary: const Color(0xFF6B7885),
      separator: const Color(0xFF232C38),
      danger: const Color(0xFFE5484D),
      online: const Color(0xFF3FB950),
      unreadBadge: scheme.primary,
      shadow: const Color(0xFF000000),
    );
  }

  factory XColors.light(ColorScheme scheme) {
    return XColors(
      accent: scheme.primary,
      onAccent: scheme.onPrimary,
      accentContainer: scheme.primaryContainer,
      onAccentContainer: scheme.onPrimaryContainer,
      canvas: const Color(0xFFF7F9FC),
      surface: const Color(0xFFFFFFFF),
      surfaceRaised: const Color(0xFFEDF1F6),
      surfaceSunken: const Color(0xFFE4EAF1),
      ownBubble: const Color(0xFFD7E9FF),
      peerBubble: const Color(0xFFFFFFFF),
      onOwnBubble: const Color(0xFF10161D),
      onPeerBubble: const Color(0xFF10161D),
      textPrimary: const Color(0xFF10161D),
      textSecondary: const Color(0xFF5A6673),
      // Deliberately darker than it looks like it needs to be: the light canvas
      // is near-white, and the "sent" tick and field hints land here. At
      // #8A96A3 this measured 2.86:1 against the canvas — below the 3:1 that
      // WCAG requires of anything carrying meaning. #78838F measures 3.66:1.
      textTertiary: const Color(0xFF78838F),
      separator: const Color(0xFFDCE3EB),
      danger: const Color(0xFFD1242F),
      online: const Color(0xFF1A7F37),
      unreadBadge: scheme.primary,
      shadow: const Color(0xFF000000),
    );
  }

  @override
  XColors copyWith({
    Color? accent,
    Color? onAccent,
    Color? accentContainer,
    Color? onAccentContainer,
    Color? canvas,
    Color? surface,
    Color? surfaceRaised,
    Color? surfaceSunken,
    Color? ownBubble,
    Color? peerBubble,
    Color? onOwnBubble,
    Color? onPeerBubble,
    Color? textPrimary,
    Color? textSecondary,
    Color? textTertiary,
    Color? separator,
    Color? danger,
    Color? online,
    Color? unreadBadge,
    Color? shadow,
  }) {
    return XColors(
      accent: accent ?? this.accent,
      onAccent: onAccent ?? this.onAccent,
      accentContainer: accentContainer ?? this.accentContainer,
      onAccentContainer: onAccentContainer ?? this.onAccentContainer,
      canvas: canvas ?? this.canvas,
      surface: surface ?? this.surface,
      surfaceRaised: surfaceRaised ?? this.surfaceRaised,
      surfaceSunken: surfaceSunken ?? this.surfaceSunken,
      ownBubble: ownBubble ?? this.ownBubble,
      peerBubble: peerBubble ?? this.peerBubble,
      onOwnBubble: onOwnBubble ?? this.onOwnBubble,
      onPeerBubble: onPeerBubble ?? this.onPeerBubble,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      textTertiary: textTertiary ?? this.textTertiary,
      separator: separator ?? this.separator,
      danger: danger ?? this.danger,
      online: online ?? this.online,
      unreadBadge: unreadBadge ?? this.unreadBadge,
      shadow: shadow ?? this.shadow,
    );
  }

  @override
  XColors lerp(covariant XColors? other, double t) {
    if (other == null) return this;
    return XColors(
      accent: Color.lerp(accent, other.accent, t)!,
      onAccent: Color.lerp(onAccent, other.onAccent, t)!,
      accentContainer: Color.lerp(accentContainer, other.accentContainer, t)!,
      onAccentContainer: Color.lerp(
        onAccentContainer,
        other.onAccentContainer,
        t,
      )!,
      canvas: Color.lerp(canvas, other.canvas, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      surfaceRaised: Color.lerp(surfaceRaised, other.surfaceRaised, t)!,
      surfaceSunken: Color.lerp(surfaceSunken, other.surfaceSunken, t)!,
      ownBubble: Color.lerp(ownBubble, other.ownBubble, t)!,
      peerBubble: Color.lerp(peerBubble, other.peerBubble, t)!,
      onOwnBubble: Color.lerp(onOwnBubble, other.onOwnBubble, t)!,
      onPeerBubble: Color.lerp(onPeerBubble, other.onPeerBubble, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      textTertiary: Color.lerp(textTertiary, other.textTertiary, t)!,
      separator: Color.lerp(separator, other.separator, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
      online: Color.lerp(online, other.online, t)!,
      unreadBadge: Color.lerp(unreadBadge, other.unreadBadge, t)!,
      shadow: Color.lerp(shadow, other.shadow, t)!,
    );
  }

  /// Every role paired with the canvas, for the contrast audit.
  ///
  /// Exposed as data rather than checked in comments so the audit is a test
  /// that can fail, instead of a claim in prose that cannot.
  Map<String, Color> get foregrounds => {
    'textPrimary': textPrimary,
    'textSecondary': textSecondary,
    'textTertiary': textTertiary,
    'accent': accent,
    'danger': danger,
    'online': online,
    'onOwnBubble': onOwnBubble,
    'onPeerBubble': onPeerBubble,
  };
}

/// Spacing, radii and type sizes.
///
/// A scale rather than arbitrary per-call values: every gap in the app is a
/// multiple of [unit], which is what lets the density be changed in one place
/// instead of in two hundred call sites.
class XDimens {
  const XDimens._();

  /// Base spacing unit. Four points, matching Material's 4dp grid.
  static const double unit = 4;

  static const double xs = unit;
  static const double sm = unit * 2;
  static const double md = unit * 3;
  static const double lg = unit * 4;
  static const double xl = unit * 6;
  static const double xxl = unit * 8;

  /// Material 3's shape scale, plus the values Telegram-shaped surfaces need
  /// that M3 does not name.
  static const double shapeSm = 8;
  static const double shapeMd = 12;
  static const double shapeLg = 16;
  static const double shapeXl = 28;

  /// Bubble corner radius, and the tail that makes it a messenger rather than
  /// a note-taking app.
  static const double bubbleRadius = shapeLg;
  static const double bubbleTailSize = 8;
  static const double bubblePaddingH = 10;
  static const double bubblePaddingV = 6;

  // Type scale. Named by role rather than by point size so a font-size
  // preference can scale them without touching call sites.
  static const double typeDisplay = 28;
  static const double typeTitle = 20;
  static const double typeHeadline = 17;
  static const double typeBody = 15;
  static const double typeLabel = 13;
  static const double typeCaption = 11;

  static const double avatarChats = 52;
  static const double avatarChat = 40;
  static const double avatarContacts = 46;

  /// Tall enough for a two-line row at [typeBody] plus its timestamp.
  static const double chatsRowHeight = 66;
  static const double chatsHorizontalPadding = md;
}

/// `context.x.accent`.
///
/// Falls back to the dark palette's roles when the host theme carries no
/// [XColors], so a widget stays usable in isolation — tests and a bare
/// `MaterialApp` must not throw. The fallback is dark because a widget rendered
/// with no theme is overwhelmingly more likely to be a preview or a test, and
/// the dark palette is the one this app is designed around.
extension XTheme on BuildContext {
  XColors get x =>
      Theme.of(this).extension<XColors>() ??
      XColors.dark(Theme.of(this).colorScheme);
}
