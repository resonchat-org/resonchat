// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// What a backup is, and — more to the point — what it may never contain.
//
// The decision this file exists to hold in place: **OMEMO key material never
// leaves the device.** The sealed identity key under `OmemoDeviceStore` opens
// every message this account has ever sent or received. A backup containing it
// is not a copy of the user's data; it is a plaintext, unrevocable,
// indefinitely-lived decryption capability in a file whose entire purpose is to
// be copied off the phone — emailed to a new handset, put in a cloud folder,
// left on a lost device's card. Nothing the user can do later takes it back,
// because the keystore key that would re-protect it never travels with it.
//
// So the exclusion here is structural rather than a default. [Secret] is a
// type; [BackupValue] is a sealed type that [Secret] is not a member of; every
// function that writes an archive takes [BackupValue]. There is no "include
// keys" flag to set, and no code path — present or future — that can put key
// material into an archive, because the encoder has no parameter that could
// accept one. [cellFromJson] is the single door that takes an untyped value,
// because a decoded file is `Object?` all the way down, and it refuses a
// [Secret] by name.
//
// What a backup *does* contain is plaintext message text, exactly as sensitive
// as the message it copies, and protected by exactly what protects the
// database it came from. This format does not encrypt the archive: the file
// goes wherever the user sends it, and adding a second secret to it would only
// mean one more thing the user cannot revoke. The trust being asked for is
// narrow and worth stating plainly — "this is your history; it is not readable
// by anyone who cannot open your database" — rather than dressed up with a
// checksum that is not, and never was, protection against a reader.
//
// JSON, all the way down, including the framing. A backup is a file a person
// may keep for years and may need to read after several app versions, possibly
// after the app is gone: a layout only this build understands is a layout that
// becomes unrecoverable the moment we stop shipping. Text also means the user
// can open it and *see* that it holds conversations and no keys, which is the
// only way that claim is checkable by anybody but us.
//
// Not in this file: reading or writing files, the document picker, the queries
// that produce rows, and the inserts that consume them. This is the layer those
// three have to agree on.

import 'dart:convert';
import 'dart:typed_data';

/// A value that must never leave the device.
///
/// [bytes] is sealed OMEMO key material — identity key, signed prekey, one-time
/// prekeys — in the form `OmemoDeviceStore` persists it. Handing it around as
/// `List<int>` is what made this a rule rather than a fact: a byte list is
/// interchangeable with every other byte list in the program, so nothing about
/// the type said "this one is a key" and the only thing standing between the
/// store and somebody's export button was a comment.
///
/// The type lives here rather than in `omemo_device_store.dart` on purpose. The
/// guarantee only has force if the enforcer owns the type: a marker defined
/// next to the thing it protects can be quietly replaced by a second, nearly
/// identical marker in the same file six months later, and the backup module
/// would have no way to tell the two apart.
///
/// [bytes] is readable by anyone holding a [Secret] — that is what the sealed
/// store does with it. What cannot happen is the value reaching an archive,
/// because [Secret] is not a [BackupValue] and no encoder accepts one.
final class Secret {
  const Secret(this.bytes);

  final List<int> bytes;

  /// Redacted, so that a crash report or a debugPrint cannot turn a diagnostic
  /// into a key dump. The default `Instance of 'Secret'` would also have been
  /// safe; this exists because a leak through here would be
  /// indistinguishable, from the outside, from the leak the rest of this file
  /// prevents.
  @override
  String toString() => 'Secret(redacted, ${bytes.length} bytes)';
}

/// One cell of a backup.
///
/// Sealed, with every member declared below, and that is the whole mechanism.
/// A sealed class's subtypes are confined to its own library, so there is no
/// `class KeyValue extends BackupValue` written later by somebody who did not
/// read this comment — the archive's value domain is closed at compile time,
/// not by a list somebody has to remember to update.
///
/// Deliberately no factory taking `Object?`. A generic constructor is where a
/// guarantee like this normally leaks: `BackupValue.of(anything)` looks
/// harmless and re-opens the door for every caller at once. [cellFromJson] is
/// the only function here that accepts an untyped value, and it exists because
/// the restore path starts from bytes that came from outside the app.
sealed class BackupValue {
  /// Const so the four scalar leaves stay value types.
  ///
  /// Not decoration: `encodeBackup` walks a tree of these and a `BackupValue`
  /// that could not be held in a `const` context would not fit in a
  /// `switch` expression over a literal list — which is the shape the decoder
  /// uses, because the decoder is the untrusted direction.
  const BackupValue();
}

/// Text: message bodies, JIDs, stanza and origin ids, emoji.
///
/// `null` is not a member of this class and never will be. A SQL NULL is
/// carried as an absent entry in the row map, and the difference matters: a
/// column that is `NULL` says "this did not happen", while a column that is
/// missing from the row says "nobody recorded it", and a restore that cannot
/// tell those apart is a restore that invents history.
final class BackupText extends BackupValue {
  const BackupText(this.value);
  final String value;
}

/// An integer: unread counts, pin order.
///
/// No double, and that is not an oversight. Nothing in this schema is a real
/// number, and JSON numbers are the one part of a payload a re-encode can
/// render differently from the bytes on disk. Leaving them out removes the
/// only way "the archive decoded but the checksum disagreed" could ever come
/// from something other than real damage.
final class BackupNumber extends BackupValue {
  const BackupNumber(this.value);
  final int value;
}

/// A boolean.
final class BackupFlag extends BackupValue {
  const BackupFlag(this.value);
  final bool value;
}

/// A timestamp.
///
/// ISO-8601 in UTC with fixed width, never epoch millis. The archive is a text
/// file a user may open in a text editor in five years, and
/// `2026-10-03T09:14:00.000Z` answers "when was this" without a converter. UTC
/// and fixed width because the manifest's date range is compared as text: mixed
/// offsets would sort wrongly, and the "newest message" would be the wrong one.
final class BackupStamp extends BackupValue {
  const BackupStamp(this.value);
  final DateTime value;
}

/// `value.cell` — the literal door into a row.
///
/// One extension per type rather than one on `Object?`, and that is the whole
/// point. A single `Object?` extension is the ergonomic choice, and it is
/// exactly the hole this file is about: `secret.cell` would have to decide what
/// a [Secret] is, and the only answer available at runtime is "some bytes".
/// Split by type, there is no expression that turns a [Secret] into a
/// [BackupValue] at all.
extension BackupTextCells on String {
  BackupValue get cell => BackupText(this);
}

extension BackupNumberCells on int {
  BackupValue get cell => BackupNumber(this);
}

extension BackupFlagCells on bool {
  BackupValue get cell => BackupFlag(this);
}

extension BackupStampCells on DateTime {
  BackupValue get cell => BackupStamp(toUtc());
}

