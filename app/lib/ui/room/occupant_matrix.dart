// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Avatar grid used by the room profile and by the group read sheet.
// One cell is a nick under a presence avatar; the wrap is the matrix.

import 'package:flutter/material.dart';

import 'package:resonchat/l10n/l10n.dart';
import 'package:resonchat/ui/contact_avatar.dart';
import 'package:resonchat/ui/theme.dart';
import 'package:resonchat/xmpp/muc/muc.dart';

/// Width of one avatar cell. Shared so the room roster and the read sheet
/// line up.
const double occupantCellWidth = 76;

/// Wrap of [OccupantCell]s. Empty lists draw nothing.
class OccupantMatrix extends StatelessWidget {
  const OccupantMatrix({
    super.key,
    required this.roomJid,
    required this.occupants,
    this.selfNick,
    this.onTap,
    this.onLongPress,
  });

  final String roomJid;
  final List<Occupant> occupants;

  /// Nick of this account. That cell is drawn bolder and is not tappable.
  final String? selfNick;

  final void Function(Occupant occupant)? onTap;
  final void Function(Occupant occupant)? onLongPress;

  @override
  Widget build(BuildContext context) {
    if (occupants.isEmpty) return const SizedBox.shrink();
    return Wrap(
      alignment: WrapAlignment.start,
      children: [
        for (final occupant in occupants)
          OccupantCell(
            roomJid: roomJid,
            occupant: occupant,
            self: occupant.nick == selfNick,
            onTap: onTap == null ? null : () => onTap!(occupant),
            onLongPress: onLongPress == null
                ? null
                : () => onLongPress!(occupant),
          ),
      ],
    );
  }
}

/// One member: avatar, nick, and "you" when [self].
class OccupantCell extends StatelessWidget {
  const OccupantCell({
    super.key,
    required this.roomJid,
    required this.occupant,
    this.self = false,
    this.onTap,
    this.onLongPress,
  });

  final String roomJid;
  final Occupant occupant;
  final bool self;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final real = occupant.realJid;
    final avatarJid = (real != null && real.isNotEmpty)
        ? real
        : '$roomJid/${occupant.nick}';
    return SizedBox(
      width: occupantCellWidth,
      child: InkWell(
        onTap: self ? null : onTap,
        onLongPress: self ? null : onLongPress,
        borderRadius: BorderRadius.circular(AppDimens.controlRadius),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ContactAvatar(
                jid: avatarJid,
                title: occupant.nick,
                radius: 28,
                showPresence: true,
                presence: occupant.presenceForDot,
              ),
              const SizedBox(height: 6),
              Text(
                occupant.nick,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: self ? FontWeight.w700 : FontWeight.w400,
                ),
              ),
              if (self)
                Text(
                  l10n.you,
                  style: context.appText.time,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
