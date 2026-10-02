// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Contact requests.
//
// This page exists because of one decision: a subscription request is recorded
// and answered by the user, not approved on arrival. Approving automatically
// means anyone can subscribe and start messaging you with no say in it, which
// is the entire reason the mechanism exists.
//
// Two lists in one screen, because a user has two kinds of waiting:
// somebody who wants to see them, and a reply they are still owed.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:moxxmpp/moxxmpp.dart' show JID;

import '../state/providers.dart';
import '../store/database.dart';
import 'contact_avatar.dart';
import 'theme.dart';

class RequestsPage extends ConsumerWidget {
  const RequestsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tg = context.tg;
    final requests = ref.watch(subscriptionRequestsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Contact requests')),
      body: requests.when(
        data: (rows) {
          final incoming =
              rows.where((r) => !r.outgoing).toList(growable: false);
          final outgoing =
              rows.where((r) => r.outgoing).toList(growable: false);
          if (rows.isEmpty) {
            return Center(
              child: Text(
                'Nothing waiting',
                style: TextStyle(color: tg.textSecondary),
              ),
            );
          }
          return ListView(
            children: [
              if (incoming.isNotEmpty) ...[
                _header(tg, 'Want to see you'),
                for (final r in incoming)
                  _IncomingRow(request: r),
              ],
              if (outgoing.isNotEmpty) ...[
                _header(tg, 'Waiting for them'),
                for (final r in outgoing)
                  ListTile(
                    leading: ContactAvatar(jid: r.jid, title: r.jid),
                    title: Text(r.jid),
                    subtitle: const Text('They have not answered yet.'),
                    trailing: TextButton(
                      onPressed: () {
                        ref
                            .read(xmppServiceProvider)
                            .resolveOutgoingRequest(JID.fromString(r.jid));
                        ref
                            .read(databaseProvider)
                            .resolveRequest(r.jid, outgoing: true);
                      },
                      child: const Text('Cancel'),
                    ),
                  ),
              ],
            ],
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
      ),
    );
  }

  static Widget _header(TgColors tg, String title) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 4),
        child: Text(
          title,
          style: TextStyle(
            color: tg.textSecondary,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
}

class _IncomingRow extends ConsumerStatefulWidget {
  const _IncomingRow({required this.request});

  final SubscriptionRequest request;

  @override
  ConsumerState<_IncomingRow> createState() => _IncomingRowState();
}

class _IncomingRowState extends ConsumerState<_IncomingRow> {
  bool _busy = false;

  Future<void> _answer(bool accept) async {
    if (_busy) return;
    setState(() => _busy = true);
    final jid = JID.fromString(widget.request.jid);
    final xmpp = ref.read(xmppServiceProvider);
    if (accept) {
      await xmpp.acceptSubscription(jid);
    } else {
      await xmpp.rejectSubscription(jid);
    }
    // Resolved last, and unconditionally: the user made the decision, and a
    // server that refused to carry it out is not a reason to ask them again.
    ref
        .read(xmppServiceProvider)
        .resolveIncomingRequest(JID.fromString(widget.request.jid));
    await ref
        .read(databaseProvider)
        .resolveRequest(widget.request.jid, outgoing: false);
    if (!mounted) return;
    setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final tg = context.tg;
    return ListTile(
      leading: ContactAvatar(jid: widget.request.jid, title: widget.request.jid),
      title: Text(widget.request.jid),
      subtitle: Text(
        'They want to see when you are online and to send you messages.',
        style: TextStyle(color: tg.textSecondary, fontSize: 12),
      ),
      trailing: _busy
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  onPressed: () => _answer(false),
                  icon: const Icon(Icons.close),
                  tooltip: 'Decline',
                  color: tg.danger,
                ),
                IconButton(
                  onPressed: () => _answer(true),
                  icon: const Icon(Icons.check),
                  tooltip: 'Accept',
                  color: tg.accent,
                ),
              ],
            ),
    );
  }
}