/// `nullable.cellOrNull` for a column that may hold SQL NULL.
extension BackupNullableStampCells on DateTime? {
  BackupValue? get cellOrNull {
    final value = this;
    return value == null ? null : BackupStamp(value.toUtc());
  }
}

/// The tables an archive may contain.
///
/// Declared in restore order: `chats` before `messages`, because
/// `messages.chat_jid` references `chats.jid` and a restore that inserts the
/// other way round fails on the foreign key at the worst possible moment. The
/// payload is written in this order, so the file reads in the order it has to be
/// applied.
enum BackupTable {
  chats,
  messages,
  rosterEntries,
  blockedContacts,
  pinnedMessages,
  subscriptionRequests,
  pendingCorrections,
  reactions,

  /// Per-chat auto-translate target language. One row, one language.
  chatTranslateSettings,

  /// Incoming XEP-0171 translations, and the local original of a replaced send.
  messageTranslations,

  /// Peer fingerprints + trust/active (public; not sealed private keys).
  omemoIdentities,
  meta;

  /// The SQLite table name, which is what the archive uses.
  ///
  /// The snake_case SQL name rather than the drift property name, so a writer
  /// can hand a row's column map straight through and a person comparing this
  /// file against the schema is looking at the same strings the schema uses.
  String get tableName => switch (this) {
    chats => 'chats',
    messages => 'messages',
    rosterEntries => 'roster_entries',
    blockedContacts => 'blocked_contacts',
    pinnedMessages => 'pinned_messages',
    subscriptionRequests => 'subscription_requests',
    pendingCorrections => 'pending_corrections',
    reactions => 'reactions',
    chatTranslateSettings => 'chat_translate_settings',
    messageTranslations => 'message_translations',
    omemoIdentities => 'omemo_identities',
    meta => 'meta',
  };
}

/// What a cell holds. Four kinds, because the schema has four kinds.
enum BackupColumnKind { text, integer, flag, stamp }

/// One allow-listed column, with the type the archive stores it as.
final class BackupColumn {
  const BackupColumn(this.name, this.kind, {this.nullable = false});

  /// The SQLite column name.
  final String name;
  final BackupColumnKind kind;

  /// True when the column may hold SQL NULL.
  ///
  /// Recorded rather than inferred from the value, because "the value is null"
  /// and "this column can be null" are different questions and only the second
  /// one is a decision this file is allowed to make on the schema's behalf.
  final bool nullable;
}

/// One table's place in the allow-list: its columns, and how they are typed.
final class BackupTableSpec {
  const BackupTableSpec(
    this.table,
    this.columns, {
    this.metaKeyPrefixes = const [],
  });

  final BackupTable table;
  final List<BackupColumn> columns;

  /// For `meta` only: the key prefixes this archive may carry.
  final List<String> metaKeyPrefixes;

  BackupColumn? column(String name) {
    for (final column in columns) {
      if (column.name == name) return column;
    }
    return null;
  }

  bool allowsMetaKey(String key) => metaKeyPrefixes.any(key.startsWith);
}

