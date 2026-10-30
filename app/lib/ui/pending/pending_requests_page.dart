// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Pending requests: contact subscriptions and group invitations.
//
// Recorded and answered by the user, not approved on arrival. Approving
// automatically would mean anyone can subscribe or pull you into a room with
// no say in it.

import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:resonchat/l10n/l10n.dart';
import 'package:resonchat/persistence/database.dart';
import 'package:resonchat/state/providers.dart';
import 'package:resonchat/ui/contact_avatar.dart';
import 'package:resonchat/ui/home/open_chat.dart';
import 'package:resonchat/ui/pending/pending_requests_viewmodel.dart';
import 'package:resonchat/ui/theme.dart';

/// True while [PendingRequestsPage] is on screen.
///
/// A [ValueNotifier] rather than a provider: leaving the page updates this
/// during [State.dispose], and a provider notification at that moment marks
/// the shell dirty while the tree is locked.
final pendingRequestsOpen = ValueNotifier<bool>(false);

class PendingRequestsPage extends ConsumerStatefulWidget {
  const PendingRequestsPage({super.key});

  @override
  ConsumerState<PendingRequestsPage> createState() =>
      _PendingRequestsPageState();
}

class _PendingRequestsPageState extends ConsumerState<PendingRequestsPage> {
  @override
  void initState() {
    super.initState();
    pendingRequestsOpen.value = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.hideCurrentSnackBar();
    });
  }

  @override
  void dispose() {
    pendingRequestsOpen.value = false;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tg = context.appColors;
    final l10n = context.l10n;
    final requests = ref.watch(subscriptionRequestsProvider);
    final invites = ref.watch(roomInvitationsProvider);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.pendingRequests)),
      body: requests.when(
        data: (rows) {
          return invites.when(
            data: (roomRows) => _body(context, ref, tg, l10n, rows, roomRows),
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(child: Text('$e')),
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
      ),
    );
  }

  static Widget _body(
    BuildContext context,
    WidgetRef ref,
    AppColors tg,
    AppLocalizations l10n,
    List<SubscriptionRequest> rows,
    List<RoomInvitation> roomRows,
  ) {
    final incoming = rows.where((r) => !r.outgoing).toList(growable: false);
    final outgoing = rows.where((r) => r.outgoing).toList(growable: false);
    if (rows.isEmpty && roomRows.isEmpty) {
      return Center(
        child: Text(
          l10n.nothingWaiting,
          style: TextStyle(color: tg.textSecondary),
        ),
      );
    }
    return ListView(
      children: [
        if (incoming.isNotEmpty) ...[
          _header(context, l10n.wantToSeeYou),
          for (final r in incoming) _IncomingContactRow(request: r),
        ],
        if (outgoing.isNotEmpty) ...[
          _header(context, l10n.waitingForThem),
          for (final r in outgoing)
            ListTile(
              leading: ContactAvatar(jid: r.jid, title: r.jid),
              title: Text(r.jid),
              subtitle: Text(l10n.theyHaveNotAnswered),
              trailing: TextButton(
                onPressed: () => ref
                    .read(pendingRequestsViewModelProvider.notifier)
                    .cancelOutgoing(r.jid),
                child: Text(l10n.cancel),
              ),
            ),
        ],
        if (roomRows.isNotEmpty) ...[
          _header(context, l10n.groupInvitations),
          for (final inv in roomRows) _RoomInviteRow(invite: inv),
        ],
      ],
    );
  }

  static Widget _header(BuildContext context, String title) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 20, 20, 4),
    child: Text(
      title,
      style: context.appText.sectionHeader,
    ),
  );
}

class _IncomingContactRow extends ConsumerStatefulWidget {
  const _IncomingContactRow({required this.request});

  final SubscriptionRequest request;

  @override
  ConsumerState<_IncomingContactRow> createState() =>
      _IncomingContactRowState();
}

class _IncomingContactRowState extends ConsumerState<_IncomingContactRow> {
  bool _busy = false;

