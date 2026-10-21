// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Ordered auto-reply rules. The first regular expression that matches an
// incoming 1:1 body wins, and that rule's reply is sent on the chat's track.

import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:logging/logging.dart';
import 'package:moxxmpp/moxxmpp.dart' show JID;

import 'package:resonchat/account/account_hub.dart';
import 'package:resonchat/crypto/dual/track.dart';
import 'package:resonchat/persistence/database.dart';
import 'package:resonchat/persistence/prefs_database.dart';
import 'package:resonchat/xmpp/connection.dart';
import 'package:resonchat/xmpp/message_send_status.dart';

const autoReplyPrefKey = 'pref_auto_reply';

/// Weighted length of a reply. A Han character counts as two.
const autoReplyMaxChars = 500;

/// A later message is answered only when it arrives strictly after this gap.
const autoReplyMinGap = Duration(seconds: 1);

final _hanChar = RegExp(r'[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]');

/// Every character counts as one, and each Han character counts as two.
int autoReplyChars(String text) {
  var count = 0;
  for (final rune in text.runes) {
    final ch = String.fromCharCodes([rune]);
    count += _hanChar.hasMatch(ch) ? 2 : 1;
  }
  return count;
}

bool autoReplyWithinLimit(String reply) =>
    autoReplyChars(reply) <= autoReplyMaxChars;

/// Arrival times of live messages, per chat. A burst closer than
/// [autoReplyMinGap] keeps only the first message.
class AutoReplyBurst {
  final Map<String, DateTime> _last = {};

  /// Records [at] and reports whether it is too close to the previous
  /// arrival in [chatJid]. Equal to [autoReplyMinGap] still counts as too soon.
  bool tooSoon(String chatJid, DateTime at) {
    final previous = _last[chatJid];
    _last[chatJid] = at;
    if (previous == null) return false;
    final gap = at.difference(previous);
    if (gap.isNegative) return false;
    return gap <= autoReplyMinGap;
  }
}

/// One rule. List order is match order: the first hit replies.
class AutoReplyRule {
  const AutoReplyRule({
    required this.id,
    required this.pattern,
    required this.reply,
  });

  final String id;
  final String pattern;
  final String reply;

  Map<String, String> toJson() => {
    'id': id,
    'pattern': pattern,
    'reply': reply,
  };

  static AutoReplyRule? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final pattern = raw['pattern'];
    final reply = raw['reply'];
    if (id is! String || pattern is! String || reply is! String) return null;
    if (id.isEmpty) return null;
    return AutoReplyRule(id: id, pattern: pattern, reply: reply);
  }
}

class AutoReplyConfig {
  const AutoReplyConfig({required this.enabled, required this.rules});

  final bool enabled;
  final List<AutoReplyRule> rules;

  static const empty = AutoReplyConfig(enabled: false, rules: []);

  Map<String, Object> toJson() => {
    'enabled': enabled,
    'rules': [for (final rule in rules) rule.toJson()],
  };
}

/// False for a blank pattern or one Dart cannot compile.
bool isAutoReplyPatternValid(String pattern) {
  if (pattern.isEmpty) return false;
  try {
    RegExp(pattern);
    return true;
  } on FormatException {
    return false;
  }
}

/// First rule whose pattern matches [body], or null.
///
/// Disabled configs, blank replies, and patterns that do not compile are
/// skipped. An empty pattern is not treated as "match everything".
AutoReplyRule? matchAutoReply(AutoReplyConfig config, String body) {
  if (!config.enabled || body.isEmpty) return null;
  for (final rule in config.rules) {
    final reply = rule.reply.trim();
    if (reply.isEmpty ||
        !autoReplyWithinLimit(reply) ||
        !isAutoReplyPatternValid(rule.pattern)) {
      continue;
    }
    if (RegExp(rule.pattern).hasMatch(body)) return rule;
  }
  return null;
}

