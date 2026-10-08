// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The backup format, read as a list of things that must not happen.
//
// Every test below asks one question: what is the worst thing that follows if
// this is wrong? For a module whose job is to describe a file, that is always
// one of two — we leak key material into a file the user sends to themselves,
// or we destroy a year of their history by accepting a file that is not whole.
// So the tests are about those two, and about the third thing that is easier to
// get wrong: telling the user "this file is corrupt" when it is not, which is
// the same as having no backup.

import 'package:test/test.dart';
import 'package:resonchat/store/backup_format.dart';

void main() {
  group('key material cannot reach an archive', () {
    test('a Secret is not a BackupValue', () {
      // The whole guarantee in one assertion, and it is a type fact rather than
      // a behaviour: `Secret` is not a subtype of the sealed `BackupValue`, so
      // there is no value in this program — not one, now or after somebody adds
      // a table — that satisfies both types. Nothing can be handed to
      // `encodeBackup` as a key, because no expression produces one.
      //
      // The other half is in this file's implementation: `Secret` has no `cell`
      // extension, and the only `Object?` door is `cellFromJson`, tested below.
      expect(const Secret([1, 2, 3]), isNot(isA<BackupValue>()));
      expect(const Secret([1, 2, 3]), isNot(isA<BackupRow>()));
    });

    test('the one untyped door refuses a Secret by name', () {
      // A decoded archive is `Object?` all the way down, so a restored file has
      // to cross a door that takes anything. That door is not allowed to guess:
      // it names what it refused, because "expected text, found Secret" in a
      // log sends whoever reads it looking in the wrong place entirely.
      final secret = Secret(List<int>.generate(32, (i) => i));
      final rejection = _refusal(
        () => cellFromJson(
          const BackupColumn('body', BackupColumnKind.text),
          secret,
        ),
      );
      expect(rejection.kind, BackupRejectionKind.secretMaterial);
      expect(rejection.problem, contains('key material'));
    });

    test('the refusal does not carry the key into the log', () {
      // A refusal is logged. The bytes must not ride along in the message: an
      // error report full of key material is a key material leak with extra
      // steps, and it is the kind nobody thinks to check for.
      final bytes = List<int>.generate(24, (i) => i * 7);
      final rejection = _refusal(
        () => cellFromJson(
          const BackupColumn('body', BackupColumnKind.text),
          Secret(bytes),
        ),
      );
      final printed = '$rejection ${rejection.problem}';
      for (final byte in bytes) {
        final hex = byte.toRadixString(16).padLeft(2, '0');
        expect(printed, isNot(contains(hex)));
      }
      expect(printed.length, lessThan(200));
    });

    test('a Secret does not print itself', () {
      // Not `const List<int>.filled(...)`: `filled` is a factory, so it cannot
      // appear in a const expression. `Secret`'s own constructor is const and
      // works either way — the const-ness is a property of how the argument is
      // built, not of whether the enclosing constructor is const.
      final secret = Secret(List<int>.filled(32, 0xAB));
      expect(secret.toString(), isNot(contains('ab')));
      expect(secret.toString(), contains('redacted'));
    });

    test('no allow-listed column is named after key material', () {
      // The grep test. A backup that grows a column called `ik` or `spk` is
      // this file failing at its one job, and it would pass every other test in
      // the file because a row of key material is a well-formed row. The terms
      // are deliberately fragments that no honest column contains; `meta.key`
      // is why a bare `key` is not one of them.
      // Fragments that mean crypto key material — not ordinary words like
      // `muc_private_non_anonymous` (MUC room type, not a private key).
      const suspicious = [
        'secret',
        'sealing',
        'passphrase',
        'private_key',
        'privkey',
        'privatekey',
        'spk',
        'opk',
        'ik_',
        '_ik',
        'sk_',
        '_sk',
      ];
      for (final spec in kBackupTables.values) {
        for (final column in spec.columns) {
          for (final term in suspicious) {
            expect(
              column.name.contains(term),
              isFalse,
              reason:
                  '${column.name} (${spec.table.tableName}) looks like key '
                  'material, and an allow-list that names it is a leak with a '
                  'test suite attached',
            );
          }
        }
      }
    });

    test('the sealed device row is not on the meta allow-list', () {
      // The leak nobody would have to write on purpose: `OmemoDeviceStore`
      // saves to "a meta-style row", so a backup that copied the meta table
      // wholesale would copy the sealed identity key with it. `meta` is listed
      // — drafts are worth keeping — but only under key prefixes.
      expect(
        _metaRejection('omemo_device'),
        BackupRejectionKind.unknownMetaKey,
      );
      expect(
        _metaRejection('omemo_device.sealed'),
        BackupRejectionKind.unknownMetaKey,
      );
    });

    test('the published device ids row is not on the meta allow-list', () {
      // Nothing secret about it, and refusing it anyway: it records which ids
      // on our own published list are superseded builds of *this* install, so
      // restoring it onto another device has us pruning the live device out of
      // our own list — an OMEMO outage caused by a backup.
      expect(
        _metaRejection('omemo_published_ids'),
        BackupRejectionKind.unknownMetaKey,
      );
    });

    test('drafts and plaintext acknowledgements are on it', () {
      // The allow-list has to have a yes in it, or it is not a policy. A draft
      // is the user's own unsent words and is lost in a reinstall.
      expect(
        rowRejection(
          BackupTable.meta,
          _metaRow('draft:juliet@example.org', 'half a sentence'),
        ),
        isNull,
      );
      expect(
        rowRejection(
          BackupTable.meta,
          _metaRow('plaintext_ack:juliet@example.org', '1'),
        ),
        isNull,
      );
    });

    test('a draft that does not begin with "draft:" is still a draft', () {
      // The prefix allow-list applies to the *key*, never to the value. Testing
      // both would refuse most of everybody's drafts.
      expect(
        rowRejection(
          BackupTable.meta,
          _metaRow('draft:juliet@example.org', 'not a draft-looking value'),
        ),
        isNull,
      );
    });
  });

  group('the allow-list fails closed', () {
    test('every table has a spec', () {
      // So that adding a table without deciding about backup fails here rather
      // than silently producing archives that do not contain it — which looks
      // exactly like a table with no rows until the day the rows matter.
      expect(kBackupTables.length, BackupTable.values.length);
      for (final table in BackupTable.values) {
        expect(backupSpecOf(table).table, table);
        expect(backupSpecOf(table).columns, isNotEmpty);
      }
    });

    test('a column nobody allow-listed is refused', () {
      final rejection = rowRejection(
        BackupTable.chats,
        _chatRow('juliet@example.org')
          ..['password'] = const BackupText('hunter2'),
      );
      expect(rejection?.kind, BackupRejectionKind.unknownColumn);
      expect(rejection?.column, 'password');
    });

    test('a missing column is refused rather than defaulted', () {
      // Not filled in with '' or 0. A restore that invents a value for a
      // column the backup did not carry is a restore that invents history: an
      // unretracted message, an unread count of zero, a conversation that was
      // never archived.
      final row = _chatRow('juliet@example.org')..remove('unread_count');
      final rejection = rowRejection(BackupTable.chats, row);
      expect(rejection?.kind, BackupRejectionKind.missingColumn);
      expect(rejection?.column, 'unread_count');
    });

    test('null in a never-null column is refused', () {
      final rejection = rowRejection(
        BackupTable.chats,
        _chatRow('juliet@example.org')..['jid'] = null,
      );
      expect(rejection?.kind, BackupRejectionKind.wrongType);
    });

    test('null in a nullable column is kept as null', () {
      // The two must stay apart: `retracted_at` being NULL says "this was never
      // retracted", which is a fact, and a restore that wrote today's date
      // there would be inventing one.
      final row = _messageRow(
        'juliet@example.org',
        'hello',
        DateTime.utc(2026, 1, 1),
      );
      expect(row['retracted_at'], isNull);
      expect(rowRejection(BackupTable.messages, row), isNull);
      expect(
        rowRejection(
          BackupTable.messages,
          _messageRow(
            'juliet@example.org',
            'hello',
            DateTime.utc(2026, 1, 1),
            retractedAt: DateTime.utc(2026, 1, 2),
          ),
        ),
        isNull,
      );
    });

    test('a value of the wrong kind is refused, not coerced', () {
      final rejection = rowRejection(
        BackupTable.chats,
        _chatRow('juliet@example.org')
          ..['unread_count'] = const BackupText('2'),
      );
      expect(rejection?.kind, BackupRejectionKind.wrongType);
    });

    test('messages.id is not on the allow-list', () {
      // Pins and decisions to leave it out: nothing in this schema points at a
      // message by row id, so carrying it forward restores nothing and
      // collides with whatever the restoring device already holds. This test
      // exists so that adding it is a decision somebody makes on purpose.
      final row = _messageRow(
        'juliet@example.org',
        'hello',
        DateTime.utc(2026, 1, 1),
      )..['id'] = const BackupNumber(17);
      final rejection = rowRejection(BackupTable.messages, row);
      expect(rejection?.kind, BackupRejectionKind.unknownColumn);
    });

    test('a table that is not on the list is refused when read back', () {
      final outcome = _adopt({
        'tables': {'secrets': <Object?>[]},
        'manifest': _manifestJson(counts: const {}),
      });
      expect(outcome, isA<BackupContentRejected>());
      expect(
        (outcome as BackupContentRejected).reason.kind,
        BackupRejectionKind.unknownTable,
      );
    });

    test('an unknown column is refused when read back', () {
      final row = _chatJson('juliet@example.org');
      row['sealing_key'] = 'AAAA';
      final outcome = _adopt({
        'tables': {
          'chats': <Object?>[row],
        },
        'manifest': _manifestJson(counts: const {}),
      });
      expect(outcome, isA<BackupContentRejected>());
      expect(
        (outcome as BackupContentRejected).reason.kind,
        BackupRejectionKind.unknownColumn,
      );
    });

    test('the encoder refuses before it produces anything', () {
      // Ordering is the point: a writer that emits rows as it reads them has
      // already put the earlier ones on the document the user is about to keep.
      // So the refusal has to be an exception from encodeBackup, not a warning.
      final first = _chatRow('juliet@example.org');
      final second = _chatRow('romeo@example.org');
      second['password'] = const BackupText('x');
      expect(
        () => encodeBackup(
          tables: {
            BackupTable.chats: [first, second],
          },
          appVersion: '0.0.1+1',
          schemaVersion: 15,
          accountJid: 'juliet@example.org',
          createdAt: _createdAt,
        ),
        throwsA(isA<BackupRejected>()),
      );
    });
  });

  group('a backup is a file a person can keep', () {
    test('it round trips', () {
      final outcome = decodeBackupText(_archive());
      expect(outcome, isA<BackupOk>(), reason: outcome.problem);
      final archive = outcome.archive!;
      expect(archive.createdAt, _createdAt);
      expect(archive.appVersion, '0.0.1+1');
      expect(archive.schemaVersion, 15);
      expect(archive.formatVersion, kBackupFormatVersion);
      expect(archive.rowsOf(BackupTable.chats).length, 1);

      final chat = archive.cell(BackupTable.chats, 0, 'jid');
      expect((chat! as BackupText).value, 'juliet@example.org');
      final body = archive.cell(BackupTable.messages, 0, 'body');
      expect((body! as BackupText).value, 'hello');
      final stamp = archive.cell(BackupTable.messages, 1, 'timestamp');
      expect((stamp! as BackupStamp).value, DateTime.utc(2026, 9, 30, 18));
      expect(archive.cell(BackupTable.messages, 0, 'retracted_at'), isNull);
    });

    test('the same state writes the same bytes', () {
      // Given the same rows and the same header, the file must be identical.
      // Without that, "is this the archive I made yesterday?" has no answer, and
      // a checksum that changes on every run is one nobody believes.
      expect(_archive(), _archive());
    });

    test('an archive with no messages is still a backup', () {
      // A user who wipes a phone and restores afterwards makes this, and a
      // user who backs up before the archive has arrived makes it too. It has
      // to restore cleanly: treating emptiness as an error is how a restore
      // that would have worked ends in a refusal.
      final outcome = decodeBackupText(
        _archive(tables: <BackupTable, List<BackupRow>>{}),
      );
      expect(outcome, isA<BackupOk>(), reason: outcome.problem);
      final manifest = outcome.archive!.manifest;
      expect(manifest.isEmpty, isTrue);
      expect(manifest.messageCount, 0);
      expect(manifest.oldest, isNull);
      expect(manifest.newest, isNull);

      final outcomeWithChats = decodeBackupText(
        _archive(
          tables: {
            BackupTable.chats: [_chatRow('juliet@example.org')],
          },
        ),
      );
      expect(outcomeWithChats, isA<BackupOk>());
      expect(outcomeWithChats.archive!.manifest.chatCount, 1);
      expect(outcomeWithChats.archive!.manifest.isEmpty, isFalse);
      expect(outcomeWithChats.archive!.manifest.oldest, isNull);
    });

    test('the header carries what a reader needs', () {
      final header = _archive().split('\n').first;
      // The marker has to be first, because recognising our own half-written
      // file is what separates "incomplete" from "not a backup".
      expect(header, startsWith('{"magic":"$kBackupMagic"'));
      expect(header, contains('"formatVersion":$kBackupFormatVersion'));
      expect(header, contains('"createdAt":"2026-10-03T09:14:00.000Z"'));
      expect(header, contains('"appVersion":"0.0.1+1"'));
      expect(header, contains('"schemaVersion":15'));
      expect(header, contains('"checksum":"crc32:'));
      // The payload is a separate document, so the covered region is exact
      // rather than a re-encoding of what was parsed.
      expect(_archive().split('\n').length, 2);
    });

    test('CRC-32 matches the published check value', () {
      // Pinned so an implementation that drifts fails here rather than
      // reporting corruption that did not happen.
      expect(crc32Hex('123456789'.codeUnits), 'cbf43926');
      expect(crc32Hex(const <int>[]), '00000000');
      expect(crc32Hex('a'.codeUnits), isNot(crc32Hex('b'.codeUnits)));
    });
  });

  group('damage is named', () {
    test('a payload cut short is incomplete, never a partial archive', () {
      // The failure this module exists to make impossible: a file cut mid
      // payload whose remaining text happens to be the start of valid JSON,
      // restored as "the conversations this archive had".
      final whole = _archiveBytes();
      final cut = whole.sublist(0, whole.length - 40);
      expect(cut.length, lessThan(whole.length));
      final outcome = decodeBackup(cut);
      expect(outcome, isA<BackupTruncated>());
      expect(outcome.ok, isFalse);
      expect(outcome.archive, isNull);
      expect((outcome as BackupTruncated).byteLength, cut.length);
    });

    test('a file cut at the payload boundary is incomplete', () {
      // Nothing of the payload at all — the case a length check exists for and
      // a JSON parser alone cannot see, because an empty payload is not a
      // parse error, it is nothing.
      final text = _archive();
      // Characters and bytes agree up to the first newline here because the
      // header is ASCII — magic, two integers, a UTC timestamp and a semver.
      final List<int> headerOnly = _archiveBytes().sublist(
        0,
        text.indexOf('\n') + 1,
      );
      final outcome = decodeBackup(headerOnly);
      expect(outcome, isA<BackupTruncated>());
      expect(outcome.problem, contains('early'));
    });

    test('a file cut inside the header is one of ours, and incomplete', () {
      final cut = _archive().substring(0, 28);
      expect(cut, startsWith('{"magic":"$kBackupMagic"'));
      final outcome = decodeBackupText(cut);
      expect(outcome, isA<BackupTruncated>());
      expect(outcome.problem, contains('header'));
    });

    test('a file cut before the marker is reported as not a backup', () {
      // The deliberate other side of the rule: too short to recognise, so it is
      // "not a backup" rather than "ours but broken", and the two words in the
      // message cover both cases for the user.
      final outcome = decodeBackupText(_archive().substring(0, 12));
      expect(outcome, isA<BackupNotABackup>());
    });

    test('bytes after the payload are not ignored', () {
      // A file that has had something appended is not the file the header
      // describes. Reading the payload anyway would mean the checksum covers
      // less than the file, which is worse than no checksum.
      final outcome = decodeBackup([..._archiveBytes(), 0x20]);
      expect(outcome, isA<BackupTruncated>());
      expect(outcome.problem, contains('follow the declared payload'));
    });

    test('one flipped byte is a checksum mismatch', () {
      final bytes = _archiveBytes();
      bytes[bytes.length - 1] ^= 0x01;
      final outcome = decodeBackup(bytes);
      expect(outcome, isA<BackupChecksumMismatch>());
      // Verified before the payload is parsed, so damage is reported as damage
      // rather than as a parse error the user cannot act on.
      expect(outcome.problem, contains('crc32:'));
      expect(outcome.archive, isNull);
    });

    test("another app's document is not a backup", () {
      // The realistic mistake: a photo, a PDF, a chat export from somewhere
      // else. Not "corrupt" — not one of ours, so the advice is "pick the
      // right file", and the head of the file is shown so the user can see it
      // is the wrong one.
      final outcome = decodeBackupText('%PDF-1.7\n%\xe2\xe3\xcf\xd3\n');
      expect(outcome, isA<BackupNotABackup>());
      expect((outcome as BackupNotABackup).found, startsWith('%PDF-1.7'));
      expect(outcome.found.length, lessThanOrEqualTo(32));
      expect(outcome.found, isNot(contains('\n')));
    });

    test('an empty file is not a backup', () {
      expect(decodeBackupText(''), isA<BackupNotABackup>());
      expect(decodeBackup(const <int>[]), isA<BackupNotABackup>());
    });

    test('a file that is not UTF-8 is reported, not thrown', () {
      // The document picker hands over whatever was on the device. This has to
      // be an outcome, because the alternative is an exception escaping a
      // restore button.
      final outcome = decodeBackup([0xFF, 0xFE, 0x00, 0x01]);
      expect(outcome, isA<BackupTruncated>());
      expect(outcome.problem, contains('UTF-8'));
    });
  });

  group('version', () {
    test('a future version is reported apart from damage', () {
      // A backup the app refuses to read is indistinguishable from data loss,
      // so "install the app that wrote it" and "this file is broken" must not
      // be the same sentence.
      final outcome = decodeBackupText(_futureVersion(_archive()));
      expect(outcome, isA<BackupUnknownVersion>());
      // A file cut before it is even recognisable as ours, for contrast.
      final damaged = decodeBackupText(
        String.fromCharCodes(_archiveBytes().sublist(0, 20)),
      );
      expect(damaged, isNot(isA<BackupUnknownVersion>()));
      expect(outcome.problem, isNot(damaged.problem));
      expect(outcome.problem, contains('format 7'));
      expect(outcome.problem, contains('reads format 1'));
    });

    test('a future version is read through a migration hook', () {
      // The hook point. Whatever it returns is validated and its manifest is
      // recomputed, so the numbers shown before a restore are the numbers that
      // will exist after it.
      final outcome = decodeBackupText(
        _futureVersion(_archive()),
        migrate: (payload, {required fromVersion}) {
          expect(fromVersion, 7);
          return _migrateAll(payload);
        },
      );
      expect(outcome, isA<BackupOk>(), reason: outcome.problem);
      final ok = outcome as BackupOk;
      expect(ok.migratedFrom, 7);
      expect(ok.archive.manifest.chatCount, 1);
      expect(ok.archive.manifest.messageCount, 2);
    });

    test('a migration that throws is our bug, not a corrupt file', () {
      // Telling a user their archive is broken because of a defect in a
      // migration sends them looking for another backup instead of at the
      // version they just installed.
      final outcome = decodeBackupText(
        _futureVersion(_archive()),
        migrate: (payload, {required fromVersion}) =>
            throw StateError('v7 renamed everything'),
      );
      expect(outcome, isA<BackupMigrationFailed>());
      expect(outcome.problem, contains('v7 renamed everything'));
      expect(outcome, isNot(isA<BackupTruncated>()));
    });

    test('a truncated file claiming a future version is incomplete', () {
      // Integrity before interpretation. The header is where damage shows up
      // first, so asking about the version first would answer "made by a newer
      // app" for a half-written file and send the user to install an update
      // that cannot help.
      final whole = _archiveBytes();
      final cut = whole.sublist(0, whole.length - 20);
      final outcome = decodeBackup(_futureVersionBytes(cut));
      expect(outcome, isA<BackupTruncated>());
      expect(outcome, isNot(isA<BackupUnknownVersion>()));
    });

    test("the migration hook's rows are allow-listed like any other", () {
      // The hook is code we wrote. The point of an allow-list is that nobody
      // read it carefully, and that includes whoever writes the migration.
      final outcome = decodeBackupText(
        _futureVersion(_archive()),
        migrate: (payload, {required fromVersion}) {
          final row = _chatRow('juliet@example.org');
          row['sealing_key'] = const BackupText('AAAA');
          return {
            BackupTable.chats: [row],
          };
        },
      );
      expect(outcome, isA<BackupContentRejected>());
      expect(
        (outcome as BackupContentRejected).reason.kind,
        BackupRejectionKind.unknownColumn,
      );
    });
  });

  group('the manifest describes what is about to be overwritten', () {
    test('counts match what was written', () {
      final manifest = decodeBackupText(_archive()).archive!.manifest;
      expect(manifest.chatCount, 1);
      expect(manifest.messageCount, 2);
      expect(manifest.countOf(BackupTable.meta), 1);
      expect(manifest.countOf(BackupTable.reactions), 0);
      expect(manifest.accountJid, 'juliet@example.org');
    });

    test('the date range is the oldest and newest message', () {
      final manifest = decodeBackupText(_archive()).archive!.manifest;
      expect(manifest.oldest, DateTime.utc(2024, 1, 2, 3, 4));
      expect(manifest.newest, DateTime.utc(2026, 9, 30, 18));
    });

    test('every table is counted, zero included', () {
      // A preview that lists only the tables it has rows for reads as "this
      // archive has no drafts" when it should read "this archive says nothing
      // about drafts".
      final manifest = decodeBackupText(_archive()).archive!.manifest;
      for (final table in BackupTable.values) {
        expect(manifest.counts.containsKey(table), isTrue, reason: table.name);
      }
    });

    test('a manifest that disagrees with the rows is refused', () {
      // The counts are recomputed from the rows on every read, so the numbers
      // the user is shown before a restore cannot have been written by
      // something other than the encoder.
      final outcome = _adopt({
        'tables': {
          'chats': <Object?>[_chatJson('juliet@example.org')],
        },
        'manifest': _manifestJson(counts: const {'chats': 99}),
      });
      expect(outcome, isA<BackupContentRejected>());
      expect(
        (outcome as BackupContentRejected).reason.kind,
        BackupRejectionKind.manifestMismatch,
      );
    });

    test('a manifest that gets the date range wrong is refused too', () {
      final manifest = _manifestJson(counts: const {'chats': 1});
      manifest['oldest'] = '1999-01-01T00:00:00.000Z';
      final outcome = _adopt({
        'tables': {
          'chats': <Object?>[_chatJson('juliet@example.org')],
        },
        'manifest': manifest,
      });
      expect(outcome, isA<BackupContentRejected>());
      expect(
        (outcome as BackupContentRejected).reason.kind,
        BackupRejectionKind.manifestMismatch,
      );
    });
  });
}

