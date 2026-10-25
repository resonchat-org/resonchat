// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Local persistence. Schema + queries are shared; the executor is swapped:
//   native → SQLCipher / SQLite file (`database_connection_io.dart`)
//   web    → sqlite3.wasm over OPFS / IndexedDB (`database_connection_web.dart`)

import 'package:drift/drift.dart';

import 'package:resonchat/crypto/dual/track.dart';
import 'package:resonchat/persistence/database_connection.dart';
import 'package:resonchat/xmpp/chat/sticker_link.dart';
import 'package:resonchat/xmpp/chat_notify_mode.dart';
import 'package:resonchat/xmpp/group_read.dart';
import 'package:resonchat/xmpp/message_send_status.dart';

part 'database.g.dart';

/// [Chats.lastActivity] when a conversation has no messages.
///
/// Sorts empty chats to the bottom of the list. Must not be "now" — roster
/// sync and cold start used to stamp login time onto every contact.
final DateTime chatActivityEpoch = DateTime.fromMillisecondsSinceEpoch(0);

/// One conversation: a 1:1 contact or a MUC room (Conversations MODE_MULTI).
///
/// Rooms are **not** roster contacts. [isGroup] + [mucNick] are what distinguish
/// them: subscription/PEP/1:1 OMEMO capability checks must not run against a
/// room bare JID.
class Chats extends Table {
  TextColumn get jid => text()();
  TextColumn get title => text().withDefault(const Constant(''))();
  DateTimeColumn get lastActivity =>
      dateTime().withDefault(currentDateAndTime)();

  /// Serialised [ChatAppearance] for this conversation, or empty for the
  /// default.
  ///
  /// Per conversation rather than global, because that is the setting people
  /// actually use: one person whose bubbles you want to tell apart at a glance.
  /// A single global setting would be a settings screen with nothing in it.
  TextColumn get appearance => text().withDefault(const Constant(''))();

  /// Pinned to the top of the chat list.
  BoolColumn get pinned => boolean().withDefault(const Constant(false))();

  /// Conversations "notify never": no shade entry, even for highlights.
  ///
  /// Combined with [alwaysNotify] for groups (see [ChatNotifyMode]). A local
  /// decision — there is no standard way to tell a server to suppress pushes
  /// for one conversation.
  BoolColumn get muted => boolean().withDefault(const Constant(false))();

  /// Conversations `alwaysNotify`. When false (and not [muted]), only nick
  /// highlights / MUC PMs alert. Ignored for 1:1 (use [muted] alone).
  BoolColumn get alwaysNotify => boolean().withDefault(const Constant(true))();

  /// JSON list of bare JIDs or `nick:` keys who still notify while this
  /// group is silenced. Empty for 1:1 and when nobody is excepted.
  TextColumn get notifyExcept => text().withDefault(const Constant('[]'))();

  /// Moved out of the main list into the archive.
  BoolColumn get archived => boolean().withDefault(const Constant(false))();

  /// Unread inbound messages.
  ///
  /// Counted rather than derived, because "unread" has to survive the app
  /// being closed: deriving it from the message table means every launch
  /// re-reads the whole transcript to work out what was already read.
  IntColumn get unreadCount => integer().withDefault(const Constant(0))();

  /// Unread messages that highlighted us (nick / MUC PM).
  ///
  /// Separate from [unreadCount] the way Telegram keeps
  /// `unread_mentions_count`: the chat list can show an `@` badge beside
  /// the ordinary unread pill.
  IntColumn get unreadMentions => integer().withDefault(const Constant(0))();

  /// Where the reader had got to, so a jump lands in the right place.
  DateTimeColumn get lastReadAt => dateTime().withDefault(currentDateAndTime)();

  /// The track the user picked for this conversation, or empty for "use the
  /// global default" (docs/10 §3).
  ///
  /// Deliberately not a foreign key to a settings table: the choice is about
  /// this conversation, and the default is a fallback the row simply does not
  /// override. Null also means "never chosen", which is what keeps a fresh
  /// install on the standard track instead of silently inheriting whatever a
  /// previous conversation was set to.
  TextColumn get trackOverride => text().withDefault(const Constant(''))();

  /// True for XEP-0045 rooms (Conversations `MODE_MULTI`).
  ///
  /// Stored rather than inferred from the JID: a bare `room@conference`
  /// and a contact share the same address shape, and guessing from
  /// `conference.` in the domain is how rooms get treated as contacts.
  BoolColumn get isGroup => boolean().withDefault(const Constant(false))();

  /// Our nickname in this room when [isGroup], empty for 1:1.
  ///
  /// Property of the join (Conversations bookmark nick / MucOptions), not of
  /// the room address. Empty means we have not joined yet / left without a
  /// nick to rejoin with.
  TextColumn get mucNick => text().withDefault(const Constant(''))();

  /// Conversations `isPrivateAndNonAnonymous` — only these rooms may use OMEMO.
  ///
  /// From disco `muc_membersonly` + `muc_nonanonymous`. Public / anonymous
  /// rooms stay plaintext groupchat.
  BoolColumn get mucPrivateNonAnonymous =>
      boolean().withDefault(const Constant(false))();

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
  ///
  /// For messages we sent this is the origin-id, which is also the message
  /// `id`. Reactions and edits address that. A group retraction addresses
  /// [roomStanzaId] instead.
  TextColumn get stanzaId => text().withDefault(const Constant(''))();

  /// Stanza-id the room assigned (XEP-0359), empty outside a group chat.
  ///
  /// XEP-0424 retracts a group message by this id, not by the sender's
  /// origin-id.
  TextColumn get roomStanzaId => text().withDefault(const Constant(''))();
  TextColumn get body => text()();
  DateTimeColumn get timestamp => dateTime().withDefault(currentDateAndTime)();
  TextColumn get encMode => text().withDefault(const Constant('none'))();
  BoolColumn get incoming => boolean()();

  /// False until a delivery receipt arrives (XEP-0184).
  ///
  /// Kept in sync with [sendStatus] for older call sites; prefer [sendStatus].
  BoolColumn get delivered => boolean().withDefault(const Constant(false))();

  /// True once a chat marker `<displayed/>` arrives (XEP-0333) — read.
  ///
  /// Kept in sync with [sendStatus] for older call sites; prefer [sendStatus].
  /// One-to-one only. A private non-anonymous room records each reader in
  /// [readBy] instead of flipping this for the first person who reads.
  BoolColumn get displayed => boolean().withDefault(const Constant(false))();

  /// Bare real JIDs that sent `<displayed/>` for this message, JSON array.
  ///
  /// Used in private non-anonymous rooms (Conversations `ReadByMarker`).
  /// Empty for 1:1, where [displayed] is the whole answer.
  TextColumn get readBy => text().withDefault(const Constant('[]'))();

  /// Conversations `Message.status` ([MessageSendStatus]).
  ///
  /// Outgoing rows start as [MessageSendStatus.waiting] / `.unsend` when the
  /// user hits send — including when the socket is down — and only move to
  /// `.sendReceived` once a receipt or MUC reflection confirms them.
  IntColumn get sendStatus => integer().withDefault(const Constant(0))();

  /// True when the sender attached `<markable/>` (XEP-0333).
  ///
  /// Conversations only sends a displayed marker for markable messages.
  BoolColumn get markable => boolean().withDefault(const Constant(false))();

  /// Set when this message came from another of our own devices
  /// (XEP-0280 carbon), so the UI can avoid a duplicate bubble.
  BoolColumn get isCarbon => boolean().withDefault(const Constant(false))();

  /// Why the server refused this message, empty when nothing went wrong.
  ///
  /// A message that comes back as `<message type='error'/>` was never
  /// delivered. Showing it as an ordinary outgoing bubble is a lie: the
  /// usual causes are a server service policy, a non-mutual subscription, or
  /// a blocked account, and each needs a different thing from the user.
  TextColumn get deliveryError => text().withDefault(const Constant(''))();

  /// True once the sender retracted this message for everyone (XEP-0424).
  ///
  /// The body is kept rather than cleared. Clearing it would look identical to
  /// the message having been encrypted and unreadable, and the two need
  /// different words — and it would make "show the message anyway" impossible
  /// for the person who sent it.
  BoolColumn get retracted => boolean().withDefault(const Constant(false))();

