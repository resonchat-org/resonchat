// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Edit history: the text a message had before it was corrected (XEP-0308).
//
// The register is restraint and failure modes. Storing the previous text is the
// easy half; the questions that decide whether this module is honest are the
// three it is built around:
//
//   * Once the bound is passed, does the history *say* that the original is
//     gone, or does it promote the oldest survivor to "the original"?
//   * After a retraction (XEP-0424), can one word of the deleted text be read
//     back by any route — including the sender un-deleting the message by
//     correcting it?
//   * Is a history that was cleared told apart from a message whose original
//     really was empty? Both end in an empty string, and only one of them means
//     we threw something away.

import 'package:test/test.dart';
import 'package:resonchat/xmpp/edit_history.dart';

void main() {
  final start = DateTime.utc(2026, 3, 1, 12);
  DateTime at(int minutes) => start.add(Duration(minutes: minutes));

  /// A history built by [times] corrections of a message that started as `v0`.
  ///
  /// Each correction displaces the text the row currently holds, so after [times]
  /// corrections the versions are `v0`..`v[times-1]` and the row holds `v[times]`.
  EditHistory edited(int times) {
    var history = const EditHistory.empty();
    var current = 'v0';
    for (var i = 1; i <= times; i++) {
      history = recordEdit(history, current, 'OM', at(i));
      current = 'v$i';
    }
    return history;
  }

  group('one edit', () {
    test('the original comes back, with the track and the moment', () {
      final history = recordEdit(
        const EditHistory.empty(),
        'the original text',
        'PO',
        at(1),
      );

      expect(isEdited(history), isTrue);
      expect(originalBody(history), 'the original text');
      expect(history.versions, hasLength(1));
      expect(history.versions.single.track, 'PO');
      expect(history.versions.single.replacedAt, at(1));
      expect(history.droppedOldest, isFalse);
    });

    test('a message that was never edited has no history at all', () {
      const history = EditHistory.empty();
      expect(isEdited(history), isFalse);
      expect(originalBody(history), isNull);
      expect(history.versions, isEmpty);
      expect(history.state, EditHistoryState.readable);
    });

    test('two corrections keep both superseded texts in the order applied', () {
      final history = edited(2);
      expect(history.versions.map((v) => v.body), ['v0', 'v1']);
      expect(originalBody(history), 'v0');
      expect(history.versions.first.replacedAt.isBefore(
            history.versions.last.replacedAt,
          ), isTrue);
    });

    test('an out-of-order timestamp is kept, not used to reorder', () {
      // The correction carries no time of its own, so `replacedAt` is when we
      // applied it. Sorting by it would show the chain in an order nobody
      // produced it in.
      final history = recordEdit(
        recordEdit(const EditHistory.empty(), 'first', 'OM', at(5)),
        'second',
        'OM',
        at(1),
      );
      expect(history.versions.map((v) => v.body), ['first', 'second']);
    });
  });

  group('the bound', () {
    test('an edit that lands exactly on the limit keeps the original', () {
      final history = edited(kEditHistoryLimit);
      expect(history.versions, hasLength(kEditHistoryLimit));
      expect(history.droppedOldest, isFalse);
      expect(originalBody(history), 'v0');
    });

    test('the next edit drops the oldest and keeps the newest', () {
      final history = edited(kEditHistoryLimit + 1);
      expect(
        history.versions.map((v) => v.body),
        [for (var i = 1; i <= kEditHistoryLimit; i++) 'v$i'],
      );
      expect(history.droppedOldest, isTrue);
    });

    test('and it is the oldest that goes, not the one just recorded', () {
      // The failure in the permissive direction is refusing to record: the
      // history looks complete and the newest correction is the one that
      // vanishes, so the message on screen has no explanation at all.
      final history = edited(kEditHistoryLimit + 1);
      final bodies = history.versions.map((v) => v.body).toList();

      expect(bodies, isNot(contains('v0')), reason: 'the oldest is dropped');
      expect(bodies, contains('v${kEditHistoryLimit}'));
      expect(bodies, hasLength(kEditHistoryLimit));
    });

    test('once dropped, the survivor is never called the original', () {
      // The whole reason for the flag. `v1` is real text and is still worth
      // showing, but calling it the text the message started with is a fluent,
      // completely false claim.
      final history = edited(kEditHistoryLimit + 1);
      expect(originalBody(history), isNull);
      expect(history.oldestVersion, isNotNull);
      expect(history.oldestVersion!.body, 'v1');
      expect(redactEditHistory(history), kHistoryTruncatedNotice);
      expect(redactEditHistory(history), isNot(contains('v1')));
    });

    test('truncation is sticky', () {
      final history = recordEdit(
        edited(kEditHistoryLimit + 1),
        'v${kEditHistoryLimit}',
        'OM',
        at(90),
      );
      expect(history.droppedOldest, isTrue);
      expect(originalBody(history), isNull);
    });

    test('a truncated history is exactly at the bound', () {
      // The invariant that makes stickiness free: dropping only ever happens at
      // the bound, so nothing has to remember that it once dropped anything.
      final short = edited(kEditHistoryLimit - 1);
      expect(short.versions, hasLength(kEditHistoryLimit - 1));
      expect(short.droppedOldest, isFalse);

      final exact = edited(kEditHistoryLimit);
      expect(exact.versions, hasLength(kEditHistoryLimit));
      expect(exact.droppedOldest, isFalse);

      final long = edited(kEditHistoryLimit + 40);
      expect(long.versions, hasLength(kEditHistoryLimit));
      expect(long.droppedOldest, isTrue);
    });

    test('a bound written by hand is applied on the way in too', () {
      // Anything that builds a list — a decoded column, a test — goes through
      // `of`, so no route into a history can exceed the limit.
      final history = EditHistory.of([
        for (var i = 0; i < 50; i++)
          MessageVersion(body: 'x$i', track: 'OM', replacedAt: at(i)),
      ]);
      expect(history.versions, hasLength(kEditHistoryLimit));
      expect(history.droppedOldest, isTrue);
      expect(history.versions.last.body, 'x49');
    });

    test('a replayed correction is recognised before it costs a slot', () {
      // Six deliveries of one correction must not read as six edits: with the
      // bound in force, the fifth replay would cost somebody the original.
      final history = edited(1);
      expect(
        isNoOpCorrection(
          currentBody: 'v1',
          currentTrack: 'OM',
          newBody: 'v1',
          newTrack: 'OM',
        ),
        isTrue,
      );
      expect(history.versions, hasLength(1));
    });

    test('a correction that only changes the track is not a replay', () {
      // Skipping it would leave the message labelled with the track it stopped
      // travelling on.
      expect(
        isNoOpCorrection(
          currentBody: 'same words',
          currentTrack: 'OM',
          newBody: 'same words',
          newTrack: 'PO',
        ),
        isFalse,
      );
    });
  });

  group('retraction', () {
    test('leaves nothing readable behind', () {
      final history = onRetraction(edited(3));
      expect(history.state, EditHistoryState.redacted);
      expect(history.versions, isEmpty);
      expect(originalBody(history), isNull);
      expect(isEdited(history), isFalse);
    });

    test('not one word of the deleted text is still in it', () {
      final history = edited(3);
      final forgotten = onRetraction(history);

      expect(forgotten.versions, isEmpty);
      expect(originalBody(forgotten), isNull);
      expect(redactEditHistory(forgotten), isNot(contains('v0')));
      expect(encodeEditHistory(forgotten), isNot(contains('v0')));
    });

    test('the words say it went with the message', () {
      expect(
        redactEditHistory(onRetraction(edited(2))),
        kHistoryRedactedNotice,
      );
      // A reader who is only told "deleted" will go looking for the old
      // version; this sentence has to close that off.
      expect(kHistoryRedactedNotice, contains('deleted'));
    });

    test('nothing can put it back, not even an un-deletion', () {
      // Retract, then correct: `applyCorrection` brings the message back, and
      // the sender un-deleted it. The history does not come back with it —
      // rebuilding one would mean writing a chain whose first link is text we
      // were told to forget.
      final redacted = onRetraction(edited(2));
      final after = recordEdit(redacted, 'the corrected text', 'OM', at(10));

      expect(after.state, EditHistoryState.redacted);
      expect(after.versions, isEmpty);
      expect(originalBody(after), isNull);
      expect(recordEdit(after, 'again', 'OM', at(11)), after);
    });

    test('an unreadable history is dropped like any other', () {
      // "We could not parse it" is not a reason to keep a copy of a message
      // somebody asked us to delete.
      final history = onRetraction(decodeEditHistory('{ not json'));
      expect(history.state, EditHistoryState.redacted);
      expect(history.versions, isEmpty);
    });

    test('an empty history is dropped too', () {
      expect(
        onRetraction(const EditHistory.empty()).state,
        EditHistoryState.redacted,
      );
    });

    test('redacting twice is the same answer', () {
      final once = onRetraction(edited(1));
      expect(onRetraction(once), once);
    });

    test('a redacted history stays redacted through a round trip', () {
      final stored = encodeEditHistory(onRetraction(edited(2)));
      final read = decodeEditHistory(stored);
      expect(read.state, EditHistoryState.redacted);
      expect(read, const EditHistory.redacted());
    });
  });

  group('an empty history', () {
    test('answers every question without throwing', () {
      const history = EditHistory.empty();
      expect(originalBody(history), isNull);
      expect(isEdited(history), isFalse);
      expect(history.oldestVersion, isNull);
      expect(redactEditHistory(history), kHistoryEmptyNotice);
      expect(encodeEditHistory(history), '[]');
    });

    test('a column that was never written is empty, not unreadable', () {
      // A message from before this feature existed has no history, which is an
      // answer. Failing to parse one would report a client bug for every
      // uncorrected message in the transcript.
      expect(decodeEditHistory(null), const EditHistory.empty());
      expect(decodeEditHistory(''), const EditHistory.empty());
      expect(isEdited(decodeEditHistory(null)), isFalse);
    });

    test('and the first correction of it becomes its original', () {
      final history = edited(1);
      expect(history.oldestVersion!.body, 'v0');
      expect(originalBody(history), 'v0');
    });
  });

  group('an empty original is not a cleared history', () {
    test('it reports an empty body, not a missing one', () {
      final history = recordEdit(const EditHistory.empty(), '', 'OM', at(1));
      expect(originalBody(history), '');
      expect(isEdited(history), isTrue);
    });

    test('and it gets its own words', () {
      final history = recordEdit(const EditHistory.empty(), '', 'OM', at(1));
      expect(redactEditHistory(history), kHistoryEmptyOriginalNotice);
      expect(kHistoryEmptyOriginalNotice, isNot(kHistoryEmptyNotice));
      expect(kHistoryEmptyOriginalNotice, isNot(kHistoryRedactedNotice));
      expect(kHistoryEmptyOriginalNotice, isNot(kHistoryTruncatedNotice));
    });

    test('every absent case is a different sentence', () {
      // One blank string cannot carry four meanings. A reader who cannot tell
      // them apart concludes the client is broken, which is worse than having
      // thrown the history away.
      final notices = {
        kHistoryRedactedNotice,
        kHistoryUnreadableNotice,
        kHistoryTruncatedNotice,
        kHistoryEmptyNotice,
        kHistoryEmptyOriginalNotice,
      };
      expect(notices, hasLength(5));
    });
  });

  group('a history we cannot read', () {
    test('garbage does not throw', () {
      for (final raw in ['{', 'not json at all', '"a string"', '42', '[1,2]']) {
        expect(decodeEditHistory(raw).state, EditHistoryState.unreadable,
            reason: raw);
      }
    });

    test('is not reported as never edited', () {
      // Reporting false would turn a real edit into an apparent absence of one.
      // The reader has to be told we cannot show it, not that there is nothing.
      final history = decodeEditHistory('{"nonsense": 1}');
      expect(isEdited(history), isTrue);
      expect(originalBody(history), isNull);
      expect(redactEditHistory(history), kHistoryUnreadableNotice);
    });

    test('is never written over', () {
      // Appending to bytes we failed to parse means overwriting a chain we
      // cannot see, and the version being displaced goes with it.
      final history = decodeEditHistory('{"nonsense": 1}');
      final after = recordEdit(history, 'displaced', 'OM', at(1));
      expect(after, history);
      expect(after.versions, isEmpty);
    });

    test('a half-corrupt chain is unreadable, not a chain with a hole', () {
      // The order *is* the chain: one missing entry and the reader cannot tell
      // which step went missing, so showing the rest would be a plausible story
      // with a hole in it.
      final history = decodeEditHistory(
        '[{"body":"kept","track":"OM","at":"2026-03-01T12:00:00.000Z"},'
        '{"track":"OM","at":"2026-03-01T12:01:00.000Z"}]',
      );
      expect(history.state, EditHistoryState.unreadable);
      expect(history.versions, isEmpty);
      expect(originalBody(history), isNull);
    });

    test('the verdict survives a round trip even though the bytes do not', () {
      final stored = encodeEditHistory(decodeEditHistory('garbage'));
      expect(decodeEditHistory(stored).state, EditHistoryState.unreadable);
    });
  });

  group('the track on a version', () {
    test('is kept, and kept as it was', () {
      // 'pqomemo' is a spelling an earlier build wrote. Normalising it to a
      // canonical token would be fine, but *defaulting* an unknown one would
      // not: see trackLabel.
      final history = recordEdit(
        const EditHistory.empty(),
        'text',
        'pqomemo',
        at(1),
      );
      expect(history.versions.single.track, 'pqomemo');
      expect(decodeEditHistory(encodeEditHistory(history)).versions.single
          .track, 'pqomemo');
    });

    test('no unrecognised token is ever called plaintext', () {
      // The failure this whole rule exists to prevent: a version that renders
      // as an unlabelled message implies it went out in the clear.
      for (final token in ['', ' ', 'zz', '0', 'n/a', 'none-but-not']) {
        expect(trackLabel(token), isNot('plaintext'), reason: token);
      }
      expect(trackLabel('error'), isNot('plaintext'));
    });

    test('a missing track in a stored version stays missing', () {
      final history = decodeEditHistory('[{"body":"text","at":'
          '"2026-03-01T12:00:00.000Z"}]');
      expect(history.state, EditHistoryState.readable);
      expect(history.versions.single.track, '');
      expect(trackLabel(history.versions.single.track), kTrackUnknownLabel);
    });
  });

  group('round trip', () {
    test('keeps bodies, order and times', () {
      final history = edited(4);
      final read = decodeEditHistory(encodeEditHistory(history));
      expect(read, history);
      expect(
        read.versions.map((v) => v.body),
        history.versions.map((v) => v.body),
      );
      expect(read.versions.first.replacedAt, at(1));
      expect(originalBody(read), 'v0');
    });

    test('re-bounds a stored list that is too long', () {
      // A column edited by hand, or written by a build with a bigger limit,
      // must not be able to blow past ours.
      final raw = '[${List.generate(9, (i) => '{"body":"b$i","track":"OM",'
              '"at":"2026-03-01T12:0${i % 9}:00.000Z"}')
          .join(',')}]';
      final read = decodeEditHistory(raw);
      expect(read.versions, hasLength(kEditHistoryLimit));
      expect(read.droppedOldest, isTrue);
      expect(originalBody(read), isNull);
    });

    test('a version whose body is empty survives as an empty body', () {
      final history = recordEdit(const EditHistory.empty(), '', 'OM', at(1));
      final read = decodeEditHistory(encodeEditHistory(history));
      expect(originalBody(read), '');
      expect(redactEditHistory(read), kHistoryEmptyOriginalNotice);
    });
  });
}