Future<AutoReplyConfig> loadAutoReply([PrefsDatabase? prefs]) async {
  final raw = await (prefs ?? appPrefs).getString(autoReplyPrefKey);
  if (raw == null || raw.isEmpty) return AutoReplyConfig.empty;
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return AutoReplyConfig.empty;
    final enabled = decoded['enabled'] == true;
    final rules = <AutoReplyRule>[];
    final list = decoded['rules'];
    if (list is List) {
      for (final item in list) {
        final rule = AutoReplyRule.fromJson(item);
        if (rule != null) rules.add(rule);
      }
    }
    return AutoReplyConfig(enabled: enabled, rules: rules);
  } catch (_) {
    return AutoReplyConfig.empty;
  }
}

Future<void> saveAutoReply(AutoReplyConfig config, {PrefsDatabase? prefs}) {
  return (prefs ?? appPrefs).setString(
    autoReplyPrefKey,
    jsonEncode(config.toJson()),
  );
}

final _log = Logger('AutoReply');

/// Stanza ids we already answered, so a duplicate delivery does not reply twice.
final _answered = <String>{};

final _burst = AutoReplyBurst();

/// Sends the first matching reply for a live 1:1 message.
///
/// Groups, archive catch-up, carbons, and messages we could not decrypt are
/// left alone. The reply uses the conversation's track, then the global
/// default, and is not silently rewritten to plaintext when that track refuses.
Future<void> maybeSendAutoReply({
  required AccountSession session,
  required InboundMessage msg,
  required String chatJid,
  required bool isGroup,
  String? ownBare,
}) async {
  if (msg.fromArchive || msg.isCarbonCopy) return;
  if (msg.encryptionError != null) return;
  if (msg.reactions != null || msg.retracts != null || msg.corrects != null) {
    return;
  }
  if (isGroup || msg.type == 'groupchat') return;
  if (ownBare != null && msg.from.toBare().toString() == ownBare) return;
  if (session.xmpp.blockedJids.contains(chatJid)) return;

  final body = msg.body.trim();
  if (body.isEmpty) return;
  if (_burst.tooSoon(chatJid, DateTime.now())) return;

  final dedupe = msg.stanzaId ?? msg.originId;
  if (dedupe != null && dedupe.isNotEmpty) {
    final key = '$chatJid|$dedupe';
    if (_answered.contains(key)) return;
    _answered.add(key);
    if (_answered.length > 200) _answered.remove(_answered.first);
  }

  final config = await loadAutoReply();
  final rule = matchAutoReply(config, body);
  if (rule == null) return;
  final reply = rule.reply.trim();
  // An echo of our own reply must not start a loop.
  if (reply.isEmpty || reply == body) return;

  final xmpp = session.xmpp;
  final override = await session.db.trackOverride(chatJid);
  final global = Track.fromStored(
    await appPrefs.getString('global_track') ?? '',
  );
  final track = override ?? global ?? Track.standard;
  final stanzaId = xmpp.allocateStanzaId();
  await session.messages.insertMessage(
    MessagesCompanion(
      chatJid: Value(chatJid),
      sender: const Value('me'),
      stanzaId: Value(stanzaId),
      body: Value(reply),
      timestamp: Value(DateTime.now()),
      encMode: Value(EncModeToken.of(track).wire),
      incoming: const Value(false),
      sendStatus: const Value(MessageSendStatus.waiting),
    ),
  );
  try {
    final outcome = await xmpp.sendOnTrack(
      JID.fromString(chatJid),
      reply,
      track: track,
      originId: stanzaId,
    );
    await session.db.updateSendStatus(
      chatJid,
      stanzaId,
      outcome.sent ? MessageSendStatus.send : MessageSendStatus.sendFailed,
    );
  } catch (e, st) {
    _log.warning('auto-reply to $chatJid failed', e, st);
    await session.db.updateSendStatus(
      chatJid,
      stanzaId,
      MessageSendStatus.sendFailed,
    );
  }
}
