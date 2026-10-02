// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Design tokens following the Telegram-Android look (docs/05 §2).
//
// Layout and interaction conventions are translated from Telegram for
// Android (GPL-2.0-or-later); the colour values below are our own
// sampling. Branding is deliberately distinct (docs/05 §6): no Telegram
// name, logo, or paper-plane glyph is used, and the accent hue is
// shifted away from stock Telegram blue so the apps are not
// confusable.

import 'package:flutter/material.dart';

/// Telegram-like palette exposed through [ThemeExtension] so widgets read
/// colours from the theme instead of hard-coding them.
@immutable
class TgColors extends ThemeExtension<TgColors> {
  const TgColors({
    required this.barBackground,
    required this.pageBackground,
    required this.peerBubble,
    required this.ownBubble,
    required this.ownBubbleFrom,
    required this.textPrimary,
    required this.textSecondary,
    required this.accent,
    required this.separator,
    required this.unreadBadge,
    required this.online,
    required this.dateSeparator,
    required this.dateSeparatorText,
    required this.danger,
  });

  /// Light theme. Values sampled from Telegram for Android's
  /// `ThemeColors.java` `defaultColors` map (`key_chat_inBubble`
  /// #ffffff, `key_chat_outBubble` #efffde, `key_chat_inTimeText`
  /// #a1aab3, `key_chat_outTimeText` #70b15c, `key_chat_messagePanelHint`
  /// #a4acb3, `key_chat_messagePanelSend` #62b0eb). The accent is
  /// intentionally *not* stock Telegram blue so the apps are not
  /// confusable (docs/05 §6).
  const TgColors.light()
      : barBackground = const Color(0xFF517DA2),
        pageBackground = const Color(0xFFFFFFFF),
        peerBubble = const Color(0xFFFFFFFF),
        ownBubble = const Color(0xFFEFFDE0),
        ownBubbleFrom = const Color(0xFFE2F7D1),
        textPrimary = const Color(0xFF000000),
        textSecondary = const Color(0xFFA1AAB3),
        accent = const Color(0xFF3D9BD4),
        separator = const Color(0xFFE5E5E5),
        unreadBadge = const Color(0xFF4FAE4E),
        online = const Color(0xFF4FAE4E),
        dateSeparator = const Color(0x19000000),
        dateSeparatorText = const Color(0xFF6D7F8F),
        danger = const Color(0xFFE53935);

  /// Dark theme. Telegram derives these at runtime from the accent colour
  /// (`Theme.java` applies `changeColorAccent` against `isDarkTheme`)
  /// rather than shipping a static dark table, so these are our
  /// hand-tuned equivalents sampled from the night theme's rendered
  /// output, not copies of a literal table.
  const TgColors.dark()
      : barBackground = const Color(0xFF242F3D),
        pageBackground = const Color(0xFF17212B),
        peerBubble = const Color(0xFF182533),
        ownBubble = const Color(0xFF2B5278),
        ownBubbleFrom = const Color(0xFF38536F),
        textPrimary = const Color(0xFFFFFFFF),
        textSecondary = const Color(0xFF6D7F8F),
        accent = const Color(0xFF5EB5F7),
        separator = const Color(0xFF101921),
        unreadBadge = const Color(0xFF4FAE4E),
        online = const Color(0xFF4FAE4E),
        dateSeparator = const Color(0x66000000),
        dateSeparatorText = const Color(0xFF8A9BA8),
        danger = const Color(0xFFEF5350);

  final Color barBackground;
  final Color pageBackground;
  final Color peerBubble;
  final Color ownBubble;
  final Color ownBubbleFrom;
  final Color textPrimary;
  final Color textSecondary;
  final Color accent;
  final Color separator;
  final Color unreadBadge;
  final Color online;
  final Color dateSeparator;
  final Color dateSeparatorText;
  final Color danger;

  @override
  TgColors copyWith({
    Color? barBackground,
    Color? pageBackground,
    Color? peerBubble,
    Color? ownBubble,
    Color? ownBubbleFrom,
    Color? textPrimary,
    Color? textSecondary,
    Color? accent,
    Color? separator,
    Color? unreadBadge,
    Color? online,
    Color? dateSeparator,
    Color? dateSeparatorText,
    Color? danger,
  }) {
    return TgColors(
      barBackground: barBackground ?? this.barBackground,
      pageBackground: pageBackground ?? this.pageBackground,
      peerBubble: peerBubble ?? this.peerBubble,
      ownBubble: ownBubble ?? this.ownBubble,
      ownBubbleFrom: ownBubbleFrom ?? this.ownBubbleFrom,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      accent: accent ?? this.accent,
      separator: separator ?? this.separator,
      unreadBadge: unreadBadge ?? this.unreadBadge,
      online: online ?? this.online,
      dateSeparator: dateSeparator ?? this.dateSeparator,
      dateSeparatorText: dateSeparatorText ?? this.dateSeparatorText,
      danger: danger ?? this.danger,
    );
  }