/// Everything an archive may contain, as data.
///
/// Allow-list, not deny-list.
///
/// A deny-list has to be updated every time a table is added, and the day
/// somebody forgets is the day the identity keys silently start appearing in a
/// file the user emails to themselves. An allow-list fails closed: a new table
/// is excluded until somebody decides to include it, which is the correct
/// default for anything that can decrypt a year of messages.
///
/// Read [rowRejection] as the only way in. It is written per row and per
/// column, which means a column can only enter an archive by being spelled out
/// here first — including a column of a table that is already listed, and
/// including a key inside `meta`.
const Map<BackupTable, BackupTableSpec> kBackupTables = {
  BackupTable.chats: BackupTableSpec(BackupTable.chats, [
    BackupColumn('jid', BackupColumnKind.text),
    BackupColumn('title', BackupColumnKind.text),
    BackupColumn('last_activity', BackupColumnKind.stamp),
    BackupColumn('appearance', BackupColumnKind.text),
    BackupColumn('pinned', BackupColumnKind.flag),
    BackupColumn('muted', BackupColumnKind.flag),
    BackupColumn('always_notify', BackupColumnKind.flag),
    BackupColumn('archived', BackupColumnKind.flag),
    BackupColumn('unread_count', BackupColumnKind.integer),
    BackupColumn('unread_mentions', BackupColumnKind.integer),
    BackupColumn('last_read_at', BackupColumnKind.stamp),
    BackupColumn('track_override', BackupColumnKind.text),
    BackupColumn('is_group', BackupColumnKind.flag),
    BackupColumn('muc_nick', BackupColumnKind.text),
    BackupColumn('muc_private_non_anonymous', BackupColumnKind.flag),
  ]),
  // `id` is deliberately absent. It is a storage artefact of the device the
  // backup came from: nothing in this schema references a message by row id —
  // reactions and corrections key on the origin-id, pins on the stanza id — so
  // carrying it forward restores nothing, and on a device that already holds
  // any of these messages it collides.
  BackupTable.messages: BackupTableSpec(BackupTable.messages, [
    BackupColumn('chat_jid', BackupColumnKind.text),
    BackupColumn('sender', BackupColumnKind.text),
    BackupColumn('stanza_id', BackupColumnKind.text),
    BackupColumn('body', BackupColumnKind.text),
    BackupColumn('timestamp', BackupColumnKind.stamp),
    BackupColumn('enc_mode', BackupColumnKind.text),
    BackupColumn('incoming', BackupColumnKind.flag),
    BackupColumn('delivered', BackupColumnKind.flag),
    BackupColumn('displayed', BackupColumnKind.flag),
    BackupColumn('send_status', BackupColumnKind.integer),
    BackupColumn('markable', BackupColumnKind.flag),
    BackupColumn('is_carbon', BackupColumnKind.flag),
    BackupColumn('delivery_error', BackupColumnKind.text),
    BackupColumn('retracted', BackupColumnKind.flag),
    BackupColumn('retracted_at', BackupColumnKind.stamp, nullable: true),
    BackupColumn('reply_to', BackupColumnKind.text),
    BackupColumn('reply_body', BackupColumnKind.text),
    BackupColumn('reply_author', BackupColumnKind.text),
    BackupColumn('edited_at', BackupColumnKind.stamp, nullable: true),
    BackupColumn('media_url', BackupColumnKind.text),
    BackupColumn('media_mime', BackupColumnKind.text),
    BackupColumn('media_name', BackupColumnKind.text),
    BackupColumn('mentions_me', BackupColumnKind.flag),
    // local_path is device-local and deliberately omitted from backups.
  ]),
  BackupTable.rosterEntries: BackupTableSpec(BackupTable.rosterEntries, [
    BackupColumn('jid', BackupColumnKind.text),
    BackupColumn('name', BackupColumnKind.text),
    BackupColumn('subscription', BackupColumnKind.text),
    BackupColumn('ask', BackupColumnKind.text),
    BackupColumn('groups', BackupColumnKind.text),
  ]),
  BackupTable.blockedContacts: BackupTableSpec(BackupTable.blockedContacts, [
    BackupColumn('jid', BackupColumnKind.text),
    BackupColumn('blocked_at', BackupColumnKind.stamp),
  ]),
  BackupTable.pinnedMessages: BackupTableSpec(BackupTable.pinnedMessages, [
    BackupColumn('chat_jid', BackupColumnKind.text),
    BackupColumn('stanza_id', BackupColumnKind.text),
    BackupColumn('pinned_at', BackupColumnKind.stamp),
    BackupColumn('sequence', BackupColumnKind.integer),
  ]),
  BackupTable.subscriptionRequests: BackupTableSpec(
    BackupTable.subscriptionRequests,
    [
      BackupColumn('jid', BackupColumnKind.text),
      BackupColumn('outgoing', BackupColumnKind.flag),
      BackupColumn('asked_at', BackupColumnKind.stamp),
    ],
  ),
  BackupTable.pendingCorrections: BackupTableSpec(
    BackupTable.pendingCorrections,
    [
      BackupColumn('target_id', BackupColumnKind.text),
      BackupColumn('body', BackupColumnKind.text),
      BackupColumn('enc_mode', BackupColumnKind.text),
      BackupColumn('corrected_at', BackupColumnKind.stamp),
    ],
  ),
  BackupTable.reactions: BackupTableSpec(BackupTable.reactions, [
    BackupColumn('target_id', BackupColumnKind.text),
    BackupColumn('emoji', BackupColumnKind.text),
    BackupColumn('reactor', BackupColumnKind.text),
    BackupColumn('reacted_at', BackupColumnKind.stamp),
  ]),
  BackupTable.chatTranslateSettings: BackupTableSpec(
    BackupTable.chatTranslateSettings,
    [
      BackupColumn('chat_jid', BackupColumnKind.text),
      BackupColumn('lang', BackupColumnKind.text),
    ],
  ),
  BackupTable.messageTranslations: BackupTableSpec(
    BackupTable.messageTranslations,
    [
      BackupColumn('chat_jid', BackupColumnKind.text),
      BackupColumn('stanza_id', BackupColumnKind.text),
      BackupColumn('lang', BackupColumnKind.text),
      BackupColumn('body', BackupColumnKind.text),
      BackupColumn('source_lang', BackupColumnKind.text),
      BackupColumn('engine', BackupColumnKind.text),
    ],
  ),
  // Public fingerprints and local trust/active decisions — not sealed private
  // keys. Restoring them keeps verification state across reinstalls the way
  // monocles keeps the identities table with the account DB.
  BackupTable.omemoIdentities: BackupTableSpec(BackupTable.omemoIdentities, [
    BackupColumn('bare_jid', BackupColumnKind.text),
    BackupColumn('fingerprint', BackupColumnKind.text),
    BackupColumn('device_id', BackupColumnKind.integer),
    BackupColumn('omemo2', BackupColumnKind.flag),
    BackupColumn('trust', BackupColumnKind.text),
    BackupColumn('active', BackupColumnKind.flag),
    BackupColumn('last_activation', BackupColumnKind.integer),
  ]),
  // meta is the one table that cannot be dumped whole, because it is a
  // key/value bag and not a shape. `OmemoDeviceStore` saves the sealed identity
  // key to "a meta-style row", so copying this table wholesale copies the key
  // with it — and that row's name is an ordinary string in somebody else's
  // code, which no type system can stop. Hence a key allow-list.
  //
  // Drafts and the plaintext acknowledgement are included: both are local
  // decisions about the user's own words, both are lost in a reinstall, and
  // neither is a secret anybody else can use. `omemo_published_ids` /
  // `omemo2_published_ids` are excluded for a second reason — they record
  // which ids on our own published device lists are superseded builds of
  // *this* installation, so restoring them onto another device has us
  // pruning the live device out of our own list.
  BackupTable.meta: BackupTableSpec(
    BackupTable.meta,
    [
      BackupColumn('key', BackupColumnKind.text),
      BackupColumn('value', BackupColumnKind.text),
    ],
    metaKeyPrefixes: ['draft:', 'plaintext_ack:', 'muc_subject_read:'],
  ),
};

/// The spec for [table], or a loud failure if somebody added a table to the
/// enum and never decided whether it may be backed up.
///
/// Not a silent skip. The whole value of an allow-list is that forgetting is
/// visible; a table silently missing from every archive looks exactly like a
/// table with no rows, and the user finds out when the messages are gone.
BackupTableSpec backupSpecOf(BackupTable table) {
  final spec = kBackupTables[table];
  if (spec == null) {
    throw StateError('table ${table.tableName} has no backup spec');
  }
  return spec;
}

/// Why a table or column was refused.
///
/// Names only, never values: a refusal ends up in a log line, and a log is the
/// last place a message body — or a key — should end up.
enum BackupRejectionKind {
  unknownTable,
  unknownColumn,
  missingColumn,
  wrongType,
  unknownMetaKey,
  secretMaterial,
  manifestMismatch,
  malformedPayload,
}

/// Raised when something outside the allow-list reaches the archive.
///
/// An exception rather than a return value because every caller of the encoder
/// has to deal with it, and a function that can return either an archive or a
/// refusal is a function whose refusal somebody will forget to check.
final class BackupRejected implements Exception {
  const BackupRejected(this.kind, {this.table, this.column, this.detail});

  final BackupRejectionKind kind;
  final String? table;
  final String? column;
  final String? detail;

  String get problem => switch (kind) {
    BackupRejectionKind.unknownTable =>
      'table "$table" is not on the backup allow-list',
    BackupRejectionKind.unknownColumn =>
      'column "$column" is not on the allow-list for table "$table"',
    BackupRejectionKind.missingColumn =>
      'a "$table" row is missing column "$column"',
    BackupRejectionKind.wrongType =>
      'column "$column" of "$table" holds the wrong kind of value'
          '${detail == null ? '' : ' ($detail)'}',
    BackupRejectionKind.unknownMetaKey =>
      'meta key "$column" is not on the allow-list',
    BackupRejectionKind.secretMaterial =>
      'refused: key material cannot be encoded into a backup',
    BackupRejectionKind.manifestMismatch =>
      'the manifest does not describe the rows it ships with'
          '${detail == null ? '' : ' ($detail)'}',
    BackupRejectionKind.malformedPayload =>
      'the payload is not shaped like a backup'
          '${detail == null ? '' : ' ($detail)'}',
  };

