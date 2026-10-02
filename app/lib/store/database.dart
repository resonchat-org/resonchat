// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Local persistence (M1: plain SQLite; M5 migrates to SQLCipher +
// Keystore without changing these table shapes).

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:sqlite3/sqlite3.dart' show Database;
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:moxxmpp/moxxmpp.dart' show XmppRosterItem;
import 'package:path/path.dart' as p;
import 'package:resonchat/omemo/track.dart';
import 'package:path_provider/path_provider.dart';

part 'database.g.dart';

/// One conversation (1:1 JID for M1; MUC rooms join at M4/M5).
class Chats extends Table {
  TextColumn get jid => text()();
  TextColumn get title => text().withDefault(const Constant(''))();
  DateTimeColumn get lastActivity =>
      dateTime().withDefault(currentDateAndTime)();

  /// The track the user picked for this conversation, or empty for "use the
  /// global default" (docs/10 §3).
  ///
  /// Deliberately not a foreign key to a settings table: the choice is about
  /// this conversation, and the default is a fallback the row simply does not
  /// override. Null also means "never chosen", which is what keeps a fresh
  /// install on the standard track instead of silently inheriting whatever a
  /// previous conversation was set to.
  TextColumn get trackOverride =>
      text().withDefault(const Constant(''))();

  @override
  Set<Column> get primaryKey => {jid};
}

/// One stored message. Both the ciphertext context (`encMode`) and —
/// unless the user opts out (Q5) — the plaintext are kept so history
/// survives restarts (M1 acceptance).
class Messages extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get chatJid => text().references(Chats, #jid)();
  TextColumn get sender => text()();

  /// Stanza id, used to match XEP-0184 delivery receipts.
  TextColumn get stanzaId => text().withDefault(const Constant(''))();
  TextColumn get body => text()();
  DateTimeColumn get timestamp =>
      dateTime().withDefault(currentDateAndTime)();
  TextColumn get encMode => text().withDefault(const Constant('none'))();
  BoolColumn get incoming => boolean()();

  /// False until a delivery receipt arrives (XEP-0184).
  BoolColumn get delivered => boolean().withDefault(const Constant(false))();

  /// Set when this message came from another of our own devices
  /// (XEP-0280 carbon), so the UI can avoid a duplicate bubble.
  BoolColumn get isCarbon => boolean().withDefault(const Constant(false))();

  /// Why the server refused this message, empty when nothing went wrong.
  ///
  /// A message that comes back as `<message type='error'/>` was never
  /// delivered. Showing it as an ordinary outgoing bubble is a lie: the
  /// usual causes are a server service policy, a non-mutual subscription, or
  /// a blocked account, and each needs a different thing from the user.
  TextColumn get deliveryError =>
      text().withDefault(const Constant(''))();

  /// True once the sender retracted this message for everyone (XEP-0424).
  ///
  /// The body is kept rather than cleared. Clearing it would look identical to
  /// the message having been encrypted and unreadable, and the two need
  /// different words — and it would make "show the message anyway" impossible
  /// for the person who sent it.
  BoolColumn get retracted => boolean().withDefault(const Constant(false))();

  /// When the retraction arrived, for ordering the "deleted" placeholder.
  DateTimeColumn get retractedAt =>
      dateTime().withDefault(currentDateAndTime)();

  /// Set once this message was corrected (XEP-0308).
  ///
  /// Null for an uncorrected message so "edited" is only claimed when it
  /// happened; a boolean defaulting to false cannot tell "not edited" from
  /// "edited and we lost the flag in a migration".
  DateTimeColumn get editedAt => dateTime().nullable()();
}

/// Roster cache + RFC 6121 version, persisted for roster versioning.
class RosterEntries extends Table {
  TextColumn get jid => text()();
  TextColumn get name => text().withDefault(const Constant(''))();
  TextColumn get subscription => text().withDefault(const Constant('none'))();
  TextColumn get ask => text().withDefault(const Constant(''))();
  TextColumn get groups => text().withDefault(const Constant(''))();

  @override
  Set<Column> get primaryKey => {jid};
}

/// A correction whose message has not arrived yet (XEP-0308).
///
/// Order is not ours to choose: a correction can legitimately arrive before
/// the message it corrects — over a slow link, out of two resource
/// connections, or because the original was archived and never loaded. Storing
/// the correction as a message of its own shows the same text twice, once
/// stale and once correct, which is worse than showing nothing for a moment.
///
/// Held by target id and consumed when the message lands.
class PendingCorrections extends Table {
  TextColumn get targetId => text()();

