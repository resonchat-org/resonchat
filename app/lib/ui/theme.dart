// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
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

/// Colour emoji families, most specific platform first.
///
/// On Linux, boot calls `ensureSystemColorEmojiFont` to FontLoader-register
/// the system `NotoColorEmoji.ttf` under this first name when
/// `fonts-noto-color-emoji` is installed — otherwise Flutter/fontconfig often
/// picks Symbola or Noto Sans Symbols (monochrome / missing glyphs). Gajim
/// avoids that via Pango's emoji family switch; we cannot. Apple / Segoe /
/// Android names cover the other platforms without loading a file.
const List<String> kColorEmojiFallback = <String>[
  'Noto Color Emoji',
  'Apple Color Emoji',
  'Segoe UI Emoji',
  'Android Emoji',
];

/// A style for strings that are only emoji.
///
/// The emoji families are the primary, not merely a fallback, because there is
/// no text in the string that should win over them.
///
/// Do not add [kColorEmojiFallback] to mixed text (message bodies, timestamps,
/// composers). Noto Color Emoji also covers ASCII digits, and its digits are
/// over one em wide, so using it as a fallback makes every number look spaced
/// out. Emoji-only widgets call this helper instead.
TextStyle emojiTextStyle({double fontSize = 22, Color? color}) {
  return TextStyle(
    fontSize: fontSize,
    color: color,
    fontFamily: kColorEmojiFallback.first,
    fontFamilyFallback: kColorEmojiFallback,
  );
}