  @override
  String toString() => 'BackupRejected($kind: $problem)';
}

/// Why [row] may not be written, or null when it is fine.
///
/// Public and row-at-a-time because the writer that eventually feeds this will
/// stream rows into a document rather than hold a whole archive in memory, and
/// a stream cannot take the file back once it has emitted a row. Validation has
/// to be callable *before* a row is written, not only as a pass over the
/// finished archive: a check that runs after the bytes are gone is not a check.
BackupRejected? rowRejection(BackupTable table, BackupRow row) {
  final spec = backupSpecOf(table);
  for (final key in row.keys) {
    if (spec.column(key) == null) {
      return BackupRejected(
        BackupRejectionKind.unknownColumn,
        table: spec.table.tableName,
        column: key,
      );
    }
  }
  for (final column in spec.columns) {
    if (!row.containsKey(column.name)) {
      return BackupRejected(
        BackupRejectionKind.missingColumn,
        table: spec.table.tableName,
        column: column.name,
      );
    }
    final cell = row[column.name];
    if (cell == null) {
      if (!column.nullable) {
        return BackupRejected(
          BackupRejectionKind.wrongType,
          table: spec.table.tableName,
          column: column.name,
          detail: 'null in a column that is never null',
        );
      }
      continue;
    }
    if (_kindOf(cell) != column.kind) {
      return BackupRejected(
        BackupRejectionKind.wrongType,
        table: spec.table.tableName,
        column: column.name,
        detail: 'stored as ${cell.runtimeType}',
      );
    }
    // The key column only. Testing the value against the prefix allow-list as
    // well would reject every draft that does not begin with "draft:", which is
    // most of them.
    if (table == BackupTable.meta &&
        column.name == 'key' &&
        cell is BackupText &&
        !spec.allowsMetaKey(cell.value)) {
      return BackupRejected(
        BackupRejectionKind.unknownMetaKey,
        table: spec.table.tableName,
        column: cell.value,
      );
    }
  }
  return null;
}

/// The kind [value] is stored as.
///
/// No `default` arm, and that is deliberate: adding a sixth [BackupValue] is a
/// compile error here rather than a column that silently stops being written
/// and an archive that quietly loses data on the way out.
BackupColumnKind _kindOf(BackupValue value) => switch (value) {
  BackupText() => BackupColumnKind.text,
  BackupNumber() => BackupColumnKind.integer,
  BackupFlag() => BackupColumnKind.flag,
  BackupStamp() => BackupColumnKind.stamp,
};

/// The cell [json] represents, for [column].
///
/// The only function in this file that takes an untyped value, because the
/// restore path starts from bytes that arrived from outside the app. The column
/// decides the type, not the JSON: that is what makes an integer in a text
/// column a defect instead of something to coerce, and it is why a timestamp
/// survives the round trip without a second marker field.
///
/// Throws [BackupRejected].
BackupValue? cellFromJson(BackupColumn column, Object? json) {
  // Named rather than folded into [BackupRejectionKind.wrongType] so the log
  // says *key material* and not the type of the thing that was refused. This
  // cannot be reached by a decoded archive — no JSON decodes to [Secret] — so
  // the only way here is code doing it on purpose. It is the braces to the
  // sealed type's belt, and it exists because the alternative is relying on
  // nobody ever writing the line.
  if (json is Secret) {
    throw const BackupRejected(BackupRejectionKind.secretMaterial);
  }
  if (json == null) {
    if (!column.nullable) {
      throw BackupRejected(
        BackupRejectionKind.wrongType,
        column: column.name,
        detail: 'null in a column that is never null',
      );
    }
    return null;
  }
  return switch (column.kind) {
    BackupColumnKind.text => BackupText(_jsonString(column, json)),
    BackupColumnKind.integer => BackupNumber(_jsonInt(column, json)),
    BackupColumnKind.flag => BackupFlag(_jsonBool(column, json)),
    BackupColumnKind.stamp => BackupStamp(_jsonStamp(column, json)),
  };
}

String _jsonString(BackupColumn column, Object? json) {
  if (json is String) return json;
  throw BackupRejected(
    BackupRejectionKind.wrongType,
    column: column.name,
    detail: 'expected text, found ${json.runtimeType}',
  );
}

int _jsonInt(BackupColumn column, Object? json) {
  if (json is int) return json;
  throw BackupRejected(
    BackupRejectionKind.wrongType,
    column: column.name,
    detail: 'expected an integer, found ${json.runtimeType}',
  );
}

bool _jsonBool(BackupColumn column, Object? json) {
  if (json is bool) return json;
  throw BackupRejected(
    BackupRejectionKind.wrongType,
    column: column.name,
    detail: 'expected a boolean, found ${json.runtimeType}',
  );
}

DateTime _jsonStamp(BackupColumn column, Object? json) {
  final text = _jsonString(column, json);
  final parsed = DateTime.tryParse(text);
  if (parsed == null) {
    throw BackupRejected(
      BackupRejectionKind.wrongType,
      column: column.name,
      detail: 'not an ISO-8601 timestamp',
    );
  }
  return parsed.toUtc();
}

/// CRC-32 of [bytes], as eight lowercase hex digits.
///
/// An integrity check, not a security control, and it must not be read as one.
/// It answers exactly one question: were these the bytes that were written.
/// An archive is plaintext and holds no key material, so anybody who can forge
/// a checksum can also read and edit the payload it covers — there is nothing
/// here for a checksum to protect. What it does buy is the question users
/// actually ask about a file that has been through cloud storage and a
/// downgrade: "is this the same archive, or did something happen to it?".
///
/// Deliberately not SHA-256. The archive is not authenticated, so the only
/// thing a hash buys over a checksum is a false sense of having checked, and
/// [Secret] — whose integrity *is* a security property, and is checked by
/// AES-GCM's tag — must never look like something this file also handles.
///
/// CRC-32 rather than something home-grown because the published check value
/// (`123456789` → `cbf43926`) is pinned by the test, so an implementation that
/// drifts fails loudly instead of reporting corruption that did not happen.
/// Upgrading this is a format version bump, not an edit.
String crc32Hex(List<int> bytes) {
  var crc = 0xFFFFFFFF;
  for (final byte in bytes) {
    crc = (crc >> 8) ^ _crcTable[(crc ^ byte) & 0xFF];
  }
  return (crc ^ 0xFFFFFFFF).toRadixString(16).padLeft(8, '0');
}

final List<int> _crcTable = List<int>.generate(256, (index) {
  var value = index;
  for (var bit = 0; bit < 8; bit++) {
    value = (value & 1) != 0 ? 0xEDB88320 ^ (value >> 1) : value >> 1;
  }
  return value;
});

