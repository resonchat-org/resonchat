// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The two shell actions: pending requests and settings.
// Portrait puts them on the chat and contact app bars. Landscape puts the
// same actions at the bottom of the rail.

import 'package:flutter/material.dart';

import 'package:resonchat/l10n/l10n.dart';
import 'package:resonchat/ui/pending/pending_requests_page.dart';

void openPendingRequests(NavigatorState nav) {
  nav.push(
    MaterialPageRoute<void>(builder: (_) => const PendingRequestsPage()),
  );
}

void openSettings(NavigatorState nav) {
  nav.pushNamed('/settings');
}

/// App-bar actions for portrait. Landscape owns these on the rail instead.
List<Widget> portraitShellActions(BuildContext context) {
  if (MediaQuery.orientationOf(context) == Orientation.landscape) {
    return const [];
  }
  final l10n = context.l10n;
  return [
    IconButton(
      icon: const Icon(Icons.person_add_alt),
      tooltip: l10n.pendingRequests,
      onPressed: () => openPendingRequests(Navigator.of(context)),
    ),
    IconButton(
      icon: const Icon(Icons.settings),
      tooltip: l10n.settings,
      onPressed: () => openSettings(Navigator.of(context)),
    ),
  ];
}
