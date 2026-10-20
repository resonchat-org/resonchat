// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter_test/flutter_test.dart';

import 'package:resonchat/ui/chat/quoted_transcript.dart';

QuotedTranscriptItem _item({
  required String id,
  required String body,
  required String sender,
  required DateTime time,
}) {
  return QuotedTranscriptItem(
    id: id,
    body: body,
    timestamp: time,
    senderKey: sender,
    senderLabel: sender,
  );
}

void main() {
  final t0 = DateTime(2024, 1, 1, 12, 0);

  test('quoteMessageBody prefixes every line', () {
    expect(quoteMessageBody('a\nb'), '> a\n> b\n');
  });

  test('single message has header and quoted body', () {
    final text = formatQuotedTranscript([
      _item(id: '1', body: 'hello', sender: 'alice', time: t0),
    ]);
    expect(
      text,
      '2024-01-01 12:00 - alice:\n'
      '> hello',
    );
  });

  test('same sender within Conversations 90s window merges header', () {
    final text = formatQuotedTranscript([
      _item(id: '1', body: 'one', sender: 'alice', time: t0),
      _item(
        id: '2',
        body: 'two',
        sender: 'alice',
        time: t0.add(const Duration(seconds: 90)),
      ),
    ]);
    expect(
      text,
      '2024-01-01 12:00 - alice:\n'
      '> one\n'
      '> two',
    );
  });

  test('gap over Conversations 90s window repeats header', () {
    final text = formatQuotedTranscript([
      _item(id: '1', body: 'one', sender: 'alice', time: t0),
      _item(
        id: '2',
        body: 'two',
        sender: 'alice',
        time: t0.add(const Duration(seconds: 91)),
      ),
    ]);
    expect(
      text,
      '2024-01-01 12:00 - alice:\n'
      '> one\n'
      '\n'
      '2024-01-01 12:01 - alice:\n'
      '> two',
    );
  });

  test('other sender interrupts merge', () {
    final text = formatQuotedTranscript([
      _item(id: '1', body: 'a1', sender: 'alice', time: t0),
      _item(
        id: '2',
        body: 'b',
        sender: 'bob',
        time: t0.add(const Duration(seconds: 10)),
      ),
      _item(
        id: '3',
        body: 'a2',
        sender: 'alice',
        time: t0.add(const Duration(seconds: 20)),
      ),
    ]);
    expect(
      text,
      '2024-01-01 12:00 - alice:\n'
      '> a1\n'
      '\n'
      '2024-01-01 12:00 - bob:\n'
      '> b\n'
      '\n'
      '2024-01-01 12:00 - alice:\n'
      '> a2',
    );
  });

  test('sorts chronologically regardless of input order', () {
    final text = formatQuotedTranscript([
      _item(
        id: '2',
        body: 'later',
        sender: 'alice',
        time: t0.add(const Duration(seconds: 20)),
      ),
      _item(id: '1', body: 'first', sender: 'alice', time: t0),
    ]);
    expect(text, contains('> first\n> later'));
  });
}