  /// When the retraction arrived.
  ///
  /// Nullable with no default, deliberately: a SQL default would fill this on
  /// every row, so `retractedAt != null` would be true of every message and the
  /// column could not answer the only question anyone asks of it. This is the
  /// same reasoning as [editedAt] below.
  DateTimeColumn get retractedAt => dateTime().nullable()();

  /// Who retracted it, when that person is not the sender.
  ///
  /// Empty for a self-retraction (XEP-0424). A moderator's room nick
  /// (XEP-0425) when someone else retracted the message.
  TextColumn get retractedBy => text().withDefault(const Constant(''))();

  /// Why a moderator retracted it (XEP-0425).
  ///
  /// Empty when they gave no reason, and empty for a self-retraction. The
  /// transcript omits the reason clause in that case.
  TextColumn get retractedReason => text().withDefault(const Constant(''))();

  /// Origin-id of the message this one replies to (XEP-0461), or empty.
  TextColumn get replyTo => text().withDefault(const Constant(''))();

  /// The quoted text, copied into this row.
  ///
  /// Denormalised on purpose. A quote is only useful if it still reads
  /// correctly after the quoted message is deleted, retracted, or simply never
  /// loaded — and the quoted message is the thing most likely to disappear,
  /// since retracting it is a normal thing to do. Re-reading it from the target
  /// row means a reply turns into an empty quote the moment its target goes.
  TextColumn get replyBody => text().withDefault(const Constant(''))();

  /// Nickname of the quoted message's author, for the same reason.
  TextColumn get replyAuthor => text().withDefault(const Constant(''))();

  /// Set once this message was corrected (XEP-0308).
  ///
  /// Null for an uncorrected message so "edited" is only claimed when it
  /// happened; a boolean defaulting to false cannot tell "not edited" from
  /// "edited and we lost the flag in a migration".
  DateTimeColumn get editedAt => dateTime().nullable()();

  /// HTTP File Upload / OOB share URL (`https://…` or `aesgcm://…#iv+key`).
  ///
  /// Empty when the message is plain text. The body usually repeats this URL
  /// (Conversations), so the column exists so the UI can treat file messages
  /// without re-parsing every body.
  TextColumn get mediaUrl => text().withDefault(const Constant(''))();

  /// Declared MIME type when known (upload Content-Type / sniff), else empty.
  TextColumn get mediaMime => text().withDefault(const Constant(''))();

  /// Original file name when known, else empty.
  TextColumn get mediaName => text().withDefault(const Constant(''))();

  /// Absolute path of a downloaded/cached copy on this device, else empty.
  TextColumn get localPath => text().withDefault(const Constant(''))();

  /// True when this inbound group message highlighted us (nick match or MUC PM).
  ///
  /// Stored at insert time (Conversations detects at paint; Telegram stores
  /// `mentioned` on the message). Persistence means the bubble still marks
  /// the mention after a nick change, and the chat-list `@` badge can count
  /// without re-parsing every body.
  BoolColumn get mentionsMe => boolean().withDefault(const Constant(false))();
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

/// One JID the user has blocked (XEP-0191).
///
/// Blocked on the server, so it is a *push* list rather than a local flag:
/// another of our own devices blocking someone has to take effect here too, and
/// a local flag would give the user the protection on one device and not the
/// other.
///
/// The server enforces nothing on our behalf — it still routes messages. What
/// blocking buys is that *we* stop acting as a reader and a signer for them,
/// which is the part that actually matters for a messenger.
class BlockedContacts extends Table {
  TextColumn get jid => text()();
  DateTimeColumn get blockedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {jid};
}

/// A subscription request awaiting a decision.
///
/// Both directions in one table, distinguished by [outgoing]: "somebody wants
/// to see my presence" and "I am waiting for somebody to let me see theirs" are
/// the same kind of row with opposite answers, and keeping them together means
/// the list screen can show both without two queries that might disagree.
class SubscriptionRequests extends Table {
  TextColumn get jid => text()();

  /// False for a request from somebody, true for one we sent.
  BoolColumn get outgoing => boolean().withDefault(const Constant(false))();

  DateTimeColumn get askedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {jid, outgoing};
}

/// A MUC invitation awaiting accept / decline (XEP-0045 / XEP-0249).
///
/// Separate from [SubscriptionRequests]: a room invite is not a presence
/// subscription, and the pending-requests screen needs both lists without
/// overloading one row type.
class RoomInvitations extends Table {
  /// Bare room JID.
  TextColumn get roomJid => text()();

  /// Inviter bare JID when known.
  TextColumn get fromJid => text().withDefault(const Constant(''))();

  TextColumn get password => text().withDefault(const Constant(''))();
  TextColumn get reason => text().withDefault(const Constant(''))();

  DateTimeColumn get invitedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {roomJid};
}

/// One message the user pinned inside a conversation.
///
/// Pinned client-side: there is no standard way to tell a server "this message
/// is the important one in this chat", and inventing one that only this app
/// understands would make the feature invisible to every other client on the
/// conversation.
class PinnedMessages extends Table {
  TextColumn get chatJid => text()();
  TextColumn get stanzaId => text()();

  /// Highest first in the UI, so the most recently pinned is the one found.
  DateTimeColumn get pinnedAt => dateTime().withDefault(currentDateAndTime)();

  /// Tiebreaker for [pinnedAt], descending.
  ///
  /// Not decoration: drift stores a DateTime at second precision, so two pins
  /// made within the same second have an identical timestamp and the order
  /// between them is whatever the query planner happens to produce. A user who
  /// pins two messages quickly would find the list reordering itself between
  /// opens.
  IntColumn get sequence => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {chatJid, stanzaId};
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
  DateTimeColumn get reactedAt => dateTime().withDefault(currentDateAndTime)();

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

/// Persisted peer / own-other OMEMO identities (monocles `identities`).
///
/// One row per (bare JID, fingerprint). Trust and active/inactive live here so
/// the security UI and encrypt path do not depend on a live PEP fetch. Device
/// list sync flips [active]; missing from the announced list → inactive, never
/// deleted (so the user can still see and distrust old keys).
///
/// Not sealed private material — public fingerprint + local trust decision —
/// so it belongs in the account DB rather than the keystore blob.
class OmemoIdentities extends Table {
  /// Bare JID that published this identity key.
  TextColumn get bareJid => text()();

  /// Lowercase hex fingerprint without whitespace (classic IK or hybrid OMEMO2).
  TextColumn get fingerprint => text()();

  /// PEP device id last associated with this fingerprint.
  IntColumn get deviceId => integer()();

  /// True for the PQ OMEMO2 stack; false for legacy A-track.
  BoolColumn get omemo2 => boolean()();

  /// Gajim trust wire: `untrusted` / `undecided` / `blind` / `verified`
  /// (legacy `trusted` is rewritten to `blind` on read).
  TextColumn get trust => text()();

  /// Currently present on the peer's announced device list for this stack.
  BoolColumn get active => boolean()();

  /// Epoch ms when this row last transitioned inactive → active; 0 if never.
  IntColumn get lastActivation => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {bareJid, fingerprint};
}

/// One saved sticker image for this account.
///
/// The picture is the collection. The three links are filled only after this
/// account sends the sticker on that mode. Saving from a message stores the
/// bytes and leaves every link empty.
class Stickers extends Table {
  IntColumn get id => integer().autoIncrement()();

  BlobColumn get image => blob()();

  TextColumn get mime => text()();

  /// `https://` upload for plaintext sends. Empty until this account sends it.
  TextColumn get plainUrl => text().withDefault(const Constant(''))();

  DateTimeColumn get plainUploadedAt => dateTime().nullable()();

  /// `aesgcm://` upload for standard OMEMO sends.
  TextColumn get omemoUrl => text().withDefault(const Constant(''))();

  DateTimeColumn get omemoUploadedAt => dateTime().nullable()();

  /// `aesgcm://` upload for PQ sends. Independent of [omemoUrl].
  TextColumn get pqUrl => text().withDefault(const Constant(''))();

  DateTimeColumn get pqUploadedAt => dateTime().nullable()();