  TextColumn get body => text()();
  TextColumn get encMode => text().withDefault(const Constant('none'))();
  DateTimeColumn get correctedAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {targetId};
}

/// One emoji reaction by one person on one message (XEP-0444).
///
/// Reactions are per-reactor, not per-message: two people reacting with the
/// same emoji is one row each, and the count is the number of rows. Collapsing
/// them into a message-level count would make "who reacted" unrecoverable,
/// which is the only thing that lets someone take their own back.
///
/// [targetId] is the *origin-id* of the message being reacted to (XEP-0359),
/// never the server's stanza id: the two differ once the message has been
/// archived and replayed, and a reaction keyed on the server id stops matching
/// after a MAM import.
class Reactions extends Table {
  TextColumn get targetId => text()();

  /// The emoji. Not an icon or a code point: reactions cross clients, so the
  /// value has to be something both ends render the same way.
  TextColumn get emoji => text()();

  /// Bare JID of the reactor.
  TextColumn get reactor => text()();

  /// When we first saw it; only used for ordering the chip strip.
  DateTimeColumn get reactedAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {targetId, emoji, reactor};
}

/// Single-row table holding the last roster version we saw.
class Meta extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}

@DriftDatabase(
    tables: [
      Chats,
      Messages,
      RosterEntries,
      PendingCorrections,
      Reactions,
      Meta,
    ],
  )
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  @override
  int get schemaVersion => 6;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onUpgrade: (m, from, to) async {
          if (from < 2) {
            // Only additive changes so far; drift still expects an explicit
            // step per version so a future destructive change has a place to
            // go. Raw SQL because addColumn's generic bound is
            // GeneratedColumn<Object> and will not take a TextColumn.
            await customStatement(
              "ALTER TABLE messages ADD COLUMN delivery_error TEXT NOT NULL "
              "DEFAULT ''",
            );
          }
          if (from < 6) {
            await customStatement(
              'CREATE TABLE IF NOT EXISTS pending_corrections ('
              'target_id TEXT NOT NULL PRIMARY KEY, '
              'body TEXT NOT NULL, '
              'enc_mode TEXT NOT NULL DEFAULT \'none\', '
              'corrected_at INTEGER NOT NULL DEFAULT 0)',
            );
          }
          if (from < 5) {
            // XEP-0424 retraction + XEP-0308 correction markers.
            await customStatement(
              'ALTER TABLE messages ADD COLUMN retracted INTEGER NOT NULL '
              'DEFAULT 0',
            );
            await customStatement(
              'ALTER TABLE messages ADD COLUMN retracted_at INTEGER',
            );
            await customStatement(
              'ALTER TABLE messages ADD COLUMN edited_at INTEGER',
            );
          }
          if (from < 4) {
            // XEP-0444 reactions. Created empty and populated from live traffic:
            // reactions are ephemeral by nature and there is nothing to
            // migrate from an earlier build, because none of them existed.
            await customStatement(
              'CREATE TABLE IF NOT EXISTS reactions ('
              'target_id TEXT NOT NULL, '
              'emoji TEXT NOT NULL, '
              'reactor TEXT NOT NULL, '
              'reacted_at INTEGER NOT NULL DEFAULT 0, '
              'PRIMARY KEY (target_id, emoji, reactor))',
            );
            await customStatement(
              'CREATE INDEX IF NOT EXISTS reactions_target '
              'ON reactions (target_id)',
            );
          }
          if (from < 3) {
            // Per-conversation track choice. Empty string means "no override",
            // which is also the right answer for every conversation that
            // existed before this column: nobody had chosen yet.
            //
            // No rewrite of messages.enc_mode here: that column stores what a
            // message *actually used*, which is a fact about the past and does
            // not change because we renamed the vocabulary. The rename lives
            // in EncModeToken.parse, which still understands the old words
            // ('pq', 'standard', ...).
            await customStatement(
              "ALTER TABLE chats ADD COLUMN track_override TEXT NOT NULL "
              "DEFAULT ''",
            );
          }
        },
      );

  /// True when the user has acknowledged, for this conversation, that
  /// plaintext is readable by anyone with server access.
  ///
  /// Remembered per conversation on purpose. Asking on every single message
  /// teaches the user that the warning is a formality, and the moment it
  /// matters — a sensitive message to a contact whose devices all failed —
  /// they will dismiss it without reading. Asking once per conversation, and
  /// never when they chose NO deliberately, is the balance.
  ///
  /// Cleared when the conversation's track changes away from NO, so returning
  /// to plaintext asks again.
  /// Marks the message addressed by [targetId] as retracted for everyone.
  ///
  /// Returns false when no such message is held, which is not an error: a
  /// retraction for a message that arrived out of order, or for one we never
  /// had, has to be a no-op rather than a failure.
  ///
  /// Returns false when no such message is held, which is not an error: a
  /// retraction for a message that arrived out of order, or for one we never
  /// had, has to be a no-op rather than a failure. The sender retracting
  /// something before we received it is ordinary, not exceptional.
  Future<bool> markRetracted(String targetId) async {
    if (targetId.isEmpty) return false;
    // Never un-retract: a second retraction for the same message is a replay,
    // and honouring it would flip the marker back off.
    final changed = await (update(messages)
          ..where((
            m,
          ) =>
              m.stanzaId.equals(targetId) & m.retracted.equals(false)))
        .write(
      MessagesCompanion(
        retracted: const Value(true),
        retractedAt: Value(DateTime.now()),
      ),
    );
    return changed > 0;
  }

  /// Applies a correction (XEP-0308) to the message addressed by [targetId],
  /// inserting it when the original was never seen.
  ///
  /// Both cases are handled here rather than by the caller because they are
  /// the same operation from the store's point of view, and the arrival order
  /// is not ours to choose: a correction can legitimately arrive before the
  /// message it corrects, and whichever way round they land the result must be
  /// one row with the corrected body.
  ///
  /// [encMode] is the track the sender declared, not one we picked. A
  /// correction is a new rendering of their message, and mislabelling its
  /// encryption would be exactly the lie the per-message label exists to
  /// avoid.
  Future<void> applyCorrection({
    required String chatJid,
    required String targetId,
    required String body,
    required String encMode,
  }) async {
    if (targetId.isEmpty) return;
    final now = DateTime.now();
    final updated = await (update(messages)
          ..where((m) => m.stanzaId.equals(targetId)))
        .write(
      MessagesCompanion(
        body: Value(body),
        editedAt: Value(now),
        // Kept in step with a correction of a retracted message: the sender
        // un-deleted it by correcting it, and a placeholder that outlives its
        // message is the wrong history.
        retracted: const Value(false),
      ),
    );
    if (updated > 0) {
      await upsertChat(chatJid);
      return;
    }
    // Never seen the original. Held until it arrives, and applied by
    // insertMessage so the two can land in either order. Storing it as a
    // message of its own would show the same text twice — once stale, once
    // correct — which is worse than showing nothing for a moment.
    await into(pendingCorrections).insertOnConflictUpdate(
      PendingCorrectionsCompanion.insert(
        targetId: targetId,
        body: body,
        encMode: Value(encMode),
        correctedAt: Value(now),
      ),
    );
  }

  /// The correction waiting for [targetId], or null.
  ///
  /// Exposed because the failure worth testing for is a held correction being
  /// silently dropped, which leaves a permanently stale message on screen.
  Future<PendingCorrection?> pendingCorrection(String targetId) =>
      (select(pendingCorrections)
            ..where((p) => p.targetId.equals(targetId)))
          .getSingleOrNull();

  /// Drops a held correction, once it has been applied.
  Future<void> clearPendingCorrection(String targetId) async {
    await (delete(pendingCorrections)
          ..where((p) => p.targetId.equals(targetId)))
        .go();
  }

  /// Records one reactor's full set of emojis on [targetId].
  ///
  /// A reaction broadcast is the *complete* list from that reactor, not a
  /// delta — replacing the set rather than merging is what makes "I took my
  /// reaction back" work. Merging would leave the old row behind forever and
  /// the sender would keep showing a reaction its owner withdrew.
  Future<void> setReactions({
    required String targetId,
    required String reactor,
    required List<String> emojis,
  }) async {
    await transaction(() async {
      await (delete(reactions)
            ..where((r) =>
                r.targetId.equals(targetId) & r.reactor.equals(reactor)))
          .go();
      // Two identical rows in one broadcast are a client bug or a replayed
      // stanza; the primary key would throw, and one emoji is what it means.
      for (final emoji in emojis.toSet()) {
        await into(reactions).insert(
          ReactionsCompanion.insert(
            targetId: targetId,
            emoji: emoji,
            reactor: reactor,
            // Passed explicitly because the ordering below depends on it, and
            // a column with a SQL default is not filled in on insert.
            reactedAt: Value(DateTime.now()),
          ),
          mode: InsertMode.insertOrIgnore,
        );
      }
    });
  }

  /// One emoji's reactors, grouped for display.
  ///
  /// Sorted by count so the common reaction leads, which is the order every
  /// other client uses and the one a user reads fastest.
  Future<List<({String emoji, Set<String> reactors, bool mine})>> reactionGroups(
    String targetId, {
    required String myJid,
  }) async {
    final rows = await (select(reactions)
          ..where((r) => r.targetId.equals(targetId))
          ..orderBy([(r) => OrderingTerm.desc(r.reactedAt)]))
        .get();
    final byEmoji = <String, Set<String>>{};
    final mine = <String>{};
    for (final row in rows) {
      (byEmoji[row.emoji] ??= {}).add(row.reactor);
      if (row.reactor == myJid) mine.add(row.emoji);
    }
    final groups = byEmoji.entries
        .map(
          (e) => (
            emoji: e.key,
            reactors: e.value,
            mine: mine.contains(e.key),
          ),
        )
        .toList();
    groups.sort((a, b) {
      final byCount = b.reactors.length.compareTo(a.reactors.length);
      // Ties break on the emoji itself so the order is stable across rebuilds
      // rather than depending on which reaction arrived first.
      return byCount != 0 ? byCount : a.emoji.compareTo(b.emoji);
    });
    return groups;
  }

  /// Every reaction on [targetId], for storage tests and diagnostics.
  Future<List<Reaction>> allReactions(String targetId) =>
      (select(reactions)..where((r) => r.targetId.equals(targetId))).get();

  Future<bool> plaintextAcknowledged(String chatJid) async {
    final value = await metaValue('plaintext_ack:$chatJid');
    return value == '1';
  }

  Future<void> acknowledgePlaintext(String chatJid) async {
    await setMetaValue('plaintext_ack:$chatJid', '1');
  }

  Future<void> clearPlaintextAcknowledgement(String chatJid) async {
    await deleteMetaValue('plaintext_ack:$chatJid');
  }

  /// The track the user chose for [chatJid], or null to use the global
  /// default.
  Future<Track?> trackOverride(String chatJid) async {
    final row = (await (select(chats)..where((c) => c.jid.equals(chatJid)))
            .getSingleOrNull())
        ?.trackOverride;
    if (row == null || row.isEmpty) return null;
    return Track.fromStored(row);
  }

  /// Pins [chatJid] to [track], or clears the override when [track] is null.
  Future<void> setTrackOverride(String chatJid, Track? track) async {
    final value = track?.stored ?? '';
    final updated = await (update(chats)..where((c) => c.jid.equals(chatJid)))
        .write(ChatsCompanion(trackOverride: Value(value)));
    if (updated == 0) {
      // A conversation the user picked a track for before any message was
      // exchanged has no row yet. Creating it here keeps "the override is
      // set" independent of "a chat exists", which is what the settings UI
      // assumes.
      await into(chats).insert(
        ChatsCompanion(jid: Value(chatJid), trackOverride: Value(value)),
        mode: InsertMode.insertOrIgnore,
      );
      await (update(chats)..where((c) => c.jid.equals(chatJid)))
          .write(ChatsCompanion(trackOverride: Value(value)));
    }
  }

  Future<List<RosterEntry>> allRosterEntries() =>
      (select(rosterEntries)).get();

  /// Records that the server refused the message sent with [stanzaId].
  ///
  /// Returns true when a row was updated, so a caller can tell whether the
  /// failure belonged to a message it still holds.
  Future<bool> markDeliveryFailure(String stanzaId, String reason) async {
    if (stanzaId.isEmpty) return false;
    final changed = await (update(messages)
          ..where((m) => m.stanzaId.equals(stanzaId)))
        .write(MessagesCompanion(deliveryError: Value(reason)));
    return changed > 0;
  }

  /// One contact's subscription state, for the "will this be delivered?"
  /// hint.
  Future<RosterEntry?> rosterEntry(String jid) =>
      (select(rosterEntries)..where((r) => r.jid.equals(jid)))
          .getSingleOrNull();

  Future<String?> metaValue(String key) async {
    final row = await (select(meta)..where((m) => m.key.equals(key)))
        .getSingleOrNull();
    return row?.value;
  }

  Future<void> setMetaValue(String key, String value) async {
    await into(meta).insertOnConflictUpdate(
      MetaCompanion(key: Value(key), value: Value(value)),
    );
  }

  Future<void> deleteMetaValue(String key) async {
    await (delete(meta)..where((m) => m.key.equals(key))).go();
  }

  Future<String?> rosterVersion() async {
    final row = await (select(meta)
          ..where((m) => m.key.equals('roster_version')))
        .getSingleOrNull();
    return row?.value;
  }

  /// Applies one roster commit (fetch result or push) atomically.
  Future<void> commitRoster({
    required String? version,
    required List<String> removed,
    required List<XmppRosterItem> modified,
    required List<XmppRosterItem> added,
  }) async {
    await transaction(() async {
      if (removed.isNotEmpty) {
        await (delete(rosterEntries)
              ..where((r) => r.jid.isIn(removed)))
            .go();
      }
      for (final item in [...modified, ...added]) {
        await into(rosterEntries).insertOnConflictUpdate(
          RosterEntriesCompanion(
            jid: Value(item.jid),
            name: Value(item.name ?? ''),
            subscription: Value(item.subscription),
            ask: Value(item.ask ?? ''),
            groups: Value(item.groups.join(',')),
          ),
        );
      }
      if (version != null) {
        await into(meta).insertOnConflictUpdate(
          MetaCompanion(
            key: const Value('roster_version'),
            value: Value(version),
          ),
        );
      }
    });
  }

  /// Chat list, newest activity first. `jid` breaks ties because drift
  /// stores DateTime at second precision.
  Stream<List<Chat>> watchChats() => (select(chats)
        ..orderBy([
          (c) => OrderingTerm.desc(c.lastActivity),
          (c) => OrderingTerm.asc(c.jid),
        ]))
      .watch();

  /// Messages in conversation order. `timestamp` first (so imported
  /// history sorts correctly), then `id` as the insertion-order
  /// tiebreaker for same-second messages.
  Stream<List<Message>> watchMessages(String chatJid) =>
      (select(messages)
            ..where((m) => m.chatJid.equals(chatJid))
            ..orderBy([
              (m) => OrderingTerm.asc(m.timestamp),
              (m) => OrderingTerm.asc(m.id),
            ]))
          .watch();

  /// Creates or updates a chat row. [at] overrides the activity timestamp
  /// (tests and MAM imports need deterministic ordering).
  Future<void> upsertChat(
    String jid, {
    String? title,
    DateTime? at,
  }) async {
    await into(chats).insertOnConflictUpdate(
      ChatsCompanion(
        jid: Value(jid),
        title: Value(title ?? jid),
        lastActivity: Value(at ?? DateTime.now()),
      ),
    );
  }

  Future<void> insertMessage(MessagesCompanion message) async {
    await transaction(() async {
      // A correction that arrived before its message is applied here rather
      // than stored as a message of its own: showing the same text twice — once
      // stale, once correct — is worse than showing nothing for a moment.
      final targetId = message.stanzaId.present
          ? message.stanzaId.value
          : '';
      PendingCorrection? pending;
      if (targetId.isNotEmpty) {
        pending = await pendingCorrection(targetId);
      }
      final effective = pending == null
          ? message
          : message.copyWith(
              body: Value(pending.body),
              editedAt: Value(pending.correctedAt),
              // The sender's declaration wins over the archive's: an archived
              // copy carries no EME, and reporting "no encryption" for a
              // message we were told was encrypted is the lie the label rule
              // exists to prevent.
              encMode: Value(pending.encMode),
              retracted: const Value(false),
            );

      await into(messages).insert(effective);
      if (pending != null) await clearPendingCorrection(targetId);
      // Bump the chat's activity only when the message is newer than what
      // we already recorded (importing old history must not regress it).
      final ts = message.timestamp.present
          ? message.timestamp.value
          : DateTime.now();
      await (update(chats)
            ..where((c) =>
                c.jid.equals(message.chatJid.value) &
                c.lastActivity.isSmallerThanValue(ts)))
          .write(ChatsCompanion(lastActivity: Value(ts)));
    });
  }

  /// Removes every stored message of one conversation from this device.
  ///
  /// The server is untouched: the other side keeps its copy, and archived
  /// messages will come back on the next MAM fetch. That distinction is why
  /// the UI words this as "clear history on this device".
  Future<int> clearChatMessages(String chatJid) =>
      (delete(messages)..where((m) => m.chatJid.equals(chatJid))).go();

  /// Marks one of our outgoing messages as delivered (XEP-0184).
  /// Returns the number of rows updated (0 when the id is unknown).
  Future<int> markDelivered(String chatJid, String stanzaId) {
    return (update(messages)
          ..where((m) =>
              m.chatJid.equals(chatJid) &
              m.stanzaId.equals(stanzaId) &
              m.incoming.equals(false)))
        .write(const MessagesCompanion(delivered: Value(true)));
  }

  /// Preview line for the chat list: the newest message body, prefixed
  /// with the sender when it did not come from us.
  Stream<String?> watchLastMessage(String chatJid) {
    final query = select(messages)
      ..where((m) => m.chatJid.equals(chatJid))
      ..orderBy([
        (m) => OrderingTerm.desc(m.timestamp),
        (m) => OrderingTerm.desc(m.id),
      ])
      ..limit(1);
    return query.watchSingleOrNull().map((row) {
      if (row == null) return null;
      if (row.encMode == 'error') return 'Unable to decrypt';
      final prefix = row.incoming ? '' : 'You: ';
      return '$prefix${row.body}';
    });
  }

  /// Finds an already-stored inbound message by its stanza id, so that a
  /// second copy (e.g. carbon + direct delivery) is not duplicated.
  Future<int?> findByStanzaId(String chatJid, String stanzaId) async {
    if (stanzaId.isEmpty) return null;
    final row = await (select(messages)
          ..where((m) =>
              m.chatJid.equals(chatJid) & m.stanzaId.equals(stanzaId))
          ..limit(1))
        .getSingleOrNull();
    return row?.id;
  }
}

