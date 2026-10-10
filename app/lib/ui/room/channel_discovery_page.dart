// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Public channel search (Conversations ChannelDiscoveryActivity).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../account/account_hub.dart';
import '../../account/chat_ref.dart';
import '../../l10n/l10n.dart';
import '../../state/providers.dart';
import '../../xmpp/channel_discovery.dart';
import '../../xmpp/muc.dart';
import '../home/open_chat.dart';
import '../theme.dart';

/// Search and join public MUCs via jabber.network or local disco.
class ChannelDiscoveryPage extends ConsumerStatefulWidget {
  const ChannelDiscoveryPage({super.key});

  @override
  ConsumerState<ChannelDiscoveryPage> createState() =>
      _ChannelDiscoveryPageState();
}

class _ChannelDiscoveryPageState extends ConsumerState<ChannelDiscoveryPage> {
  final _query = TextEditingController();
  ChannelDiscoveryMethod _method = ChannelDiscoveryMethod.jabberNetwork;
  bool _optedIn = false;
  bool _ready = false;
  bool _loading = false;
  List<PublicChannel> _results = const [];
  late final ChannelDiscoveryService _service;

  @override
  void initState() {
    super.initState();
    _service = ChannelDiscoveryService(xmpp: ref.read(xmppServiceProvider));
    unawaited(_bootstrap());
  }

  Future<void> _bootstrap() async {
    final method = await loadChannelDiscoveryMethod();
    final optedIn = await loadChannelDiscoveryOptIn();
    if (!mounted) return;
    setState(() {
      _method = method;
      _optedIn = optedIn;
      _ready = true;
    });
    if (_method == ChannelDiscoveryMethod.localServer || _optedIn) {
      await _search();
    } else {
      await _promptOptIn();
    }
  }

  Future<void> _promptOptIn() async {
    final l10n = context.l10n;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.channelDiscoveryOptInTitle),
        content: Text(l10n.channelDiscoveryOptInMessage),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.accept),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (ok == true) {
      await saveChannelDiscoveryOptIn(true);
      setState(() => _optedIn = true);
      await _search();
    }
  }

  Future<void> _search() async {
    if (_method == ChannelDiscoveryMethod.jabberNetwork && !_optedIn) {
      await _promptOptIn();
      return;
    }
    setState(() => _loading = true);
    final results = await _service.discover(_query.text, method: _method);
    if (!mounted) return;
    setState(() {
      _results = results;
      _loading = false;
    });
  }

  Future<void> _join(PublicChannel channel) async {
    final l10n = context.l10n;
    final xmpp = ref.read(xmppServiceProvider);
    final nickCtrl = TextEditingController(
      text: xmpp.myJid?.split('@').first ?? '',
    );
    final nick = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.joinGroup),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              channel.displayName,
              style: Theme.of(ctx).textTheme.titleSmall,
            ),
            Text(
              channel.address,
              style: TextStyle(
                color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: nickCtrl,
              autofocus: true,
              decoration: InputDecoration(labelText: l10n.yourNicknameInRoom),
              onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(nickCtrl.text.trim()),
            child: Text(l10n.joinGroup),
          ),
        ],
      ),
    );
    nickCtrl.dispose();
    if (nick == null || nick.isEmpty || !mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(SnackBar(content: Text(l10n.joining)));
    final failure = await xmpp.joinGroupChat(channel.address, nick);
    if (!mounted) return;
    if (failure != null) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.couldNotJoin('$failure'))),
      );
      return;
    }
    final db = ref.read(databaseProvider);
    final features = await xmpp.queryRoomFeatures(channel.address);
    final encryptable = isPrivateAndNonAnonymous(features);
    await xmpp.refreshRoomMembership(
      channel.address,
      privateNonAnonymous: encryptable,
    );
    await db.upsertChat(
      channel.address,
      isGroup: true,
      mucNick: nick,
      title: channel.displayName,
      mucPrivateNonAnonymous: encryptable,
    );
    if (!mounted) return;
    final accountId = accountHub.primarySession?.account.id;
    final chatKey = accountId == null
        ? channel.address
        : ChatRef(accountId: accountId, jid: channel.address).key;
    openChat(context, chatKey);
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final tg = context.tg;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.discoverChannels),
        actions: [
          PopupMenuButton<ChannelDiscoveryMethod>(
            tooltip: l10n.channelDiscoveryMethod,
            onSelected: (m) async {
              await saveChannelDiscoveryMethod(m);
              _service.clearCache();
              setState(() => _method = m);
              await _search();
            },
            itemBuilder: (ctx) => [
              CheckedPopupMenuItem(
                value: ChannelDiscoveryMethod.jabberNetwork,
                checked: _method == ChannelDiscoveryMethod.jabberNetwork,
                child: Text(l10n.channelDiscoveryJabberNetwork),
              ),
              CheckedPopupMenuItem(
                value: ChannelDiscoveryMethod.localServer,
                checked: _method == ChannelDiscoveryMethod.localServer,
                child: Text(l10n.channelDiscoveryLocalServer),
              ),
            ],
          ),
        ],
      ),
      body: !_ready
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  child: TextField(
                    controller: _query,
                    textInputAction: TextInputAction.search,
                    decoration: InputDecoration(
                      hintText: l10n.searchChannels,
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _query.clear();
                          unawaited(_search());
                        },
                      ),
                    ),
                    onSubmitted: (_) => unawaited(_search()),
                  ),
                ),
                if (_loading) const LinearProgressIndicator(minHeight: 2),
                Expanded(
                  child: _results.isEmpty && !_loading
                      ? Center(
                          child: Text(
                            l10n.noChannelsFound,
                            style: TextStyle(color: tg.textSecondary),
                          ),
                        )
                      : ListView.separated(
                          itemCount: _results.length,
                          separatorBuilder: (_, _) => Divider(
                            height: 0.5,
                            color: tg.separator,
                            indent: 72,
                          ),
                          itemBuilder: (context, i) {
                            final room = _results[i];
                            final lang = room.language?.trim();
                            final langOk = lang != null && lang.length == 2;
                            return ListTile(
                              leading: CircleAvatar(
                                backgroundColor: tg.accent.withValues(
                                  alpha: 0.15,
                                ),
                                child: Icon(
                                  Icons.forum_outlined,
                                  color: tg.accent,
                                ),
                              ),
                              title: Text(room.displayName),
                              subtitle: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    room.address,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  if (room.description.isNotEmpty)
                                    Text(
                                      room.description,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: tg.textSecondary,
                                        fontSize: 13,
                                      ),
                                    ),
                                ],
                              ),
                              isThreeLine: room.description.isNotEmpty,
                              trailing: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  if (room.numberOfUsers > 0)
                                    Text(
                                      '${room.numberOfUsers}',
                                      style: TextStyle(
                                        color: tg.textSecondary,
                                        fontSize: 12,
                                      ),
                                    ),
                                  if (langOk)
                                    Text(
                                      lang.toUpperCase(),
                                      style: TextStyle(
                                        color: tg.accent,
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                ],
                              ),
                              onTap: () => unawaited(_join(room)),
                            );
                          },
                        ),
                ),
              ],
            ),
    );
  }
}
