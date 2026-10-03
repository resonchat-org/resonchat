// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Whether an inbound message notifies, and what the notification may say.
//
// The register of these tests is the worst thing that happens if a rule is
// wrong, which for this module cuts both ways. Three tests below are about the
// phone going buzz when it must not: a buzz for the user's own carbon, a buzz
// for someone they blocked, a buzz for a mute they set. Three more are about
// the phone staying quiet when it must speak up, because that is the failure
// that costs a user permanently rather than annoyingly — a client that drops
// the one message you needed is a client you uninstall.
//
// The sweeps are exhaustive over the nine boolean inputs on purpose. These
// rules interact, and an interaction is exactly what a hand-written table of
// examples misses.

import 'package:test/test.dart';
import 'package:resonchat/xmpp/notify_policy.dart';

void main() {
  const alice = NotifyIdentity(jid: 'alice@example.org/phone');
  const roomAlice = NotifyIdentity(
    jid: 'room@conference.example.org/phone',
    nickname: 'alice',
  );
  const zoe = NotifyIdentity(jid: 'zoe@example.org/phone', nickname: 'zoe');
  const zoeNoNick = NotifyIdentity(jid: 'zoe@example.org/phone');

  /// Every combination of the nine boolean inputs.
  ///
  /// Bit 4 is `pinned`, so `sweep(bits | 4)` is the same message with the
  /// conversation pinned and nothing else changed.
  NotifyPolicy sweep(int bits, {String body = 'see you soon'}) => NotifyPolicy(
        sender: roomAlice,
        me: zoe,
        body: body,
        muted: (bits & 1) != 0,
        archived: (bits & 2) != 0,
        pinned: (bits & 4) != 0,
        isGroup: (bits & 8) != 0,
        carbon: (bits & 16) != 0,
        undecryptable: (bits & 32) != 0,
        blocked: (bits & 64) != 0,
        appInForeground: (bits & 128) != 0,
        reading: (bits & 256) != 0,
      );

  /// The whole space of inputs, over the three bodies that matter.
  Iterable<NotifyPolicy> everyInput() => [
        for (final body in const [
          'see you soon',
          'zoe: are you there?',
          '   ',
        ])
          for (var bits = 0; bits < 512; bits++) sweep(bits, body: body),
      ];

  /// Every reason a decision is allowed to give.
  const reasons = {
    NotifyReason.blocked,
    NotifyReason.carbon,
    NotifyReason.readingThisConversation,
    NotifyReason.archived,
    NotifyReason.muted,
    NotifyReason.mentionedInMutedConversation,
    NotifyReason.appInForeground,
    NotifyReason.undecryptable,
    NotifyReason.incoming,
  };

  void expectIdentical(NotifyDecision a, NotifyDecision b, String what) {
    expect(b.post, a.post, reason: '$what: post');
    expect(b.sound, a.sound, reason: '$what: sound');
    expect(b.banner, a.banner, reason: '$what: banner');
    expect(b.includePreview, a.includePreview, reason: '$what: preview');
    expect(b.countsAsUnread, a.countsAsUnread, reason: '$what: unread');
    expect(b.reason, a.reason, reason: '$what: reason');
  }

  group('the two rules that outrank everything else', () {
    test('a blocked sender reaches nothing at all', () {
      // Not quiet — absent. Not even the badge. `blocking.dart` stops this
      // device acting as a reader for a blocked person, and a badge saying
      // "3" is the loudest way to keep doing that.
      for (final policy in everyInput()) {
        if (!policy.blocked) continue;
        final d = decide(policy);
        expect(d.post, isFalse, reason: 'bits for $policy');
        expect(d.sound, isFalse);
        expect(d.banner, isFalse);
        expect(d.alerts, isFalse);
        expect(d.countsAsUnread, isFalse);
        expect(d.reason, NotifyReason.blocked);
      }
    });

    test('and beats a mention, because a mention is their text', () {
      // The one thing that would make blocking decorative: anyone who knows the
      // user's name could then reach them through a muted conversation.
      final d = decide(
        const NotifyPolicy(
          sender: roomAlice,
          me: zoe,
          body: 'zoe: are you there?',
          isGroup: true,
          muted: true,
          blocked: true,
        ),
      );
      expect(d.reason, NotifyReason.blocked);
      expect(d.alerts, isFalse);
    });

    test('a carbon never notifies, whatever else is true', () {
      // The user's own typing, arriving from their own laptop. A buzz here
      // teaches them that notifications are noise, and the cure they reach for
      // costs every other conversation its messages too.
      //
      // The silence is asserted over the *whole* input space, exhaustively. The
      // reported reason is not: a carbon from a blocked sender reports `blocked`,
      // because that is the security-relevant fact and the reason is what a bug
      // report quotes. This used to demand `carbon` for every combination, which
      // contradicts the blocked rule directly — and the two are not both
      // satisfiable, so one of them had to give. Blocked wins; see `decide`.
      for (final policy in everyInput()) {
        if (!policy.carbon) continue;
        final d = decide(policy);
        expect(d.post, isFalse);
        expect(d.alerts, isFalse);
        expect(d.countsAsUnread, isFalse);
      }
    });

    test('and the reason is carbon whenever no stronger rule applies', () {
      // The narrowed claim, which is the one the module actually makes: carbon
      // is the explanation unless something security-relevant overrides it.
      for (final policy in everyInput()) {
        if (!policy.carbon || policy.blocked) continue;
        expect(decide(policy).reason, NotifyReason.carbon);
      }
    });

    test('and beats a mention in a muted conversation', () {
      // The text in a carbon is text this user wrote. A self-mention is not
      // something that happened in the world.
      final d = decide(
        const NotifyPolicy(
          sender: zoe,
          me: zoe,
          body: 'zoe: are you there?',
          isGroup: true,
          muted: true,
          carbon: true,
        ),
      );
      expect(d.reason, NotifyReason.carbon);
    });
  });

  group('each rule on its own', () {
    test('a muted conversation is silent', () {
      final d = decide(
        const NotifyPolicy(sender: alice, me: zoe, body: 'hi', muted: true),
      );
      expect(d.post, isFalse);
      expect(d.alerts, isFalse);
      expect(d.countsAsUnread, isFalse);
      expect(d.reason, NotifyReason.muted);
    });

    test('an archived conversation is silent', () {
      // A notification is how an archived conversation comes back. The user put
      // it away, and the whole of archiving is that it stays away.
      final d = decide(
        const NotifyPolicy(sender: alice, me: zoe, body: 'hi', archived: true),
      );
      expect(d.post, isFalse);
      expect(d.countsAsUnread, isFalse);
      expect(d.reason, NotifyReason.archived);
    });

    test('an undecryptable message announces itself and says nothing', () {
      // Announced, because silence would leave the user to conclude the message
      // was lost when they open the app to an unreadable row they were never
      // told about. Described never, because there is nothing honest to
      // describe.
      final d = decide(
        const NotifyPolicy(
          sender: alice,
          me: zoe,
          undecryptable: true,
        ),
      );
      expect(d.post, isTrue);
      expect(d.sound, isTrue);
      expect(d.banner, isTrue);
      expect(d.includePreview, isFalse);
      expect(d.countsAsUnread, isTrue);
      expect(d.reason, NotifyReason.undecryptable);
    });

    test('the foreground counts but does not buzz', () {
      // The badge is not a notification. It is the only record that a message is
      // waiting, and if it is not updated here then closing the app looks
      // identical to never having received anything.
      final d = decide(
        const NotifyPolicy(
          sender: alice,
          me: zoe,
          body: 'hi',
          appInForeground: true,
        ),
      );
      expect(d.post, isFalse);
      expect(d.sound, isFalse);
      expect(d.banner, isFalse);
      expect(d.alerts, isFalse);
      expect(d.countsAsUnread, isTrue);
      expect(d.reason, NotifyReason.appInForeground);
    });

    test('the conversation being read is not a notification', () {
      // They are looking at it. It is on the screen in front of them, and a
      // notification would cover the message with a card about the message.
      final d = decide(
        const NotifyPolicy(
          sender: alice,
          me: zoe,
          body: 'hi',
          appInForeground: true,
          reading: true,
        ),
      );
      expect(d.post, isFalse);
      expect(d.countsAsUnread, isFalse);
      expect(d.reason, NotifyReason.readingThisConversation);
    });

    test('an ordinary message notifies', () {
      final d = decide(const NotifyPolicy(sender: alice, me: zoe, body: 'hi'));
      expect(d.post, isTrue);
      expect(d.sound, isTrue);
      expect(d.banner, isTrue);
      expect(d.includePreview, isTrue);
      expect(d.countsAsUnread, isTrue);
      expect(d.reason, NotifyReason.incoming);
    });

    test('reading outranks an undecryptable message', () {
      // The user is looking at the conversation that holds the unreadable row.
      // Telling them about it is the definition of redundant.
      final d = decide(
        const NotifyPolicy(
          sender: alice,
          me: zoe,
          reading: true,
          undecryptable: true,
        ),
      );
      expect(d.post, isFalse);
      expect(d.reason, NotifyReason.readingThisConversation);
    });

    test('the foreground outranks an undecryptable message', () {
      // "The app is open" is about the phone; "we could not open the message" is
      // about the message. The foreground wins, or the phone interrupts the
      // user to report a problem in a conversation they are already reading.
      final d = decide(
        const NotifyPolicy(
          sender: alice,
          me: zoe,
          undecryptable: true,
          appInForeground: true,
        ),
      );
      expect(d.post, isFalse);
      expect(d.countsAsUnread, isTrue);
      expect(d.reason, NotifyReason.appInForeground);
    });
  });

  group('a mute and a direct mention', () {
    test('a mention in a muted room breaks the mute', () {
      // The decision this file exists for. Silently dropping a direct mention
      // because the user muted the *conversation* is how a person ends up
      // muting everything, and once they have, no rule here can reach them.
      final d = decide(
        const NotifyPolicy(
          sender: roomAlice,
          me: zoe,
          body: 'zoe: are you there?',
          isGroup: true,
          muted: true,
        ),
      );
      expect(d.post, isTrue);
      expect(d.sound, isTrue);
      expect(d.banner, isTrue);
      expect(d.includePreview, isTrue);
      expect(d.countsAsUnread, isTrue);
      expect(d.reason, NotifyReason.mentionedInMutedConversation);
      expect(mentionsUser(
        const NotifyPolicy(
          sender: roomAlice,
          me: zoe,
          body: 'zoe: are you there?',
          isGroup: true,
        ),
      ), isTrue);
    });

    test('and only that message', () {
      // The mention is not a hole in the mute. The next message in the same
      // muted room, which does not name the user, is silent again.
      const room = NotifyPolicy(
        sender: roomAlice,
        me: zoe,
        isGroup: true,
        muted: true,
      );
      expect(decide(room).reason, NotifyReason.muted);
      expect(
        decide(const NotifyPolicy(
          sender: roomAlice,
          me: zoe,
          body: 'reacted 👍',
          isGroup: true,
          muted: true,
        )).reason,
        NotifyReason.muted,
      );
      expect(
        decide(const NotifyPolicy(
          sender: roomAlice,
          me: zoe,
          body: 'zoe: ping',
          isGroup: true,
          muted: true,
        )).reason,
        NotifyReason.mentionedInMutedConversation,
      );
    });

    test('a mention in a 1:1 does not break the mute', () {
      // There is nobody else in the conversation to address. In a 1:1 the mute
      // *is* the notification setting for that person, and letting any message
      // containing their own name defeat it would make mute un-honourable.
      final d = decide(
        const NotifyPolicy(
          sender: alice,
          me: zoe,
          body: 'zoe, are you there?',
          muted: true,
        ),
      );
      expect(d.reason, NotifyReason.muted);
      expect(d.alerts, isFalse);
    });

    test('an archived room does not come back for a mention', () {
      // Archive and mute are different claims. A mute is about one person's
      // stream; archiving is about a room with dozens of senders the user did
      // not choose and cannot mute one by one. Letting the whole membership
      // break it would turn "archive this room" into a subscription.
      final d = decide(
        const NotifyPolicy(
          sender: roomAlice,
          me: zoe,
          body: 'zoe: are you there?',
          isGroup: true,
          muted: true,
          archived: true,
        ),
      );
      expect(d.reason, NotifyReason.archived);
      expect(d.alerts, isFalse);
    });

    test('a mention in a message we could not read does not break the mute', () {
      // The body here is the one thing that cannot happen: a message we could
      // not open has no body. It is spelled out anyway, because it is the shape
      // of the bug — a stale body left in the row by an earlier decryption
      // attempt must not become a way round a mute, and the check has to be
      // here rather than in the caller.
      final policy = const NotifyPolicy(
        sender: roomAlice,
        me: zoe,
        body: 'zoe: are you there?',
        isGroup: true,
        muted: true,
        undecryptable: true,
      );
      expect(mentionsUser(policy), isFalse);
      expect(decide(policy).reason, NotifyReason.muted);
      expect(decide(policy).alerts, isFalse);
    });

    test('a name inside another word is not a mention', () {
      // Otherwise any word containing a name defeats a mute, and the user has
      // no way to predict when they will be interrupted.
      final policy = const NotifyPolicy(
        sender: roomAlice,
        me: zoe,
        body: 'zoey went home early',
        isGroup: true,
        muted: true,
      );
      expect(mentionsUser(policy), isFalse);
      expect(decide(policy).reason, NotifyReason.muted);
    });

    test('the name still counts at a word boundary', () {
      const names = ['zoe', 'zoe:', 'hey zoe', '@zoe', 'zoe?', '(zoe)'];
      for (final body in names) {
        expect(
          mentionsUser(NotifyPolicy(
            sender: roomAlice,
            me: zoe,
            body: body,
            isGroup: true,
          )),
          isTrue,
          reason: 'should match: $body',
        );
      }
    });

    test('the localpart is the name when there is no nickname', () {
      // Rooms address people by nick, but not always — a bridge or a gateway
      // will use the address. Dropping the localpart would lose those mentions
      // silently, which is the failure this rule exists to prevent.
      expect(
        mentionsUser(const NotifyPolicy(
          sender: roomAlice,
          me: zoeNoNick,
          body: 'zoe: ping',
          isGroup: true,
        )),
        isTrue,
      );
    });

    test('the resource is not part of the name', () {
      // `zoe@example.org/phone` contains `phone`, and a room that mentions a
      // device name is not addressing the user.
      expect(zoeNoNick.localpart, 'zoe');
      expect(
        mentionsUser(const NotifyPolicy(
          sender: roomAlice,
          me: zoeNoNick,
          body: 'phone was talking all night',
          isGroup: true,
        )),
        isFalse,
      );
    });

    test('an identity with no name to match never matches', () {
      // A blank token is a pattern that matches every message, which would make
      // a mute un-honourable for a user whose account carries nothing usable.
      for (final me in const [
        NotifyIdentity(jid: ''),
        NotifyIdentity(jid: '@example.org'),
        NotifyIdentity(jid: 'zoe@example.org', nickname: '   '),
      ]) {
        expect(
          mentionsUser(NotifyPolicy(
            sender: roomAlice,
            me: me,
            body: 'anyone around?',
            isGroup: true,
          )),
          isFalse,
          reason: '$me',
        );
      }
    });
  });

  group('pinned changes nothing', () {
    test('a pinned conversation is not louder', () {
      // Pinning is a statement about where a conversation sits in a list. If it
      // could un-mute, the mute would be something another device could undo.
      final pinned = decide(
        const NotifyPolicy(sender: alice, me: zoe, body: 'hi', pinned: true),
      );
      final plain = decide(const NotifyPolicy(sender: alice, me: zoe, body: 'hi'));
      expectIdentical(pinned, plain, 'pinned vs not');
    });

    test('nor does it un-mute, un-archive or un-block', () {
      for (var bits = 0; bits < 512; bits++) {
        expectIdentical(
          decide(sweep(bits | 4)),
          decide(sweep(bits)),
          'bits $bits',
        );
      }
    });
  });

  group('the defaults', () {
    test('an empty settings object means notify normally', () {
      // The worst bug available to a policy module is one whose default is
      // silence: it looks exactly like working software until somebody tries to
      // receive a message.
      final d = decide(const NotifyPolicy(sender: alice, me: zoe));
      expect(d.post, isTrue);
      expect(d.sound, isTrue);
      expect(d.banner, isTrue);
      expect(d.countsAsUnread, isTrue);
      expect(d.reason, NotifyReason.incoming);
    });

    test('a message with no text still notifies', () {
      // An empty body is an image or a sticker, not a message that failed to
      // arrive. The notification is the only way the user learns it is there.
      final d = decide(const NotifyPolicy(sender: alice, me: zoe));
      expect(d.post, isTrue);
      expect(previewText(const NotifyPolicy(sender: alice, me: zoe)),
          kNoPreviewText);
    });
  });

  group('nothing is decided without saying why', () {
    test('every decision names a rule', () {
      // "No notification appeared" and "the message never arrived" look the
      // same from the outside. A decision with no reason is a silence nobody can
      // investigate, and it gets filed as a delivery bug.
      for (final policy in everyInput()) {
        final d = decide(policy);
        expect(d.reason, isNotEmpty, reason: '$policy');
        expect(reasons, contains(d.reason), reason: '$policy → ${d.reason}');
      }
    });

    test('nothing is announced without being posted', () {
      for (final policy in everyInput()) {
        final d = decide(policy);
        if (d.post) continue;
        expect(d.sound, isFalse, reason: '$policy');
        expect(d.banner, isFalse, reason: '$policy');
        expect(d.includePreview, isFalse, reason: '$policy');
      }
    });

    test('a preview is only ever offered for a message we could read', () {
      for (final policy in everyInput()) {
        if (!decide(policy).includePreview) continue;
        expect(policy.undecryptable, isFalse, reason: '$policy');
        expect(policy.blocked, isFalse, reason: '$policy');
        expect(policy.carbon, isFalse, reason: '$policy');
      }
    });

    test('the badge agrees with the reasons that suppress it', () {
      // These five are exactly the early returns in `_acceptInbound`, so the
      // badge cannot end up disagreeing with the buzz about one message. The
      // one the counter does not have is the mention: a mention notifies, so it
      // counts, and a conversation that buzzes while showing no badge reads as
      // read.
      const neverCounts = {
        NotifyReason.blocked,
        NotifyReason.carbon,
        NotifyReason.readingThisConversation,
        NotifyReason.archived,
        NotifyReason.muted,
      };
      for (final policy in everyInput()) {
        final d = decide(policy);
        expect(d.countsAsUnread, neverCounts.contains(d.reason) ? isFalse : isTrue,
            reason: '${d.reason} for $policy');
      }
    });
  });

  group('what the notification is allowed to say', () {
    test('an undecryptable message is announced and not described', () {
      expect(
        previewText(const NotifyPolicy(sender: alice, me: zoe,
            undecryptable: true)),
        kNoPreviewText,
      );
    });

    test('and the store placeholder never reaches a lock screen', () {
      // "Unable to decrypt" is a description of *our* failure, not of their
      // message. The store already keeps it out of search so nobody goes
      // looking for words nobody wrote; a notification is the same disclosure
      // with a worse audience.
      final text = previewText(
        const NotifyPolicy(sender: alice, me: zoe, undecryptable: true),
      );
      expect(text.toLowerCase(), isNot(contains('decrypt')));
      expect(text.toLowerCase(), isNot(contains('unable')));
    });

    test('and no part of the stored body either', () {
      // The body of an undecryptable message is empty. A rule phrased as "show
      // the body, and the empty string when there is none" starts leaking the
      // day a failed decryption leaves stale text in the row.
      final text = previewText(
        const NotifyPolicy(
          sender: alice,
          me: zoe,
          body: 'the bank account is 1234',
          undecryptable: true,
        ),
      );
      expect(text, kNoPreviewText);
      expect(text, isNot(contains('1234')));
    });

    test('a blocked sender has no preview at all', () {
      // Defensive only — the decision posts nothing — but the text is what ends
      // up in front of whoever is holding the phone, so it must be safe for a
      // caller that ignored the decision.
      final text = previewText(
        const NotifyPolicy(
          sender: alice,
          me: zoe,
          body: 'are you still there?',
          blocked: true,
        ),
      );
      expect(text, kNoPreviewText);
      expect(text, isNot(contains('still there')));
    });

    test('a carbon is not echoed back at the user', () {
      final text = previewText(
        const NotifyPolicy(
          sender: zoe,
          me: zoe,
          body: 'sent from my laptop',
          carbon: true,
        ),
      );
      expect(text, kNoPreviewText);
      expect(text, isNot(contains('laptop')));
    });

    test('a group names the sender', () {
      // "see you at 8" is a different message depending on who said it, and a
      // preview without the name makes the user open the app to find out.
      expect(
        previewText(const NotifyPolicy(
          sender: roomAlice,
          me: zoe,
          body: 'see you at 8',
          isGroup: true,
        )),
        'alice: see you at 8',
      );
    });

    test('a group member with no nickname is still named', () {
      expect(
        previewText(const NotifyPolicy(
          sender: NotifyIdentity(jid: 'bob@conference.example.org/x'),
          me: zoe,
          body: 'yes',
          isGroup: true,
        )),
        'bob: yes',
      );
      expect(
        const NotifyIdentity(jid: 'zoe@example.org/phone', nickname: '  ')
            .label,
        'zoe',
      );
    });

    test('a 1:1 prefixes nothing', () {
      // The title of the notification is already the person. Repeating it in the
      // body wastes the one line that is supposed to be the message.
      expect(
        previewText(
          const NotifyPolicy(sender: alice, me: zoe, body: 'see you at 8'),
        ),
        'see you at 8',
      );
    });

    test('whitespace is collapsed onto one line', () {
      expect(
        previewText(const NotifyPolicy(
          sender: alice,
          me: zoe,
          body: 'line one\n\n   line two\t',
        )),
        'line one line two',
      );
    });

    test('a long message is cut, sender prefix included', () {
      final text = previewText(NotifyPolicy(
        sender: roomAlice,
        me: zoe,
        body: 'x' * 200,
        isGroup: true,
      ));
      expect(text.length, lessThanOrEqualTo(kMaxPreviewLength));
      expect(text, endsWith('…'));
      expect(text, startsWith('alice: '));
    });

    test('and a short one is not cut', () {
      final text = previewText(
        const NotifyPolicy(sender: alice, me: zoe, body: 'ok'),
      );
      expect(text, 'ok');
    });

    test('no input produces an empty line', () {
      // A notification with no body reads as a failure to arrive, which is the
      // exact confusion the constant exists to prevent.
      for (final policy in everyInput()) {
        expect(previewText(policy), isNotEmpty, reason: '$policy');
      }
    });
  });

  group('what a mechanism is handed', () {
    test('a request exists exactly when something should be posted', () {
      for (final policy in everyInput()) {
        final r = notificationFor(policy, chatJid: 'room@conf.example.org');
        expect(
          r != null,
          decide(policy).post,
          reason: '${decide(policy).reason} for $policy',
        );
      }
    });

    test('and it carries the text the decision allowed', () {
      // One sweep, because the failure this prevents is a mechanism that posts
      // the body of a message it was told not to describe: the flags and the
      // line have to come from the same decision.
      for (final policy in everyInput()) {
        final r = notificationFor(policy, chatJid: 'room@conf.example.org');
        if (r == null) continue;
        final d = r.decision;
        expect(
          r.preview,
          d.includePreview ? previewText(policy) : null,
          reason: '${d.reason} for $policy',
        );
      }
    });

    test('an undecryptable message reaches it with no text at all', () {
      final r = notificationFor(
        const NotifyPolicy(
          sender: roomAlice,
          me: zoe,
          body: 'the bank account is 1234',
          isGroup: true,
          undecryptable: true,
        ),
        chatJid: 'room@conf.example.org',
      );
      expect(r, isNotNull);
      expect(r!.preview, isNull);
      expect(r.decision.post, isTrue);
      expect(r.decision.reason, NotifyReason.undecryptable);
    });

    test('it says which conversation and whose it is', () {
      final r = notificationFor(
        const NotifyPolicy(
          sender: roomAlice,
          me: zoe,
          body: 'see you at 8',
          isGroup: true,
        ),
        chatJid: 'room@conf.example.org',
      );
      expect(r!.chatJid, 'room@conf.example.org');
      expect(r.sender.label, 'alice');
      expect(r.preview, 'alice: see you at 8');
    });

    test('and a silence produces nothing to post at all', () {
      expect(
        notificationFor(
          const NotifyPolicy(sender: alice, me: zoe, blocked: true),
          chatJid: 'alice@example.org',
        ),
        isNull,
      );
    });
  });
}