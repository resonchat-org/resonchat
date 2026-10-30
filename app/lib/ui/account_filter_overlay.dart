// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Sliding account filter panel shared by Chats / Contacts / Groups.
// Display-only: chooses which account’s rows the list shows.

import 'package:flutter/material.dart';

import 'package:resonchat/l10n/l10n.dart';
import 'package:resonchat/persistence/account_store.dart';
import 'package:resonchat/ui/chats/chats_filter_bar.dart';
import 'package:resonchat/ui/theme.dart';

/// Round hamburger that opens the account filter drawer.
class AccountFilterMenuButton extends StatelessWidget {
  const AccountFilterMenuButton({super.key, required this.onPressed});

  final VoidCallback onPressed;

  static const double size = 32;

  @override
  Widget build(BuildContext context) {
    final tg = context.appColors;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final track = isDark
        ? tg.separator.withValues(alpha: 0.85)
        : const Color(0xFFE8EBEE);
    return AccountFilterCircleButton(
      size: size,
      color: track,
      iconColor: tg.textSecondary,
      tooltip: context.l10n.filterAccounts,
      onPressed: onPressed,
    );
  }
}

/// Dimmed scrim + sliding [ChatsAccountDrawer] over [child].
class AccountFilterOverlay extends StatelessWidget {
  const AccountFilterOverlay({
    super.key,
    required this.controller,
    required this.slide,
    required this.accounts,
    required this.selectedAccountId,
    required this.onSelected,
    required this.onDismiss,
    required this.child,
  });

  final AnimationController controller;
  final Animation<Offset> slide;
  final List<StoredAccount> accounts;
  final String? selectedAccountId;
  final ValueChanged<String?> onSelected;
  final VoidCallback onDismiss;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          final open = controller.status != AnimationStatus.dismissed;
          return Stack(
            children: [
              child,
              if (open) ...[
                Positioned.fill(
                  child: GestureDetector(
                    onTap: onDismiss,
                    behavior: HitTestBehavior.opaque,
                    child: ColoredBox(
                      color: Colors.black.withValues(
                        alpha: 0.32 * controller.value,
                      ),
                    ),
                  ),
                ),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: SlideTransition(
                    position: slide,
                    child: ChatsAccountDrawer(
                      accounts: accounts,
                      selectedAccountId: selectedAccountId,
                      onSelected: onSelected,
                    ),
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}
