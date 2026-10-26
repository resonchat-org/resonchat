// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Message bookmarks (XEP-0333, PEP Native Bookmarks).
//
// Most of these are about the two ways this feature can hurt somebody. A diff
// that trusts a list it has not actually read deletes every room the user has,
// on every device, at the moment they reinstall the app. A rewrite that does
// not carry the fields we did not model quietly strips the nickname and the
// password out of a room the user joined deliberately. Both fail silently and
// both look like somebody else's bug, so both are pinned down here.

import 'package:test/test.dart';

import 'package:resonchat/xmpp/roster/bookmarks.dart';

void main() {
  /// What a bookmark's row reads as, which is all a test needs to assert on.
  List<String> labels(List<Bookmark> list) =>
      list.map((b) => b.displayName).toList();

  group('an address we cannot store is refused, not thrown over', () {
    // Every one of these arrived from a device we do not control. A parse
    // failure takes down the whole settings list to lose one row that was
    // already unreadable, so the answer has to be null every time.
    const rubbish = <String?>[
      null,
      '',
      '   ',
      'xmpp:',
      'xmpp:?join',
      'xmpp:@example.org',
      'xmpp:room@',
      'room@',
      '@',
      '/',
      '?join',
      'xmpp:a@b@example.org',
      'xmpp:room@confe rence.example.org',
      'xmpp:example.org',
      'https://conference.example.org/room',
      'mailto:someone@example.org',
      'xmpp:a"b@example.org',
      'xmpp:a<b@example.org',
      'xmpp:room@example.org:notaport',
    ];

    test('nothing here throws', () {
      for (final input in rubbish) {
        expect(
          () => BookmarkUri.parse(input),
          returnsNormally,
          reason: 'parsing $input must not take the list down',
        );
      }
    });

    test('nothing here parses into an address', () {
      // A bookmark that half-parses is worse than one that does not: it joins
      // the wrong room, in front of the people in it.
      for (final input in rubbish) {
        expect(BookmarkUri.parse(input), isNull, reason: '$input');
      }
    });

    test('a room with a resource keeps the room', () {
      // The resource of a room address is *our nickname*, which changes every
      // time we rejoin under another one. Dropping the whole address would
      // lose a bookmark the user clearly meant.
      final uri = BookmarkUri.parse('xmpp:room@conference.example.org/me?join');
      expect(uri!.jid, 'room@conference.example.org');
      expect(uri.join, isTrue);
    });

    test('an empty resource is dropped, not refused', () {
      // `room@server/` is what a truncated paste looks like. The room in front
      // of the slash is unambiguous, and refusing the address over a character
      // the user cannot see loses the bookmark for nothing.
      expect(
        BookmarkUri.parse('xmpp:room@conference.example.org/')!.jid,
        'room@conference.example.org',
      );
    });

    test('a nickname containing a slash is dropped whole, not truncated', () {
      // Nothing to preserve — it is a resource — but it must not turn into a
      // shorter address that happens to parse.
      expect(
        BookmarkUri.parse('xmpp:room@conference.example.org/a/b')!.jid,
        'room@conference.example.org',
      );
    });

    test('a bookmark built on a refused address is a caller bug, loudly', () {
      // Unlike the parser: this one is handed a string the caller has already
      // read, and a bookmark with no address publishes as an entry pointing
      // nowhere.
      expect(() => Bookmark(jid: 'not a jid'), throwsArgumentError);
    });
  });

  group('the leniency that has to be there', () {
    test('a bare JID is accepted, because that is how the server sends it', () {
      // `<jid>room@conference.example.org</jid>` — no scheme. Requiring the URI
      // form would reject every bookmark we already hold.
      expect(
        BookmarkUri.parse('room@conference.example.org')!.toUriString(),
        'xmpp:room@conference.example.org',
      );
    });

    test('the scheme is case-insensitive', () {
      expect(
        BookmarkUri.parse('XMPP:room@conference.example.org')!.jid,
        'room@conference.example.org',
      );
    });

    test('the old im: scheme still names the same address', () {
      expect(
        BookmarkUri.parse('im:room@conference.example.org?join')!.toUriString(),
        'xmpp:room@conference.example.org?join',
      );
    });

    test('xmpp:// is what some clients actually emit', () {
      expect(
        BookmarkUri.parse('xmpp://room@conference.example.org')!.jid,
        'room@conference.example.org',
      );
    });

    test('?join=false is not a request to join', () {
      final uri = BookmarkUri.parse(
        'xmpp:room@conference.example.org?join=false',
      );
      expect(uri!.join, isFalse);
      expect(uri.toUriString(), 'xmpp:room@conference.example.org');
    });

    test('a fragment is dropped rather than refused', () {
      // It addresses nothing in XMPP, so the address in front of it is usually
      // the usable one.
      expect(
        BookmarkUri.parse('xmpp:room@conference.example.org#nicks')!.jid,
        'room@conference.example.org',
      );
    });
  });

  group('?join and ?qr survive a round trip', () {
    for (final input in [
      'xmpp:room@conference.example.org',
      'xmpp:room@conference.example.org?join',
      'xmpp:room@conference.example.org?qr',
      'xmpp:room@conference.example.org?join&qr',
    ]) {
      test(input, () {
        final uri = BookmarkUri.parse(input);
        expect(uri, isNotNull);
        expect(uri!.toUriString(), input);
        expect(BookmarkUri.parse(uri.toUriString()), uri);
      });
    }

    test('?qr&join normalises to join first', () {
      // The order is fixed on the way out so two devices that bookmarked the
      // same room from the same link produce the same string; nothing settles
      // while the spelling depends on who typed it.
      expect(
        BookmarkUri.parse('xmpp:room@conference.example.org?qr&join')!
            .toUriString(),
        'xmpp:room@conference.example.org?join&qr',
      );
    });

    test('a ?message payload does not survive into a bookmark', () {
      // A bookmark is re-read on every launch. Anything that means "do this
      // once" has to die at the edge, or every start of the app would send the
      // same greeting again.
      final uri = BookmarkUri.parse(
        'xmpp:peer@example.org?message=hello%20there',
      );
      expect(uri!.jid, 'peer@example.org');
      expect(uri.toUriString(), 'xmpp:peer@example.org');
    });
  });

  group('identity is the folded address', () {
    test('two spellings of one room collide', () {
      // If they did not, one room would sit in the list twice under two
      // independent auto-join flags and open or not open depending on which
      // copy a client read.
      expect(
        BookmarkUri.parse('XMPP:MyRoom@Conference.Example.ORG')!.key,
        'myroom@conference.example.org',
      );
    });

    test('the casing the user typed is still what we show', () {
      // Folding is for identity only. The stored string is what other clients
      // display, so folding it here would be a silent edit of their data.
      expect(
        BookmarkUri.parse('XMPP:MyRoom@Conference.Example.ORG')!.jid,
        'MyRoom@Conference.Example.ORG',
      );
    });

    test('two bookmarks for one room are one bookmark', () {
      final a = Bookmark(jid: 'Room@conference.example.org', name: 'Room');
      final b = Bookmark(jid: 'room@conference.example.org', name: 'Room');
      expect(a.key, b.key);
      expect(a.matches(b), isTrue);
    });
  });

  group('a nameless bookmark still reads as something', () {
    test('the local part stands in for a name', () {
      // XEP-0333 makes the name optional and plenty of clients write an empty
      // one. An empty row in a settings list is a row the user cannot pick out.
      expect(Bookmark(jid: 'room@conference.example.org').displayName, 'room');
    });

    test('a name of whitespace is not a name', () {
      expect(
        Bookmark(jid: 'room@conference.example.org', name: '  ').displayName,
        'room',
      );
    });

    test('the domain is still there for the line underneath', () {
      final bookmark = Bookmark(jid: 'room@conference.example.org');
      expect(bookmark.domainPart, 'conference.example.org');
      expect(bookmark.localPart, 'room');
    });

    test('a name is trimmed once, so the value is the same either way', () {
      // `Room ` and `Room` are one bookmark, not two, and must not make every
      // sync report a change that publishing cannot clear.
      expect(
        Bookmark(
          jid: 'room@x.example',
          name: ' Room ',
        ).matches(Bookmark(jid: 'room@x.example', name: 'Room')),
        isTrue,
      );
    });
  });

  group('a flag the XEP has no attribute for is dropped, not invented', () {
    test('auto-join on a contact is not a thing XEP-0333 can store', () {
      // Written into an element with nowhere to put it, it would read as set in
      // our own list and be ignored by every other client — a setting that
      // looks like it works.
      final bookmark = Bookmark(
        jid: 'peer@example.org',
        kind: BookmarkKind.contact,
        autoJoin: true,
      );
      expect(bookmark.autoJoin, isFalse);
      expect(bookmark.kind.autoJoinAttribute, isNull);
    });

    test('auto-submit on a conference is not one either', () {
      final bookmark = Bookmark(
        jid: 'room@conference.example.org',
        autoSubmit: true,
      );
      expect(bookmark.autoSubmit, isFalse);
      expect(bookmark.kind.autoSubmitAttribute, isNull);
    });

    test('changing the kind drops the flag the new kind cannot carry', () {
      final room = Bookmark(
        jid: 'peer@example.org',
        autoJoin: true,
      ).copyWith(kind: BookmarkKind.contact);
      expect(room.kind, BookmarkKind.contact);
      expect(room.autoJoin, isFalse);
    });

    test('each flag does reach the wire attribute it belongs to', () {
      expect(BookmarkKind.conference.autoJoinAttribute, 'autojoin');
      expect(BookmarkKind.contact.autoSubmitAttribute, 'auto_submit');
    });
  });

  group('fields we did not model are not lost by a rewrite', () {
    const foreign =
        '<nick>Me</nick>'
        '<extensions xmlns="urn:xmpp:example:thing"/>'
        '<password>hunter2</password>';

    test('copyWith carries the opaque payload over untouched', () {
      // This is the whole reason it is opaque. The rewrite that turns auto-join
      // on must leave `<nick>` and `<password>` exactly as it found them, or a
      // user who bookmarked a protected room on a phone loses the password by
      // touching a switch on a laptop.
      final bookmark = Bookmark(
        jid: 'room@conference.example.org',
        extensionXml: foreign,
      );
      final rewritten = bookmark.copyWith(autoJoin: true);
      expect(rewritten.extensionXml, foreign);
      expect(rewritten.autoJoin, isTrue);
      expect(rewritten.hasExtensionXml, isTrue);
    });

    test('an empty opaque payload is distinguishable from a lost one', () {
      expect(
        Bookmark(jid: 'room@conference.example.org').hasExtensionXml,
        isFalse,
      );
    });

    test('a change to another device’s payload is not a change to publish', () {
      // If it were, our republish would drop what they added, which would come
      // back as a change here again: two devices republishing one room at each
      // other for as long as both are signed in, losing a field on every pass.
      final ours = Bookmark(jid: 'room@conference.example.org', name: 'Room');
      final theirs = ours.copyWith(extensionXml: '<nick>Them</nick>');
      final plan = diffBookmarks(
        current: [theirs],
        desired: [ours],
        intent: BookmarkIntent.replace,
      );
      expect(plan.operations, isEmpty);
      expect(plan.needsPublish, isFalse);
      // ...and the bytes that were there are what would be republished.
      expect(plan.publishList.single.extensionXml, '<nick>Them</nick>');
    });
  });

  group('diffing an unchanged list produces nothing', () {
    final list = [
      Bookmark(
        jid: 'room@conference.example.org',
        name: 'Room',
        autoJoin: true,
      ),
      Bookmark(
        jid: 'peer@example.org',
        kind: BookmarkKind.contact,
        name: 'Peer',
        autoSubmit: true,
      ),
    ];

    test('no operations and nothing worth publishing', () {
      // A republish that changes nothing still wakes every one of the user's
      // other devices and transfers a whole list of rooms to say nothing.
      final plan = diffBookmarks(
        current: list,
        desired: list,
        intent: BookmarkIntent.replace,
      );
      expect(plan.operations, isEmpty);
      expect(plan.needsPublish, isFalse);
      expect(plan.retained, isEmpty);
      expect(plan.publishList, hasLength(2));
    });

    test('a reordered list is still an unchanged list', () {
      // Order is derived, never stored. Two devices holding the same bookmarks
      // must agree without either of them publishing anything.
      final plan = diffBookmarks(
        current: list,
        desired: list.reversed.toList(),
        intent: BookmarkIntent.replace,
      );
      expect(plan.operations, isEmpty);
      expect(labels(plan.publishList), ['Room', 'Peer']);
    });

    test('two empty lists produce nothing', () {
      final plan = diffBookmarks(
        current: const [],
        desired: const [],
        intent: BookmarkIntent.replace,
      );
      expect(plan.operations, isEmpty);
      expect(plan.publishList, isEmpty);
    });

    test('two bookmarks for one room in the payload do not loop forever', () {
      // A payload we did not write. Which copy survives is arbitrary; that it
      // is always the same one is not — otherwise every sync reports a change
      // that no amount of publishing could clear.
      final duplicated = [
        Bookmark(jid: 'room@conference.example.org', name: 'First'),
        Bookmark(jid: 'Room@conference.example.org', name: 'Second'),
      ];
      final plan = diffBookmarks(
        current: duplicated,
        desired: duplicated,
        intent: BookmarkIntent.replace,
      );
      expect(plan.operations, isEmpty);
      expect(plan.publishList, hasLength(1));
      expect(plan.publishList.single.name, 'First');
    });
  });

  group('an empty desired list is not a delete-everything order', () {
    final rooms = [
      Bookmark(jid: 'one@conference.example.org', name: 'One'),
      Bookmark(jid: 'two@conference.example.org', name: 'Two'),
    ];

    test('merge mode keeps everything and removes nothing', () {
      // The fresh-install case: the store is empty, the fetch has not landed,
      // and a list built from what has been seen so far would republish as
      // "the user has no rooms" — on every device, at the moment they least
      // expect it.
      final plan = diffBookmarks(
        current: rooms,
        desired: const [],
        intent: BookmarkIntent.merge,
      );
      expect(plan.removed, isEmpty);
      expect(plan.operations, isEmpty);
      expect(plan.publishList, hasLength(2));
    });

    test('merge mode still adds, and still keeps what it did not see', () {
      // The point of merge is that a caller may add a bookmark without having
      // read the whole list. The published list is the union — publishing the
      // desired list verbatim would delete exactly what merge exists to keep.
      final plan = diffBookmarks(
        current: rooms,
        desired: [Bookmark(jid: 'three@conference.example.org', name: 'Three')],
        intent: BookmarkIntent.merge,
      );
      expect(labels(plan.added), ['Three']);
      expect(labels(plan.publishList), ['One', 'Three', 'Two']);
    });

    test('replace mode does remove, so the last one can go', () {
      // A guard that cannot be turned off is not restraint, it is a bug waiting
      // for the user who really did delete everything.
      final plan = diffBookmarks(
        current: rooms,
        desired: const [],
        intent: BookmarkIntent.replace,
      );
      expect(labels(plan.removed), ['One', 'Two']);
      expect(plan.publishList, isEmpty);
      expect(plan.needsPublish, isTrue);
    });

    test('an empty current list cannot remove what was never seen', () {
      // Reinstall: the server holds twelve rooms and we hold none. Only the
      // adds are known to be right.
      final plan = diffBookmarks(
        current: const [],
        desired: rooms,
        intent: BookmarkIntent.replace,
      );
      expect(labels(plan.added), ['One', 'Two']);
      expect(plan.removed, isEmpty);
    });
  });

  group('our own bookmark is never removable', () {
    const me = 'me@example.org';
    final mine = Bookmark(
      jid: me,
      kind: BookmarkKind.contact,
      name: 'Notes to self',
    );
    final rooms = [
      mine,
      Bookmark(jid: 'room@conference.example.org', name: 'Room'),
    ];

    test('it survives a list that no longer contains it', () {
      // There is no room to re-join and no contact to re-add for the one
      // conversation that is our own address — only a box to type it into.
      final plan = diffBookmarks(
        current: rooms,
        desired: [rooms.last],
        intent: BookmarkIntent.replace,
        ourOwnJid: me,
      );
      expect(plan.removed, isEmpty);
      expect(plan.publishList, hasLength(2));
    });

    test('and the user is told which row did not move', () {
      // Silently keeping it would leave the user staring at a delete they did,
      // waiting for a list that never changes.
      final plan = diffBookmarks(
        current: rooms,
        desired: [rooms.last],
        intent: BookmarkIntent.replace,
        ourOwnJid: me,
      );
      expect(labels(plan.retained), ['Notes to self']);
      expect(plan.needsPublish, isFalse);
    });

    test('the protection is on the address, not the spelling of it', () {
      final plan = diffBookmarks(
        current: rooms,
        desired: [rooms.last],
        intent: BookmarkIntent.replace,
        ourOwnJid: 'ME@Example.ORG',
      );
      expect(plan.removed, isEmpty);
      expect(plan.retained, hasLength(1));
    });

    test('an address we cannot parse protects nothing, and says so', () {
      // Nothing to protect: every bookmark here has a parsed identity, so a
      // broken argument cannot silently unguard the list.
      final plan = diffBookmarks(
        current: rooms,
        desired: [rooms.last],
        intent: BookmarkIntent.replace,
        ourOwnJid: 'not a jid',
      );
      expect(labels(plan.removed), ['Notes to self']);
      expect(plan.retained, isEmpty);
    });

    test('it is still updatable when the user really changes it', () {
      // The guard is on removal only. Refusing to rename the self-chat would be
      // a different and much more annoying kind of wrong.
      final renamed = mine.copyWith(name: 'Self');
      final plan = diffBookmarks(
        current: [mine],
        desired: [renamed],
        intent: BookmarkIntent.replace,
        ourOwnJid: me,
      );
      expect(plan.updated.single.name, 'Self');
      expect(plan.retained, isEmpty);
    });
  });

  group('the order of the list is a decision, made once', () {
    // Bookmarks are a list the user re-reads. One that reshuffles between two
    // opens does not read as a missing sort, it reads as a broken app — and the
    // user cannot tell which it is, so they stop trusting the list.
    test('it is the same whatever order the payloads arrive in', () {
      final bookmarks = [
        Bookmark(jid: 'b@conference.example.org', name: 'Beta'),
        Bookmark(jid: 'a@conference.example.org', name: 'Alpha'),
        Bookmark(jid: 'c@conference.example.org', name: 'Gamma'),
      ];
      expect(labels(orderBookmarks(bookmarks)), ['Alpha', 'Beta', 'Gamma']);
      expect(labels(orderBookmarks(bookmarks.reversed.toList())), [
        'Alpha',
        'Beta',
        'Gamma',
      ]);
      expect(
        orderBookmarks(bookmarks.reversed.toList()).map((b) => b.key).toList(),
        orderBookmarks(bookmarks).map((b) => b.key).toList(),
      );
    });

    test('sorting does not touch the caller’s list', () {
      final bookmarks = [
        Bookmark(jid: 'b@conference.example.org', name: 'Beta'),
        Bookmark(jid: 'a@conference.example.org', name: 'Alpha'),
      ];
      orderBookmarks(bookmarks);
      expect(labels(bookmarks), ['Beta', 'Alpha']);
    });

    test('rooms the app opens by itself come first', () {
      // They are the list the user is really looking at, and the ones whose
      // absence they notice when the app starts.
      final bookmarks = [
        Bookmark(jid: 'a@conference.example.org', name: 'Alpha'),
        Bookmark(jid: 'z@conference.example.org', name: 'Zulu', autoJoin: true),
      ];
      expect(labels(orderBookmarks(bookmarks)), ['Zulu', 'Alpha']);
    });

    test('two rooms with the same name keep a defined order', () {
      // Dart's sort is not stable, so a comparator that calls two bookmarks
      // equal leaves their order to the implementation. Two rooms called
      // `Room` on two services is an ordinary thing to have.
      final sameName = [
        Bookmark(jid: 'room@b.example.org', name: 'Room'),
        Bookmark(jid: 'room@a.example.org', name: 'Room'),
      ];
      expect(labels(orderBookmarks(sameName)), ['Room', 'Room']);
      expect(orderBookmarks(sameName).map((b) => b.key).toList(), [
        'room@a.example.org',
        'room@b.example.org',
      ]);
      expect(
        orderBookmarks(sameName.reversed.toList()).map((b) => b.key).toList(),
        ['room@a.example.org', 'room@b.example.org'],
      );
    });

    test('a name differing only in case still has a defined order', () {
      final differing = [
        Bookmark(jid: 'a@conference.example.org', name: 'room'),
        Bookmark(jid: 'b@conference.example.org', name: 'Room'),
      ];
      expect(orderBookmarks(differing).map((b) => b.key).toList(), [
        'a@conference.example.org',
        'b@conference.example.org',
      ]);
    });

    test('the plan’s operations come back in the order they will be seen', () {
      // A plan whose order disagreed with the list on screen is harder to check
      // by eye, and checking by eye is the only check a log or a failing test
      // gets.
      final current = [Bookmark(jid: 'm@conference.example.org', name: 'Mike')];
      final desired = [
        Bookmark(jid: 'z@conference.example.org', name: 'Zoe'),
        Bookmark(jid: 'a@conference.example.org', name: 'Ann'),
        Bookmark(jid: 'm@conference.example.org', name: 'Mike'),
      ];
      final plan = diffBookmarks(
        current: current,
        desired: desired,
        intent: BookmarkIntent.replace,
      );
      expect(labels(plan.added), ['Ann', 'Zoe']);
      expect(plan.operations.map((o) => o.bookmark.displayName).toList(), [
        'Ann',
        'Zoe',
      ]);
    });

    test('removals come last, because they have no place in the new list', () {
      final stays = Bookmark(
        jid: 'stays@conference.example.org',
        name: 'Stays',
      );
      final plan = diffBookmarks(
        current: [
          Bookmark(jid: 'gone@conference.example.org', name: 'Gone'),
          stays,
        ],
        desired: [stays.copyWith(name: 'Still here')],
        intent: BookmarkIntent.replace,
      );
      expect(plan.operations.map((o) => o.bookmark.displayName).toList(), [
        'Still here',
        'Gone',
      ]);
      expect(plan.operations.first.change, BookmarkChange.updated);
      expect(plan.operations.last.change, BookmarkChange.removed);
    });
  });

  group('the node is the one the standard names', () {
    test('the payload namespace and the feature string coincide', () {
      // They answer different questions and go in different stanzas, so they
      // are two constants; only one spelling keeps them from drifting.
      expect(bookmarksNamespace, 'urn:xmpp:bookmarks:1');
      expect(bookmarksFeature, bookmarksNamespace);
      expect(bookmarksNode, 'storage:bookmarks');
    });

    test('the list is one item, which is why removal is a republish', () {
      // A removal is not a retract: there is a single item, so there is
      // nothing to retract. Any code that reaches for a per-item delete is
      // implementing a different XEP.
      expect(bookmarksItemId, 'current');
    });

    test('the node is private and unbounded', () {
      // `presence` would hand the room list to any roster member who asks; a
      // fixed item cap would drop the oldest bookmark of a user with many
      // rooms and the only symptom would be a room that stopped opening.
      expect(bookmarksAccessModel, 'whitelist');
      expect(bookmarksMaxItems, 'max');
      expect(bookmarksSendLastPublishedItem, 'never');
    });

    test('the config form is the owner one, not the publisher one', () {
      // `pubsub#owner` configures the node; a publish carries no access model
      // at all, because re-configuring an existing node on every publish is how
      // a private room list becomes readable by the whole roster.
      expect(pubsubOwnerXmlns, 'http://jabber.org/protocol/pubsub#owner');
      expect(
        pubsubNodeConfigFormType,
        'http://jabber.org/protocol/pubsub#node_config',
      );
      expect(bookmarksNotifyFeature, 'storage:bookmarks+notify');
    });
  });

  group('the diff says what it is doing', () {
    test('a room becoming a contact is an update, not a delete and re-add', () {
      // The identity is the JID and the item id is the identity, so this is
      // one bookmark changing shape.
      final asRoom = Bookmark(jid: 'x@example.org', name: 'X');
      final asContact = asRoom.copyWith(kind: BookmarkKind.contact);
      final plan = diffBookmarks(
        current: [asRoom],
        desired: [asContact],
        intent: BookmarkIntent.replace,
      );
      expect(plan.operations.single.change, BookmarkChange.updated);
      expect(plan.added, isEmpty);
      expect(plan.removed, isEmpty);
    });

    test('an operation carries what it was and what it becomes', () {
      final before = Bookmark(jid: 'room@conference.example.org', name: 'Old');
      final after = before.copyWith(name: 'New');
      final plan = diffBookmarks(
        current: [before],
        desired: [after],
        intent: BookmarkIntent.replace,
      );
      final op = plan.operations.single;
      expect(op.change, BookmarkChange.updated);
      expect(op.before!.name, 'Old');
      expect(op.after!.name, 'New');
      expect(op.bookmark.name, 'New');
    });

    test('a removal has nothing after it', () {
      final plan = diffBookmarks(
        current: [Bookmark(jid: 'room@conference.example.org')],
        desired: const [],
        intent: BookmarkIntent.replace,
      );
      final op = plan.operations.single;
      expect(op.change, BookmarkChange.removed);
      expect(op.before, isNotNull);
      expect(op.after, isNull);
      expect(op.bookmark.key, 'room@conference.example.org');
    });
  });
}