// ---------------------------------------------------------------------------
// Fixtures.
//
// The row builders spell out every allow-listed column on purpose: a column
// added to the allow-list later breaks these, which is the point. A row of key
// material is a perfectly well-formed row, so the only thing standing between a
// new column and a leak is somebody noticing that the fixtures moved.
// ---------------------------------------------------------------------------

final DateTime _createdAt = DateTime.utc(2026, 10, 3, 9, 14);

BackupRow _chatRow(String jid, {int unread = 0}) => {
  'jid': jid.cell,
  'title': 'Jules'.cell,
  'last_activity': DateTime.utc(2026, 9, 30, 18).cell,
  'appearance': ''.cell,
  'pinned': false.cell,
  'muted': false.cell,
  'archived': false.cell,
  'unread_count': unread.cell,
  'last_read_at': DateTime.utc(2026, 9, 29).cell,
  'track_override': ''.cell,
  'is_group': false.cell,
  'muc_nick': ''.cell,
  'muc_private_non_anonymous': false.cell,
};

BackupRow _messageRow(
  String chatJid,
  String body,
  DateTime at, {
  String stanzaId = 's1',
  bool incoming = false,
  DateTime? retractedAt,
}) => {
  'chat_jid': chatJid.cell,
  'sender': 'juliet@example.org'.cell,
  'stanza_id': stanzaId.cell,
  'body': body.cell,
  'timestamp': at.cell,
  'enc_mode': 'standard'.cell,
  'incoming': incoming.cell,
  'delivered': true.cell,
  'displayed': false.cell,
  'markable': false.cell,
  'is_carbon': false.cell,
  'delivery_error': ''.cell,
  'retracted': (retractedAt != null).cell,
  'retracted_at': retractedAt.cellOrNull,
  'reply_to': ''.cell,
  'reply_body': ''.cell,
  'reply_author': ''.cell,
  'edited_at': null,
  'media_url': ''.cell,
  'media_mime': ''.cell,
  'media_name': ''.cell,
};

