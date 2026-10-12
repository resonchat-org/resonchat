// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
// Banner when the contact is not a mutual subscription.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:moxxmpp/moxxmpp.dart' show JID;

import '../../account/resolve.dart';
import '../../l10n/l10n.dart';
import '../../state/providers.dart';
import '../theme.dart';

/// Warns when the contact is not a mutual subscription.
///
/// Without this, a server that refuses stanzas outside a mutual
/// subscription looks exactly like silent data loss: messages vanish and
/// nothing in the interface explains why.
class ChatSubscriptionBanner extends ConsumerWidget {
  const ChatSubscriptionBanner({super.key, required this.chatJid});

  final String chatJid;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tg = context.tg;
    final state = ref.watch(contactStateProvider(chatJid)).value;
    // Nothing to say before the roster has loaded, or when all is well.
    if (state == null || state.isMutual) return const SizedBox.shrink();

    final l10n = context.l10n;
    final text = switch (state.subscription) {
      'none' => l10n.subscriptionBannerNone,
      'to' =>
        state.asked
            ? l10n.subscriptionBannerToAsked
            : l10n.subscriptionBannerTo,
      'from' =>
        state.asked
            ? l10n.subscriptionBannerFromAsked
            : l10n.subscriptionBannerFrom,
      _ => l10n.subscriptionBannerOther(state.subscription),
    };

    return Material(
      color: tg.danger.withValues(alpha: 0.12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        child: Row(
          children: [
            Icon(Icons.info_outline, size: 18, color: tg.danger),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                text,
                style: TextStyle(fontSize: 13, color: tg.textPrimary),
              ),
            ),
            if (state.subscription != 'both')
              TextButton(
                onPressed: () {
                  final r = resolveChatKey(chatJid);
                  r.session.xmpp.requestSubscription(JID.fromString(r.jid));
                },
                child: Text(context.l10n.askAgain),
              ),
          ],
        ),
      ),
    );
  }
}
