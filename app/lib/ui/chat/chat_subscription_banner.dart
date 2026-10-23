// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
// Banner when the contact is not a mutual subscription.

import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:moxxmpp/moxxmpp.dart' show JID;

import 'package:resonchat/account/resolve.dart';
import 'package:resonchat/l10n/l10n.dart';
import 'package:resonchat/state/providers.dart';
import 'package:resonchat/ui/theme.dart';

/// Warns when the contact is not a mutual subscription.
///
/// Without this, a server that refuses stanzas outside a mutual
/// subscription looks exactly like silent data loss: messages vanish and
/// nothing in the interface explains why.
///
/// When the other side has already asked to add us, the only useful action is
/// to accept — asking *them* again cannot make the relationship mutual.
class ChatSubscriptionBanner extends ConsumerStatefulWidget {
  const ChatSubscriptionBanner({super.key, required this.chatJid});

  final String chatJid;

  @override
  ConsumerState<ChatSubscriptionBanner> createState() =>
      _ChatSubscriptionBannerState();
}

class _ChatSubscriptionBannerState
    extends ConsumerState<ChatSubscriptionBanner> {
  /// Set once the user has accepted the incoming request, cleared as soon as
  /// the roster reflects it.
  ///
  /// Accepting makes *their* subscription to us active; our roster item stays
  /// non-mutual until the server pushes the update. Falling back to "ask again"
  /// in that window tells the user the accept did not work.
  bool _accepted = false;

  @override
  void didUpdateWidget(covariant ChatSubscriptionBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.chatJid != widget.chatJid) _accepted = false;
  }

  Future<void> _accept(String bareJid) async {
    final r = resolveChatKey(widget.chatJid);
    final jid = JID.fromString(bareJid);
    setState(() => _accepted = true);
    try {
      await r.session.xmpp.acceptSubscription(jid);
      r.session.xmpp.resolveIncomingRequest(jid);
      await r.session.db.resolveRequest(r.jid, outgoing: false);
    } catch (_) {
      // Leave the banner actionable: the request is still pending.
      if (mounted) setState(() => _accepted = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tg = context.tg;
    final state = ref.watch(contactStateProvider(widget.chatJid)).value;
    // Nothing to say before the roster has loaded, or when all is well.
    if (state == null || state.isMutual) return const SizedBox.shrink();

    final bareJid = resolveChatKey(widget.chatJid).jid;
    final requests = ref.watch(subscriptionRequestsProvider).valueOrNull ??
        const [];
    final incoming = requests.any((r) => !r.outgoing && r.jid == bareJid);

    final l10n = context.l10n;
    final text = incoming
        ? l10n.subscriptionBannerIncoming
        : _accepted
        ? l10n.subscriptionBannerAccepted
        : switch (state.subscription) {
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
            if (incoming)
              TextButton(
                onPressed: () => _accept(bareJid),
                child: Text(l10n.accept),
              )
            else if (!_accepted)
              TextButton(
                onPressed: () {
                  final r = resolveChatKey(widget.chatJid);
                  r.session.xmpp.requestSubscription(JID.fromString(r.jid));
                },
                child: Text(l10n.askAgain),
              ),
          ],
        ),
      ),
    );
  }
}