BackupRow _metaRow(String key, String value) => {
  'key': key.cell,
  'value': value.cell,
};

BackupRejectionKind? _metaRejection(String key) =>
    rowRejection(BackupTable.meta, _metaRow(key, 'x'))?.kind;

/// Two conversations' worth of state, used by most of the tests above.
Map<BackupTable, List<BackupRow>> _sampleTables() => {
  BackupTable.chats: [_chatRow('juliet@example.org', unread: 2)],
  BackupTable.messages: [
    _messageRow('juliet@example.org', 'hello', DateTime.utc(2024, 1, 2, 3, 4)),
    _messageRow(
      'juliet@example.org',
      'goodbye',
      DateTime.utc(2026, 9, 30, 18),
      stanzaId: 's2',
      incoming: true,
    ),
  ],
  BackupTable.meta: [_metaRow('draft:juliet@example.org', 'half a sentence')],
};

String _archive({Map<BackupTable, List<BackupRow>>? tables}) => encodeBackup(
  tables: tables ?? _sampleTables(),
  appVersion: '0.0.1+1',
  schemaVersion: 15,
  accountJid: 'juliet@example.org',
  createdAt: _createdAt,
);

List<int> _archiveBytes() => encodeBackupBytes(
  tables: _sampleTables(),
  appVersion: '0.0.1+1',
  schemaVersion: 15,
  accountJid: 'juliet@example.org',
  createdAt: _createdAt,
);

