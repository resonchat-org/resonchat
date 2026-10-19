// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Multi-account list chrome (stripe / via / avatar ring) for [DialogCell].

import 'package:flutter/material.dart';

import '../account/account_color.dart';
import 'theme.dart';

/// Avatar wrapped in an account-colored ring.
Widget accountAvatarRing({
  required Widget child,
  required Color accent,
  required bool show,
}) {
  if (!show) return child;
  return Container(
    padding: const EdgeInsets.all(2),
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      border: Border.all(color: accent, width: 2),
    ),
    child: child,
  );
}

/// Short “via this account” label under the title.
Widget accountViaText(String accountBareJid, Color accent) {
  return Text(
    accountViaLabel(accountBareJid),
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: TextStyle(
      fontSize: TgDimens.timeFontSize,
      color: accent,
      fontWeight: FontWeight.w600,
    ),
  );
}
