// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Which of our own OMEMO device ids may be removed from our published list.
//
// The rule is deliberately narrow: only ids this installation published are
// candidates at all. Every test below the first group is about ids we do *not*
// recognise, because that is where the tempting shortcuts live — and a shortcut
// there removes a device belonging to the user's other phone.

import 'package:test/test.dart';
import 'package:resonchat/omemo/device_pruning.dart';

void main() {
  /// A `bundleFetches` that answers true exactly for [live].
  bool Function(int) fetcher(Set<int> live) => (id) => live.contains(id);

  group('an id we published and no longer use goes', () {
    test('when its bundle no longer answers', () {
      final kept = keepableDeviceIds(
        listed: {1, 2, 3},
        ourDeviceId: 3,
        idsWePublished: {1, 2, 3},
        bundleFetches: fetcher(const {3}),
      );
      expect(kept, {3});
      expect(deadDeviceIds(listed: {1, 2, 3}, kept: kept), {1, 2});
    });

    test('but not when it is still answering', () {
      // Another install the user is still running. Dropping its entry would
      // make every peer stop encrypting to it — the exact opposite failure.
      final kept = keepableDeviceIds(
        listed: {1, 2, 3},
        ourDeviceId: 3,
        idsWePublished: {1, 2, 3},
        bundleFetches: fetcher(const {1, 3}),
      );
      expect(kept, {1, 3});
    });
  });

  group('an id we have never seen is left alone', () {
    test('even when its bundle does not answer', () {
      // It may belong to a device of ours we have no record of, or to another
      // implementation's entry in a list we can publish to. We are not
      // entitled to decide that.
      final kept = keepableDeviceIds(
        listed: {7, 3},
        ourDeviceId: 3,
        idsWePublished: {1, 2, 3},
        bundleFetches: fetcher(const {3}),
      );
      expect(kept, {7, 3});
    });

    test('including when we published nothing at all', () {
      // First run after an upgrade from a build that did not record ids. The
      // list is left exactly as found rather than emptied on a guess.
      final kept = keepableDeviceIds(
        listed: {7, 8, 3},
        ourDeviceId: 3,
        idsWePublished: const {},
        bundleFetches: fetcher(const {}),
      );
      expect(kept, {7, 8, 3});
    });
  });

  group('our own current id is never removed', () {
    test('even when the fetch says otherwise', () {
      // The bundle was published seconds ago; a "not found" answer is
      // measuring the wrong thing. Removing it would make this client
      // invisible to everyone.
      final kept = keepableDeviceIds(
        listed: {3},
        ourDeviceId: 3,
        idsWePublished: {1, 2, 3},
        bundleFetches: fetcher(const {}),
      );
      expect(kept, {3});
    });
  });

  group('the situation this exists for', () {
    test('two dozen dead ids collapse to one', () {
      final dead = {for (var i = 1; i <= 24; i++) i * 7};
      final listed = {...dead, 999};
      final kept = keepableDeviceIds(
        listed: listed,
        ourDeviceId: 999,
        idsWePublished: {...dead, 999},
        bundleFetches: fetcher(const {999}),
      );
      expect(kept, {999});
      expect(deadDeviceIds(listed: listed, kept: kept).length, 24);
    });

    test('one still-live install among the dead is preserved', () {
      final dead = {1, 2, 3, 4};
      final listed = {...dead, 5, 9};
      final kept = keepableDeviceIds(
        listed: listed,
        ourDeviceId: 9,
        idsWePublished: {...dead, 5, 9},
        bundleFetches: fetcher(const {5, 9}),
      );
      expect(kept, {5, 9});
    });

    test('an unknown id survives the collapse', () {
      final kept = keepableDeviceIds(
        listed: {1, 2, 42, 9},
        ourDeviceId: 9,
        idsWePublished: {1, 2, 9},
        bundleFetches: fetcher(const {9}),
      );
      expect(kept, {42, 9});
    });
  });

  group('edges', () {
    test('an empty list stays empty', () {
      final kept = keepableDeviceIds(
        listed: const {},
        ourDeviceId: 9,
        idsWePublished: const {},
        bundleFetches: fetcher(const {}),
      );
      expect(kept, isEmpty);
      expect(deadDeviceIds(listed: const {}, kept: kept), isEmpty);
    });

    test('an id absent from the list is not resurrected', () {
      // The list we republish must not gain entries the server never had: the
      // answer is produced by walking `listed`, so ids we remember that the
      // server does not list simply do not appear.
      final kept = keepableDeviceIds(
        listed: {1, 9},
        ourDeviceId: 9,
        idsWePublished: {1, 2, 3, 9},
        bundleFetches: fetcher(const {}),
      );
      expect(kept, {9});
      expect(kept.contains(2), isFalse);
      expect(kept.contains(3), isFalse);
    });

    test('an unasked-about id counts as answering', () {
      // The manager only probes ids that are both listed and ours. Anything
      // else must not be treated as dead just because nobody looked.
      final kept = keepableDeviceIds(
        listed: {1, 5, 9},
        ourDeviceId: 9,
        idsWePublished: {1, 5, 9},
        bundleFetches: (id) => id == 5 ? true : false,
      );
      expect(kept, {5, 9});
    });
  });
}