/// The same archive with its header claiming a version this build does not read.
///
/// The header is not covered by the checksum — only the payload is — so this is
/// what a file from a future build looks like from here.
String _futureVersion(String archive) =>
    archive.replaceFirst('"formatVersion":1', '"formatVersion":7');

List<int> _futureVersionBytes(List<int> bytes) {
  // Code units in, bytes out. Exact for anything that came out of
  // `encodeBackupBytes` below the first multi-byte character, which is what a
  // header and the start of a payload are, and the header is the only part
  // this touches.
  final text = _futureVersion(String.fromCharCodes(bytes));
  return [for (final unit in text.codeUnits) unit & 0xFF];
}

/// [adoptPayload] with the header fields every caller has to supply anyway.
BackupOutcome _adopt(Map<String, Object?> payload) => adoptPayload(
  payload,
  createdAt: _createdAt,
  appVersion: '0.0.1+1',
  schemaVersion: 15,
  formatVersion: kBackupFormatVersion,
);

Map<String, Object?> _manifestJson({required Map<String, int> counts}) => {
  'counts': counts,
  'oldest': null,
  'newest': null,
  'accountJid': 'juliet@example.org',
};

/// A chat row as it appears in a file: text, numbers, booleans, timestamps.
Map<String, Object?> _chatJson(String jid) => {
  'jid': jid,
  'title': 'Jules',
  'last_activity': '2026-09-30T18:00:00.000Z',
  'appearance': '',
  'pinned': false,
  'muted': false,
  'archived': false,
  'unread_count': 0,
  'last_read_at': '2026-09-29T00:00:00.000Z',
  'track_override': '',
  'is_group': false,
  'muc_nick': '',
  'muc_private_non_anonymous': false,
};

