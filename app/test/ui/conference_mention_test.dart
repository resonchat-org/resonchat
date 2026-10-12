// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter_test/flutter_test.dart';
import 'package:resonchat/ui/chat/conference_mention.dart';

void main() {
  bool known(List<String> nicks) =>
      nicks.every((n) => const {'alice', 'bob', 'carol'}.contains(n));

  group('insertConferenceMention', () {
    test('empty composer gets nick: ', () {
      final edit = insertConferenceMention(
        text: '',
        selectionStart: 0,
        nick: 'alice',
        areValidNicks: known,
      );
      expect(edit.text, 'alice: ');
      expect(edit.selection, 'alice: '.length);
    });

    test('whitespace-only composer is treated as empty', () {
      final edit = insertConferenceMention(
        text: '   ',
        selectionStart: 3,
        nick: 'alice',
        areValidNicks: known,
      );
      expect(edit.text, 'alice:    ');
      expect(edit.selection, 'alice: '.length);
    });

    test('caret at start prepends nick: ', () {
      final edit = insertConferenceMention(
        text: 'hello',
        selectionStart: 0,
        nick: 'alice',
        areValidNicks: known,
      );
      expect(edit.text, 'alice: hello');
      expect(edit.selection, 'alice: '.length);
    });

    test('after a newline starts a new mention line', () {
      final edit = insertConferenceMention(
        text: 'hi\n',
        selectionStart: 3,
        nick: 'bob',
        areValidNicks: known,
      );
      expect(edit.text, 'hi\nbob: ');
      expect(edit.selection, 'hi\nbob: '.length);
    });

    test('second avatar tap extends with a comma', () {
      final first = insertConferenceMention(
        text: '',
        selectionStart: 0,
        nick: 'alice',
        areValidNicks: known,
      );
      final second = insertConferenceMention(
        text: first.text,
        selectionStart: first.selection,
        nick: 'bob',
        areValidNicks: known,
      );
      expect(second.text, 'alice, bob: ');
      // Caret stays after ": " so a further tap can keep comma-merging.
      expect(second.selection, 'alice, bob: '.length);
    });

    test('third avatar tap keeps extending the comma list', () {
      var edit = insertConferenceMention(
        text: '',
        selectionStart: 0,
        nick: 'alice',
        areValidNicks: known,
      );
      edit = insertConferenceMention(
        text: edit.text,
        selectionStart: edit.selection,
        nick: 'bob',
        areValidNicks: known,
      );
      edit = insertConferenceMention(
        text: edit.text,
        selectionStart: edit.selection,
        nick: 'carol',
        areValidNicks: known,
      );
      expect(edit.text, 'alice, bob, carol: ');
      expect(edit.selection, 'alice, bob, carol: '.length);
    });

    test('comma path requires every previous nick to be valid', () {
      final edit = insertConferenceMention(
        text: 'notanick: ',
        selectionStart: 'notanick: '.length,
        nick: 'bob',
        areValidNicks: known,
      );
      // Falls through to plain nick insert with a leading space.
      expect(edit.text, 'notanick: bob ');
    });

    test('mid-text insert pads with spaces', () {
      final edit = insertConferenceMention(
        text: 'say hi',
        selectionStart: 3, // after "say"
        nick: 'carol',
        areValidNicks: known,
      );
      expect(edit.text, 'say carol hi');
      // Existing space after caret → selection advances past it.
      expect(edit.selection, 'say carol '.length);
    });

    test('insert between words when neither side is whitespace', () {
      final edit = insertConferenceMention(
        text: 'ab',
        selectionStart: 1,
        nick: 'bob',
        areValidNicks: known,
      );
      expect(edit.text, 'a bob b');
      expect(edit.selection, 'a bob '.length);
    });

    test('blank nick is a no-op', () {
      final edit = insertConferenceMention(
        text: 'hello',
        selectionStart: 5,
        nick: '  ',
        areValidNicks: known,
      );
      expect(edit.text, 'hello');
      expect(edit.selection, 5);
    });
  });
}