/// Opens the database, encrypted with SQLCipher when the native library is
/// available.
///
/// The passphrase lives in the platform keystore and is generated on first
/// run. Losing it makes the file unreadable, which is the intended
/// behaviour: a rooted device must not be able to read messages.
///
/// Falls back to plain SQLite (with a warning) when SQLCipher is missing,
/// so development on desktop keeps working.
Future<AppDatabase> openAppDatabase() async {
  final dir = await getApplicationDocumentsDirectory();
  final file = File(p.join(dir.path, 'resonchat.sqlite3'));

  final passphrase = await _databasePassphrase();
  if (passphrase != null) {
    try {
      // `package:sqlite3` ships a SQLCipher build selected via the
      // `hooks.user_defines` entry in pubspec.yaml. Applying the key
      // pragma is all that is needed; reading with the wrong key fails,
      // which the probe below turns into a clean fallback.
      void applyKey(Database db) {
        db.execute("PRAGMA key = \"x'${_hex(passphrase)}'\";");
        db.select('SELECT count(*) FROM sqlite_master;');
      }

      final native = NativeDatabase.createInBackground(
        file,
        setup: applyKey,
      );
      final probe = AppDatabase(native);
      await probe.customSelect('SELECT count(*) FROM sqlite_master').get();
      await probe.close();
      return AppDatabase(
        NativeDatabase.createInBackground(file, setup: applyKey),
      );
    } catch (e) {
      debugPrint('SQLCipher unavailable, falling back to plain SQLite: $e');
    }
  }

  return AppDatabase(NativeDatabase.createInBackground(file));
}

/// Lowercase hex of [bytes], for the `PRAGMA key` literal syntax.
String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// Reads (or creates) the database passphrase from the platform keystore.
Future<List<int>?> _databasePassphrase() async {
  const key = 'resonchat.database.passphrase';
  try {
    const storage = FlutterSecureStorage();
    final existing = await storage.read(key: key);
    if (existing != null) return base64Decode(existing);
    final fresh = <int>[for (var i = 0; i < 32; i++) _rng.nextInt(256)];
    await storage.write(key: key, value: base64Encode(fresh));
    return fresh;
  } catch (e) {
    debugPrint('keystore unavailable for the database key: $e');
    return null;
  }
}

final Random _rng = Random.secure();