/// One row: column name to cell.
///
/// A nullable cell is an entry whose value is null. An absent entry is not a
/// NULL, it is a malformed row, and [rowRejection] says so — see [BackupText]
/// for why the two have to stay apart.
typedef BackupRow = Map<String, BackupValue?>;

/// What an archive contains, in numbers, so a restore can show the user what
/// they are about to overwrite before they overwrite it.
///
/// The counts are total: every allow-listed table appears, zero included. A
/// restore preview that omits a table it happens to hold nothing for reads as
/// "this archive has no drafts" versus "this archive says nothing about
/// drafts", and the second is the one where a user's unsent message quietly
/// fails to come back.
final class BackupManifest {
  const BackupManifest({
    required this.counts,
    required this.oldest,
    required this.newest,
    required this.accountJid,
  });

  /// Counted from the rows themselves, never from what the caller believes it
  /// wrote.
  factory BackupManifest.of(
    Map<BackupTable, List<BackupRow>> tables, {
    required String accountJid,
  }) {
    final counts = <BackupTable, int>{
      for (final table in BackupTable.values) table: tables[table]?.length ?? 0,
    };
    DateTime? oldest;
    DateTime? newest;
    for (final row in tables[BackupTable.messages] ?? const <BackupRow>[]) {
      final cell = row['timestamp'];
      if (cell is! BackupStamp) continue;
      if (oldest == null || cell.value.isBefore(oldest)) oldest = cell.value;
      if (newest == null || cell.value.isAfter(newest)) newest = cell.value;
    }
    return BackupManifest(
      counts: counts,
      oldest: oldest,
      newest: newest,
      accountJid: accountJid,
    );
  }

  final Map<BackupTable, int> counts;

  /// Oldest message timestamp, or null when there are no messages.
  ///
  /// Null rather than "now", and null rather than an error: a backup of an
  /// empty account is a thing a user does on purpose (a new phone before the
  /// archive has arrived, a wipe they meant to do), and it has to restore as
  /// cleanly as a full one.
  final DateTime? oldest;
  final DateTime? newest;

  /// The account the archive was made on.
  ///
  /// Shown before a restore overwrites something. An archive that cannot name
  /// its account is labelled unknown rather than being attributed to whoever
  /// happens to open it — restoring somebody else's history over your own
  /// because the file forgot to say whose it was is the failure this field
  /// exists to make visible.
  final String accountJid;

  int countOf(BackupTable table) => counts[table] ?? 0;

  int get chatCount => countOf(BackupTable.chats);

  int get messageCount => countOf(BackupTable.messages);

  bool get isEmpty => BackupTable.values.every((table) => countOf(table) == 0);

  /// Whether this manifest describes [other].
  ///
  /// Compared against a manifest rebuilt from the rows on every read, so the
  /// numbers the user is shown before a restore are the numbers the rows
  /// actually have. A manifest that disagrees with its own payload is a file
  /// that has been assembled by something other than [encodeBackup].
  bool sameAs(BackupManifest other) {
    for (final table in BackupTable.values) {
      if (countOf(table) != other.countOf(table)) return false;
    }
    return _sameInstant(oldest, other.oldest) &&
        _sameInstant(newest, other.newest);
  }

  Map<String, Object?> toJson() => {
    'counts': {
      for (final table in BackupTable.values) table.tableName: countOf(table),
    },
    'oldest': oldest?.toUtc().toIso8601String(),
    'newest': newest?.toUtc().toIso8601String(),
    'accountJid': accountJid,
  };
}

/// `DateTime` equality also compares the time zone, so two descriptions of the
/// same instant in different zones would otherwise look like a mismatch and
/// every archive written on a device that was not set to UTC would be refused.
bool _sameInstant(DateTime? left, DateTime? right) => left == null
    ? right == null
    : right != null && left.toUtc() == right.toUtc();

/// A backup that has been read, checked and validated.
///
/// Only [decodeBackupText], [decodeBackup] and the migration path can build one,
/// which is the point: there is no way to obtain an archive that has not been
/// through the allow-list.
final class BackupArchive {
  BackupArchive._({
    required this.tables,
    required this.manifest,
    required this.createdAt,
    required this.appVersion,
    required this.schemaVersion,
    required this.formatVersion,
  });

  final Map<BackupTable, List<BackupRow>> tables;
  final BackupManifest manifest;
  final DateTime createdAt;

  /// The app that wrote the archive. For diagnostics only: what a restore has
  /// to understand is [formatVersion], and reading a file's contents by what
  /// version string it happens to carry is how a restore ends up guessing.
  final String appVersion;

  /// The drift schema version of the writing install.
  ///
  /// Recorded so a future restore can say "this was written by a build with 19
  /// columns" rather than guessing from what is missing.
  final int schemaVersion;

  /// The format version the rows are in, which after a migration is not the
  /// version in the file.
  final int formatVersion;

  List<BackupRow> rowsOf(BackupTable table) =>
      tables[table] ?? const <BackupRow>[];

  /// The cell at [row]/[column], or null when the column holds SQL NULL.
  ///
  /// Null means "the value is null", never "the column is absent": every row
  /// that came through the validator has every allow-listed column, so the
  /// restore path can insert a row without first working out what shape it is
  /// looking at.
  BackupValue? cell(BackupTable table, int row, String column) =>
      rowsOf(table)[row][column];
}

/// First bytes of every archive, and the first key of the header.
///
/// The marker is checked as a *prefix of the raw header* rather than as a
/// parsed field, because a header cut in half does not parse and "this is one
/// of ours, but incomplete" is the one answer that sends the user to the right
/// place. Being first is what makes the prefix check meaningful.
const String kBackupMagic = 'resonchat.backup';

/// The format version this build writes, and reads without a migration.
const int kBackupFormatVersion = 1;

// Version policy, so the next change does not have to re-derive it: adding a
// column to the allow-list above is *not* a format change, because the key set
// is frozen in this file and not read out of the table definition — a v1
// archive and a v2 archive differ only where this file says they do. Renaming
// a column, splitting a table, or changing what a stored value means is a
// format change and must come with a migration in [decodeBackupText]'s caller.
//
// The version is checked before the contents and never guessed at: a file this
// build reads as v1 when it was written as v2 restores with data missing, and
// missing data does not announce itself.

