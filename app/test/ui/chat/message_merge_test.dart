// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter_test/flutter_test.dart';

import 'package:resonchat/persistence/database.dart';
import 'package:resonchat/ui/chat/message_merge.dart';
import 'package:resonchat/ui/chat/quoted_transcript.dart';

Message _msg({
  required String sender,
  required DateTime time,
  bool incoming = true,
  bool retracted = false,
}) {
  return Message(
    id: 0,
    chatJid: 'room@muc.example',
    sender: sender,
    stanzaId: 's-${time.millisecondsSinceEpoch}',
    roomStanzaId: '',
    body: 'hi',
    timestamp: time,
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
    replyTo: '',
    replyBody: '',
    replyAuthor: '',
    forwardFromJid: '',
    forwardAuthor: '',
    forwardBody: '',
    forwardOriginId: '',
    mediaUrl: '',
    mediaMime: '',
    mediaName: '',
    localPath: '',
    mentionsMe: false,
  );
}

void main() {
  final t0 = DateTime(2024, 1, 1, 12, 0);

  test('same nick within 90s merges', () {
    expect(
      messagesMergeForChrome(
        _msg(sender: 'room@muc/alice', time: t0),
        _msg(sender: 'room@muc/alice', time: t0.add(kMessageMergeWindow)),
      ),
      isTrue,
    );
  });

  test('91s gap does not merge', () {
    expect(
      messagesMergeForChrome(
        _msg(sender: 'room@muc/alice', time: t0),
        _msg(
          sender: 'room@muc/alice',
          time: t0.add(const Duration(milliseconds: 90001)),
        ),
      ),
      isFalse,
    );
  });

  test('different nick does not merge', () {
    expect(
      messagesMergeForChrome(
        _msg(sender: 'room@muc/alice', time: t0),
        _msg(sender: 'room@muc/bob', time: t0.add(const Duration(seconds: 10))),
      ),
      isFalse,
    );
  });

  test('incoming then outgoing does not merge', () {
    expect(
      messagesMergeForChrome(
        _msg(sender: 'room@muc/alice', time: t0),
        _msg(
          sender: 'me',
          time: t0.add(const Duration(seconds: 10)),
          incoming: false,
        ),
      ),
      isFalse,
    );
  });

  test('day break refuses list merge', () {
    expect(
      messagesMergeAcrossList(
        _msg(sender: 'room@muc/alice', time: t0),
        _msg(sender: 'room@muc/alice', time: DateTime(2024, 1, 2, 0, 0, 30)),
      ),
      isFalse,
    );
  });
}