  @override
  TgColors lerp(ThemeExtension<TgColors>? other, double t) {
    if (other is! TgColors) return this;
    return TgColors(
      barBackground: Color.lerp(barBackground, other.barBackground, t)!,
      pageBackground: Color.lerp(pageBackground, other.pageBackground, t)!,
      peerBubble: Color.lerp(peerBubble, other.peerBubble, t)!,
      ownBubble: Color.lerp(ownBubble, other.ownBubble, t)!,
      ownBubbleFrom: Color.lerp(ownBubbleFrom, other.ownBubbleFrom, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      separator: Color.lerp(separator, other.separator, t)!,
      unreadBadge: Color.lerp(unreadBadge, other.unreadBadge, t)!,
      online: Color.lerp(online, other.online, t)!,
      dateSeparator: Color.lerp(dateSeparator, other.dateSeparator, t)!,
      dateSeparatorText:
          Color.lerp(dateSeparatorText, other.dateSeparatorText, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
    );
  }
}

/// Spacing and sizing constants sampled from Telegram (docs/05 §2).
class TgDimens {
  const TgDimens._();

  static const double bubbleRadius = 12;
  static const double bubbleTailSize = 8;
  static const double bubblePaddingH = 8;
  static const double bubblePaddingV = 6;

  static const double messageFontSize = 16;
  static const double chatTitleFontSize = 16;
  static const double chatSubtitleFontSize = 14;
  static const double timeFontSize = 11;

  static const double avatarChats = 54;
  static const double avatarChat = 40;
  static const double avatarContacts = 46;

  static const double chatsRowHeight = 64;
  static const double chatsHorizontalPadding = 12;
  static const double chatsTitleGap = 2;
}

/// Convenience accessor: `context.tg.accent`.
///
/// Falls back to the light palette when the host theme has no
/// [TgColors] extension, so widgets stay usable in isolation (tests,
/// bare MaterialApp) instead of throwing.
extension TgTheme on BuildContext {
  TgColors get tg =>
      Theme.of(this).extension<TgColors>() ??
      (Theme.of(this).brightness == Brightness.dark
          ? const TgColors.dark()
          : const TgColors.light());
}

class AppThemeTokens {
  const AppThemeTokens._();

  /// Font family used across the app. On Android this resolves to
  /// Roboto, which is what Telegram uses; overridable so the preview
  /// harness can substitute a locally available font.
  static String fontFamily = 'Roboto';

  static ThemeData light() {
    const tg = TgColors.light();
    return _base(tg, Brightness.light);
  }

  static ThemeData dark() {
    const tg = TgColors.dark();
    return _base(tg, Brightness.dark);
  }

  static ThemeData _base(TgColors tg, Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: tg.accent,
      brightness: brightness,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      fontFamily: fontFamily,
      scaffoldBackgroundColor: tg.pageBackground,
      // Telegram's action bar has no elevation and no shadow.
      appBarTheme: AppBarTheme(
        backgroundColor: tg.barBackground,
        foregroundColor: Colors.white,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: Colors.white,
          fontSize: TgDimens.chatTitleFontSize,
          fontWeight: FontWeight.w600,
        ),
      ),
      dividerTheme: DividerThemeData(color: tg.separator, space: 0.5),
      extensions: <ThemeExtension<dynamic>>[tg],
    );
  }
}

/// Lock badge for the encryption state: `OMEMO`, `PQ`, or plaintext.
class EncBadge extends StatelessWidget {
  const EncBadge({
    super.key,
    required this.label,
    required this.locked,
    this.onTap,
  });

  final String label;
  final bool locked;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final tg = context.tg;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              locked ? Icons.lock_outline : Icons.lock_open_outlined,
              size: 14,
              color: locked ? tg.accent : tg.textSecondary,
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: TgDimens.timeFontSize,
                fontWeight: FontWeight.w600,
                color: locked ? tg.accent : tg.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}