/// Writes an archive.
///
/// Throws [BackupRejected] — every row is checked against the allow-list
/// before a single byte is produced, so there is no output to clean up if a
/// later row is the one that should not have been there. That ordering is not
/// tidiness: a writer that emits rows as it reads them has already put them on
/// a document the user is about to keep.
///
/// Tables left out are written as empty rather than refused. "There is nothing
/// in this table" is the answer a backup gives for a table it was not asked
/// about, and refusing it would make an empty archive impossible to make.
///
/// Apart from [createdAt] the output is a pure function of the rows and the
/// header arguments, so two backups of the same state differ only in the
/// timestamp — which is what makes "is this the same archive as yesterday's?"
/// a question with an answer.
String encodeBackup({
  required Map<BackupTable, List<BackupRow>> tables,
  required String appVersion,
  required int schemaVersion,
  required String accountJid,
  DateTime? createdAt,
}) {
  final tableJson = <String, Object?>{};
  for (final spec in kBackupTables.values) {
    final encoded = <Map<String, Object?>>[];
    for (final row in tables[spec.table] ?? const <BackupRow>[]) {
      final rejection = rowRejection(spec.table, row);
      if (rejection != null) throw rejection;
      encoded.add(_rowJson(spec, row));
    }
    tableJson[spec.table.tableName] = encoded;
  }
  final payload = <String, Object?>{
    'tables': tableJson,
    'manifest': BackupManifest.of(tables, accountJid: accountJid).toJson(),
  };
  final payloadBytes = utf8.encode(jsonEncode(payload));
  final header = <String, Object?>{
    'magic': kBackupMagic,
    'formatVersion': kBackupFormatVersion,
    'createdAt': (createdAt ?? DateTime.now()).toUtc().toIso8601String(),
    'appVersion': appVersion,
    'schemaVersion': schemaVersion,
    // The payload is a separate document rather than a field of the header for
    // one reason: the checksum has to cover the payload's bytes *as they sit in
    // the file*. Hashing a re-encoding of the parsed object is only equivalent
    // while every writer agrees about escaping — and a future build, on a
    // different platform, escaping a non-ASCII message body differently would
    // then report every archive ever written as corrupt. A declared byte length
    // after a newline is what makes the covered region exact rather than
    // reconstructed.
    'payloadLength': payloadBytes.length,
    'checksum': 'crc32:${crc32Hex(payloadBytes)}',
  };
  return '${jsonEncode(header)}\n${jsonEncode(payload)}';
}

/// [encodeBackup] as the bytes to hand to a document stream.
Uint8List encodeBackupBytes({
  required Map<BackupTable, List<BackupRow>> tables,
  required String appVersion,
  required int schemaVersion,
  required String accountJid,
  DateTime? createdAt,
}) => Uint8List.fromList(
  utf8.encode(
    encodeBackup(
      tables: tables,
      appVersion: appVersion,
      schemaVersion: schemaVersion,
      accountJid: accountJid,
      createdAt: createdAt,
    ),
  ),
);

/// Reads an archive written in a different format version.
///
/// Returns the tables in [kBackupFormatVersion] terms. Everything after this is
/// still checked: the hook's rows go back through [rowRejection] and the
/// manifest is recomputed from them, because the point of an allow-list is that
/// nobody has read it carefully, and that includes the person who wrote the
/// migration.
///
/// Never called for a version this build already understands, and never called
/// on a payload that failed its checksum. Translating damaged input is how a
/// half-written file becomes a half-written database.
typedef BackupMigration = Map<BackupTable, List<BackupRow>> Function(
  Map<String, Object?> payload, {
  required int fromVersion,
});

/// Reads an archive from bytes, the way a document picker hands them over.
///
/// The door the file layer uses, so that a file which is not UTF-8 — some other
/// app's document, a truncated sync — is a reportable outcome rather than an
/// exception thrown out of a restore button.
BackupOutcome decodeBackup(List<int> bytes, {BackupMigration? migrate}) {
  try {
    return decodeBackupText(utf8.decode(bytes), migrate: migrate);
  } on FormatException {
    return BackupTruncated(byteLength: bytes.length, detail: 'not valid UTF-8');
  }
}

/// Reads an archive, naming every way it can fail.
///
/// A backup the app refuses to read is indistinguishable from data loss to the
/// user: they picked a file that used to work, and either answer leaves them
/// with no history. So the failures are separated by what the user can do about
/// them rather than by which exception happened to be thrown:
///
///   * wrong magic — not one of ours; pick the right file.
///   * truncated — the copy did not finish; make the backup again.
///   * checksum mismatch — complete but different; the file is not what it
///     claims to be, and an install step or a hand-edit both look like this.
///   * unknown version — intact, and this build does not read it; install the
///     app that wrote it, or supply a [BackupMigration].
///   * refused content — intact, and something in it may not be restored.
///
/// The last two are the ones that must never be collapsed into "corrupt": one
/// means the app is behind, the other means the app is doing its job, and
/// telling a user their archive is corrupt because it was written by a newer
/// version is how a working file gets thrown away.
BackupOutcome decodeBackupText(String text, {BackupMigration? migrate}) {
  final split = text.indexOf('\n');
  final headerText = split < 0 ? text : text.substring(0, split);
  final payloadText = split < 0 ? '' : text.substring(split + 1);
  final total = utf8.encode(text).length;

  if (!headerText.startsWith(_markerPrefix)) {
    return BackupNotABackup(found: _head(headerText));
  }

  Object? header;
  try {
    header = jsonDecode(headerText);
  } on FormatException {
    return BackupTruncated(byteLength: total, detail: 'the header is cut off');
  }
  if (header is! Map<String, Object?>) {
    return BackupTruncated(
      byteLength: total,
      detail: 'the header is not an object',
    );
  }

  final formatVersion = header['formatVersion'];
  final payloadLength = header['payloadLength'];
  final checksum = header['checksum'];
  final createdAt = header['createdAt'];
  final appVersion = header['appVersion'];
  final schemaVersion = header['schemaVersion'];
  if (formatVersion is! int ||
      payloadLength is! int ||
      checksum is! String ||
      createdAt is! String ||
      appVersion is! String ||
      schemaVersion is! int) {
    return BackupTruncated(
      byteLength: total,
      detail: 'the header is missing a field',
    );
  }
  final when = DateTime.tryParse(createdAt);
  if (when == null) {
    return BackupTruncated(
      byteLength: total,
      detail: 'createdAt is not a timestamp',
    );
  }

  // Length before checksum before contents. The order is the whole difference
  // between "the copy was interrupted" and "this file was altered", and both
  // orderings are guesses somebody already made and got wrong: a header field
  // is exactly what a damaged file gets wrong, so a version check first would
  // answer "made by a newer app" for a half-written file and send the user to
  // install an update that cannot help.
  final payloadStart = utf8
      .encode(text.substring(0, split < 0 ? 0 : split + 1))
      .length;
  final declaredTotal = payloadStart + payloadLength;
  if (total < declaredTotal) {
    return BackupTruncated(
      byteLength: total,
      detail: 'the payload stops ${declaredTotal - total} bytes early',
    );
  }
  if (total > declaredTotal) {
    return BackupTruncated(
      byteLength: total,
      detail: '${total - declaredTotal} bytes follow the declared payload',
    );
  }
  final expected = 'crc32:${crc32Hex(utf8.encode(payloadText))}';
  if (expected.toLowerCase() != checksum.trim().toLowerCase()) {
    return BackupChecksumMismatch(expected: expected, found: checksum.trim());
  }

  Object? payload;
  try {
    payload = jsonDecode(payloadText);
  } on FormatException {
    return BackupTruncated(
      byteLength: total,
      detail: 'the payload is not a complete document',
    );
  }
  if (payload is! Map<String, Object?>) {
    return BackupTruncated(
      byteLength: total,
      detail: 'the payload is not an object',
    );
  }

  if (formatVersion != kBackupFormatVersion) {
    if (migrate == null) {
      return BackupUnknownVersion(
        found: formatVersion,
        supported: kBackupFormatVersion,
      );
    }
    Map<BackupTable, List<BackupRow>> migrated;
    try {
      migrated = migrate(payload, fromVersion: formatVersion);
    } catch (error) {
      // The file is fine and this build is not. Saying "corrupt" here would
      // send the user looking for another backup instead of at the version they
      // just installed.
      return BackupMigrationFailed(found: formatVersion, error: error);
    }
    // The manifest is recomputed rather than read: a v0 archive's manifest may
    // describe rows the hook deliberately dropped, and the numbers shown before
    // a restore have to be the numbers that will exist after it.
    return _archiveFromTables(
      migrated,
      manifest: BackupManifest.of(migrated, accountJid: _accountJidOf(payload)),
      createdAt: when,
      appVersion: appVersion,
      schemaVersion: schemaVersion,
      formatVersion: formatVersion,
      // The only caller that passes this. Everything else builds an archive that
      // was already this build's format, where a non-null value would claim a
      // migration that never happened.
      migratedFrom: formatVersion,
    );
  }

  return adoptPayload(
    payload,
    createdAt: when,
    appVersion: appVersion,
    schemaVersion: schemaVersion,
    formatVersion: formatVersion,
  );
}

