// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The avatar circle used everywhere a person appears.
//
// One widget because it is drawn in three places — the chat list, the chat
// header and the profile — and the fallback is the part that has to be
// consistent between them. An avatar that is a coloured initial in the list and
// a grey generic glyph on the profile reads as two different people.
//
// The fallback is drawn in a colour derived from the JID, not in a uniform grey,
// and that is deliberate: "we have no avatar" must not look like "this person
// chose to hide their face". A deterministic per-contact colour also means two
// contacts in the same list are visually distinguishable without a photo,
// which is the actual job the placeholder is doing.

import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:moxxmpp/moxxmpp.dart' show PresenceShow;

import 'package:resonchat/state/providers.dart';
import 'package:resonchat/ui/theme.dart';
import 'package:resonchat/xmpp/roster/avatar.dart';

class ContactAvatar extends ConsumerWidget {
  const ContactAvatar({
    super.key,
    required this.jid,
    required this.title,
    this.radius = TgDimens.avatarChats / 2,
    this.hero = false,
    this.showPresence = false,
    this.presence,
  });

  final String jid;

  /// The display name. Falls back to the JID when empty.
  final String title;

  final double radius;

  /// Wrapped in a [Hero] so the circle carries across the chat transition.
  final bool hero;

  /// When true, draw the corner status dot (1:1 only; never for group chats).
  final bool showPresence;

  /// RFC 6121 availability; null = offline (grey dot). Ignored unless
  /// [showPresence] is true.
  final PresenceShow? presence;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tg = context.tg;
    final bytes = ref.watch(contactAvatarProvider(jid)).value;
    final fallback = _Fallback(
      initial: avatarInitial(title, jid),
      colour: tintFor(jid, tg.accent),
      radius: radius,
    );

    final Widget circle;
    if (bytes != null && bytes.isNotEmpty) {
      circle = ClipOval(
        child: Image.memory(
          bytes,
          width: radius * 2,
          height: radius * 2,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          // Decoding failures here are a corrupt avatar from the other end, and
          // the initial letter is a perfectly good answer. Without this the
          // exception surfaces as a red box in the chat list.
          errorBuilder: (_, _, _) => fallback,
        ),
      );
    } else {
      circle = fallback;
    }

    final withDot = !showPresence
        ? circle
        : SizedBox(
            width: radius * 2,
            height: radius * 2,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                circle,
                PresenceStatusDot(avatarRadius: radius, show: presence),
              ],
            ),
          );

    if (!hero) return withDot;
    return Hero(tag: 'avatar-$jid', child: withDot);
  }
}

/// Telegram DialogCell online circle: white ring + coloured fill at bottom-right.
///
/// Colours follow Gajim status CSS (`gajim-status-online/away/dnd/offline`).
class PresenceStatusDot extends StatelessWidget {
  const PresenceStatusDot({super.key, required this.avatarRadius, this.show});

  final double avatarRadius;

  /// null = offline (grey).
  final PresenceShow? show;

  /// Gajim `default.css` status colours (`gajim-status-offline` = rgb(154,154,154)).
  static Color colorFor(PresenceShow? show) => switch (show) {
    null => const Color(0xFF9A9A9A),
    PresenceShow.online || PresenceShow.chat => const Color(0xFF66BF10),
    PresenceShow.away => const Color(0xFFFF8533),
    PresenceShow.dnd || PresenceShow.xa => const Color(0xFFE62E00),
  };