  /// Lowercase SHA-256 of [image].
  TextColumn get contentHash => text()();

  /// Grid order. A repeated save moves the existing row to the end.
  IntColumn get position => integer()();
}

@DriftDatabase(
  tables: [
    Chats,
    Messages,
    RosterEntries,
    BlockedContacts,
    PinnedMessages,
    SubscriptionRequests,
    RoomInvitations,
    PendingCorrections,
    Reactions,
    Meta,
    OmemoIdentities,
    Stickers,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  @override
  // Keep in sync with [kAccountSchemaVersion] in database_connection_io.dart.
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration =>
      MigrationStrategy(onCreate: (m) async => m.createAll());

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
  /// Rows updated when marking non-retracted messages with [stanzaId] = [targetId].
  Future<int> markMessageRetractedByStanzaId(
    String targetId,
    MessagesCompanion mark,
  ) {
    return (update(messages)..where(
          (m) => m.stanzaId.equals(targetId) & m.retracted.equals(false),
        ))
        .write(mark);
  }

  /// Rows updated when marking non-retracted messages with [roomStanzaId] = [targetId].
  Future<int> markMessageRetractedByRoomStanzaId(
    String targetId,
    MessagesCompanion mark,
  ) {
    return (update(messages)..where(
          (m) => m.roomStanzaId.equals(targetId) & m.retracted.equals(false),
        ))
        .write(mark);
  }

  /// Fills empty [retractedBy] on messages addressed by [targetId].
  Future<int> fillRetractedByIfEmpty(String targetId, String nick) {
    final addressed =
        messages.stanzaId.equals(targetId) |
        messages.roomStanzaId.equals(targetId);
    return (update(messages)
          ..where((m) => addressed & m.retractedBy.equals('')))
        .write(MessagesCompanion(retractedBy: Value(nick)));
  }

  /// Fills empty [retractedReason] on messages addressed by [targetId].
  Future<int> fillRetractedReasonIfEmpty(String targetId, String text) {
    final addressed =
        messages.stanzaId.equals(targetId) |
        messages.roomStanzaId.equals(targetId);
    return (update(messages)
          ..where((m) => addressed & m.retractedReason.equals('')))
        .write(MessagesCompanion(retractedReason: Value(text)));
  }

  /// True when [chatJid] holds a message addressed by [targetId].
  Future<bool> messageAddressedBy(String chatJid, String targetId) async {
    if (targetId.isEmpty) return false;
    final row =
        await (select(messages)
              ..where(
                (m) =>
                    m.chatJid.equals(chatJid) &
                    (m.stanzaId.equals(targetId) |
                        m.roomStanzaId.equals(targetId)),
              )
              ..limit(1))
            .getSingleOrNull();
    return row != null;
  }

  /// Updates body / editedAt and clears retract for [targetId] by stanza id.
  Future<int> updateMessageBodyClearingRetract({
    required String targetId,
    required String body,
    required DateTime editedAt,
  }) {
    return (update(messages)..where((m) => m.stanzaId.equals(targetId))).write(
      MessagesCompanion(
        body: Value(body),
        editedAt: Value(editedAt),
        retracted: const Value(false),
      ),
    );
  }

  /// Holds a correction until the original message arrives.
  Future<void> upsertPendingCorrection({
    required String targetId,
    required String body,
    required String encMode,
    required DateTime correctedAt,
  }) {
    return into(pendingCorrections).insertOnConflictUpdate(
      PendingCorrectionsCompanion.insert(
        targetId: targetId,
        body: body,
        encMode: Value(encMode),
        correctedAt: Value(correctedAt),
      ),
    );
  }

  /// The correction waiting for [targetId], or null.
  ///
  /// Exposed because the failure worth testing for is a held correction being
  /// silently dropped, which leaves a permanently stale message on screen.
  Future<PendingCorrection?> pendingCorrection(String targetId) => (select(
    pendingCorrections,
  )..where((p) => p.targetId.equals(targetId))).getSingleOrNull();

  /// Drops a held correction, once it has been applied.
  Future<void> clearPendingCorrection(String targetId) async {
    await (delete(
      pendingCorrections,
    )..where((p) => p.targetId.equals(targetId))).go();
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
      await (delete(reactions)..where(
            (r) => r.targetId.equals(targetId) & r.reactor.equals(reactor),
          ))
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
  Future<List<({String emoji, Set<String> reactors, bool mine})>>
  reactionGroups(String targetId, {required String myJid}) async {
    final rows =
        await (select(reactions)
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
          (e) => (emoji: e.key, reactors: e.value, mine: mine.contains(e.key)),
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
    final row = (await (select(
      chats,
    )..where((c) => c.jid.equals(chatJid))).getSingleOrNull())?.trackOverride;
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
        ChatsCompanion(
          jid: Value(chatJid),
          trackOverride: Value(value),
          lastActivity: Value(chatActivityEpoch),
        ),
        mode: InsertMode.insertOrIgnore,
      );
      await (update(chats)..where((c) => c.jid.equals(chatJid))).write(
        ChatsCompanion(trackOverride: Value(value)),
      );
    }
  }

  Future<List<RosterEntry>> allRosterEntries() => (select(rosterEntries)).get();

  /// Bare JIDs of MODE_MULTI chats. Contacts must not list these.
  Future<Set<String>> groupChatJids() async {
    final rows = await (select(
      chats,
    )..where((c) => c.isGroup.equals(true))).get();
    return {for (final c in rows) c.jid};
  }

  /// Live roster for the Contacts tab (RFC 6121 pushes land in [commitRosterRows]).
  Stream<List<RosterEntry>> watchRoster() =>
      (select(rosterEntries)..orderBy([
            (r) => OrderingTerm.asc(r.name),
            (r) => OrderingTerm.asc(r.jid),
          ]))
          .watch();

  /// Records that the server refused the message sent with [stanzaId].
  ///
  /// Returns true when a row was updated, so a caller can tell whether the
  /// failure belonged to a message it still holds.
  Future<bool> markDeliveryFailure(String stanzaId, String reason) async {
    if (stanzaId.isEmpty) return false;
    final changed =
        await (update(
          messages,
        )..where((m) => m.stanzaId.equals(stanzaId))).write(
          MessagesCompanion(
            deliveryError: Value(reason),
            sendStatus: const Value(MessageSendStatus.sendFailed),
          ),
        );
    return changed > 0;
  }

  /// One contact's subscription state, for the "will this be delivered?"
  /// hint.
  Future<RosterEntry?> rosterEntry(String jid) => (select(
    rosterEntries,
  )..where((r) => r.jid.equals(jid))).getSingleOrNull();

  /// Meta key: the chat's MAM archive has no messages older than what we hold.
  static String mamOlderExhaustedKey(String chatJid) =>
      'mam_older_exhausted:${chatJid.trim().toLowerCase()}';

  Future<bool> mamOlderExhausted(String chatJid) async =>
      (await metaValue(mamOlderExhaustedKey(chatJid))) == '1';

  Future<void> setMamOlderExhausted(String chatJid, bool exhausted) {
    final key = mamOlderExhaustedKey(chatJid);
    if (!exhausted) return deleteMetaValue(key);
    return setMetaValue(key, '1');
  }

  Future<String?> metaValue(String key) async {
    final row = await (select(
      meta,
    )..where((m) => m.key.equals(key))).getSingleOrNull();
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

  /// Saved MUC display roster, keyed by lowercased bare room JID.
  static const roomMembersPrefix = 'room_members:';

  static String roomMembersKey(String roomJid) =>
      '$roomMembersPrefix${roomJid.trim().toLowerCase()}';

  Future<void> saveRoomMembers(String roomJid, String json) {
    return setMetaValue(roomMembersKey(roomJid), json);
  }

  /// Lowercased bare room JID → encoded occupant list.
  Future<Map<String, String>> roomMemberBlobs() async {
    final rows = await metaEntriesWithPrefix(roomMembersPrefix);
    return {
      for (final row in rows)
        row.key.substring(roomMembersPrefix.length): row.value,
    };
  }

  /// Meta rows whose key starts with [prefix] (SQL `LIKE 'prefix%'`).
  Future<List<MetaData>> metaEntriesWithPrefix(String prefix) {
    return (select(meta)..where((m) => m.key.like('$prefix%'))).get();
  }

  Future<String?> rosterVersion() async {
    final row = await (select(
      meta,
    )..where((m) => m.key.equals('roster_version'))).getSingleOrNull();
    return row?.value;
  }

  /// Applies one roster commit atomically (companions already mapped).
  Future<void> commitRosterRows({
    required String? version,
    required List<String> removed,
    required List<RosterEntriesCompanion> upserts,
  }) async {
    await transaction(() async {
      if (removed.isNotEmpty) {
        await (delete(rosterEntries)..where((r) => r.jid.isIn(removed))).go();
      }
      for (final row in upserts) {
        await into(rosterEntries).insertOnConflictUpdate(row);
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
  /// The chat list, in the order the user sees it.
  ///
  /// Pinned first, then most recent. The tiebreaker on jid matters more than it
  /// looks: two conversations with the same last-activity second would otherwise
  /// swap places between rebuilds, which reads as the list jittering.
  Stream<List<Chat>> watchChats({
    bool includeArchived = false,
    bool archivedOnly = false,
  }) {
    final query = select(chats)
      ..orderBy([
        (c) => OrderingTerm.desc(c.pinned),
        (c) => OrderingTerm.desc(c.lastActivity),
        (c) => OrderingTerm.asc(c.jid),
      ]);
    // Applied conditionally rather than as a Dart bool folded into the SQL
    // expression: `includeArchived || !archived` makes the query depend on a
    // value that is not in the database, so the same stream cannot serve both
    // lists and the two can drift apart.
    if (archivedOnly) {
      query.where((c) => c.archived.equals(true));
    } else if (!includeArchived) {
      query.where((c) => c.archived.equals(false));
    }
    return query.watch();
  }

  /// Archived conversations only.
  ///
  /// A separate method rather than a flag on [watchChats], because "the
  /// archive" is a place the user goes and "everything" is not; a caller that
  /// has to remember which combination of flags means what is how the archive
  /// ends up showing the whole chat list.
  Stream<List<Chat>> watchArchivedChats() =>
      watchChats(includeArchived: true, archivedOnly: true);

  /// Every pending subscription request, newest first.
  Stream<List<SubscriptionRequest>> watchSubscriptionRequests() => (select(
    subscriptionRequests,
  )..orderBy([(r) => OrderingTerm.desc(r.askedAt)])).watch();

  /// Records that [jid] asked to subscribe.
  ///
  /// Idempotent: the server re-sends the request, and a second row would show
  /// the user two requests from the same person to decide on.
  Future<void> addIncomingRequest(String jid) async {
    await into(subscriptionRequests).insert(
      SubscriptionRequestsCompanion.insert(jid: jid),
      mode: InsertMode.insertOrIgnore,
    );
  }

  /// Records that we asked [jid] to let us see their presence.
  Future<void> addOutgoingRequest(String jid) async {
    await into(subscriptionRequests).insert(
      SubscriptionRequestsCompanion.insert(
        jid: jid,
        outgoing: const Value(true),
      ),
      mode: InsertMode.insertOrIgnore,
    );
  }

  /// Records that [jid]'s request was answered, in either direction.
  Future<void> resolveRequest(String jid, {required bool outgoing}) async {
    await (delete(
      subscriptionRequests,
    )..where((r) => r.jid.equals(jid) & r.outgoing.equals(outgoing))).go();
  }

  /// True when [jid] has asked to subscribe to us (Conversations
  /// `Contact.Options.PENDING_SUBSCRIPTION_REQUEST`).
  Future<bool> hasIncomingSubscriptionRequest(String jid) async {
    final row =
        await (select(subscriptionRequests)
              ..where((r) => r.jid.equals(jid) & r.outgoing.equals(false)))
            .getSingleOrNull();
    return row != null;
  }

  Stream<List<RoomInvitation>> watchRoomInvitations() => (select(
    roomInvitations,
  )..orderBy([(r) => OrderingTerm.desc(r.invitedAt)])).watch();

  /// Upserts a pending room invitation (re-invites refresh the row).
  Future<void> upsertRoomInvitation({
    required String roomJid,
    required String fromJid,
    String password = '',
    String reason = '',
  }) async {
    await into(roomInvitations).insertOnConflictUpdate(
      RoomInvitationsCompanion.insert(
        roomJid: roomJid,
        fromJid: Value(fromJid),
        password: Value(password),
        reason: Value(reason),
        invitedAt: Value(DateTime.now()),
      ),
    );
  }

  Future<void> removeRoomInvitation(String roomJid) async {
    await (delete(
      roomInvitations,
    )..where((r) => r.roomJid.equals(roomJid))).go();
  }

  /// Classic OMEMO (A-track) device ids this installation has published.
  Future<Set<int>> publishedOmemoDeviceIds() =>
      _publishedDeviceIds('omemo_published_ids');

  Future<void> savePublishedOmemoDeviceIds(Set<int> ids) =>
      setMetaValue('omemo_published_ids', ids.join(','));

  /// OMEMO2 / PQ (B-track) device ids this installation has published.
  Future<Set<int>> publishedPqDeviceIds() =>
      _publishedDeviceIds('omemo2_published_ids');

  Future<void> savePublishedPqDeviceIds(Set<int> ids) =>
      setMetaValue('omemo2_published_ids', ids.join(','));

  Future<Set<int>> _publishedDeviceIds(String metaKey) async {
    final raw = await metaValue(metaKey);
    if (raw == null || raw.isEmpty) return const {};
    try {
      return raw
          .split(',')
          .map((s) => int.tryParse(s.trim()))
          .whereType<int>()
          .toSet();
    } catch (_) {
      return const {};
    }
  }

  /// Stores [raw] as [chatJid]'s appearance, or clears it when null.
  ///
  /// Cleared rather than stored as the default encoding: a row of defaults is a
  /// list of conversations that once had a setting, which is not a thing, and it
  /// would stop a later change of the app's own defaults from reaching them.
  Future<void> setChatAppearance(String chatJid, String? raw) async {
    final value = raw?.trim() ?? '';
    if (value.isEmpty) {
      await (update(chats)..where((c) => c.jid.equals(chatJid))).write(
        const ChatsCompanion(appearance: Value('')),
      );
      return;
    }
    final changed = await (update(chats)..where((c) => c.jid.equals(chatJid)))
        .write(ChatsCompanion(appearance: Value(value)));
    if (changed == 0) {
      // Appearance set before the conversation has a row — the same case as
      // pinning a chat that has never had a message.
      await upsertChat(chatJid);
      await (update(chats)..where((c) => c.jid.equals(chatJid))).write(
        ChatsCompanion(appearance: Value(value)),
      );
    }
  }

  /// The draft for [chatJid], or null when the box is empty.
  ///
  /// Kept in the database rather than in the text field's controller: the field
  /// dies with the page, and the whole point of a draft is that it survives
  /// leaving and coming back.
  Future<String?> draft(String chatJid) async {
    final value = await metaValue('draft:$chatJid');
    return value == null || value.isEmpty ? null : value;
  }

  Future<void> setDraft(String chatJid, String? text) async {
    final trimmed = text?.trim() ?? '';
    // Cleared rather than stored as empty: a row of empty strings is a list of
    // conversations that once had a draft, which is not a thing.
    await deleteMetaValue('draft:$chatJid');
    if (trimmed.isEmpty) return;
    await setMetaValue('draft:$chatJid', text!);
  }

  /// MUC subject text the user dismissed after reading, or null.
  ///
  /// Compared to the live subject: equal → hide the floating banner; different
  /// (or missing) → show again until they open the detail and dismiss.
  Future<String?> mucSubjectRead(String chatJid) =>
      metaValue('muc_subject_read:$chatJid');

  Future<void> setMucSubjectRead(String chatJid, String subject) async {
    final trimmed = subject.trim();
    if (trimmed.isEmpty) {
      await deleteMetaValue('muc_subject_read:$chatJid');
      return;
    }
    await setMetaValue('muc_subject_read:$chatJid', trimmed);
  }

  /// Pins a message, or unpins it when already pinned.
  Future<void> togglePinned(String chatJid, String stanzaId) async {
    if (stanzaId.isEmpty) return;
    final existing =
        await (select(pinnedMessages)..where(
              (p) => p.chatJid.equals(chatJid) & p.stanzaId.equals(stanzaId),
            ))
            .getSingleOrNull();
    if (existing != null) {
      await (delete(pinnedMessages)..where(
            (p) => p.chatJid.equals(chatJid) & p.stanzaId.equals(stanzaId),
          ))
          .go();
      return;
    }
    // A monotonic counter rather than the clock, for the reason on the column:
    // two pins inside one second must still have a defined order.
    // The expression is what gets read, not the column: with `max()` the result
    // set carries the aggregate, not a plain column.
    final highestExpr = pinnedMessages.sequence.max();
    final highest =
        await (selectOnly(pinnedMessages)
              ..addColumns([highestExpr])
              ..where(pinnedMessages.chatJid.equals(chatJid)))
            .getSingle();
    final next = (highest.read(highestExpr) ?? 0) + 1;
    await into(pinnedMessages).insert(
      PinnedMessagesCompanion.insert(
        chatJid: chatJid,
        stanzaId: stanzaId,
        sequence: Value(next),
      ),
    );
  }

  Future<bool> isPinned(String chatJid, String stanzaId) async =>
      (await (select(pinnedMessages)..where(
            (p) => p.chatJid.equals(chatJid) & p.stanzaId.equals(stanzaId),
          ))
          .getSingleOrNull()) !=
      null;

  /// Pinned messages in [chatJid], most recently pinned first.
  Stream<List<String>> watchPinned(String chatJid) =>
      (select(pinnedMessages)
            ..where((p) => p.chatJid.equals(chatJid))
            ..orderBy([
              (p) => OrderingTerm.desc(p.sequence),
              (p) => OrderingTerm.desc(p.pinnedAt),
              (p) => OrderingTerm.desc(p.stanzaId),
            ]))
          .watch()
          .map((rows) => rows.map((r) => r.stanzaId).toList());

  /// The JIDs currently blocked (XEP-0191).
  Future<Set<String>> blockedJids() async =>
      (await select(blockedContacts).get()).map((b) => b.jid).toSet();

  /// True when [jid] is blocked.
  Future<bool> isBlocked(String jid) async =>
      (await (select(
        blockedContacts,
      )..where((b) => b.jid.equals(jid))).getSingleOrNull()) !=
      null;

  /// Records that [jid] is blocked.
  ///
  /// Idempotent. The server pushes the whole block list on every change, so a
  /// duplicate entry is ordinary — and it arrives on the inbound path, where a
  /// thrown constraint violation would take the push handler down with it.
  Future<void> addBlocked(String jid) async {
    await into(blockedContacts).insert(
      BlockedContactsCompanion.insert(jid: jid),
      mode: InsertMode.insertOrIgnore,
    );
  }

  /// Records that [jid] is no longer blocked.
  Future<void> removeBlocked(String jid) async {
    await (delete(blockedContacts)..where((b) => b.jid.equals(jid))).go();
  }

  /// Marks [chatJid] as read up to [at] (default: now).
  ///
  /// Badges are *recomputed* from inbound messages newer than the marker,
  /// not forced to zero. Leave-chat calls this asynchronously after dispose;
  /// a message that landed in that gap used to be counted by
  /// [markChatUnread] and then wiped here (first @ invisible; second showed
  /// `1`). Recomputing keeps those rows.
  ///
  /// Prefer passing [at] captured *before* any await on the leave path so the
  /// marker is the moment the user left, not when this SQL eventually runs.
  Future<void> markChatRead(String chatJid, {DateTime? at}) async {
    final readSec = (at ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
    // Drift stores DateTime as unix seconds (integer). Same unit as
    // [markChatUnread].
    await customStatement(
      'UPDATE chats SET '
      'last_read_at = ?, '
      'unread_count = ('
      '  SELECT COUNT(*) FROM messages '
      '  WHERE chat_jid = ? AND incoming = 1 AND timestamp > ?'
      '), '
      'unread_mentions = ('
      '  SELECT COUNT(*) FROM messages '
      '  WHERE chat_jid = ? AND incoming = 1 AND mentions_me = 1 '
      '    AND timestamp > ?'
      ') '
      'WHERE jid = ?',
      [readSec, chatJid, readSec, chatJid, readSec, chatJid],
    );
  }

  /// Increments the unread count for [chatJid], and pulls the read marker back
  /// so the next mark-read does not swallow the increment.
  ///
  /// The arithmetic happens in SQL rather than read-modify-write: two messages
  /// arriving while the UI is idle would otherwise both read the same count and
  /// one would be lost. Counting is exactly where an off-by-one stays invisible
  /// to the user until they open the chat and find a message already marked
  /// read.
  ///
  /// When [mentionsMe] is true, also bumps [Chats.unreadMentions] (Telegram
  /// `unread_mentions_count`).
  Future<void> markChatUnread(
    String chatJid, {
    required DateTime arrivedAt,
    bool mentionsMe = false,
  }) async {
    // Raw SQL because drift's typed update cannot express
    // `unread_count = unread_count + 1`. The guard is in the same statement on
    // purpose: archive replay delivers old messages, and counting those would
    // show a badge for a conversation the user has already read.
    //
    // Seconds, not milliseconds: that is what drift stores a DateTime as, and
    // getting it wrong makes the comparison always false, so every replayed
    // message counts and the guard is quietly dead.
    final mentionBump = mentionsMe
        ? ', unread_mentions = unread_mentions + 1'
        : '';
    await customStatement(
      'UPDATE chats SET unread_count = unread_count + 1$mentionBump '
      'WHERE jid = ? AND last_read_at <= ?',
      [chatJid, arrivedAt.millisecondsSinceEpoch ~/ 1000],
    );
  }

  /// Sets one of the per-conversation switches.
  Future<void> setChatFlag(
    String chatJid, {
    bool? pinned,
    bool? muted,
    bool? alwaysNotify,
    bool? archived,
  }) async {
    final updated = await (update(chats)..where((c) => c.jid.equals(chatJid)))
        .write(
          ChatsCompanion(
            pinned: pinned == null ? const Value.absent() : Value(pinned),
            muted: muted == null ? const Value.absent() : Value(muted),
            alwaysNotify: alwaysNotify == null
                ? const Value.absent()
                : Value(alwaysNotify),
            archived: archived == null ? const Value.absent() : Value(archived),
          ),
        );
    if (updated == 0) {
      // Pinning a conversation that has no row yet — opening a chat from a JID
      // and pinning it before any message exists. Creating the row keeps
      // "the flag is set" independent of "the conversation exists".
      await upsertChat(chatJid);
      await (update(chats)..where((c) => c.jid.equals(chatJid))).write(
        ChatsCompanion(
          pinned: pinned == null ? const Value.absent() : Value(pinned),
          muted: muted == null ? const Value.absent() : Value(muted),
          alwaysNotify: alwaysNotify == null
              ? const Value.absent()
              : Value(alwaysNotify),
          archived: archived == null ? const Value.absent() : Value(archived),
        ),
      );
    }
  }

  /// Conversations-style notification mode for [chatJid].
  Future<void> setChatNotifyMode(String chatJid, ChatNotifyMode mode) {
    final flags = mode.storageFlags;
    return setChatFlag(
      chatJid,
      muted: flags.muted,
      alwaysNotify: flags.alwaysNotify,
    );
  }

  /// Notification mode plus the Still notify list. The list is kept even
  /// when the mode is [ChatNotifyMode.all], so switching back does not
  /// drop the checks.
  Future<void> setChatNotifySettings(
    String chatJid, {
    required ChatNotifyMode mode,
    required List<String> except,
  }) async {
    await setChatNotifyMode(chatJid, mode);
    await (update(chats)..where((c) => c.jid.equals(chatJid))).write(
      ChatsCompanion(notifyExcept: Value(encodeNotifyExcept(except))),
    );
  }

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

  /// Makes [needle] safe to interpolate into a `LIKE` pattern.
  ///
  /// `%` and `_` are wildcards in SQL, so a user typing them gets matches that
  /// have nothing to do with what they asked for — `%%%` in particular is true
  /// of every row, which turns "I typed three percent signs" into "here is
  /// your entire history". `escape` tells SQLite to treat `\` as the escape
  /// character, so the wildcards become literal.
  ///
  /// Also collapses a needle that is nothing but wildcards to a string that
  /// cannot match, because `ESCAPE` alone leaves `%%%` matching everything.
  static String _likePattern(String needle) {
    final escaped = needle
        .replaceAll('\\', '\\\\')
        .replaceAll('%', '\\%')
        .replaceAll('_', '\\_');
    if (escaped.replaceAll(RegExp(r'\\'), '').trim().isEmpty) {
      // Only wildcards (or nothing). There is no honest result for this query.
      return '\\x00';
    }
    return '%$escaped%';
  }

  /// Messages whose body contains [needle], newest first.
  ///
  /// Case-insensitive, because a user typing "ok" is looking for "OK" too, and
  /// because making them reach for a capitals toggle to find their own message
  /// is the kind of friction that gets reported as "search is broken".
  ///
  /// Excludes two kinds of row, because a result the user cannot act on is
  /// worse than a missing result:
  ///   * messages we could not open — their body is a placeholder, and matching
  ///     the placeholder text would send them looking for words nobody wrote;
  ///   * retracted messages — the body is kept on purpose so the sender can
  ///     still read what they said, and a user who deleted it does not expect
  ///     to find it again in search.
  ///
  /// Only ever consulted from a search, never on the message-list path: a `LIKE`
  /// scan per keystroke over a table that grows with the archive is fine, but
  /// running it for every conversation in the chat list is not.
  Stream<List<Message>> searchMessages(String needle, {int limit = 200}) {
    final trimmed = needle.trim();
    if (trimmed.isEmpty) return Stream.value(const []);
    final pattern = _likePattern(trimmed);
    return (select(messages)
          ..where(
            (m) =>
                m.body.like(pattern, escapeChar: r'\') &
                m.retracted.equals(false) &
                m.encMode.equals('error').not(),
          )
          ..orderBy([
            (m) => OrderingTerm.desc(m.timestamp),
            (m) => OrderingTerm.desc(m.id),
          ])
          ..limit(limit))
        .watch();
  }

  /// Searches within one conversation.
  Stream<List<Message>> searchInChat(
    String chatJid,
    String needle, {
    int limit = 200,
  }) {
    final trimmed = needle.trim();
    if (trimmed.isEmpty) return Stream.value(const []);
    final pattern = _likePattern(trimmed);
    return (select(messages)
          ..where(
            (m) =>
                m.chatJid.equals(chatJid) &
                m.body.like(pattern, escapeChar: r'\') &
                m.retracted.equals(false) &
                m.encMode.equals('error').not(),
          )
          ..orderBy([
            (m) => OrderingTerm.desc(m.timestamp),
            (m) => OrderingTerm.desc(m.id),
          ])
          ..limit(limit))
        .watch();
  }

  /// Creates or updates a chat row.
  ///
  /// New rows get [at], or [chatActivityEpoch] when omitted (no messages yet).
  /// On conflict, [lastActivity] is left alone unless [at] is passed — roster
  /// sync must not rewrite every contact's time to "now".
  ///
  /// [isGroup] / [mucNick] / [mucPrivateNonAnonymous] are optional so a later
  /// 1:1 upsert cannot wipe a room's MODE_MULTI flags.
  Future<void> upsertChat(
    String jid, {
    String? title,
    DateTime? at,
    bool? isGroup,
    String? mucNick,
    bool? mucPrivateNonAnonymous,
  }) async {
    final row = ChatsCompanion(
      jid: Value(jid),
      // New rows need a title; omit [title] and we seed with the address.
      title: Value(title ?? jid),
      lastActivity: Value(at ?? chatActivityEpoch),
      isGroup: isGroup != null ? Value(isGroup) : const Value.absent(),
      mucNick: mucNick != null ? Value(mucNick) : const Value.absent(),
      mucPrivateNonAnonymous: mucPrivateNonAnonymous != null
          ? Value(mucPrivateNonAnonymous)
          : const Value.absent(),
    );
    // Drift cannot emit `DO UPDATE SET` with zero columns. When the caller
    // only ensures the row exists, insert-or-ignore leaves an existing title /
    // nick / flags alone.
    final hasConflictUpdate =
        title != null ||
        at != null ||
        isGroup != null ||
        mucNick != null ||
        mucPrivateNonAnonymous != null;
    if (!hasConflictUpdate) {
      await into(chats).insert(row, mode: InsertMode.insertOrIgnore);
      return;
    }
    await into(chats).insert(
      row,
      onConflict: DoUpdate(
        (_) => ChatsCompanion(
          // Never clobber a bookmark/disco name just because a message arrived
          // without an explicit title.
          title: title != null ? Value(title) : const Value.absent(),
          lastActivity: at != null ? Value(at) : const Value.absent(),
          isGroup: isGroup != null ? Value(isGroup) : const Value.absent(),
          mucNick: mucNick != null ? Value(mucNick) : const Value.absent(),
          mucPrivateNonAnonymous: mucPrivateNonAnonymous != null
              ? Value(mucPrivateNonAnonymous)
              : const Value.absent(),
        ),
      ),
    );
  }

  /// Sets each chat's [Chats.lastActivity] from its newest message, or
  /// [chatActivityEpoch] when the conversation is empty.
  ///
  /// Repairs rows stamped with login time by an older upsert.
  Future<void> syncChatLastActivity() async {
    final rows = await select(chats).get();
    for (final chat in rows) {
      final latest =
          await (select(messages)
                ..where((m) => m.chatJid.equals(chat.jid))
                ..orderBy([
                  (m) => OrderingTerm.desc(m.timestamp),
                  (m) => OrderingTerm.desc(m.id),
                ])
                ..limit(1))
              .getSingleOrNull();
      final ts = latest?.timestamp ?? chatActivityEpoch;
      if (chat.lastActivity == ts) continue;
      await (update(chats)..where((c) => c.jid.equals(chat.jid))).write(
        ChatsCompanion(lastActivity: Value(ts)),
      );
    }
  }

  /// One conversation row, or null.
  Future<Chat?> getChat(String jid) =>
      (select(chats)..where((c) => c.jid.equals(jid))).getSingleOrNull();

  /// Rooms with a nick to rejoin after login (Conversations connectMultiMode).
  Future<List<Chat>> groupChatsForJoin() => (select(
    chats,
  )..where((c) => c.isGroup.equals(true) & c.mucNick.equals('').not())).get();

  /// Inserts one message row (no pending-correction merge).
  Future<void> insertMessageRow(MessagesCompanion message) =>
      into(messages).insert(message);

  /// Bumps [chatJid] lastActivity when [ts] is newer.
  Future<void> bumpChatActivityIfNewer(String chatJid, DateTime ts) {
    return (update(chats)..where(
          (c) => c.jid.equals(chatJid) & c.lastActivity.isSmallerThanValue(ts),
        ))
        .write(ChatsCompanion(lastActivity: Value(ts)));
  }

  /// Non-empty [localPath] values for messages in [chatJid].
  Future<List<String>> localPathsForChat(String chatJid) async {
    final rows =
        await (select(messages)..where(
              (m) => m.chatJid.equals(chatJid) & m.localPath.equals('').not(),
            ))
            .get();
    return [for (final r in rows) r.localPath];
  }

  /// Non-empty [localPath] values for messages older than [cutoff].
  Future<List<String>> localPathsOlderThan(DateTime cutoff) async {
    final rows =
        await (select(messages)..where(
              (m) =>
                  m.timestamp.isSmallerThanValue(cutoff) &
                  m.localPath.equals('').not(),
            ))
            .get();
    return [for (final r in rows) r.localPath];
  }

  /// Drops a chat row and its messages/pins (after room destroy / leave wipe).
  Future<void> deleteChat(String chatJid) {
    return transaction(() async {
      await (delete(
        pinnedMessages,
      )..where((p) => p.chatJid.equals(chatJid))).go();
      await (delete(messages)..where((m) => m.chatJid.equals(chatJid))).go();
      await (delete(chats)..where((c) => c.jid.equals(chatJid))).go();
      await deleteMetaValue('draft:$chatJid');
      await deleteMetaValue('plaintext_ack:$chatJid');
      await deleteMetaValue(roomMembersKey(chatJid));
    });
  }

  /// Removes every stored message of one conversation from this device.
  ///
  /// The server is untouched: the other side keeps its copy, and archived
  /// messages will come back on the next MAM fetch. That distinction is why
  /// the UI words this as "clear history on this device".
  ///
  /// Callers should delete [localPathsForChat] files before/after this.
  Future<int> clearChatMessages(String chatJid) {
    return transaction(() async {
      await (delete(
        pinnedMessages,
      )..where((p) => p.chatJid.equals(chatJid))).go();
      final n = await (delete(
        messages,
      )..where((m) => m.chatJid.equals(chatJid))).go();
      await (update(chats)..where((c) => c.jid.equals(chatJid))).write(
        ChatsCompanion(lastActivity: Value(chatActivityEpoch)),
      );
      await deleteMetaValue(mamOlderExhaustedKey(chatJid));
      return n;
    });
  }

  /// Deletes messages with `timestamp < cutoff` (Conversations expiry).
  ///
  /// Also drops pins that pointed at those rows. Callers delete attachment
  /// files via [localPathsOlderThan] around this call.
  Future<int> expireMessagesOlderThan(DateTime cutoff) {
    return transaction(() async {
      final doomed = await (select(
        messages,
      )..where((m) => m.timestamp.isSmallerThanValue(cutoff))).get();
      if (doomed.isEmpty) return 0;
      final byChat = <String, Set<String>>{};
      for (final m in doomed) {
        if (m.stanzaId.isEmpty) continue;
        (byChat[m.chatJid] ??= <String>{}).add(m.stanzaId);
      }
      for (final entry in byChat.entries) {
        await (delete(pinnedMessages)..where(
              (p) =>
                  p.chatJid.equals(entry.key) &
                  p.stanzaId.isIn(entry.value.toList()),
            ))
            .go();
      }
      return (delete(
        messages,
      )..where((m) => m.timestamp.isSmallerThanValue(cutoff))).go();
    });
  }

  /// Records the local cache path after a successful download.
  Future<int> setMessageLocalPath(int messageId, String path) {
    return (update(messages)..where((m) => m.id.equals(messageId))).write(
      MessagesCompanion(localPath: Value(path)),
    );
  }

  /// Marks one of our outgoing messages as delivered (XEP-0184 / MUC reflection).
  ///
  /// Conversations `markMessage(..., STATUS_SEND_RECEIVED)`. Never downgrades
  /// an already-read ([MessageSendStatus.sendDisplayed]) row. Returns rows
  /// updated (0 when unknown / already displayed / failed).
  Future<int> markDelivered(String chatJid, String stanzaId) {
    return (update(messages)..where(
          (m) =>
              m.chatJid.equals(chatJid) &
              m.stanzaId.equals(stanzaId) &
              m.incoming.equals(false) &
              m.sendStatus.isIn([
                MessageSendStatus.waiting,
                MessageSendStatus.unsend,
                MessageSendStatus.send,
                MessageSendStatus.sendReceived,
              ]),
        ))
        .write(
          const MessagesCompanion(
            delivered: Value(true),
            sendStatus: Value(MessageSendStatus.sendReceived),
          ),
        );
  }

  /// Updates [sendStatus] (and legacy flags) for one outgoing stanza id.
  Future<int> updateSendStatus(
    String chatJid,
    String stanzaId,
    int status, {
    String deliveryError = '',
  }) {
    final failed = status == MessageSendStatus.sendFailed;
    final received =
        status == MessageSendStatus.sendReceived ||
        status == MessageSendStatus.sendDisplayed;
    final displayed = status == MessageSendStatus.sendDisplayed;
    return (update(messages)..where(
          (m) =>
              m.chatJid.equals(chatJid) &
              m.stanzaId.equals(stanzaId) &
              m.incoming.equals(false),
        ))
        .write(
          MessagesCompanion(
            sendStatus: Value(status),
            delivered: Value(received || displayed),
            displayed: Value(displayed),
            deliveryError: Value(failed ? deliveryError : ''),
          ),
        );
  }

  /// Fails outgoing rows that have been `waiting` for longer than [before].
  ///
  /// A `waiting` row only exists between the local insert and the socket
  /// write. If the process dies, or a send throws outside the paths that call
  /// [updateSendStatus], nothing remains to move that row on — it would show a
  /// clock forever. Reconciliation is deliberately time-bounded so a send
  /// that is genuinely still resolving is never mistaken for a stranded one.
  Future<int> failStaleOutgoingWaiting(
    String chatJid, {
    required DateTime before,
    String reason = '',
  }) =>
      (update(messages)..where(
            (m) =>
                m.chatJid.equals(chatJid) &
                m.incoming.equals(false) &
                m.sendStatus.equals(MessageSendStatus.waiting) &
                m.timestamp.isSmallerThanValue(before),
          ))
          .write(
            MessagesCompanion(
              sendStatus: const Value(MessageSendStatus.sendFailed),
              deliveryError: Value(reason),
            ),
          );

  /// Corrects the declared track of an outgoing row.
  ///
  /// The row is written as soon as the send is queued — before the track is
  /// resolved, so the bubble is not held up by the peer's PEP round-trips —
  /// and the resolution can substitute a different track. Without this the
  /// badge would keep showing the track the composer was set to rather than
  /// the one the message actually went out on.
  Future<int> updateEncMode(String chatJid, String stanzaId, String encMode) =>
      (update(messages)..where(
            (m) =>
                m.chatJid.equals(chatJid) &
                m.stanzaId.equals(stanzaId) &
                m.incoming.equals(false),
          ))
          .write(MessagesCompanion(encMode: Value(encMode)));

  /// Removes a queued outgoing row that was never sent.
  ///
  /// Used when the user cancels at a track dialog: the row existed only so the
  /// bubble could appear immediately, and a send the user chose not to make
  /// must leave no trace rather than a permanent "failed" mark.
  Future<int> deleteOutgoingByStanzaId(String chatJid, String stanzaId) =>
      (delete(messages)..where(
            (m) =>
                m.chatJid.equals(chatJid) &
                m.stanzaId.equals(stanzaId) &
                m.incoming.equals(false),
          ))
          .go();

  /// Marks an outgoing message (and older sent ones) as read (XEP-0333).
  ///
  /// The named stanza always becomes [MessageSendStatus.sendDisplayed] (read
  /// implies delivered — even if no 0184 arrived). Older outgoing rows that
  /// are already on the wire / delivered / read are upgraded too; waiting /
  /// failed rows are left alone.
  Future<int> markDisplayed(String chatJid, String stanzaId) async {
    if (stanzaId.isEmpty) return 0;
    final target =
        await (select(messages)..where(
              (m) =>
                  m.chatJid.equals(chatJid) &
                  m.stanzaId.equals(stanzaId) &
                  m.incoming.equals(false),
            ))
            .getSingleOrNull();
    if (target == null) return 0;
    return (update(messages)..where(
          (m) =>
              m.chatJid.equals(chatJid) &
              m.incoming.equals(false) &
              m.timestamp.isSmallerOrEqualValue(target.timestamp) &
              (m.stanzaId.equals(stanzaId) |
                  m.sendStatus.isIn([
                    MessageSendStatus.send,
                    MessageSendStatus.sendReceived,
                    MessageSendStatus.sendDisplayed,
                  ])),
        ))
        .write(
          const MessagesCompanion(
            delivered: Value(true),
            displayed: Value(true),
            sendStatus: Value(MessageSendStatus.sendDisplayed),
          ),
        );
  }

  /// Records that [readerJid] has displayed the message addressed by [markerId]
  /// and every earlier outgoing message in the chat.
  ///
  /// A displayed marker names the latest message the reader has seen, so the
  /// ones before it are read as well. The chat transcript is otherwise left
  /// as it was: this does not flip [Messages.displayed], which stays the 1:1
  /// signal.
  Future<void> noteGroupRead({
    required String chatJid,
    required String markerId,
    required String readerJid,
  }) async {
    final reader = readerJid.trim().toLowerCase();
    if (markerId.isEmpty || reader.isEmpty) return;
    final target =
        await (select(messages)
              ..where(
                (m) =>
                    m.chatJid.equals(chatJid) &
                    (m.roomStanzaId.equals(markerId) |
                        m.stanzaId.equals(markerId)),
              )
              ..limit(1))
            .getSingleOrNull();
    if (target == null) return;
    final rows =
        await (select(messages)..where(
              (m) =>
                  m.chatJid.equals(chatJid) &
                  m.incoming.equals(false) &
                  m.timestamp.isSmallerOrEqualValue(target.timestamp),
            ))
            .get();
    for (final row in rows) {
      final readers = decodeReadBy(row.readBy);
      if (!readers.add(reader)) continue;
      await (update(messages)..where((m) => m.id.equals(row.id))).write(
        MessagesCompanion(readBy: Value(encodeReadBy(readers))),
      );
    }
  }

  /// Newest incoming room message that has a stanza-id, for a group
  /// `<displayed/>`.
  Future<Message?> lastIncomingWithRoomStanza(String chatJid) {
    return (select(messages)
          ..where(
            (m) =>
                m.chatJid.equals(chatJid) &
                m.incoming.equals(true) &
                m.roomStanzaId.isNotValue(''),
          )
          ..orderBy([
            (m) => OrderingTerm.desc(m.timestamp),
            (m) => OrderingTerm.desc(m.id),
          ])
          ..limit(1))
        .getSingleOrNull();
  }

  /// Newest incoming markable message in [chatJid], for sending `<displayed/>`.
  Future<Message?> lastIncomingMarkable(String chatJid) {
    return (select(messages)
          ..where(
            (m) =>
                m.chatJid.equals(chatJid) &
                m.incoming.equals(true) &
                m.markable.equals(true) &
                m.stanzaId.isNotValue(''),
          )
          ..orderBy([
            (m) => OrderingTerm.desc(m.timestamp),
            (m) => OrderingTerm.desc(m.id),
          ])
          ..limit(1))
        .getSingleOrNull();
  }

  /// Privacy prefs: delivery (XEP-0184), read (XEP-0333), typing (XEP-0085).
  Future<bool> sendDeliveryReceiptsEnabled() async =>
      (await metaValue('pref_delivery_receipts')) != '0';

  Future<bool> sendReadReceiptsEnabled() async =>
      (await metaValue('pref_read_receipts')) != '0';

  Future<bool> sendChatStatesEnabled() async =>
      (await metaValue('pref_chat_states')) != '0';

  Future<void> setSendDeliveryReceipts(bool enabled) =>
      setMetaValue('pref_delivery_receipts', enabled ? '1' : '0');

  Future<void> setSendReadReceipts(bool enabled) =>
      setMetaValue('pref_read_receipts', enabled ? '1' : '0');

  Future<void> setSendChatStates(bool enabled) =>
      setMetaValue('pref_chat_states', enabled ? '1' : '0');

  /// Own RFC 6121 `<show/>` preference (`online` / `chat` / `away` / `xa` / `dnd`).
  Future<String> ownPresenceShowWire() async =>
      (await metaValue('pref_presence_show')) ?? 'chat';

  Future<void> setOwnPresenceShowWire(String show) =>
      setMetaValue('pref_presence_show', show);

  /// Newest message timestamp across all chats.
  ///
  /// Conversations `getLastMessageReceived` — used as the MAM catch-up
  /// `start` when no archive id cursor is stored yet.
  Future<DateTime?> latestMessageTimestamp() async {
    final row =
        await (select(messages)
              ..orderBy([
                (m) => OrderingTerm.desc(m.timestamp),
                (m) => OrderingTerm.desc(m.id),
              ])
              ..limit(1))
            .getSingleOrNull();
    return row?.timestamp;
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

  /// The stored row addressed by [stanzaId], or null.
  Future<Message?> messageWithStanzaId(String chatJid, String stanzaId) async {
    if (stanzaId.isEmpty) return null;
    return (select(messages)..where(
          (m) => m.chatJid.equals(chatJid) & m.stanzaId.equals(stanzaId),
        ))
        .getSingleOrNull();
  }

  /// Fills the room's stanza-id on a message we already stored.
  ///
  /// Conversations `markMessage` / duplicate handling only writes `serverMsgId`
  /// when the row does not have one yet. A later copy must not replace it.
  Future<void> setRoomStanzaId(
    String chatJid,
    String stanzaId,
    String roomStanzaId,
  ) async {
    if (stanzaId.isEmpty || roomStanzaId.isEmpty) return;
    await (update(messages)..where(
          (m) =>
              m.chatJid.equals(chatJid) &
              m.stanzaId.equals(stanzaId) &
              m.roomStanzaId.equals(''),
        ))
        .write(MessagesCompanion(roomStanzaId: Value(roomStanzaId)));
  }

  /// Finds an already-stored inbound message by its stanza id, so that a
  /// second copy (e.g. carbon + direct delivery) is not duplicated.
  Future<int?> findByStanzaId(String chatJid, String stanzaId) async {
    if (stanzaId.isEmpty) return null;
    final row =
        await (select(messages)
              ..where(
                (m) => m.chatJid.equals(chatJid) & m.stanzaId.equals(stanzaId),
              )
              ..limit(1))
            .getSingleOrNull();
    return row?.id;
  }

  /// Saved stickers in grid order. The add tile is drawn after the last row.
  Stream<List<Sticker>> watchStickers() =>
      (select(stickers)..orderBy([
            (s) => OrderingTerm.asc(s.position),
            (s) => OrderingTerm.asc(s.id),
          ]))
          .watch();

  Future<Sticker?> stickerById(int id) =>
      (select(stickers)..where((s) => s.id.equals(id))).getSingleOrNull();

  /// Stores the picture only. Links stay empty until [rememberStickerLink].
  ///
  /// A matching [contentHash] reuses that row, leaves its links alone, and
  /// moves it to the end of the grid.
  Future<StickerSave> addSticker({
    required Uint8List image,
    required String mime,
  }) async {
    final hash = await stickerContentHash(image);
    final position = await _nextStickerPosition();
    final existing =
        await (select(stickers)
              ..where((s) => s.contentHash.equals(hash))
              ..limit(1))
            .getSingleOrNull();
    if (existing != null) {
      await (update(stickers)..where((s) => s.id.equals(existing.id))).write(
        StickersCompanion(position: Value(position)),
      );
      return StickerSave(id: existing.id, hashMatched: true);
    }
    final id = await into(stickers).insert(
      StickersCompanion.insert(
        image: image,
        mime: mime,
        contentHash: hash,
        position: position,
      ),
    );
    return StickerSave(id: id, hashMatched: false);
  }

  Future<int> _nextStickerPosition() async {
    final max = stickers.position.max();
    final row = await (selectOnly(stickers)..addColumns([max])).getSingle();
    return (row.read(max) ?? 0) + 1;
  }

  /// Writes the link for [kind] only. The other two modes are left alone.
  Future<void> rememberStickerLink({
    required int id,
    required StickerSendKind kind,
    required String url,
    required DateTime uploadedAt,
  }) {
    final row = switch (kind) {
      StickerSendKind.plain => StickersCompanion(
        plainUrl: Value(url),
        plainUploadedAt: Value(uploadedAt),
      ),
      StickerSendKind.omemo => StickersCompanion(
        omemoUrl: Value(url),
        omemoUploadedAt: Value(uploadedAt),
      ),
      StickerSendKind.pq => StickersCompanion(
        pqUrl: Value(url),
        pqUploadedAt: Value(uploadedAt),
      ),
    };
    return (update(stickers)..where((s) => s.id.equals(id))).write(row);
  }

  Future<void> deleteSticker(int id) =>
      (delete(stickers)..where((s) => s.id.equals(id))).go();
}

/// Opens the per-account DB (`resonchat_<accountId>.sqlite3`).
///
/// Shared prefs live in [openAppPrefs] / `resonchat.sqlite3`, not here.
Future<AppDatabase> openAppDatabase({required String accountId}) async {
  final executor = await openAccountDatabaseConnection(accountId);
  return AppDatabase(executor);
}
