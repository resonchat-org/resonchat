// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter_test/flutter_test.dart';

import 'package:resonchat/persistence/database.dart';
import 'package:resonchat/ui/chat/reply_quote.dart';

Message _msg({
  String sender = 'fkumffku@anoxinon.me',
  bool incoming = true,
  String body = '',
  String replyTo = '',
  String replyBody = '',
  String replyAuthor = '',
  bool retracted = false,
  String stanzaId = 's1',
}) {
  return Message(
    id: 0,
    chatJid: 'fkumffku@anoxinon.me',
    sender: sender,
    stanzaId: stanzaId,
    roomStanzaId: '',
    body: body,
    timestamp: DateTime(2026, 10, 24, 11, 17),
    encMode: 'none',
    incoming: incoming,
    delivered: false,
    displayed: false,
    readBy: '[]',
    sendStatus: 0,
    markable: false,
    isCarbon: false,
    deliveryError: '',
    retracted: retracted,
    retractedBy: '',
    retractedReason: '',
    replyTo: replyTo,
    replyBody: replyBody,
    replyAuthor: replyAuthor,
    mediaUrl: '',
    mediaMime: '',
    mediaName: '',
    localPath: '',
    mentionsMe: false,
  );
}

void main() {
  group('splitting the leading quote block', () {
    test('separates a one-line quote from the reply', () {
      final split = splitLeadingQuote('> 999\n后量子测试收到')!;
      expect(split.quote, '999');
      expect(split.body, '后量子测试收到');
    });

    test('keeps a multi-line quote together', () {
      final split = splitLeadingQuote('> first\n> second\nanswer')!;
      expect(split.quote, 'first\nsecond');
      expect(split.body, 'answer');
    });

    test('drops the blank line Conversations puts after the quote', () {
      final split = splitLeadingQuote('> quoted\n\nanswer')!;
      expect(split.quote, 'quoted');
      expect(split.body, 'answer');
    });

    test('leaves a body without a quote alone', () {
      expect(splitLeadingQuote('just text'), isNull);
      expect(splitLeadingQuote('>not a fallback?'), isNotNull);
    });
  });

  group('resolving a reply card', () {
    test('a legacy row gets the quote back and loses it from the bubble', () {
      final message = _msg(
        body: '> 999\n后量子测试收到',
        replyTo: 'target',
        replyBody: '后量子测试收到',
        replyAuthor: 'fkumffku@anoxinon.me',
      );
      final target = _msg(stanzaId: 'target', body: '999', incoming: false);
      final reply = replyPresentation(
        message,
        quoted: target,
        isGroup: false,
        peerName: 'fkumffku',
        selfLabel: '你',
      );
      expect(reply.body, '后量子测试收到');
      expect(reply.quote, '999');
      // The target is ours, so the quote is ours, not the replying peer.
      expect(reply.author, '你');
    });

    test('names the peer when the quoted message is theirs', () {
      final message = _msg(
        body: 'answer',
        replyTo: 'target',
        replyBody: 'quoted',
      );
      final target = _msg(stanzaId: 'target', body: 'quoted');
      final reply = replyPresentation(
        message,
        quoted: target,
        isGroup: false,
        // No roster name: monocles falls back to the local part, not the JID.
        peerName: 'fkumffku@anoxinon.me',
        selfLabel: '你',
      );
      expect(reply.quote, 'quoted');
      expect(reply.author, 'fkumffku');
    });

    test('a group quote names the quoted occupant', () {
      final message = _msg(
        body: 'answer',
        replyTo: 'target',
        replyBody: 'quoted',
      );
      final target = _msg(
        stanzaId: 'target',
        sender: 'room@muc.example/alice',
        body: 'quoted',
      );
      final reply = replyPresentation(
        message,
        quoted: target,
        isGroup: true,
        peerName: 'Room',
        selfLabel: 'me',
      );
      expect(reply.author, 'alice');
    });

    test('falls back to the stored quote when the target is gone', () {
      final message = _msg(
        body: 'answer',
        replyTo: 'gone',
        replyBody: 'the original',
      );
      final reply = replyPresentation(
        message,
        quoted: null,
        isGroup: false,
        peerName: 'fkumffku',
        selfLabel: '你',
      );
      expect(reply.quote, 'the original');
      // A stored bare JID is not a display name.
      expect(reply.author, '');
    });

    test('the old no-offset duplicate is repaired from the target', () {
      final message = _msg(
        body: 'my answer',
        replyTo: 'target',
        replyBody: 'my answer',
      );
      final target = _msg(stanzaId: 'target', body: 'the original');
      final reply = replyPresentation(
        message,
        quoted: target,
        isGroup: false,
        peerName: 'fkumffku',
        selfLabel: '你',
      );
      expect(reply.quote, 'the original');
      expect(reply.body, 'my answer');
    });
  });
}
