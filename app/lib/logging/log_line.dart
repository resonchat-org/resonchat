// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// One line of the developer log, and the redaction applied to it.
//
// Kept free of `dart:io` so both the file-backed implementation and the web
// stub can share it, and free of the app so it can be tested directly.

import 'package:logging/logging.dart';

/// Formats one [LogRecord] as a single file line.
///
/// Local time to the millisecond, because the interesting failures are about
/// ordering (a capability lookup that lost a race, a bundle that went stale
/// between the check and the send). [LogRecord.time] is UTC-agnostic wall
/// clock; a log read next to a `adb logcat` dump has to line up with it.
String formatLogRecord(LogRecord record, {required bool redact}) {
  final t = record.time;
  final buffer = StringBuffer()
    ..write(_two(t.hour))
    ..write(':')
    ..write(_two(t.minute))
    ..write(':')
    ..write(_two(t.second))
    ..write('.')
    ..write(t.millisecond.toString().padLeft(3, '0'))
    ..write(' ')
    // Padded so the level column does not ragged the logger names against
    // each other.
    ..write(record.level.name.padRight(5))
    ..write(' ')
    ..write(record.loggerName)
    ..write(': ')
    ..write(record.message);
  final error = record.error;
  if (error != null) buffer.write(' — $error');
  final trace = record.stackTrace;
  if (trace != null) buffer.write('\n$trace');
  final line = buffer.toString();
  return redact ? redactLogLine(line) : line;
}

String _two(int n) => n.toString().padLeft(2, '0');

/// Masks the parts of [line] that name a person or carry a secret.
///
/// The developer log is a file that ends up in a file manager or a chat, so
/// what leaves the process is already reduced:
///
/// * a JID keeps its domain and its device ids, and its local part becomes a
///   short stable tag, so two lines about the same contact can still be lined
///   up against each other without naming them;
/// * long opaque runs — keys, tokens, base64 payloads — collapse to a length.
///   They are never what a diagnostic line is about, and they are the part
///   that is genuinely dangerous to paste somewhere.
///
/// Best effort, and deliberately so. This is a guard against accidental
/// exposure, not a guarantee about the file's contents.
String redactLogLine(String line) {
  if (line.isEmpty) return line;
  return line
      .replaceAllMapped(_jid, (m) => '${_tag(m[1]!)}@${m[2]!}')
      .replaceAllMapped(_blob, (m) => '<blob:${m[0]!.length}>');
}

/// `local@domain.tld`. Deliberately requires a dotted domain so that an
/// `urn:monocles:…` namespace or a bare `user@host` in a sentence is left
/// alone unless it really looks like a JID.
final _jid = RegExp(
  r'([A-Za-z0-9._%+-]{1,64})@([A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,})',
);

/// An unbroken run long enough that it is a key or a payload, not a word.
final _blob = RegExp(r'[A-Za-z0-9+/=_-]{40,}');

/// FNV-1a, 32-bit, hex. Not a cryptographic hash: the point is only that the
/// same input gives the same tag within a file and that the original cannot be
/// read off it at a glance.
String _tag(String value) {
  var hash = 0x811c9dc5;
  for (final unit in value.codeUnits) {
    hash = ((hash ^ (unit & 0xff)) * 0x01000193) & 0xffffffff;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}