  Future<void> _answer(bool accept) async {
    if (_busy) return;
    setState(() => _busy = true);
    await ref
        .read(pendingRequestsViewModelProvider.notifier)
        .answerSubscription(widget.request.jid, accept: accept);
    if (!mounted) return;
    setState(() => _busy = false);
  }

  Future<void> _block() async {
    if (_busy) return;
    setState(() => _busy = true);
    await ref
        .read(pendingRequestsViewModelProvider.notifier)
        .blockSubscription(widget.request.jid);
    if (!mounted) return;
    setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final tg = context.appColors;
    final l10n = context.l10n;
    return ListTile(
      leading: ContactAvatar(
        jid: widget.request.jid,
        title: widget.request.jid,
      ),
      title: Text(widget.request.jid),
      subtitle: Text(
        l10n.incomingRequestSubtitle,
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
                  onPressed: () => _block(),
                  icon: const Icon(Icons.block),
                  tooltip: l10n.block,
                  color: tg.danger,
                ),
                IconButton(
                  onPressed: () => _answer(false),
                  icon: const Icon(Icons.close),
                  tooltip: l10n.decline,
                  color: tg.danger,
                ),
                IconButton(
                  onPressed: () => _answer(true),
                  icon: const Icon(Icons.check),
                  tooltip: l10n.accept,
                  color: tg.accent,
                ),
              ],
            ),
    );
  }
}

class _RoomInviteRow extends ConsumerStatefulWidget {
  const _RoomInviteRow({required this.invite});

  final RoomInvitation invite;

  @override
  ConsumerState<_RoomInviteRow> createState() => _RoomInviteRowState();
}

class _RoomInviteRowState extends ConsumerState<_RoomInviteRow> {
  bool _busy = false;

  Future<void> _decline() async {
    if (_busy) return;
    setState(() => _busy = true);
    await ref
        .read(pendingRequestsViewModelProvider.notifier)
        .declineInvite(widget.invite);
    if (!mounted) return;
    setState(() => _busy = false);
  }

  Future<void> _accept() async {
    if (_busy) return;
    final l10n = context.l10n;
    final defaultNick =
        ref.read(xmppServiceProvider).myJid?.split('@').first ?? '';
    final nickController = TextEditingController(text: defaultNick);
    final nick = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.joinGroup),
        content: TextField(
          controller: nickController,
          autofocus: true,
          decoration: InputDecoration(
            labelText: l10n.yourNicknameInRoom,
            helperText: l10n.nicknameHelper,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, nickController.text.trim()),
            child: Text(l10n.join),
          ),
        ],
      ),
    );
    await WidgetsBinding.instance.endOfFrame;
    nickController.dispose();
    if (nick == null || nick.isEmpty || !mounted) return;

    setState(() => _busy = true);
    final result = await ref
        .read(pendingRequestsViewModelProvider.notifier)
        .acceptInvite(widget.invite, nick: nick);
    if (!mounted) return;
    setState(() => _busy = false);
    final reason = result.reason;
    if (reason != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(l10n.couldNotJoin(reason))));
      return;
    }
    openChat(context, result.chatKey!);
  }

  @override
  Widget build(BuildContext context) {
    final tg = context.appColors;
    final l10n = context.l10n;
    final inv = widget.invite;
    final subtitle = inv.fromJid.isEmpty
        ? l10n.groupInvitationSubtitleUnknown
        : l10n.groupInvitationSubtitle(inv.fromJid);
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: tg.accent.withValues(alpha: 0.18),
        child: Icon(Icons.groups_outlined, color: tg.accent),
      ),
      title: Text(inv.roomJid),
      subtitle: Text(
        subtitle,
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
                  onPressed: _decline,
                  icon: const Icon(Icons.close),
                  tooltip: l10n.decline,
                  color: tg.danger,
                ),
                IconButton(
                  onPressed: _accept,
                  icon: const Icon(Icons.check),
                  tooltip: l10n.accept,
                  color: tg.accent,
                ),
              ],
            ),
    );
  }
}