/// Validates a decoded payload and builds an archive from it.
///
/// Public because [BackupMigration]'s result has to go through the same
/// allow-list as a file's, and because that is the only honest place to put the
/// difference between "read a file" and "read some JSON somebody handed us".
///
/// A table the payload does not mention counts as empty; the manifest
/// comparison below is what catches a payload that has quietly lost one.
BackupOutcome adoptPayload(
  Map<String, Object?> payload, {
  required DateTime createdAt,
  required String appVersion,
  required int schemaVersion,
  required int formatVersion,
}) {
  try {
    return _adoptChecked(
      payload,
      createdAt: createdAt,
      appVersion: appVersion,
      schemaVersion: schemaVersion,
      formatVersion: formatVersion,
    );
  } on BackupRejected catch (rejection) {
    return BackupContentRejected(rejection);
  }
}

/// [adoptPayload]'s body, refusing by throwing.
///
/// Separate only so that the refusal paths can throw: a function that both
/// throws and returns a value has to be read twice to see which failures are
/// which, and this one has eight.
BackupOutcome _adoptChecked(
  Map<String, Object?> payload, {
  required DateTime createdAt,
  required String appVersion,
  required int schemaVersion,
  required int formatVersion,
}) {
  final tables = <BackupTable, List<BackupRow>>{};
  final raw = payload['tables'];
  if (raw is! Map<String, Object?>) {
    throw const BackupRejected(
      BackupRejectionKind.malformedPayload,
      detail: 'no tables object',
    );
  }
  for (final entry in raw.entries) {
    final table = _tableNamed(entry.key);
    if (table == null) {
      throw BackupRejected(BackupRejectionKind.unknownTable, table: entry.key);
    }
    if (entry.value is! List) {
      throw BackupRejected(
        BackupRejectionKind.malformedPayload,
        table: entry.key,
        detail: 'not a list of rows',
      );
    }
    final spec = backupSpecOf(table);
    final rows = <BackupRow>[];
    for (final rawRow in entry.value as List<Object?>) {
      if (rawRow is! Map<String, Object?>) {
        throw BackupRejected(
          BackupRejectionKind.malformedPayload,
          table: entry.key,
          detail: 'a row is not an object',
        );
      }
      final row = <String, BackupValue?>{};
      for (final cell in rawRow.entries) {
        final column = spec.column(cell.key);
        if (column == null) {
          throw BackupRejected(
            BackupRejectionKind.unknownColumn,
            table: entry.key,
            column: cell.key,
          );
        }
        row[column.name] = cellFromJson(column, cell.value);
      }
      rows.add(row);
    }
    tables[table] = rows;
  }
  final manifestJson = payload['manifest'];
  if (manifestJson is! Map<String, Object?>) {
    throw const BackupRejected(
      BackupRejectionKind.malformedPayload,
      detail: 'no manifest',
    );
  }
  final stored = _manifestFromJson(manifestJson);
  final recomputed = BackupManifest.of(tables, accountJid: stored.accountJid);
  if (!recomputed.sameAs(stored)) {
    throw const BackupRejected(
      BackupRejectionKind.manifestMismatch,
      detail: 'the counts or the date range do not match the rows',
    );
  }
  return _archiveFromTables(
    tables,
    manifest: stored,
    createdAt: createdAt,
    appVersion: appVersion,
    schemaVersion: schemaVersion,
    formatVersion: formatVersion,
  );
}

/// The header's marker plus the quote and brace that must follow it, used to
/// recognise our own file before trying to parse a header that may be half a
/// file.
const String _markerPrefix = '{"magic":"$kBackupMagic"';

BackupTable? _tableNamed(String name) {
  for (final table in BackupTable.values) {
    if (table.tableName == name) return table;
  }
  return null;
}

String _accountJidOf(Map<String, Object?> payload) {
  final manifest = payload['manifest'];
  if (manifest is! Map<String, Object?>) return '';
  final jid = manifest['accountJid'];
  return jid is String ? jid : '';
}

BackupManifest _manifestFromJson(Map<String, Object?> json) {
  final raw = json['counts'];
  if (raw is! Map<String, Object?>) {
    throw const BackupRejected(
      BackupRejectionKind.malformedPayload,
      detail: 'the manifest has no counts',
    );
  }
  final counts = <BackupTable, int>{};
  for (final entry in raw.entries) {
    final table = _tableNamed(entry.key);
    if (table == null) {
      throw BackupRejected(BackupRejectionKind.unknownTable, table: entry.key);
    }
    final count = entry.value;
    if (count is! int || count < 0) {
      throw BackupRejected(
        BackupRejectionKind.wrongType,
        table: entry.key,
        detail: 'not a row count',
      );
    }
    counts[table] = count;
  }
  final jid = json['accountJid'];
  return BackupManifest(
    counts: counts,
    oldest: _stampFromJson(json['oldest']),
    newest: _stampFromJson(json['newest']),
    accountJid: jid is String ? jid : '',
  );
}

