// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Which OMEMO device ids may be removed from a published device list.
//
// Every test below the first group is about the distinction that this file
// exists for: "the bundle is gone" versus "I could not reach it". A caller
// that conflates them deletes live devices and silently downgrades somebody's
// messages — the failure this is written to make impossible.

import 'package:test/test.dart';
import 'package:resonchat/crypto/omemo/device_pruning.dart';

void main() {
  /// A `bundleAbsent` answering true exactly for [absent].
  bool Function(int) probe(Set<int> absent) =>
      (id) => absent.contains(id);

  group('a positively absent bundle is removed', () {
    test('and reported as removed', () {
      final listed = {1, 2, 3};
      final kept = keepableDeviceIds(
        listed: listed,
        ourDeviceId: 3,
        bundleAbsent: probe({1, 2}),
      );
      expect(kept, {3});
      expect(deadDeviceIds(listed: listed, kept: kept), {1, 2});
    });

    test('a device whose bundle is present stays', () {
      final kept = keepableDeviceIds(
        listed: {1, 2, 3},
        ourDeviceId: 3,
        bundleAbsent: probe({1}),
      );
      expect(kept, {2, 3});
    });
  });

  group('an unreachable bundle is not removed', () {
    test('a timeout is not absence', () {
      // The caller's `bundleAbsent` must answer false here. This test exists to
      // state the contract from the other end: there is no input to this
      // function that expresses "unreachable", by design — if there were, one
      // of the two states would be unrepresentable and quietly defaulted.
      final kept = keepableDeviceIds(
        listed: {1, 2, 3},
        ourDeviceId: 3,
        bundleAbsent: probe(const {}),
      );
      expect(kept, {1, 2, 3});
    });

    test('an id nobody probed counts as present', () {
      // The manager only probes ids that are on the list and not ours. An id
      // that was never asked about must not be treated as dead just because
      // nobody looked — the same mistake, reached a different way.
      final probed = {1};
      final kept = keepableDeviceIds(
        listed: {1, 2, 3},
        ourDeviceId: 3,
        bundleAbsent: (id) => probed.contains(id),
      );
      expect(kept, {2, 3});
    });
  });

  group('our own current id is never removed', () {
    test('even when absence is claimed', () {
      // The bundle was published seconds ago, so an "absent" reading is
      // measuring the wrong thing. Removing it would make this client invisible
      // to everyone.
      final kept = keepableDeviceIds(
        listed: {3},
        ourDeviceId: 3,
        bundleAbsent: probe({3}),
      );
      expect(kept, {3});
      expect(deadDeviceIds(listed: {3}, kept: kept), isEmpty);
    });
  });

  group('the situation this exists for', () {
    test('two dozen dead ids collapse to one', () {
      final dead = {for (var i = 1; i <= 24; i++) i * 7};
      final listed = {...dead, 999};
      final kept = keepableDeviceIds(
        listed: listed,
        ourDeviceId: 999,
        bundleAbsent: probe(dead),
      );
      expect(kept, {999});
      expect(deadDeviceIds(listed: listed, kept: kept).length, 24);
    });

    test('one still-live device among the dead is preserved', () {
      // Another install of ours, or somebody else's — either way, a device that
      // answers. Peers must keep encrypting to it.
      final dead = {1, 2, 3, 4};
      final listed = {...dead, 5, 9};
      final kept = keepableDeviceIds(
        listed: listed,
        ourDeviceId: 9,
        bundleAbsent: probe(dead),
      );
      expect(kept, {5, 9});
    });

    test('an entirely unreadable list changes nothing', () {
      // Every probe failed, so every answer is "not absent" and the list is
      // republished unchanged. Refusing to act on no information is the correct
      // outcome, not a disappointing one.
      final listed = {for (var i = 1; i <= 30; i++) i};
      final kept = keepableDeviceIds(
        listed: listed,
        ourDeviceId: 1,
        bundleAbsent: probe(const {}),
      );
      expect(kept, listed);
    });
  });

  group('edges', () {
    test('an empty list stays empty', () {
      final kept = keepableDeviceIds(
        listed: const {},
        ourDeviceId: 9,
        bundleAbsent: probe(const {}),
      );
      expect(kept, isEmpty);
      expect(deadDeviceIds(listed: const {}, kept: kept), isEmpty);
    });

    test('the republished list is a subset of the original', () {
      // It must never gain an entry, or peers start encrypting to devices that
      // do not exist — which looks like a delivery bug on their side and is
      // indistinguishable from one here.
      final listed = {for (var i = 1; i <= 12; i++) i};
      final kept = keepableDeviceIds(
        listed: listed,
        ourDeviceId: 5,
        // Claims far more ids are absent than were ever on the list.
        bundleAbsent: probe({for (var i = 1; i <= 40; i++) i}),
      );
      expect(kept.difference(listed), isEmpty);
      expect(kept.contains(5), isTrue, reason: 'our own id is always kept');
    });

    test('our id missing from the list is not resurrected', () {
      // It cannot be: the answer walks `listed`, so an id the server does not
      // list simply never appears. Asserted because it is the one way this
      // function could publish something the server never had.
      final kept = keepableDeviceIds(
        listed: const {1},
        ourDeviceId: 999,
        bundleAbsent: probe({1}),
      );
      expect(kept, isEmpty);
      expect(kept.contains(999), isFalse);
    });
  });
}
