// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The line format and the redaction of the developer log. Redaction is the
// part worth testing: the file is meant to be handed to someone else, so what
// it leaves out is the feature, and a regression there is silent.

import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:resonchat/logging/log_line.dart';

void main() {
  group('formatLogRecord', () {
    // `logging` stamps `time` inside the constructor and offers no way to pass
    // one, so the clock is matched rather than asserted.
    test('writes time, level, logger and message on one line', () {
      final record = LogRecord(Level.INFO, 'connected', 'xmpp.session');
      expect(
        formatLogRecord(record, redact: false),
        matches(
          RegExp(r'^\d{2}:\d{2}:\d{2}\.\d{3} INFO  xmpp\.session: connected$'),
        ),
      );
    });

    test('level is padded so logger names line up', () {
      final warn = LogRecord(Level.WARNING, 'm', 'a.b');
      expect(formatLogRecord(warn, redact: false), contains(' WARNING a.b: m'));
    });

    test('appends the error and the stack trace', () {
      final record = LogRecord(
        Level.SEVERE,
        'boom',
        'a.b',
        StateError('nope'),
        StackTrace.fromString('#0 here'),
      );
      final line = formatLogRecord(record, redact: false);
      expect(line, contains('a.b: boom — Bad state: nope'));
      expect(line, contains('\n#0 here'));
    });

    test('redacts when asked', () {
      final record = LogRecord(Level.INFO, 'peer bob@example.org', 'a.b');
      expect(formatLogRecord(record, redact: true), isNot(contains('bob@')));
    });
  });

  group('redactLogLine', () {
    test('keeps the domain and the device list, drops the local part', () {
      final out = redactLogLine('pq bundle for bob@example.org:12345 refused');
      expect(out, isNot(contains('bob')));
      expect(out, contains('@example.org:12345 refused'));
      expect(out, matches(RegExp(r'[0-9a-f]{8}@example\.org')));
    });

    test('the same JID gets the same tag, different JIDs do not', () {
      final first = redactLogLine('caps(bob@example.org)');
      final again = redactLogLine('send to bob@example.org');
      final other = redactLogLine('caps(amy@example.org)');
      final firstTag = RegExp(r'[0-9a-f]{8}').firstMatch(first)![0];
      expect(again, contains('$firstTag@example.org'));
      expect(other, isNot(contains(firstTag)));
    });

    test('a namespace that merely looks like an address is left alone', () {
      const input = 'using urn:monocles:omemo-pq:1 with ML-KEM-1024';
      expect(redactLogLine(input), input);
    });

    test('an unbroken key-length run collapses to its length', () {
      final key = 'A' * 44;
      expect(redactLogLine('device key $key ok'), 'device key <blob:44> ok');
    });

    test('a short token is not mistaken for a key', () {
      expect(redactLogLine('device id 12345'), 'device id 12345');
    });

    test('an empty line survives', () {
      expect(redactLogLine(''), '');
    });
  });
}