/// What a migration hook looks like when written properly: typed against the
/// allow-list rather than against whatever the old format happened to contain,
/// and dropping what this build no longer keeps.
Map<BackupTable, List<BackupRow>> _migrateAll(Map<String, Object?> payload) {
  final tables = <BackupTable, List<BackupRow>>{};
  final raw = payload['tables'];
  if (raw is! Map<String, Object?>) return tables;
  for (final entry in raw.entries) {
    final table = _tableFor(entry.key);
    final rows = entry.value;
    if (table == null || rows is! List) continue;
    tables[table] = [
      for (final row in rows)
        if (row is Map<String, Object?>) _migrateRow(table, row),
    ];
  }
  return tables;
}

BackupTable? _tableFor(String name) {
  for (final table in BackupTable.values) {
    if (table.tableName == name) return table;
  }
  return null;
}

BackupRow _migrateRow(BackupTable table, Map<String, Object?> json) {
  final spec = backupSpecOf(table);
  return <String, BackupValue?>{
    for (final column in spec.columns)
      if (json.containsKey(column.name))
        column.name: cellFromJson(column, json[column.name]),
  };
}

/// The rejection [body] raises, or a failure if it raises nothing.
BackupRejected _refusal(void Function() body) {
  try {
    body();
  } on BackupRejected catch (rejection) {
    return rejection;
  }
  fail('expected a refusal, and got none');
}
