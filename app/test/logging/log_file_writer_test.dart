// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The file side of developer log mode: where lines land, when a file is
// replaced, and which old ones get deleted. All of it runs against a temp
// directory — the app's own directory needs a platform channel.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:resonchat/logging/log_file_writer.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('resonchat-log-test');
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  // A fixed clock keeps the file names predictable; the second rollover below
  // is the case where a real clock would not have moved yet.
  DateTime fixedClock() => DateTime(2026, 1, 2, 3, 4, 5);

  test('creates the directory and writes one dated file', () async {
    final target = Directory(p.join(dir.path, 'logs'));
    final writer = LogFileWriter(dir: target, clock: fixedClock);
    await writer.write('first');
    await writer.write('second');
    await writer.flush();

    final file = writer.file!;
    expect(p.basename(file.path), 'resonchat-20260102-030405.log');
    expect(await file.readAsString(), 'first\nsecond\n');
    expect(await writer.files(), hasLength(1));
    await writer.close();
  });

  test(
    'a later run appends to the newest file instead of starting one',
    () async {
      final first = LogFileWriter(dir: dir, clock: fixedClock);
      await first.write('a');
      await first.close();

      final second = LogFileWriter(dir: dir, clock: fixedClock);
      await second.write('b');
      await second.flush();

      expect(await second.file!.readAsString(), 'a\nb\n');
      expect(await second.files(), hasLength(1));
      await second.close();
    },
  );

  test('rolls over once maxBytes is reached', () async {
    // 'aaaa\n' is five bytes, so the second write crosses an eight-byte cap.
    final writer = LogFileWriter(dir: dir, maxBytes: 8, clock: fixedClock);
    await writer.write('aaaa');
    await writer.write('bbbb');
    await writer.flush();

    final files = await writer.files();
    expect(files, hasLength(2));
    expect(p.basename(files.first.path), 'resonchat-20260102-030405.log');
    // Same second, so the new file needs a suffix: without one it would be
    // named after the full file it just replaced.
    expect(p.basename(files.last.path), 'resonchat-20260102-030405-1.log');
    expect(await files.first.readAsString(), 'aaaa\nbbbb\n');
    await writer.close();
  });

  test('prunes the oldest so that opening one more leaves maxFiles', () async {
    final writer = LogFileWriter(
      dir: dir,
      maxBytes: 1,
      maxFiles: 2,
      clock: fixedClock,
    );
    await writer.write('a');
    await writer.write('b');
    await writer.flush();

    final files = await writer.files();
    expect(files, hasLength(2));
    // The oldest — the one named without a suffix — is the one that went.
    expect(p.basename(files.first.path), 'resonchat-20260102-030405-1.log');
    await writer.close();
  });

  test('ignores files that are not ours', () async {
    await File(p.join(dir.path, 'resonchat.log')).writeAsString('stray');
    await File(p.join(dir.path, 'notes.txt')).writeAsString('stray');

    final writer = LogFileWriter(dir: dir, clock: fixedClock);
    await writer.write('mine');
    await writer.flush();

    final files = await writer.files();
    expect(files, hasLength(1));
    expect(p.basename(files.single.path), 'resonchat-20260102-030405.log');
    await writer.close();
  });

  test('closing twice is harmless', () async {
    final writer = LogFileWriter(dir: dir, clock: fixedClock);
    await writer.write('once');
    await writer.close();
    await writer.close();
    expect(await writer.files(), hasLength(1));
  });
}
