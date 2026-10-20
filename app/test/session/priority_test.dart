// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Publish lists: the ignore list and the priority list.
//
// Almost every test here is about restraint rather than coverage. Three ways
// this module can be wrong all look like working software:
//
//   * an empty list, or one we could not read, that reads as "ignore
//     everybody";
//   * a priority entry that hides a contact once their subscription state
//     moves on, so the one conversation the user just fixed is the one that
//     vanishes;
//   * a patch that retracts a publish-list item nobody observed, deleting an
//     entry another of our own devices had just written.

import 'package:test/test.dart';

import 'package:resonchat/xmpp/priority.dart';

void main() {
  /// Reads an entry from the cases where the address is known good.
  IgnoreEntry ignored(String jid, {String? name, String? subscription}) =>
      IgnoreEntry.fromWire(jid, name: name, subscription: subscription)!;

  PriorityEntry prioritised(String jid, {String? subscription, String? name}) =>
      PriorityEntry.fromWire(jid, name: name, subscription: subscription)!;

  PublishLists lists({
    List<IgnoreEntry>? ignore,
    List<PriorityEntry>? priorities,
    bool complete = true,
  }) => PublishLists(
    ignore: ignore ?? const [],
    priorities: priorities ?? const [],
    complete: complete,
  );

  group('the names', () {
    test('a resource is not part of the key', () {
      // The list is about a person. Keying on the full JID would leave the
      // whole protection defeatable by changing device.
      expect(publishJidKey('juliet@example.org/phone'), 'juliet@example.org');
      expect(
        publishJidKey('juliet@example.org/phone/laptop'),
        'juliet@example.org',
      );
    });

    test('case does not make a second entry', () {
      // Case is not something a person controls: it comes from whoever they
      // typed their address into somewhere else.
      expect(publishJidKey('Juliet@Example.ORG'), 'juliet@example.org');
    });

    test('a domain is a legal bare JID', () {
      // Ignoring a whole service is something users do, and a normaliser that
      // rejected it would write an item nothing can then match.
      expect(publishJidKey('example.org'), 'example.org');
    });

    test('a pasted uri is keyed as the JID inside it', () {
      expect(publishJidKey('xmpp:juliet@example.org'), 'juliet@example.org');
    });

    test('normalising twice changes nothing', () {
      // Callers normalise a JID and then compare it against entries that were
      // normalised when they were read. A normaliser that was not idempotent
      // would make those two disagree, and every lookup would miss.
      final once = publishJidKey('Juliet@Example.ORG/phone')!;
      expect(publishJidKey(once), once);
    });

    test('an address we cannot read is dropped, and nothing throws', () {
      // Every one of these arrives from somewhere: a corrupt push item, a
      // truncated stanza, a paste. Throwing on any of them takes down the
      // handling of a whole list over one bad attribute.
      for (final junk in [
        '',
        '   ',
        '/',
        '@example.org',
        'juliet@',
        'a@b@c',
        'juliet@exa mple.org',
        '<juliet@example.org>',
        'juliet"@example.org',
      ]) {
        expect(publishJidKey(junk), isNull, reason: 'accepted "$junk"');
        expect(() => IgnoreEntry.fromWire(junk), returnsNormally);
        expect(IgnoreEntry.fromWire(junk), isNull);
        expect(() => PriorityEntry.fromWire(junk), returnsNormally);
        expect(PriorityEntry.fromWire(junk), isNull);
        expect(() => PriorityEntry.fromItemId(junk), returnsNormally);
      }
    });
  });

  group('subscription states', () {
    test('the four states survive the round trip', () {
      for (final state in SubscriptionState.values) {
        expect(SubscriptionState.fromWire(state.wire), state);
      }
    });

    test('a value we do not know is not "none"', () {
      // `none` is a real instruction on the priority node — "while we have no
      // subscription" — and it is exactly what a broken attribute would be
      // mistaken for if everything unreadable resolved to it.
      expect(SubscriptionState.fromWire('pending'), isNull);
      expect(SubscriptionState.fromWire('mutual'), isNull);
    });

    test('absent and unreadable both read as unknown, never as a state', () {
      expect(SubscriptionState.fromWire(null), isNull);
      expect(SubscriptionState.fromWire('  '), isNull);
    });
  });

  group('the ignore node', () {
    test('a malformed name costs only the name', () {
      // Un-ignoring somebody because an optional attribute was junk would be
      // the worst thing this list could do, and a client we do not control is
      // what would do it.
      final entry = ignored('bad@example.org', name: '  ');
      expect(entry.jid, 'bad@example.org');
      expect(entry.displayName, isNull);
    });

    test('a malformed subscription costs only the subscription', () {
      final entry = ignored('bad@example.org', subscription: 'pending');
      expect(entry.subscription, isNull);
      expect(entry.itemId, 'bad@example.org');
    });

    test('the item id is the bare JID', () {
      expect(ignored('Bad@Example.org/phone').itemId, 'bad@example.org');
    });
  });

  group('the priority node', () {
    test('a state we cannot read makes the entry inert', () {
      // The state is part of the key here, so an unreadable key cannot be
      // honoured — and it must not be read as "no state named" either, which
      // would widen it to every state.
      expect(
        PriorityEntry.fromWire('a@example.org', subscription: 'pending'),
        isNull,
      );
    });

    test('an entry naming no state applies to every state', () {
      final entry = PriorityEntry.fromWire('a@example.org')!;
      for (final state in [...SubscriptionState.values, null]) {
        expect(entry.appliesTo(state), isTrue, reason: '$state');
      }
    });

    test('an entry naming a state applies only to that one', () {
      final entry = prioritised('a@example.org', subscription: 'both');
      expect(entry.appliesTo(SubscriptionState.both), isTrue);
      expect(entry.appliesTo(SubscriptionState.none), isFalse);
      // A contact whose state we could not read is not in `both`, whatever the
      // entry claims; guessing here would promote people on a bad lookup.
      expect(entry.appliesTo(null), isFalse);
    });

    test('the item id carries the state', () {
      expect(
        prioritised('a@example.org', subscription: 'both').itemId,
        'a@example.org/both',
      );
      expect(PriorityEntry.fromWire('a@example.org')!.itemId, 'a@example.org');
    });

    test('an item id is split at the last slash', () {
      // Taking the first slash leaves `phone` in the address and `both`
      // nowhere, which is an entry keyed on nothing.
      final entry = PriorityEntry.fromItemId('a@example.org/phone/both')!;
      expect(entry.jid, 'a@example.org');
      expect(entry.subscription, SubscriptionState.both);
    });

    test('an item id with no state is the bare JID', () {
      expect(PriorityEntry.fromItemId('a@example.org')!.subscription, isNull);
    });

    test('an entry survives a round trip through its item id', () {
      // The push gives us an item id and the patch wants one back. If these
      // disagreed, every publish would look like a change.
      for (final id in ['a@example.org', 'a@example.org/both']) {
        expect(PriorityEntry.fromItemId(id)!.itemId, id);
      }
    });
  });

  group('which list a contact is in', () {
    test('nobody is in the list that does not name them', () {
      final published = lists(
        ignore: [ignored('bad@example.org')],
        priorities: [prioritised('busy@example.org', subscription: 'both')],
      );
      expect(
        bucketFor(published, 'someone@example.org'),
        PublishBucket.contact,
      );
    });

    test('an empty list ignores nobody', () {
      // A bug that read an empty ignore list as "everyone" would look exactly
      // like working software until somebody tried a fresh install.
      const empty = PublishLists.empty();
      const unread = PublishLists.unread();
      expect(bucketFor(empty, 'anyone@example.org'), PublishBucket.contact);
      expect(rosterViewFor(empty, 'anyone@example.org'), RosterView.listed);
      // "We looked and there is nothing" and "we did not look" answer alike but
      // are not the same fact, and only the first is worth telling the user.
      expect(empty.complete, isTrue);
      expect(unread.complete, isFalse);
    });

    test('a contact in both lists is ignored', () {
      // The two lists are written by our other devices as well as by us and can
      // disagree. Ignore is the reading where we do least on the contact's
      // behalf; "most recently published wins" would hand the outcome to clock
      // skew between our own devices, and on a tie to whichever stanza arrived
      // second — which is not a rule anybody could have chosen.
      final both = lists(
        ignore: [ignored('a@example.org')],
        priorities: [prioritised('a@example.org', subscription: 'both')],
      );
      expect(bucketFor(both, 'a@example.org'), PublishBucket.ignored);
      expect(
        rosterViewFor(
          both,
          'a@example.org',
          subscription: SubscriptionState.both,
        ),
        RosterView.hidden,
      );
    });

    test('the order of the entries does not change the answer', () {
      final one = lists(
        ignore: [ignored('a@example.org'), ignored('b@example.org')],
        priorities: [
          prioritised('b@example.org', subscription: 'both'),
          prioritised('a@example.org', subscription: 'to'),
        ],
      );
      final two = lists(
        ignore: [ignored('b@example.org'), ignored('a@example.org')],
        priorities: [
          prioritised('a@example.org', subscription: 'to'),
          prioritised('b@example.org', subscription: 'both'),
        ],
      );
      for (final jid in ['a@example.org', 'b@example.org', 'c@example.org']) {
        expect(bucketFor(one, jid), bucketFor(two, jid), reason: jid);
      }
    });

    test('a contact cannot escape the ignore list by changing resource', () {
      final published = lists(ignore: [ignored('bad@example.org')]);
      expect(
        bucketFor(published, 'bad@example.org/phone'),
        PublishBucket.ignored,
      );
    });

    test('nor by changing case', () {
      final published = lists(ignore: [ignored('bad@example.org')]);
      expect(bucketFor(published, 'BAD@Example.ORG'), PublishBucket.ignored);
    });

    test('an entry naming another state still names the contact', () {
      // The bucket answers which *person* is on which list. Whether their entry
      // applies right now is the roster question; answering it here would make
      // a contact leave the priority bucket every time somebody accepted a
      // subscription request.
      final published = lists(
        priorities: [prioritised('a@example.org', subscription: 'none')],
      );
      expect(bucketFor(published, 'a@example.org'), PublishBucket.priority);
    });

    test('an entry we could not read never acts in either direction', () {
      // The ignore entry survives a subscription we could not read, because its
      // key is the JID; the priority entry does not, because its key includes
      // the state. A client writing nonsense must not be able to put somebody
      // on the ignore list either.
      expect(
        PriorityEntry.fromWire('busy@example.org', subscription: 'pending'),
        isNull,
      );
      final published = lists(
        ignore: [ignored('bad@example.org', subscription: 'pending')],
      );
      expect(bucketFor(published, 'bad@example.org'), PublishBucket.ignored);
      expect(bucketFor(published, 'busy@example.org'), PublishBucket.contact);
    });

    test('an address we cannot read is in neither', () {
      final published = lists(ignore: [ignored('bad@example.org')]);
      expect(bucketFor(published, 'not a jid'), PublishBucket.contact);
      expect(rosterViewFor(published, 'not a jid'), RosterView.listed);
    });
  });

  group('what the roster shows', () {
    test('an ignored contact is hidden', () {
      final published = lists(ignore: [ignored('bad@example.org')]);
      expect(rosterViewFor(published, 'bad@example.org'), RosterView.hidden);
    });

    test('an ordinary contact is shown', () {
      final published = lists(
        ignore: [ignored('bad@example.org')],
        priorities: [prioritised('busy@example.org', subscription: 'both')],
      );
      expect(rosterViewFor(published, 'friend@example.org'), RosterView.listed);
    });

    test('a priority entry naming this state promotes the contact', () {
      final published = lists(
        priorities: [prioritised('a@example.org', subscription: 'both')],
      );
      expect(
        rosterViewFor(
          published,
          'a@example.org',
          subscription: SubscriptionState.both,
        ),
        RosterView.listedFirst,
      );
    });

    test('a priority entry naming another state does not hide them', () {
      // Entries are written against the state their client saw when it
      // published, so they go stale the moment either side accepts a request.
      // Hiding on a mismatch makes the conversation the user just fixed
      // disappear, with nothing in the interface to say why.
      final published = lists(
        priorities: [
          prioritised('a@example.org', subscription: 'none'),
          prioritised('b@example.org', subscription: 'to'),
        ],
      );
      expect(
        rosterViewFor(
          published,
          'a@example.org',
          subscription: SubscriptionState.both,
        ),
        RosterView.listed,
      );
      expect(
        rosterViewFor(
          published,
          'b@example.org',
          subscription: SubscriptionState.both,
        ),
        RosterView.listed,
      );
    });

    test('an ignore entry whose state does not match still hides', () {
      // The other half of the same trap: if the ignore list were narrowed by
      // subscription state, a contact ignored while pending would reappear the
      // moment they became a mutual contact — a list that stops applying
      // exactly when it is needed.
      final published = lists(
        ignore: [ignored('bad@example.org', subscription: 'none')],
      );
      expect(
        rosterViewFor(
          published,
          'bad@example.org',
          subscription: SubscriptionState.both,
        ),
        RosterView.hidden,
      );
    });

    test('a contact whose state we could not read is not promoted', () {
      final published = lists(
        priorities: [prioritised('a@example.org', subscription: 'both')],
      );
      expect(rosterViewFor(published, 'a@example.org'), RosterView.listed);
    });

    test('one matching entry out of several is enough', () {
      // The priority node legitimately holds an entry per state, and our other
      // devices publish them independently.
      final published = lists(
        priorities: [
          prioritised('a@example.org', subscription: 'none'),
          prioritised('a@example.org', subscription: 'both'),
        ],
      );
      expect(
        rosterViewFor(
          published,
          'a@example.org',
          subscription: SubscriptionState.both,
        ),
        RosterView.listedFirst,
      );
    });

    test('lists we could not read hide nobody, and promote nobody', () {
      // Not being able to reach a server is a fact about us, and the roster has
      // to keep working through it. Answering `hidden` for everyone would empty
      // the contact list on a flaky connection. The honest answer is shown here
      // and `complete` is there for the UI to say so in words.
      const unread = PublishLists.unread();
      expect(rosterViewFor(unread, 'anyone@example.org'), RosterView.listed);
      expect(bucketFor(unread, 'anyone@example.org'), PublishBucket.contact);
      expect(unread.complete, isFalse);
    });

    test('a list we did read still decides while the other is missing', () {
      // `complete` is about both nodes together; the entries we do have are
      // still ours to act on.
      final half = lists(ignore: [ignored('bad@example.org')], complete: false);
      expect(rosterViewFor(half, 'bad@example.org'), RosterView.hidden);
    });
  });

  group('the patch', () {
    test('nothing to do is an empty patch', () {
      final patch = ignorePatch(
        desired: [ignored('a@example.org')],
        published: [ignored('a@example.org')],
      );
      expect(patch.isEmpty, isTrue);
      expect(patch.toAdd, isEmpty);
      expect(patch.toRemove, isEmpty);
    });

    test('a name already published is not published again', () {
      // A publish overwrites the payload, so re-sending an entry we already
      // published overwrites whatever another of our devices put there.
      final patch = ignorePatch(
        desired: [ignored('a@example.org')],
        published: [ignored('a@example.org')],
      );
      expect(patch.toAdd, isEmpty);
      expect(patch.toRemove, isEmpty);
    });

    test('a changed display name is not a change', () {
      // Republishing on a name change would fight our own other devices over a
      // field nobody here acts on.
      final patch = ignorePatch(
        desired: [ignored('a@example.org', name: 'Juliet')],
        published: [ignored('a@example.org', name: 'Jules')],
      );
      expect(patch.isEmpty, isTrue);
    });

    test('a name we never published is never retracted', () {
      // Retracting something that is not there is not a no-op: prosody answers
      // `item-not-found`, which a caller cannot tell from a write that failed.
      final patch = ignorePatch(
        desired: [ignored('a@example.org'), ignored('new@example.org')],
        published: [ignored('a@example.org')],
      );
      expect(patch.toAdd, {'new@example.org'});
      expect(patch.toRemove, isEmpty);
    });

    test('a name we published and no longer want is retracted', () {
      final patch = ignorePatch(
        desired: const [],
        published: [ignored('bad@example.org')],
      );
      expect(patch.toRemove, {'bad@example.org'});
      expect(patch.toAdd, isEmpty);
    });

    test('case and resource differences are not changes', () {
      final patch = ignorePatch(
        desired: [ignored('Juliet@Example.ORG/phone')],
        published: [ignored('juliet@example.org')],
      );
      expect(patch.isEmpty, isTrue);
    });

    test('two entries that normalise alike are one add', () {
      final patch = ignorePatch(
        desired: [ignored('a@example.org'), ignored('A@Example.org/laptop')],
        published: null,
      );
      expect(patch.toAdd, {'a@example.org'});
    });

    test('a state change is a retract and a publish, not an edit', () {
      // The state is part of the item id, so there is no such thing as editing
      // one id into another — and the id retracted must be the one the server
      // actually has.
      final patch = priorityPatch(
        desired: [prioritised('a@example.org', subscription: 'both')],
        published: [prioritised('a@example.org', subscription: 'none')],
      );
      expect(patch.toAdd, {'a@example.org/both'});
      expect(patch.toRemove, {'a@example.org/none'});
    });

    test('an unread list is republished whole and retracted from nothing', () {
      // We did not look, so we may not take anything away. Retracting here is a
      // lost update against whichever of our devices published in the meantime,
      // and publishing the whole desired set is the only action that converges
      // on a state we cannot see.
      final patch = ignorePatch(
        desired: [ignored('a@example.org'), ignored('b@example.org')],
        published: null,
      );
      expect(patch.toAdd, {'a@example.org', 'b@example.org'});
      expect(patch.toRemove, isEmpty);
    });

    test('an unread list with nothing to publish retracts nothing', () {
      final patch = priorityPatch(desired: const [], published: null);
      expect(patch.toRemove, isEmpty);
      expect(patch.isEmpty, isTrue);
    });

    test('no name is ever both published and retracted', () {
      final patch = ignorePatch(
        desired: [ignored('a@example.org'), ignored('b@example.org')],
        published: [ignored('b@example.org'), ignored('c@example.org')],
      );
      expect(patch.toAdd.intersection(patch.toRemove), isEmpty);
      // Only the *changed* names, and `b` is not one of them: it is in both
      // lists and identical in both, so a minimal patch does not mention it.
      // The first assertion above is the property this test is named for; this
      // one pins the other half — a patch that re-published unchanged entries
      // would still satisfy the intersection check, and would turn every save
      // into a rewrite of the whole list.
      expect(patch.toAdd.union(patch.toRemove), {
        'a@example.org',
        'c@example.org',
      });
    });

    test('a patch that only takes things away says so', () {
      // The caller has to be able to tell "removed something" from "removed
      // nothing" before it reports a write that succeeded.
      final removing = ignorePatch(
        desired: const [],
        published: [ignored('a@example.org')],
      );
      final idle = ignorePatch(desired: const [], published: const []);
      expect(removing.isRetractOnly, isTrue);
      expect(idle.isRetractOnly, isFalse);
    });
  });
}
