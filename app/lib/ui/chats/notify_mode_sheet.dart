// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Per-conversation notification mode picker (Conversations conference notify).
//
// The mode is not applied on tap. Save at the bottom commits it; dismissing
// the sheet drops the draft. Groups also list people who still notify while
// the room is silenced.

import 'dart:async';

import 'package:flutter/material.dart';

import '../../account/resolve.dart';
import '../../l10n/l10n.dart';
import '../../store/chat_notify_mode.dart';
import '../../store/database.dart';
import '../theme.dart';

/// Icon for the current [ChatNotifyMode] (list row / settings tile).
IconData notifyModeIcon(ChatNotifyMode mode) => switch (mode) {
  ChatNotifyMode.never => Icons.notifications_off,
  ChatNotifyMode.highlights => Icons.notifications_paused,
  ChatNotifyMode.all => Icons.notifications_none,
};

/// Localized label for [mode].
String notifyModeLabel(AppLocalizations l10n, ChatNotifyMode mode) =>
    switch (mode) {
      ChatNotifyMode.all => l10n.notifyAllMessages,
      ChatNotifyMode.highlights => l10n.notifyOnlyWhenHighlighted,
      ChatNotifyMode.never => l10n.notifyNever,
    };

/// Conversations-style sheet: all / highlighted / never for groups.
Future<void> pickChatNotifyMode(
  BuildContext context, {
  required AppDatabase db,
  required Chat chat,
  required String chatKey,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => _NotifyModeSheet(db: db, chat: chat, chatKey: chatKey),
  );
}

/// Opens notification settings for [chatKey] (group sheet or 1:1 mute sheet).
Future<void> openChatNotifySettings(
  BuildContext context,
  String chatKey,
) async {
  final resolved = resolveChatKey(chatKey);
  final db = resolved.session.db;
  final chat = await db.getChat(resolved.jid);
  if (chat == null || !context.mounted) return;
  await pickChatNotifyMode(context, db: db, chat: chat, chatKey: chatKey);
}

class _Person {
  const _Person({required this.key, required this.nick, this.jid});

  final String key;
  final String nick;
  final String? jid;
}

class _NotifyModeSheet extends StatefulWidget {
  const _NotifyModeSheet({
    required this.db,
    required this.chat,
    required this.chatKey,
  });

  final AppDatabase db;
  final Chat chat;
  final String chatKey;

  @override
  State<_NotifyModeSheet> createState() => _NotifyModeSheetState();
}

class _NotifyModeSheetState extends State<_NotifyModeSheet> {
  late ChatNotifyMode _mode;
  late final Set<String> _selected;
  List<_Person> _people = const [];
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _mode = chatNotifyModeOf(
      muted: widget.chat.muted,
      alwaysNotify: widget.chat.alwaysNotify,
    );
    _selected = decodeNotifyExcept(widget.chat.notifyExcept).toSet();
    if (widget.chat.isGroup) unawaited(_loadPeople());
  }

  Future<void> _loadPeople() async {
    final resolved = resolveChatKey(widget.chatKey);
    final members = await resolved.session.xmpp.roomDisplayMembers(
      resolved.jid,
    );
    if (!mounted) return;
    final mineNick = widget.chat.mucNick.trim();
    final mineJid = resolved.session.account.bareJid.trim().toLowerCase();
    final people = <_Person>[];
    final seen = <String>{};
    for (final occupant in members) {
      final nick = occupant.nick.trim();
      if (nick.isEmpty) continue;
      if (mineNick.isNotEmpty && nick == mineNick) continue;
      final jid = occupant.realJid?.trim();
      if (jid != null && jid.toLowerCase() == mineJid) continue;
      final key = notifyExceptKey(realJid: jid, nick: nick);
      if (!seen.add(key)) continue;
      people.add(_Person(key: key, nick: nick, jid: jid));
    }
    people.sort((a, b) => a.nick.toLowerCase().compareTo(b.nick.toLowerCase()));
    setState(() => _people = people);
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    await widget.db.setChatNotifySettings(
      widget.chat.jid,
      mode: _mode,
      except: widget.chat.isGroup ? _selected.toList() : const [],
    );
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final tg = context.tg;
    final modes = widget.chat.isGroup
        ? ChatNotifyMode.values
        : const [ChatNotifyMode.all, ChatNotifyMode.never];
    final exceptionsOn = _mode != ChatNotifyMode.all;
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Text(
                l10n.notificationSettings,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            for (final mode in modes)
              ListTile(
                leading: Icon(notifyModeIcon(mode)),
                title: Text(notifyModeLabel(l10n, mode)),
                trailing: mode == _mode ? const Icon(Icons.check) : null,
                onTap: _saving ? null : () => setState(() => _mode = mode),
              ),
            if (widget.chat.isGroup) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Text(
                  l10n.notifyStill,
                  style: TextStyle(
                    color: exceptionsOn
                        ? tg.textSecondary
                        : tg.textSecondary.withValues(alpha: 0.38),
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 2, 16, 4),
                child: Text(
                  l10n.notifyStillSummary,
                  style: TextStyle(
                    color: (exceptionsOn
                        ? tg.textSecondary
                        : tg.textSecondary.withValues(alpha: 0.38)),
                    fontSize: 13,
                  ),
                ),
              ),
              IgnorePointer(
                ignoring: !exceptionsOn || _saving,
                child: Opacity(
                  opacity: exceptionsOn ? 1 : 0.38,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 220),
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: _people.length,
                      itemBuilder: (context, i) {
                        final person = _people[i];
                        final on = _selected.contains(person.key);
                        final jid = person.jid;
                        return CheckboxListTile(
                          dense: true,
                          value: on,
                          title: Text(
                            person.nick,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: jid == null || jid == person.nick
                              ? null
                              : Text(
                                  jid,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                          onChanged: (v) {
                            setState(() {
                              if (v == true) {
                                _selected.add(person.key);
                              } else {
                                _selected.remove(person.key);
                              }
                            });
                          },
                        );
                      },
                    ),
                  ),
                ),
              ),
            ],
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
              child: FilledButton(
                onPressed: _saving ? null : () => unawaited(_save()),
                child: Text(l10n.save),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
