// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Reply quotes (XEP-0461).
//
// A reply has two independent copies of the quote: the `> `-prefixed fallback
// in the body, and the one stored on the row. That is deliberate, and the tests
// below cover the case that makes it necessary — the quoted message being
// retracted, after which a quote resolved by lookup has nothing left to show.

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:moxxmpp/moxxmpp.dart' show ReplyData;
import 'package:test/test.dart';

import 'package:resonchat/domain/messages_service.dart';
import 'package:resonchat/persistence/database.dart';
import 'package:resonchat/xmpp/chat/replies.dart';

void main() {
  late AppDatabase db;
  const chat = 'peer@example.org';

  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<void> insert({
    required String stanzaId,
    required String body,
    String replyTo = '',
    String replyBody = '',
    String replyAuthor = '',
  }) async {
    await db.upsertChat(chat);
    await db.insertMessageRow(
      MessagesCompanion.insert(
        chatJid: chat,
        sender: 'peer@example.org/x',
        stanzaId: Value(stanzaId),
        body: body,
        incoming: true,
        replyTo: Value(replyTo),
        replyBody: Value(replyBody),
        replyAuthor: Value(replyAuthor),
      ),
    );
  }

  group('the fallback body', () {
    test('quotes every line and keeps the reply after it', () {
      final fallback = buildReplyFallback('first\nsecond', 'my answer');
      expect(fallback.wireBody, '> first\n> second\nmy answer');
    });

    test('the offsets cover exactly the quote', () {
      // Without correct offsets a reader cannot tell a quoted line from the
      // reply's own first line, and the reply arrives looking like a quotation
      // of itself.
      final fallback = buildReplyFallback('quoted', 'reply');
      expect(fallback.start, 0);
      expect(fallback.end, '> quoted\n'.length);
      expect(
        fallback.wireBody.substring(fallback.start, fallback.end),
        '> quoted\n',
      );
      expect(fallback.wireBody.substring(fallback.end), 'reply');
    });

    test('a multi-line quote ends after its last line', () {
      final fallback = buildReplyFallback('a\nb\nc', 'r');
      expect(fallback.end, '> a\n> b\n> c\n'.length);
    });

    test('an empty quote produces a reply with no prefix', () {
      // Happens when the quoted message was empty or unreadable; the reply
      // must still read as a reply rather than as a stray blank line.
      final fallback = buildReplyFallback('', 'just this');
      expect(fallback.end, 0);
      expect(fallback.wireBody, 'just this');
    });

    test('blank lines inside the quote stay quoted', () {
      // A blank line in the middle of a quoted message is part of the quote;
      // leaving it bare makes the reply look two messages long.
      final fallback = buildReplyFallback('a\n\nb', 'r');
      expect(fallback.wireBody, '> a\n> \n> b\nr');
    });
  });

  group('the quote is stored, not looked up', () {
    test('a reply keeps its quote after the target is retracted', () {
      // The failure this design exists for: resolving the quote from the
      // target row means a one-tap retraction empties out every reply that
      // quoted it, leaving the reader with "replying to" and nothing under it.
      return Future.wait([
        insert(stanzaId: 'target', body: 'the original'),
        insert(
          stanzaId: 'reply',
          body: 'my answer',
          replyTo: 'target',
          replyBody: 'the original',
          replyAuthor: 'peer@example.org',
        ),
      ]).then((_) async {
        await MessagesService(db).markRetracted('target');
        final rows = await db.watchMessages(chat).first;
        final reply = rows.firstWhere((m) => m.stanzaId == 'reply');
        expect(reply.replyBody, 'the original');
        expect(reply.replyTo, 'target');
        // The reply's own text is untouched by the retraction — deleting a
        // message the other person wrote must not delete mine.
        expect(reply.body, 'my answer');
        expect(reply.retracted, isFalse);
      });
    });

    test('and after the target is corrected', () {
      return Future.wait([
        insert(stanzaId: 'target', body: 'the original'),
        insert(
          stanzaId: 'reply',
          body: 'my answer',
          replyTo: 'target',
          replyBody: 'the original',
        ),
      ]).then((_) async {
        await MessagesService(db).applyCorrection(
          chatJid: chat,
          targetId: 'target',
          body: 'the corrected text',
          encMode: 'OM',
        );
        final rows = await db.watchMessages(chat).first;
        expect(
          rows.firstWhere((m) => m.stanzaId == 'reply').replyBody,
          'the original',
        );
      });
    });

    test('an ordinary message has no quote', () {
      return insert(stanzaId: 'plain', body: 'hi').then((_) async {
        final row = (await db.watchMessages(chat).first).single;
        expect(row.replyTo, '');
        expect(row.replyBody, '');
      });
    });

    test('the author is stored with the quote', () {
      // A quote without an author is much harder to place in a conversation;
      // the reader is looking at a fragment with no idea whose it was.
      return insert(
        stanzaId: 'r',
        body: 'answer',
        replyTo: 'target',
        replyBody: 'quoted',
        replyAuthor: 'peer@example.org',
      ).then((_) async {
        final row = (await db.watchMessages(chat).first).single;
        expect(row.replyAuthor, 'peer@example.org');
      });
    });
  });

  group('a hostile or broken sender cannot crash the parser', () {
    // moxxmpp's own withoutFallback calls String.replaceRange with the offsets
    // unchecked, so these come off the wire from the other end. A RangeError
    // here is a remote way to close the app.
    test('an end past the body is refused, not thrown', () {
      final info = ReplyInfo.from(
        const ReplyData('id', body: 'quoted', start: 0, end: 65535),
        'my answer',
      );
      // No usable range → no quote card; body stays intact via stripFallback.
      expect(info.body, '');
      expect(
        stripFallback(
          const ReplyData('id', body: 'quoted', start: 0, end: 65535),
          'my answer',
        ),
        'my answer',
      );
    });

    test('a negative start is refused', () {
      final info = ReplyInfo.from(
        const ReplyData('id', body: 'quoted', start: -5, end: 3),
        'my answer',
      );
      expect(info.body, '');
    });

    test('end before start is refused', () {
      final info = ReplyInfo.from(
        const ReplyData('id', body: 'quoted', start: 4, end: 2),
        'my answer',
      );
      expect(info.body, '');
    });

    test('an offset inside the body yields the quote, not the reply', () {
      final info = ReplyInfo.from(
        const ReplyData('id', body: 'quoted', start: 0, end: 9),
        '> quoted\nmy answer',
      );
      expect(info.body, 'quoted');
      expect(
        stripFallback(
          const ReplyData('id', body: 'quoted', start: 0, end: 9),
          '> quoted\nmy answer',
        ),
        'my answer',
      );
    });
  });

  group('parsing an inbound reply', () {
    test('ReplyInfo.body is the quote; stripFallback is the reply', () {
      final fallback = buildReplyFallback('the original', 'my answer');
      final data = ReplyData(
        'origin-id-1',
        body: fallback.wireBody,
        start: fallback.start,
        end: fallback.end,
      );
      final info = ReplyInfo.from(data, fallback.wireBody);
      expect(info.targetId, 'origin-id-1');
      // Quote card above the bubble (Conversations / Telegram style).
      expect(info.body, 'the original');
      // Bubble text is the reply alone.
      expect(stripFallback(data, fallback.wireBody), 'my answer');
    });

    test('a sender that sent no offsets leaves the body alone', () {
      // There is no way to tell where the quote ends without them, and
      // guessing would cut the reply itself in half.
      final data = const ReplyData('origin-id-1', body: 'quoted');
      final info = ReplyInfo.from(data, '> quoted\nmy answer');
      expect(info.body, '');
      expect(stripFallback(data, '> quoted\nmy answer'), '> quoted\nmy answer');
    });
  });
}
