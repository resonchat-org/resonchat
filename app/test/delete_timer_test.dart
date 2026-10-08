// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// "Delete messages after": what is eligible, what a single sweep deletes, and
// when recovery is even possible.
//
// The register below is restraint and failure modes, not coverage of the
// feature working. Per rule, the question asked of each is: what is the worst
// thing that happens if this is wrong? For most of them the answer is "a
// conversation the user can still read is emptied, and the interface offers no
// way to tell that apart from a bug", so the tests that matter are the ones
// where the answer must be *no*.

import 'package:test/test.dart';
import 'package:resonchat/xmpp/delete_timer.dart';

void main() {
  // Fixed so that "two hours ago" means the same thing in every test and an
  // accidental use of the real clock cannot make a rule look satisfied.
  final now = DateTime(2026, 3, 1, 12);

  /// One stored message, [ago] older than [now] unless a timestamp is given.
  StoredMessage row(
    int id, {
    Duration ago = const Duration(hours: 2),
    bool pinned = false,
    bool outgoing = false,
    DateTime? at,
  }) => (
    id: id,
    timestamp: at ?? now.subtract(ago),
    pinned: pinned,
    outgoing: outgoing,
  );

  /// The duration a caller would hand to the eligibility rule.
  ///
  /// Exactly `interval.age`, which is null for off. Every test below goes
  /// through this rather than naming a [Duration] literal, so that the rule is
  /// exercised the way the store will actually feed it and a future change to
  /// what an interval means cannot leave these tests behind.
  Duration? ageOf(DeleteInterval interval) => interval.age;

  group('off means nothing is ever eligible', () {
    test('a three-week-old message is not eligible', () {
      expect(
        isEligibleForDeletion(
          interval: ageOf(DeleteInterval.off),
          // Armed, even though off: a null age has to win over an arming time
          // that is present, or a conversation could be swept by a setting the
          // user has already turned off.
          armedAt: now.subtract(const Duration(days: 30)),
          timestamp: now.subtract(const Duration(days: 21)),
          now: now,
          pinned: false,
          outgoing: false,
          hasDraft: false,
        ),
        isFalse,
      );
    });

    test('a sweep under off returns an empty batch', () {
      final batch = deleteBatchFor(
        interval: ageOf(DeleteInterval.off),
        armedAt: now.subtract(const Duration(days: 30)),
        now: now,
        hasDraft: false,
        rows: [for (var i = 1; i <= 2000; i++) row(i)],
      );
      expect(batch.ids, isEmpty);
      expect(batch.count, 0);
      // Not "finished": a caller looping while moreRemaining would stop here
      // for the right reason only if this is false, and off means the same
      // thing for ever.
      expect(batch.moreRemaining, isFalse);
    });
  });

  group('the interval is a closed set', () {
    test('an unknown stored token resolves to off', () {
      expect(DeleteInterval.fromStored('2 minutes'), DeleteInterval.off);
      expect(DeleteInterval.fromStored('30 seconds'), DeleteInterval.off);
    });

    test('an absent or unreadable value resolves to off', () {
      // A corrupt setting must never be the thing that starts deleting a
      // conversation. Only off is a safe direction here.
      expect(DeleteInterval.fromStored(null), DeleteInterval.off);
      expect(DeleteInterval.fromStored(''), DeleteInterval.off);
    });

    test('every offered interval survives a storage round trip', () {
      for (final interval in DeleteInterval.values) {
        expect(
          DeleteInterval.fromStored(interval.stored),
          interval,
          reason: 'the token a restore reads must name the interval it wrote',
        );
      }
    });

    test('no two intervals share a token', () {
      // Two intervals collapsing onto one stored string would make the user's
      // choice silently a different one after a restart.
      final tokens = DeleteInterval.values.map((i) => i.stored).toSet();
      expect(tokens.length, DeleteInterval.values.length);
    });
  });

  group('a corrupt interval cannot delete anything', () {
    test('zero means off, not "delete immediately"', () {
      // No such choice is offered anywhere, so a zero here can only be a
      // corrupt or computed value. Reading it as instant deletion empties the
      // conversation on the first sweep, with nothing on screen to explain it.
      expect(
        isEligibleForDeletion(
          interval: Duration.zero,
          armedAt: now.subtract(const Duration(days: 30)),
          timestamp: now.subtract(const Duration(days: 30)),
          now: now,
          pinned: false,
          outgoing: false,
          hasDraft: false,
        ),
        isFalse,
      );
    });

    test('a negative interval means off', () {
      expect(
        isEligibleForDeletion(
          interval: const Duration(seconds: -30),
          armedAt: now.subtract(const Duration(days: 30)),
          timestamp: now.subtract(const Duration(days: 30)),
          now: now,
          pinned: false,
          outgoing: false,
          hasDraft: false,
        ),
        isFalse,
      );
    });

    test('a sweep on a zero interval is empty however much is due', () {
      final batch = deleteBatchFor(
        interval: Duration.zero,
        armedAt: now.subtract(const Duration(days: 30)),
        now: now,
        hasDraft: false,
        rows: [
          for (var i = 1; i <= 500; i++) row(i, ago: const Duration(days: 29)),
        ],
      );
      expect(batch.ids, isEmpty);
    });

    test('a limit of zero means delete nothing, not delete everything', () {
      // Clamping a zero limit up to the default would perform a deletion the
      // caller explicitly declined, because it wanted the work done later.
      final batch = deleteBatchFor(
        interval: ageOf(DeleteInterval.oneHour),
        armedAt: now.subtract(const Duration(days: 2)),
        now: now,
        hasDraft: false,
        rows: [row(1, ago: const Duration(hours: 5))],
        limit: 0,
      );
      expect(batch.ids, isEmpty);
      expect(batch.moreRemaining, isFalse);
    });

    test('a negative limit is refused rather than treated as unlimited', () {
      final batch = deleteBatchFor(
        interval: ageOf(DeleteInterval.oneHour),
        armedAt: now.subtract(const Duration(days: 2)),
        now: now,
        hasDraft: false,
        rows: [row(1, ago: const Duration(hours: 5))],
        limit: -1,
      );
      expect(batch.ids, isEmpty);
    });
  });

  group('arming is not the same thing as the interval', () {
    test(
      'a message older than the interval but newer than arming is exempt',
      () {
        // The user set the timer an hour ago, having just read a day-old
        // conversation. A one-hour timer must not reach back over what they
        // were reading when they opted in.
        expect(
          isEligibleForDeletion(
            interval: ageOf(DeleteInterval.oneHour),
            armedAt: now.subtract(const Duration(hours: 1)),
            timestamp: now.subtract(const Duration(hours: 3)),
            now: now,
            pinned: false,
            outgoing: false,
            hasDraft: false,
          ),
          isFalse,
        );
      },
    );

    test('nothing that predates the arming instant is deletable', () {
      // The rule that makes *changing* the interval safe. [armedAt] is a
      // precondition — the moment the current interval took effect — and it only
      // does this job if the caller refreshes it on every change.
      //
      // The failure it prevents: a user with a week-long timer has read three
      // months of history, then shortens the interval to thirty seconds because
      // they now want fast expiry. Those messages were never eligible under a
      // week; after the change they are. Without a refreshed instant the next
      // sweep destroys months of already-read conversation, irreversibly, from a
      // settings change that reads as innocuous.
      expect(
        isEligibleForDeletion(
          interval: ageOf(DeleteInterval.thirtySeconds),
          // The change happened five seconds ago.
          armedAt: now.subtract(const Duration(seconds: 5)),
          // A message from three months ago, present before the change.
          timestamp: now.subtract(const Duration(days: 90)),
          now: now,
          pinned: false,
          outgoing: false,
          hasDraft: false,
        ),
        isFalse,
      );
    });

    test('a message that arrived after arming does age out on the new interval', () {
      // The other half, and the reason the rule above is a floor rather than a
      // blanket refusal. Reading it the other way — "nothing that was ever
      // present when the setting changed" — would make the feature delete
      // nothing at all, which is its own silent failure.
      expect(
        isEligibleForDeletion(
          interval: ageOf(DeleteInterval.thirtySeconds),
          armedAt: now.subtract(const Duration(hours: 2)),
          timestamp: now.subtract(const Duration(hours: 1)),
          now: now,
          pinned: false,
          outgoing: false,
          hasDraft: false,
        ),
        isTrue,
      );
    });

    test('no arming time means nothing is eligible', () {
      // Every row in the conversation predates a rule whose origin is unknown,
      // so the only honest outcome is to delete none of them. Every other
      // exemption is switched off above, so this cannot pass for the wrong
      // reason.
      expect(
        isEligibleForDeletion(
          interval: ageOf(DeleteInterval.thirtySeconds),
          armedAt: null,
          timestamp: now.subtract(const Duration(days: 400)),
          now: now,
          pinned: false,
          outgoing: false,
          hasDraft: false,
        ),
        isFalse,
      );
    });

    test('a message arriving in the same instant as arming is eligible', () {
      // Stored timestamps have second precision, so equality is the common
      // case for a message that landed as the user tapped the switch, and a
      // strict comparison here would make the first message after arming
      // immortal.
      final armedAt = now.subtract(const Duration(minutes: 1));
      expect(
        isEligibleForDeletion(
          interval: ageOf(DeleteInterval.thirtySeconds),
          armedAt: armedAt,
          timestamp: armedAt,
          now: now,
          pinned: false,
          outgoing: false,
          hasDraft: false,
        ),
        isTrue,
      );
    });
  });

  group('a pin is an exemption, not a delay', () {
    test('a pinned message is exempt at any age', () {
      expect(
        isEligibleForDeletion(
          interval: ageOf(DeleteInterval.thirtySeconds),
          armedAt: now.subtract(const Duration(days: 400)),
          timestamp: now.subtract(const Duration(days: 400)),
          now: now,
          pinned: true,
          outgoing: false,
          hasDraft: false,
        ),
        isFalse,
      );
    });

    test('the same message unpinned is due', () {
      // Asserted as a pair because a rule that made everything ineligible would
      // pass the pin test on its own. Every other exemption is off above, so a
      // failure here means the pin is not being read.
      bool eligible({required bool pinned}) => isEligibleForDeletion(
        interval: ageOf(DeleteInterval.thirtySeconds),
        armedAt: now.subtract(const Duration(days: 400)),
        timestamp: now.subtract(const Duration(days: 400)),
        now: now,
        pinned: pinned,
        outgoing: false,
        hasDraft: false,
      );
      expect(eligible(pinned: true), isFalse);
      expect(eligible(pinned: false), isTrue);
    });

    test('unpinning makes an overdue message due on the next sweep', () {
      // Deliberate. A pin that outlived its exemption would be a promise about
      // history that has already been thrown away, and the UI would claim to be
      // protecting something it no longer has.
      final protected = row(1, ago: const Duration(days: 90), pinned: true);
      final batch = deleteBatchFor(
        interval: ageOf(DeleteInterval.oneWeek),
        armedAt: now.subtract(const Duration(days: 400)),
        now: now,
        hasDraft: false,
        rows: [
          row(1, ago: const Duration(days: 90), pinned: true),
          // The same message, after the user unpinned it.
          (
            id: protected.id,
            timestamp: protected.timestamp,
            pinned: false,
            outgoing: false,
          ),
        ],
      );
      // Both rows describe one message; the pinned view must not drag the
      // unprotected one into the batch as well.
      expect(batch.ids, [1]);
    });
  });

  group('our own messages are exempt', () {
    test('an outgoing message is kept even when overdue', () {
      expect(
        isEligibleForDeletion(
          interval: ageOf(DeleteInterval.thirtySeconds),
          armedAt: now.subtract(const Duration(days: 2)),
          timestamp: now.subtract(const Duration(days: 1)),
          now: now,
          pinned: false,
          outgoing: true,
          hasDraft: false,
        ),
        isFalse,
      );
    });

    test('an incoming message of the same age is deleted', () {
      expect(
        isEligibleForDeletion(
          interval: ageOf(DeleteInterval.thirtySeconds),
          armedAt: now.subtract(const Duration(days: 2)),
          timestamp: now.subtract(const Duration(days: 1)),
          now: now,
          pinned: false,
          outgoing: false,
          hasDraft: false,
        ),
        isTrue,
      );
    });

    test('a sweep keeps ours and takes theirs in one pass', () {
      // The carbon case: a copy of our own message arriving from another device
      // is still ours, and the caller answers `outgoing` as
      // `!incoming || isCarbon` so both copies share one fate.
      final batch = deleteBatchFor(
        interval: ageOf(DeleteInterval.oneHour),
        armedAt: now.subtract(const Duration(days: 2)),
        now: now,
        hasDraft: false,
        rows: [
          row(1, ago: const Duration(hours: 5)),
          row(2, ago: const Duration(hours: 5), outgoing: true),
          row(3, ago: const Duration(hours: 5), outgoing: true),
        ],
      );
      expect(batch.ids, [1]);
      expect(batch.count, 1);
    });
  });

  group('a draft holds the whole conversation', () {
    test('nothing is eligible while the user is typing', () {
      // The user is composing a reply to what they are reading right now, so
      // the transcript changing under them loses their place and their
      // reference at the moment they are least able to notice.
      expect(
        isEligibleForDeletion(
          interval: ageOf(DeleteInterval.thirtySeconds),
          armedAt: now.subtract(const Duration(days: 2)),
          timestamp: now.subtract(const Duration(days: 1)),
          now: now,
          pinned: false,
          outgoing: false,
          hasDraft: true,
        ),
        isFalse,
      );
    });

    test('not even a thousand due messages, and no partial sweep', () {
      final batch = deleteBatchFor(
        interval: ageOf(DeleteInterval.thirtySeconds),
        armedAt: now.subtract(const Duration(days: 2)),
        now: now,
        hasDraft: true,
        rows: [
          for (var i = 1; i <= 1000; i++) row(i, ago: const Duration(days: 1)),
        ],
      );
      expect(batch.ids, isEmpty);
      expect(batch.moreRemaining, isFalse);
    });

    test('clearing the draft releases the backlog', () {
      final rows = [row(1, ago: const Duration(days: 1))];
      DeleteBatch sweep({required bool hasDraft}) => deleteBatchFor(
        interval: ageOf(DeleteInterval.thirtySeconds),
        armedAt: now.subtract(const Duration(days: 2)),
        now: now,
        hasDraft: hasDraft,
        rows: rows,
      );
      expect(sweep(hasDraft: true).ids, isEmpty);
      expect(sweep(hasDraft: false).ids, [1]);
    });
  });

  group('the clock is not assumed to be right', () {
    test('a message stamped in the future is not yet due', () {
      // An archive replay carries the sender's clock. Treating a future
      // timestamp as arbitrarily old would delete on arrival.
      expect(
        isEligibleForDeletion(
          interval: ageOf(DeleteInterval.oneHour),
          armedAt: now.subtract(const Duration(days: 2)),
          timestamp: now.add(const Duration(days: 1)),
          now: now,
          pinned: false,
          outgoing: false,
          hasDraft: false,
        ),
        isFalse,
      );
    });

    test('a millisecond short of the interval is not due', () {
      expect(
        isEligibleForDeletion(
          interval: ageOf(DeleteInterval.oneHour),
          armedAt: now.subtract(const Duration(days: 2)),
          // 1h - 1ms of age, so just under the bar.
          timestamp: now.subtract(
            const Duration(hours: 1) - const Duration(milliseconds: 1),
          ),
          now: now,
          pinned: false,
          outgoing: false,
          hasDraft: false,
        ),
        isFalse,
      );
    });

    test('a millisecond past the interval is due', () {
      expect(
        isEligibleForDeletion(
          interval: ageOf(DeleteInterval.oneHour),
          armedAt: now.subtract(const Duration(days: 2)),
          timestamp: now.subtract(
            const Duration(hours: 1) + const Duration(milliseconds: 1),
          ),
          now: now,
          pinned: false,
          outgoing: false,
          hasDraft: false,
        ),
        isTrue,
      );
    });

    test('exactly at the interval is due', () {
      // The other half of the boundary test above: a rule that fires one
      // millisecond early deletes a message the user was still reading.
      expect(
        isEligibleForDeletion(
          interval: ageOf(DeleteInterval.oneHour),
          armedAt: now.subtract(const Duration(days: 2)),
          timestamp: now.subtract(const Duration(hours: 1)),
          now: now,
          pinned: false,
          outgoing: false,
          hasDraft: false,
        ),
        isTrue,
      );
    });

    test('the smallest offered interval still lets a message be read', () {
      // Thirty seconds is the floor, so the worst case is a message surviving
      // thirty seconds rather than vanishing unread.
      expect(
        isEligibleForDeletion(
          interval: ageOf(DeleteInterval.thirtySeconds),
          armedAt: now.subtract(const Duration(hours: 1)),
          timestamp: now.subtract(const Duration(seconds: 29)),
          now: now,
          pinned: false,
          outgoing: false,
          hasDraft: false,
        ),
        isFalse,
      );
    });
  });

  group('a sweep is a bounded batch, never every match', () {
    /// A thousand due incoming messages, all inside one second so the id
    /// tiebreaker is the only thing ordering them.
    List<StoredMessage> dueRows(int count) => [
      for (var i = 1; i <= count; i++) row(i, ago: const Duration(days: 1)),
    ];

    test('an empty message list yields an empty batch', () {
      final batch = deleteBatchFor(
        interval: ageOf(DeleteInterval.oneHour),
        armedAt: now.subtract(const Duration(days: 2)),
        now: now,
        hasDraft: false,
        rows: const <StoredMessage>[],
      );
      expect(batch.ids, isEmpty);
      expect(batch.count, 0);
      expect(batch.moreRemaining, isFalse);
    });

    test('everything due inside one batch means nothing more remains', () {
      final batch = deleteBatchFor(
        interval: ageOf(DeleteInterval.oneHour),
        armedAt: now.subtract(const Duration(days: 2)),
        now: now,
        hasDraft: false,
        rows: dueRows(3),
      );
      expect(batch.ids, [1, 2, 3]);
      expect(batch.count, 3);
      expect(batch.moreRemaining, isFalse);
    });

    test('a long backlog is capped and says so', () {
      // A sweep that deletes everything at once is an outage wearing the
      // costume of a cleanup: the whole batch becomes one statement full of
      // placeholders, inside a transaction that already holds the write lock.
      final batch = deleteBatchFor(
        interval: ageOf(DeleteInterval.oneHour),
        armedAt: now.subtract(const Duration(days: 2)),
        now: now,
        hasDraft: false,
        rows: dueRows(4000),
      );
      expect(batch.count, kMaxDeleteBatch);
      expect(batch.ids.length, lessThan(4000));
      // The caller has to be able to tell "finished" from "there is more",
      // or it will report a conversation as swept while the backlog grows.
      expect(batch.moreRemaining, isTrue);
    });

    test('the batch drains from the oldest end', () {
      final batch = deleteBatchFor(
        interval: ageOf(DeleteInterval.oneHour),
        armedAt: now.subtract(const Duration(days: 400)),
        now: now,
        hasDraft: false,
        rows: [
          row(1, ago: const Duration(days: 10)),
          row(2, ago: const Duration(days: 30)),
          row(3, ago: const Duration(days: 20)),
        ],
      );
      expect(batch.ids, [2, 3, 1]);
    });

    test('a capped batch still takes the oldest rows', () {
      final batch = deleteBatchFor(
        interval: ageOf(DeleteInterval.oneHour),
        armedAt: now.subtract(const Duration(days: 400)),
        now: now,
        hasDraft: false,
        rows: [
          // Age grows with the id, so id 10 is the oldest row by a whole day
          // and the capped batch has to reach past id 1 to get to it.
          for (var i = 1; i <= 10; i++) row(i, ago: Duration(days: i)),
        ],
        limit: 3,
      );
      expect(batch.ids, [10, 9, 8]);
      expect(batch.moreRemaining, isTrue);
    });

    test('a caller asking for fewer rows than are due is obeyed exactly', () {
      final batch = deleteBatchFor(
        interval: ageOf(DeleteInterval.oneHour),
        armedAt: now.subtract(const Duration(days: 2)),
        now: now,
        hasDraft: false,
        rows: dueRows(5),
        limit: 2,
      );
      expect(batch.count, 2);
      expect(batch.moreRemaining, isTrue);
    });

    test('a repeated row is counted once', () {
      // A join that yields one message twice must not inflate the count the
      // user is shown, even though the duplicate is harmless to the database.
      final one = row(1, ago: const Duration(days: 1));
      final batch = deleteBatchFor(
        interval: ageOf(DeleteInterval.oneHour),
        armedAt: now.subtract(const Duration(days: 2)),
        now: now,
        hasDraft: false,
        rows: [one, one, one],
      );
      expect(batch.ids, [1]);
      expect(batch.count, 1);
    });

    test('the returned ids cannot be mutated by the caller', () {
      final batch = deleteBatchFor(
        interval: ageOf(DeleteInterval.oneHour),
        armedAt: now.subtract(const Duration(days: 2)),
        now: now,
        hasDraft: false,
        rows: dueRows(1),
      );
      expect(() => batch.ids.add(999), throwsUnsupportedError);
    });

    test('the batch agrees with the single-message rule on every row', () {
      // The sweep must not carry its own copy of the exemptions. If it did,
      // this is where the two would come to disagree, and the disagreement
      // would show up as a message the sweep takes that the interface
      // promised was safe.
      final rows = <StoredMessage>[
        row(1, ago: const Duration(days: 5)),
        row(2, ago: const Duration(days: 5), pinned: true),
        row(3, ago: const Duration(days: 5), outgoing: true),
        row(4, ago: const Duration(minutes: 1)),
        row(5, ago: const Duration(days: 20)),
        row(6, at: now.add(const Duration(days: 1))),
      ];
      final batch = deleteBatchFor(
        interval: ageOf(DeleteInterval.oneHour),
        armedAt: now.subtract(const Duration(days: 30)),
        now: now,
        hasDraft: false,
        rows: rows,
        limit: 10,
      );
      for (final r in rows) {
        final individually = isEligibleForDeletion(
          interval: ageOf(DeleteInterval.oneHour),
          armedAt: now.subtract(const Duration(days: 30)),
          timestamp: r.timestamp,
          now: now,
          pinned: r.pinned,
          outgoing: r.outgoing,
          hasDraft: false,
        );
        expect(batch.ids.contains(r.id), individually, reason: 'row ${r.id}');
      }
    });
  });

  group('recovery is refused unless it is proven possible', () {
    test('a caller that proves nothing is told no', () {
      // Every piece of evidence defaults to false, so the forgetting case and
      // the ignorant case are the same case: no. A feature that offers undo for
      // something it cannot undo is found out at the moment the user relies on
      // it, when the message is already gone.
      expect(canUndelete(messageId: 1), isFalse);
      expect(undeleteRefusal(), UndeleteRefusal.unaddressable);
    });

    test('a pinned message has nothing to undo', () {
      // A pin is exempt in the first place, so "Undo" here would suggest the
      // timer had taken a message the app plainly still holds.
      expect(
        undeleteRefusal(
          pinned: true,
          addressable: true,
          copyExistsElsewhere: true,
        ),
        UndeleteRefusal.stillHere,
      );
      expect(
        canUndelete(
          messageId: 1,
          pinned: true,
          addressable: true,
          copyExistsElsewhere: true,
        ),
        isFalse,
      );
    });

    test('a message with no origin-id cannot be fetched by anyone', () {
      // The archive and a carbon both address messages by origin-id, so
      // without one there is nothing to ask for — including on the copy we are
      // trying to recover from.
      expect(
        undeleteRefusal(addressable: false, copyExistsElsewhere: true),
        UndeleteRefusal.unaddressable,
      );
    });

    test('addressable with no other copy is still a refusal', () {
      // The other party's client may have cleared it, their backup may have
      // expired, and the archive may never have had it. This is the case the
      // local-only promise creates, and it is why undo cannot be offered on
      // the strength of hope.
      expect(
        undeleteRefusal(addressable: true, copyExistsElsewhere: false),
        UndeleteRefusal.nothingLeftToFetchFrom,
      );
    });

    test('an addressable message with a copy elsewhere may be recovered', () {
      expect(
        undeleteRefusal(addressable: true, copyExistsElsewhere: true),
        isNull,
      );
      expect(
        canUndelete(
          messageId: 42,
          addressable: true,
          copyExistsElsewhere: true,
        ),
        isTrue,
      );
    });

    test('a nonsensical id is refused without consulting anything else', () {
      // A caller that checks the current selection while meaning to restore
      // some other message would otherwise recover nothing and report success.
      expect(
        canUndelete(messageId: 0, addressable: true, copyExistsElsewhere: true),
        isFalse,
      );
      expect(
        canUndelete(
          messageId: -3,
          addressable: true,
          copyExistsElsewhere: true,
        ),
        isFalse,
      );
    });

    test('recovery does not read the timer setting at all', () {
      // Restoring a row does not disarm the timer, and that is deliberate: undo
      // is a reprieve, not a reversal. Asserted by the absence of any interval
      // input — the two questions cannot be confused for one another, and a
      // caller cannot quietly make one decide the other.
      expect(
        canUndelete(messageId: 7, addressable: true, copyExistsElsewhere: true),
        isTrue,
      );
      expect(
        isEligibleForDeletion(
          interval: ageOf(DeleteInterval.thirtySeconds),
          armedAt: now,
          timestamp: now,
          now: now,
          pinned: false,
          outgoing: false,
          hasDraft: false,
        ),
        isFalse,
        reason: 'a restored row is subject to the rule again from the start',
      );
    });
  });

  group('the feature promises only what it can do', () {
    test('the wording says this device, not the conversation', () {
      // Every screen that offers this has to carry it. Without it the feature
      // reads as "delete for everyone", and a user who believes their messages
      // no longer exist anywhere is less careful about what they type next.
      for (final interval in DeleteInterval.values) {
        expect(
          interval.description,
          contains('this device'),
          reason: '${interval.stored} must not read as a global deletion',
        );
      }
      expect(DeleteIntervalText.locality, contains('not told'));
    });

    test('off describes keeping everything', () {
      expect(
        DeleteInterval.off.description,
        contains('Nothing is ever deleted'),
      );
      expect(DeleteInterval.off.deletes, isFalse);
      expect(DeleteInterval.off.age, isNull);
    });

    test('only the smallest interval is aggressive enough to test the floor', () {
      // The set is short on purpose. Asserted so that adding a five-second
      // interval, which would remove a message before it could be read, cannot
      // happen quietly.
      expect(DeleteInterval.values.length, 5);
      expect(DeleteInterval.values.where((i) => i.deletes).map((i) => i.age), [
        const Duration(seconds: 30),
        const Duration(hours: 1),
        const Duration(days: 1),
        const Duration(days: 7),
      ]);
    });
  });
}