  @override
  Widget build(BuildContext context) {
    final diameter = avatarRadius * 2;
    // Telegram DialogCell: outer dp(7), inner dp(5) on a ~54dp chats avatar.
    final outer = diameter * (7 / 54);
    final inner = diameter * (5 / 54);
    final insetRight = diameter * (6 / 54);
    final insetBottom = diameter * (8 / 54);
    final bg = Theme.of(context).scaffoldBackgroundColor;

    // Centre of the dot sits insetRight/insetBottom from the avatar corner
    // (Telegram DialogCell: avatar.right - 6dp, avatar.bottom - 8dp).
    return Positioned(
      right: insetRight - outer,
      bottom: insetBottom - outer,
      child: SizedBox(
        width: outer * 2,
        height: outer * 2,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: outer * 2,
              height: outer * 2,
              decoration: BoxDecoration(shape: BoxShape.circle, color: bg),
            ),
            Container(
              width: inner * 2,
              height: inner * 2,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: colorFor(show), // null → grey offline
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Fallback extends StatelessWidget {
  const _Fallback({
    required this.initial,
    required this.colour,
    required this.radius,
  });

  final String initial;
  final Color colour;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return CircleAvatar(
      radius: radius,
      backgroundColor: avatarFill(colour),
      child: Text(
        initial,
        style: TextStyle(
          color: colour,
          fontSize: radius * 0.8,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

/// Outer padding so [AvatarCameraBadge] (which hangs past the circle) is not
/// clipped by a parent. Match [AvatarCameraBadge.outsetFor].
EdgeInsets avatarCameraBadgePadding(double avatarRadius) {
  final o = AvatarCameraBadge.outsetFor(avatarRadius);
  return EdgeInsets.only(right: o, bottom: o);
}

/// Camera affordance on an editable avatar (account profile / room sheet).
///
/// Sized and offset as fractions of [avatarRadius] so a 48px room icon and a
/// 96px profile photo keep the same badge∶avatar proportions.
class AvatarCameraBadge extends StatelessWidget {
  const AvatarCameraBadge({
    super.key,
    required this.avatarRadius,
    required this.tooltip,
    this.onPressed,
  });

  final double avatarRadius;
  final String tooltip;
  final VoidCallback? onPressed;

  /// Badge diameter ≈ 72% of radius (≈ 36% of avatar diameter).
  ///
  /// Middle ground: smaller than a full [IconButton] on a 96px profile photo,
  /// larger than the tiny room-sheet chip.
  static double badgeSizeFor(double avatarRadius) => avatarRadius * 0.72;

  /// Glyph ≈ 45% of radius (≈ 62% of the badge).
  static double iconSizeFor(double avatarRadius) => avatarRadius * 0.45;

  /// How far past the circle's bottom-right the badge hangs.
  static double outsetFor(double avatarRadius) => avatarRadius * 0.14;

  @override
  Widget build(BuildContext context) {
    final tg = context.tg;
    final badge = badgeSizeFor(avatarRadius);
    final icon = iconSizeFor(avatarRadius);
    final outset = outsetFor(avatarRadius);
    final pad = ((badge - icon) / 2).clamp(2.0, 12.0);
    return Positioned(
      right: -outset,
      bottom: -outset,
      child: Tooltip(
        message: tooltip,
        child: Material(
          color: tg.accent,
          shape: const CircleBorder(),
          elevation: 1,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onPressed,
            child: Padding(
              padding: EdgeInsets.all(pad),
              child: Icon(Icons.camera_alt, size: icon, color: Colors.white),
            ),
          ),
        ),
      ),
    );
  }
}

/// Placeholder fill: the tint at 22% over white.
///
/// The circle stays opaque. A translucent tint would show the page, or an
/// account halo, through the letter.
Color avatarFill(Color colour) =>
    Color.alphaBlend(colour.withValues(alpha: 0.22), Colors.white);

/// A stable colour for [jid], derived from the JID itself.
///
/// Deterministic from the address rather than from the display name, because a
/// contact can rename themselves: the circle beside their name would otherwise
// change colour when they changed their nickname, which looks like a different
/// person arrived.
Color tintFor(String jid, Color fallback) {
  var hash = 0;
  for (final unit in jid.toLowerCase().codeUnits) {
    // FNV-1a: small, well-distributed, and cheap enough to run on every list
    // row without a visible cost.
    hash = ((hash ^ unit) * 0x01000193) & 0x7FFFFFFF;
  }
  if (hash == 0) return fallback;
  final hue = (hash % 360).toDouble();
  return HSLColor.fromAHSL(1, hue, 0.55, 0.5).toColor();
}
