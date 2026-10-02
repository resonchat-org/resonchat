// Copyright (C) 2026 resonchat contributors.
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

import '../state/providers.dart';
import '../xmpp/avatar.dart';
import 'theme.dart';

class ContactAvatar extends ConsumerWidget {
  const ContactAvatar({
    super.key,
    required this.jid,
    required this.title,
    this.radius = TgDimens.avatarChats / 2,
    this.hero = false,
  });

  final String jid;

  /// The display name. Falls back to the JID when empty.
  final String title;

  final double radius;

  /// Wrapped in a [Hero] so the circle carries across the chat transition.
  final bool hero;

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

    if (!hero) return circle;
    return Hero(tag: 'avatar-$jid', child: circle);
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
      backgroundColor: colour.withValues(alpha: 0.22),
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