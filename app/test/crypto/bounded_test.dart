// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Bounded concurrency.
//
// The register here is *timing*, which is the awkward kind to test: these tests
// must not be flaky, and a test for a concurrency bug that only fails under load
// is a test that will fail in CI once and never again. So every case below is
// written to distinguish "the runner is wrong" from "the machine is busy" by
// checking the *invariant* rather than the wall clock — peak concurrency, ordering,
// and completion — and by using zero-delay futures wherever the schedule itself
// is what is under test.

import 'dart:async';

import 'package:test/test.dart';

import 'package:resonchat/crypto/dual/bounded.dart';

void main() {
  group('every element runs exactly once', () {
    test('an empty input does nothing and does not hang', () {
      expect(forEachBounded(<int>[], 4, (_) async {}), completes);
    });

    test('more elements than the limit still all run', () async {
      final seen = <int>[];
      await forEachBounded(List<int>.generate(50, (i) => i), 4, (i) async {
        seen.add(i);
      });
      expect(seen, hasLength(50));
      expect(seen.toSet(), hasLength(50));
    });

    test('a limit of one is sequential', () async {
      expect(
        await measurePeakConcurrency(List<int>.filled(10, 0), 1, (_) async {
          await Future<void>.delayed(Duration.zero);
        }),
        1,
      );
    });
  });

  group('the limit is respected', () {
    test('peak concurrency never exceeds the limit', () async {
      for (final limit in [1, 2, 3, 8, 17]) {
        final peak = await measurePeakConcurrency(
          List<int>.filled(60, 0),
          limit,
          (_) async {
            // A real yield, not a no-op: without one everything would run in
            // one synchronous block and the measurement would be meaningless.
            await Future<void>.delayed(Duration.zero);
          },
        );
        expect(peak, lessThanOrEqualTo(limit), reason: 'limit $limit');
      }
    });

    test('the limit is actually reached, not merely respected', () async {
      // The other half of the previous test: a runner that always used one slot
      // would satisfy "never exceeds" perfectly while being 8x slower than it
      // claims. This is the assertion that would catch a limit wired to 1.
      final peak = await measurePeakConcurrency(
        List<int>.filled(60, 0),
        8,
        (_) async => Future<void>.delayed(Duration.zero),
      );
      expect(peak, greaterThan(1));
    });

    test('a degenerate limit does not deadlock or drop work', () async {
      // Zero and negative are the shapes that make the obvious implementation
      // either spin forever or skip everything. Both are treated as one.
      for (final limit in [0, -1, -100]) {
        var ran = 0;
        await forEachBounded(List<int>.filled(5, 0), limit, (_) async {
          ran++;
        });
        expect(ran, 5, reason: 'limit $limit');
      }
    });
  });

  group('one failure does not take the batch with it', () {
    test('a throwing element does not stop the others', () async {
      final ran = <int>[];
      await forEachBounded(List<int>.generate(20, (i) => i), 4, (i) async {
        if (i == 7) throw StateError('this one device is unreadable');
        ran.add(i);
      });
      expect(ran, hasLength(19));
      expect(ran, isNot(contains(7)));
    });

    test('a rejected future is handled the same as a throw', () async {
      // `throw` inside an async body and a returned Future.error are the same
      // thing to a caller, but not always to an implementation.
      final ran = <int>[];
      await forEachBounded(List<int>.generate(10, (i) => i), 3, (i) async {
        if (i == 2) return Future<void>.error(StateError('nope'));
        ran.add(i);
      });
      expect(ran, hasLength(9));
    });

    test('every element failing still completes', () async {
      await forEachBounded(List<int>.filled(10, 0), 2, (_) async {
        throw StateError('all of them');
      });
    });

    test('the failure does not arrive before the work is done', () async {
      // The subtle version: a runner that catches too eagerly can swallow the
      // rejection *before* the element's own work has finished, so a caller
      // observes "completed" while an element is still mid-flight.
      var finished = 0;
      await forEachBounded(List<int>.filled(10, 0), 3, (i) async {
        await Future<void>.delayed(Duration.zero);
        finished++;
        if (i.isEven) throw StateError('half of them');
      });
      expect(finished, 10);
    });
  });

  group('ordering is not promised, and saying so is the point', () {
    test('elements with different delays finish out of input order', () async {
      // If this ever stops being true the runner changed behaviour; if it were
      // ever *required* to be true, a caller would already be relying on an
      // order the documentation refuses.
      final done = <int>[];
      await forEachBounded(List<int>.generate(6, (i) => i), 6, (i) async {
        await Future<void>.delayed(Duration(milliseconds: (6 - i) * 2));
        done.add(i);
      });
      expect(done, hasLength(6));
      expect(done, isNot(List<int>.generate(6, (i) => i)));
    });
  });

  group('measurePeakConcurrency does not distort what it measures', () {
    test('it reports the peak the same way the runner behaved', () async {
      var live = 0;
      var peak = 0;
      final measured = await measurePeakConcurrency(
        List<int>.filled(40, 0),
        5,
        (_) async {
          live++;
          if (live > peak) peak = live;
          await Future<void>.delayed(Duration.zero);
          live--;
        },
      );
      // The caller's own accounting and the helper must agree. If the helper
      // serialised anything the two would diverge, and a test written against
      // the helper would then be validating a fiction.
      expect(measured, peak);
    });
  });
}