DateTime? _stampFromJson(Object? json) {
  if (json == null) return null;
  if (json is! String) {
    throw const BackupRejected(
      BackupRejectionKind.wrongType,
      detail: 'a manifest timestamp is not text',
    );
  }
  final parsed = DateTime.tryParse(json);
  if (parsed == null) {
    throw const BackupRejected(
      BackupRejectionKind.wrongType,
      detail: 'a manifest timestamp is not ISO-8601',
    );
  }
  return parsed.toUtc();
}

Map<String, Object?> _rowJson(BackupTableSpec spec, BackupRow row) {
  final out = <String, Object?>{};
  // Spec order, not map order, so the file is byte-identical for identical
  // data no matter how the caller built the row.
  for (final column in spec.columns) {
    out[column.name] = _cellJson(row[column.name]);
  }
  return out;
}

Object? _cellJson(BackupValue? cell) => switch (cell) {
  null => null,
  BackupText(:final value) => value,
  BackupNumber(:final value) => value,
  BackupFlag(:final value) => value,
  BackupStamp(:final value) => value.toUtc().toIso8601String(),
};

BackupOutcome _archiveFromTables(
  Map<BackupTable, List<BackupRow>> tables, {
  required BackupManifest manifest,
  required DateTime createdAt,
  required String appVersion,
  required int schemaVersion,
  required int formatVersion,
  int? migratedFrom,
}) {
  try {
    for (final spec in kBackupTables.values) {
      for (final row in tables[spec.table] ?? const <BackupRow>[]) {
        final rejection = rowRejection(spec.table, row);
        if (rejection != null) throw rejection;
      }
    }
    return BackupOk(
      BackupArchive._(
        tables: Map<BackupTable, List<BackupRow>>.unmodifiable({
          for (final table in BackupTable.values)
            table: List<BackupRow>.unmodifiable(
              tables[table] ?? const <BackupRow>[],
            ),
        }),
        manifest: manifest,
        createdAt: createdAt,
        appVersion: appVersion,
        schemaVersion: schemaVersion,
        formatVersion: formatVersion,
      ),
      // Carried through rather than set by the caller afterwards: this is the
      // only place the outcome is built, so a migration that produced a valid
      // archive and then lost the fact that it migrated would hand the restore
      // path a file it has to describe as "read N messages" — indistinguishable,
      // to the user, from an archive that arrived intact and was quietly
      // rearranged on the way in.
      migratedFrom: migratedFrom,
    );
  } on BackupRejected catch (rejection) {
    return BackupContentRejected(rejection);
  }
}

/// A short printable description of what an unreadable file starts with.
///
/// Bounded and stripped of anything unprintable because it goes into a log: the
/// bytes of a file the user picked are not ours to reproduce anywhere.
String _head(String text, [int limit = 32]) {
  final taken = text.length > limit ? text.substring(0, limit) : text;
  final buffer = StringBuffer();
  for (final unit in taken.codeUnits) {
    buffer.write(unit >= 0x20 && unit < 0x7f ? String.fromCharCode(unit) : '.');
  }
  return buffer.toString();
}

/// What reading an archive produced.
///
/// Sealed, and exhaustive in [problem], because "each failure needs its own
/// actionable outcome" stops being true the moment somebody adds a case and
/// does not give it a sentence: the user is then told "corrupt", which is the
/// one answer that is wrong for most of what can go wrong.
sealed class BackupOutcome {
  const BackupOutcome();

  /// True when there is an archive to restore.
  bool get ok => this is BackupOk;

  /// The archive, or null when there is nothing to restore.
  BackupArchive? get archive => switch (this) {
    BackupOk(:final archive) => archive,
    _ => null,
  };

  String get problem;
}

final class BackupOk extends BackupOutcome {
  const BackupOk(this.archive, {this.migratedFrom});

  @override
  final BackupArchive archive;

  /// The version the file was in, when it was not this build's.
  ///
  /// Reported rather than hidden so the restore path can say "migrated from
  /// format 0" out loud. A restore that silently rearranged somebody's history
  /// and said nothing is indistinguishable from one that lost some of it.
  final int? migratedFrom;

  @override
  String get problem => migratedFrom == null
      ? 'read ${archive.manifest.messageCount} messages'
      : 'read after migrating from format version $migratedFrom';
}

/// The file is not one of ours.
final class BackupNotABackup extends BackupOutcome {
  const BackupNotABackup({required this.found});

  /// The first bytes of the file, printable and bounded. Diagnostics only.
  final String found;

  @override
  String get problem =>
      'not a backup: the file does not begin with the backup marker '
      '(found "$found")';
}

/// The file is incomplete, or the header does not hold together.
///
/// One outcome for every way the bytes can stop making sense before the
/// checksum is reached, because from the user's side they are the same event —
/// the file they picked did not survive the trip — and the advice is the same.
/// Kept apart from [BackupChecksumMismatch], which means the file is complete
/// and says something different.
final class BackupTruncated extends BackupOutcome {
  const BackupTruncated({required this.byteLength, required this.detail});

  final int byteLength;
  final String detail;

  @override
  String get problem => 'incomplete ($byteLength bytes): $detail';
}

/// The file is intact and is not in a version this build reads.
///
/// Distinct from every kind of damage, because the file is fine and the fix is
/// on this side of it.
final class BackupUnknownVersion extends BackupOutcome {
  const BackupUnknownVersion({required this.found, required this.supported});

  final int found;
  final int supported;

  @override
  String get problem =>
      'written in backup format $found; this build reads format $supported';
}

/// This build could not translate the file it was asked to read.
///
/// The user's file is intact; the failure is ours. Reported separately so that
/// a bug in a migration is not presented as a broken backup.
final class BackupMigrationFailed extends BackupOutcome {
  const BackupMigrationFailed({required this.found, required this.error});

  final int found;
  final Object error;

  @override
  String get problem => 'could not read backup format $found: $error';
}

/// The payload is not the bytes the header described.
final class BackupChecksumMismatch extends BackupOutcome {
  const BackupChecksumMismatch({required this.expected, required this.found});

  final String expected;
  final String found;

  @override
  String get problem =>
      'the payload does not match the header ($found, expected $expected)';
}

/// The file is intact but something in it may not be restored.
final class BackupContentRejected extends BackupOutcome {
  const BackupContentRejected(this.reason);

  final BackupRejected reason;

  @override
  String get problem => reason.problem;
}
