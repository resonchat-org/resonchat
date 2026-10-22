// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The two shell actions: pending requests and settings.
// Portrait puts them on the chat and contact app bars. Landscape puts the
// same actions at the bottom of the rail.

import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:resonchat/l10n/l10n.dart';
import 'package:resonchat/state/providers.dart';
import 'package:resonchat/ui/pending/pending_requests_page.dart';
import 'package:resonchat/ui/theme.dart';

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
    const PendingRequestsButton(),
    IconButton(
      icon: const Icon(Icons.settings),
      tooltip: l10n.settings,
      onPressed: () => openSettings(Navigator.of(context)),
    ),
  ];
}

/// Pending-requests entry with a red count of incoming items.
class PendingRequestsButton extends ConsumerWidget {
  const PendingRequestsButton({super.key, this.color, this.onPressed});

  final Color? color;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final count = ref.watch(actionablePendingCountProvider);
    final label = count > 99 ? '99+' : '$count';
    return IconButton(
      tooltip: l10n.pendingRequests,
      color: color,
      onPressed: onPressed ?? () => openPendingRequests(Navigator.of(context)),
      icon: Badge(
        isLabelVisible: count > 0,
        backgroundColor: context.tg.danger,
        textColor: Colors.white,
        label: Text(label),
        child: const Icon(Icons.person_add_alt),
      ),
    );
  }
}

/// Snackbar when the incoming-request count grows, including the first
/// time the shell sees a non-zero count.
void remindPendingRequests(BuildContext context, WidgetRef ref) {
  ref.listen<int>(actionablePendingCountProvider, (prev, next) {
    if (next <= 0) return;
    if (prev != null && next <= prev) return;
    if (pendingRequestsOpen.value) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final nav = Navigator.maybeOf(context);
    if (messenger == null || nav == null) return;
    final l10n = context.l10n;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(l10n.pendingRequestsReminder(next)),
          action: SnackBarAction(
            label: l10n.pendingRequestsView,
            onPressed: () => openPendingRequests(nav),
          ),
        ),
      );
  });
}