/// Telegram-like palette exposed through [ThemeExtension] so widgets read
/// colours from the theme instead of hard-coding them.
@immutable
class AppColors extends ThemeExtension<AppColors> {
  const AppColors({
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
  const AppColors.light()
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
  const AppColors.dark()
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
  AppColors copyWith({
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
    return AppColors(
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
  AppColors lerp(ThemeExtension<AppColors>? other, double t) {
    if (other is! AppColors) return this;
    return AppColors(
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
      dateSeparatorText: Color.lerp(
        dateSeparatorText,
        other.dateSeparatorText,
        t,
      )!,
      danger: Color.lerp(danger, other.danger, t)!,
    );
  }
}

/// Shared layout and type sizes (bubbles, avatars, list rows, text roles).
class AppDimens {
  const AppDimens._();

  static const double bubbleRadius = 12;
  static const double bubbleTailSize = 8;
  static const double bubblePaddingH = 8;
  static const double bubblePaddingV = 6;

  /// Shared radius for form controls (inputs, small chips, ink wells).
  static const double controlRadius = 8;

  static const double messageFontSize = 16;
  static const double chatTitleFontSize = 16;
  static const double chatSubtitleFontSize = 14;
  static const double timeFontSize = 11;
  static const double sectionHeaderFontSize = 13;
  static const double helperFontSize = 13;
  static const double captionFontSize = 12;

  static const double avatarChats = 54;
  static const double avatarChat = 40;
  static const double avatarContacts = 46;

  static const double chatsRowHeight = 64;
  static const double chatsHorizontalPadding = 12;
  static const double chatsTitleGap = 2;

  static const EdgeInsets inputContentPadding = EdgeInsets.all(12);
}

/// Repeated text roles. Prefer these over one-off `TextStyle(fontSize: …)`.
///
/// Only clear, duplicated roles live here — leave one-offs inline.
@immutable
class AppTextStyles extends ThemeExtension<AppTextStyles> {
  const AppTextStyles({
    required this.sectionHeader,
    required this.helper,
    required this.caption,
    required this.time,
  });

  factory AppTextStyles.fromColors(AppColors tg) {
    return AppTextStyles(
      sectionHeader: TextStyle(
        color: tg.textSecondary,
        fontSize: AppDimens.sectionHeaderFontSize,
        fontWeight: FontWeight.w600,
      ),
      helper: TextStyle(
        color: tg.textSecondary,
        fontSize: AppDimens.helperFontSize,
      ),
      caption: TextStyle(
        color: tg.textSecondary,
        fontSize: AppDimens.captionFontSize,
      ),
      time: TextStyle(
        color: tg.textSecondary,
        fontSize: AppDimens.timeFontSize,
      ),
    );
  }

  /// Settings / profile section titles.
  final TextStyle sectionHeader;

  /// Sheet summaries, empty-state hints, secondary body copy.
  final TextStyle helper;

  /// Fingerprint labels and other quiet meta.
  final TextStyle caption;

  /// Message timestamps.
  final TextStyle time;

  @override
  AppTextStyles copyWith({
    TextStyle? sectionHeader,
    TextStyle? helper,
    TextStyle? caption,
    TextStyle? time,
  }) {
    return AppTextStyles(
      sectionHeader: sectionHeader ?? this.sectionHeader,
      helper: helper ?? this.helper,
      caption: caption ?? this.caption,
      time: time ?? this.time,
    );
  }

  @override
  AppTextStyles lerp(ThemeExtension<AppTextStyles>? other, double t) {
    if (other is! AppTextStyles) return this;
    return AppTextStyles(
      sectionHeader: TextStyle.lerp(sectionHeader, other.sectionHeader, t)!,
      helper: TextStyle.lerp(helper, other.helper, t)!,
      caption: TextStyle.lerp(caption, other.caption, t)!,
      time: TextStyle.lerp(time, other.time, t)!,
    );
  }
}

/// Convenience accessors: `context.appColors.accent`, `context.appText.helper`.
///
/// Falls back to the light palette when the host theme has no
/// [AppColors] extension, so widgets stay usable in isolation (tests,
/// bare MaterialApp) instead of throwing.
extension AppThemeContext on BuildContext {
  AppColors get appColors =>
      Theme.of(this).extension<AppColors>() ??
      (Theme.of(this).brightness == Brightness.dark
          ? const AppColors.dark()
          : const AppColors.light());

  AppTextStyles get appText =>
      Theme.of(this).extension<AppTextStyles>() ??
      AppTextStyles.fromColors(appColors);
}

class AppThemeTokens {
  const AppThemeTokens._();

  static ThemeData light([AppColors? tg]) {
    return lightOrDark(tg ?? const AppColors.light(), Brightness.light);
  }

  static ThemeData dark([AppColors? tg]) {
    return lightOrDark(tg ?? const AppColors.dark(), Brightness.dark);
  }

  /// Fixed-accent Telegram-like theme (seeded [ColorScheme]).
  static ThemeData lightOrDark(AppColors tg, Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: tg.accent,
      brightness: brightness,
      dynamicSchemeVariant: DynamicSchemeVariant.fidelity,
    );
    return _base(
      tg: tg,
      brightness: brightness,
      scheme: scheme,
      onBar: Colors.white,
    );
  }

  /// Fallback when Material You is selected but the platform has no palette.
  static ThemeData fromSeed(Color seed, Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
      dynamicSchemeVariant: DynamicSchemeVariant.fidelity,
    );
    return fromMaterialYou(scheme);
  }

  /// Material You / Monet: drive chrome from the platform [ColorScheme]
  /// (TelegramAndroid monet_* themes use system_accent / system_neutral).
  static ThemeData fromMaterialYou(ColorScheme scheme) {
    final brightness = scheme.brightness;
    final base = brightness == Brightness.dark
        ? const AppColors.dark()
        : const AppColors.light();
    // Coloured action bar like Telegram Monet previews (primary / a1_600).
    final bar = scheme.primary;
    final tg = base.copyWith(
      barBackground: bar,
      accent: scheme.primary,
      pageBackground: scheme.surface,
      textPrimary: scheme.onSurface,
      textSecondary: scheme.onSurfaceVariant,
      separator: scheme.outlineVariant,
      peerBubble: scheme.surfaceContainerHigh,
      ownBubble: scheme.primaryContainer,
      ownBubbleFrom: Color.lerp(scheme.primaryContainer, scheme.primary, 0.12)!,
      dateSeparatorText: scheme.onSurfaceVariant,
    );
    return _base(
      tg: tg,
      brightness: brightness,
      scheme: scheme,
      onBar: scheme.onPrimary,
    );
  }

  static ThemeData _base({
    required AppColors tg,
    required Brightness brightness,
    required ColorScheme scheme,
    required Color onBar,
  }) {
    final text = AppTextStyles.fromColors(tg);
    final controlShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(AppDimens.controlRadius),
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      brightness: brightness,
      scaffoldBackgroundColor: tg.pageBackground,
      // Telegram's action bar has no elevation and no shadow.
      appBarTheme: AppBarTheme(
        backgroundColor: tg.barBackground,
        foregroundColor: onBar,
        iconTheme: IconThemeData(color: onBar),
        actionsIconTheme: IconThemeData(color: onBar),
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: onBar,
          fontSize: AppDimens.chatTitleFontSize,
          fontWeight: FontWeight.w600,
        ),
      ),
      dividerTheme: DividerThemeData(color: tg.separator, space: 0.5),
      inputDecorationTheme: InputDecorationTheme(
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(AppDimens.controlRadius)),
        contentPadding: AppDimens.inputContentPadding,
      ),
      chipTheme: ChipThemeData(
        showCheckmark: false,
        backgroundColor: scheme.surfaceContainer,
        side: BorderSide.none,
        shape: controlShape,
      ),
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          shape: controlShape,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          shape: controlShape,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          shape: controlShape,
          side: BorderSide(color: scheme.primary),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(shape: controlShape),
      ),
      textSelectionTheme: TextSelectionThemeData(
        selectionColor: scheme.onSurface.withValues(alpha: 0.24),
        selectionHandleColor: scheme.secondary,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        strokeCap: StrokeCap.round,
        color: scheme.primary,
        refreshBackgroundColor: scheme.primaryContainer,
      ),
      listTileTheme: ListTileThemeData(
        iconColor: tg.textSecondary,
        textColor: tg.textPrimary,
      ),
      extensions: <ThemeExtension<dynamic>>[tg, text],
    );
  }
}

/// Lock badge for the encryption state: `OMEMO`, `PQ`, or plaintext.
///
/// Colours follow the ambient [IconTheme] (AppBar `onBar`) so the chip stays
/// readable on the tinted action bar — using [AppColors.accent] here used to
/// paint the same colour as the bar and vanish into it.
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
    final theme = Theme.of(context);
    final onBar =
        IconTheme.of(context).color ??
        theme.appBarTheme.foregroundColor ??
        theme.colorScheme.onPrimary;
    // Locked: full contrast with other AppBar actions. Open lock: slightly
    // softer so plaintext reads as a weaker state without leaving the bar palette.
    final color = locked ? onBar : onBar.withValues(alpha: 0.72);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppDimens.controlRadius),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              locked ? Icons.lock_outline : Icons.lock_open_outlined,
              size: 24,
              color: color,
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: context.appText.sectionHeader.copyWith(color: color),
            ),
          ],
        ),
      ),
    );
  }
}
