// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Local nicknames.
//
// Every value below is either typed by a person or pasted by one, and the
// failures they protect against are all the same shape: something that looks
// correct on screen and is not correct in the string. A name ending in a
// zero-width space, a nickname a build we do not recognise wrote, and an
// avatar drawn from a family emoji are one bug each, and none of them announces
// itself.
//
// Two rules the rest of the file is measured against: what the app draws has to
// be what the user typed, and a value this build cannot read may cost a
// nickname but must never cost a conversation.

import 'package:test/test.dart';

import 'package:resonchat/xmpp/roster/local_nickname.dart';

void main() {
  group('what a nickname may be', () {
    test('an ordinary name is one', () {
      final nick = LocalNickname.tryParse('Alex Chen');
      expect(nick, isNotNull);
      expect(nick!.value, 'Alex Chen');
    });

    test('padding is trimmed, not refused', () {
      // Refusing " Alex " would leave the user staring at a name they can
      // plainly see, hunting for why it was rejected.
      expect(LocalNickname.tryParse('  Alex Chen  ')?.value, 'Alex Chen');
      // And the space inside it is kept: trimming the ends is not a licence to
      // rewrite the middle.
      expect(LocalNickname.tryParse(' Alex Chen ')?.value, 'Alex Chen');
      // What trimming is not is a way of losing the characters the rules
      // refuse, and `trim()` is eager: it takes the tab, the next-line control
      // and the byte order mark along with the spaces. So these are refused with
      // the character still in them — checked before the padding comes off,
      // which is the only order in which "Bob\t" is not quietly "Bob".
      expect(LocalNickname.tryParse('  Alex Chen \n'), isNull);
      expect(LocalNickname.tryParse('  Alex Chen\t'), isNull);
      expect(LocalNickname.tryParse('Bob \u00A0 ')?.value, 'Bob');
    });

    test('a name that is only whitespace is not a name', () {
      // It would be a chat row with a blank title, which reads as a row that
      // failed to load rather than as a name.
      for (final blank in const [
        ' ',
        '     ',
        '\t',
        '\n\n',
        ' \t \n ',
        '\u00A0',
        '\u3000\u3000',
        '\u2000\u2001',
      ]) {
        expect(LocalNickname.tryParse(blank), isNull, reason: 'blank=$blank');
      }
    });

    test('a zero-width character is refused, not stripped', () {
      // "Bob" and "Bob" with a zero-width space are two strings that look
      // identical and collide silently, in the chat list and in a mention.
      for (final hidden in const [
        'Bo\u200Bb',
        'Bob\u200B',
        '\u200B',
        'A\u00ADB', // soft hyphen
        '\uFEFFAlex', // byte order mark, which arrives with a paste
        'Alex\u2060', // word joiner
        'Alex\u200E', // left-to-right mark
      ]) {
        expect(
          LocalNickname.tryParse(hidden),
          isNull,
          reason: 'hidden="$hidden"',
        );
      }
      // The same name without the invisible character is fine, so the rule
      // above cannot pass by refusing everything.
      expect(LocalNickname.tryParse('Bob')?.value, 'Bob');
    });

    test('a bidi control is refused', () {
      // The sharper version of the same problem: an override does not merely
      // add an invisible character, it renders the rest of the string in the
      // other order. A chat row showing one person's name can be made to show
      // somebody else's.
      expect(LocalNickname.tryParse('Bob\u202Egav'), isNull);
      expect(LocalNickname.tryParse('Bob\u202E\u202C'), isNull);
      expect(LocalNickname.tryParse('bo\u2066\u2069b'), isNull);
    });

    test('a control character is refused', () {
      for (final raw in const [
        'Bo\nb',
        'Bob\t',
        'A\u0000B',
        'Bob\u007F',
        'Bob\u0085',
        'Bob\u009F',
        // At the front, where trimming used to launder it: `trim()` takes a
        // leading tab and a leading next-line control with the padding, so this
        // is the position the blacklist was never actually reached in.
        '\tBob',
        '\nBob',
        '\u0085Bob',
      ]) {
        expect(LocalNickname.tryParse(raw), isNull, reason: 'raw=$raw');
      }
    });

    test('a lone surrogate is refused but an emoji is not', () {
      // A lone surrogate is what a bad decode leaves behind and it draws a
      // replacement box. A whole emoji above the surrogate range is a name
      // somebody chose on purpose, so refusing it would be refusing the name.
      expect(LocalNickname.tryParse('\uD800'), isNull);
      expect(LocalNickname.tryParse('Bob\uDFFF'), isNull);
      expect(LocalNickname.tryParse('\u{1F600}')?.value, '\u{1F600}');
    });

    test('over length is refused rather than truncated', () {
      final atLimit = LocalNickname.tryParse('a' * LocalNickname.maxRunes);
      expect(atLimit, isNotNull);
      expect(atLimit!.value.length, LocalNickname.maxRunes);
      expect(
        LocalNickname.tryParse('a' * (LocalNickname.maxRunes + 1)),
        isNull,
      );
      // Refused outright, not shortened: a truncated name is one the user never
      // typed, and it can be cut in the middle of a word or of a character the
      // display needs a second code unit for.
      expect(LocalNickname.tryParse('a' * 500), isNull);
    });

    test('the cap counts characters, not UTF-16 units', () {
      // One emoji is two units and a flag is four, so a cap measured in units
      // would refuse a name the user reads as 64 characters.
      final emoji = LocalNickname.tryParse(
        '\u{1F389}' * LocalNickname.maxRunes,
      );
      expect(emoji, isNotNull);
      expect(emoji!.value.length, 2 * LocalNickname.maxRunes);
      expect(emoji.value.runes.length, LocalNickname.maxRunes);
      expect(
        LocalNickname.tryParse('\u{1F389}' * (LocalNickname.maxRunes + 1)),
        isNull,
      );
    });

    test('a name made only of invisible characters is refused', () {
      // The blacklist above is the wrong shape on its own: it is only as good
      // as the next character somebody invents. So a name also has to contain
      // something that draws.
      expect(LocalNickname.tryParse('\u200D'), isNull);
      expect(LocalNickname.tryParse('\uFE0F'), isNull);
      expect(LocalNickname.tryParse('\u200B\u200B'), isNull);
      expect(LocalNickname.tryParse('\u200D\uFE0F\u200D'), isNull);
    });

    test('one emoji written as several code points is one name', () {
      // The joiners draw nothing, but they are how a single emoji is written,
      // and refusing them would refuse the emoji. What keeps a name made only
      // of them out is the rule above.
      expect(
        LocalNickname.tryParse('\u{1F468}\u200D\u{1F469}\u200D\u{1F467}'),
        isNotNull,
      );
      expect(LocalNickname.tryParse('\u{1F44D}\u{1F3FD}'), isNotNull);
    });

    test('two parses of one name are one value', () {
      final a = LocalNickname.tryParse('Bob');
      final b = LocalNickname.tryParse('  Bob  ');
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a.toString(), 'Bob');
    });

    test('null is not a nickname', () {
      expect(LocalNickname.tryParse(null), isNull);
    });
  });

  group('the stored form', () {
    test('round trips', () {
      for (final raw in const ['Bob', '张 三', 'Alex Chen', '🎉 party']) {
        final nick = LocalNickname.tryParse(raw)!;
        expect(LocalNickname.decode(nick.encode()), nick, reason: raw);
      }
    });

    test('is the version byte and then the name', () {
      // One byte, and it is what makes a stored name distinguishable from a
      // name that was never set: a build that tightens the rules cannot migrate
      // values it has already made illegal if nothing says which form they
      // were written in.
      final encoded = LocalNickname.tryParse('Bob')!.encode();
      expect(encoded, '1Bob');
      expect(encoded.length, 4);
    });

    test('null gives no nickname', () {
      expect(LocalNickname.decode(null), isNull);
    });

    test('empty gives no nickname', () {
      // A conversation the user has never named is the ordinary state, and it
      // has to be distinguishable from one they named badly.
      expect(LocalNickname.decode(''), isNull);
    });

    test('garbage never throws', () {
      // The point of this list is that nothing in it can reach a throw: it comes
      // out of a column somebody else wrote. What it decodes to is a separate
      // question, and the answer here is mostly "nothing" — no version byte, no
      // nickname under the byte, over the cap, or a name the rules refuse.
      // Unreadable is the documented answer to all four: a value this build
      // cannot read costs a nickname and not a conversation.
      final rubbish = <String>[
        '',
        '1',
        '0',
        '99',
        'x',
        'é',
        '\u{1F600}',
        '11',
        '  1Bob  ',
        '1Bo\u200Bb',
        '1\uD800',
        '1\u0000',
        '1' * 100,
        '1${'a' * 500}',
        '1\u2028Bob', // a paste that carried a line separator
      ];
      // Readable: a version byte and a name. The second is the paste — a line
      // separator draws nothing but is not a character the rules refuse, so it
      // is padding and comes off like a space.
      const readable = <String>{'11', '1\u2028Bob'};
      for (final raw in rubbish) {
        expect(() => LocalNickname.decode(raw), returnsNormally, reason: raw);
        expect(
          LocalNickname.decode(raw),
          readable.contains(raw) ? isNotNull : isNull,
          reason: raw,
        );
      }
      expect(LocalNickname.decode('11')?.value, '1');
      expect(LocalNickname.decode('1\u2028Bob')?.value, 'Bob');
    });

    test('a form we do not know is not guessed at', () {
      // A later build may store more than a name. Interpreting its bytes as
      // text puts something in the chat list that is not anybody's name, and
      // the fallback — the other party's own name — is true and readable.
      expect(LocalNickname.decode('2Bob'), isNull);
      expect(LocalNickname.decode('0Bob'), isNull);
      expect(LocalNickname.decode('zBob'), isNull);
    });

    test('a name with no version byte is not read as text', () {
      // Every row that exists was written by a build that knew the format, so
      // a bare string is a value from somewhere else. It is also ambiguous with
      // a version byte: "404 Gang" is either the name or version 4 followed by
      // "04 Gang".
      expect(LocalNickname.decode('Bob'), isNull);
      expect(LocalNickname.decode('404 Gang'), isNull);
      expect(LocalNickname.decode('张'), isNull);
    });

    test('the rules still apply to a stored value', () {
      // Going through the database is not a way around them.
      expect(LocalNickname.decode('1Bo\u200Bb'), isNull);
      expect(LocalNickname.decode('1   Bob'), isNotNull);
      expect(LocalNickname.decode('1${'a' * 500}'), isNull);
    });

    test('a name at the length limit survives the byte', () {
      final long = LocalNickname.tryParse('a' * LocalNickname.maxRunes)!;
      expect(
        LocalNickname.decode(long.encode())?.value.length,
        LocalNickname.maxRunes,
      );
    });
  });

  group('which name a conversation is drawn with', () {
    test('the stored column is drawn without its version byte', () {
      // The column holds the version byte in front of the name. Drawing that
      // string as text would rename Bobby to 1Bobby.
      final stored = LocalNickname.tryParse('Bobby')!.encode();
      expect(
        conversationDisplayName(
          storedLocalNickname: stored,
          title: 'Alex Chen',
          jid: 'alex@x.example',
          isRoom: false,
        ),
        'Bobby',
      );
    });

    test(
      'a value this build cannot read falls through to the roster title',
      () {
        expect(
          conversationDisplayName(
            storedLocalNickname: '404 Gang',
            title: 'Alex Chen',
            jid: 'alex@x.example',
            isRoom: false,
          ),
          'Alex Chen',
        );
      },
    );

    test('a room the user named is drawn from the stored column', () {
      final stored = LocalNickname.tryParse('The Team')!.encode();
      expect(
        conversationDisplayName(
          storedLocalNickname: stored,
          title: 'Bob',
          roomTitle: 'Engineering',
          jid: 'team@muc.example.org',
          isRoom: true,
        ),
        'The Team',
      );
    });

    test('a details heading keeps the original name visible', () {
      // Gajim's contact-information name row. The list itself stays "Bobby".
      expect(displayNameHeading('Bobby', 'Alex Chen'), 'Bobby (Alex Chen)');
      expect(displayNameHeading('Alex Chen', 'Alex Chen'), 'Alex Chen');
      expect(displayNameHeading('Bobby', '   '), 'Bobby');
    });

    test('a local nickname outranks the roster title and the address', () {
      // A roster title is a name the other party chose and can change at any
      // moment without warning. A user who named somebody locally has said
      // which name they want.
      expect(
        displayName(
          localNickname: 'Bobby',
          rosterTitle: 'Alex Chen',
          jid: 'alex@x.example',
          isRoom: false,
        ),
        'Bobby',
      );
    });

    test('without one, the roster title is used', () {
      expect(
        displayName(
          localNickname: null,
          rosterTitle: 'Alex Chen',
          jid: 'alex@x.example',
          isRoom: false,
        ),
        'Alex Chen',
      );
    });

    test('with neither, the address is used', () {
      expect(
        displayName(
          localNickname: null,
          rosterTitle: '',
          jid: 'alex@x.example',
          isRoom: false,
        ),
        'alex@x.example',
      );
    });

    test('a roster title that is the address again is harmless', () {
      // This is what upsertChat writes for a contact with no roster name.
      expect(
        displayName(
          localNickname: null,
          rosterTitle: 'alex@x.example',
          jid: 'alex@x.example',
          isRoom: false,
        ),
        'alex@x.example',
      );
    });

    test('a roster title of nothing but whitespace falls through', () {
      expect(
        displayName(
          localNickname: null,
          rosterTitle: '   ',
          jid: 'alex@x.example',
          isRoom: false,
        ),
        'alex@x.example',
      );
    });

    test('an unusable local nickname falls through rather than winning', () {
      // A name the user could see in the field must not turn the row blank, and
      // a name this build would refuse must not be the one thing that gets past
      // the rule.
      for (final unusable in const ['', '   ', '\u200B', 'Bo\u200Bb']) {
        expect(
          displayName(
            localNickname: unusable,
            rosterTitle: 'Alex Chen',
            jid: 'alex@x.example',
            isRoom: false,
          ),
          'Alex Chen',
          reason: 'unusable="$unusable"',
        );
      }
    });

    test('a roster title is trimmed before it is drawn', () {
      expect(
        displayName(
          localNickname: null,
          rosterTitle: '  Alex Chen\t',
          jid: 'alex@x.example',
          isRoom: false,
        ),
        'Alex Chen',
      );
    });

    test('the answer is never an empty string', () {
      // A blank title in a chat row reads as a row that failed to load.
      expect(
        displayName(
          localNickname: null,
          rosterTitle: '',
          jid: '',
          isRoom: false,
        ),
        unknownName,
      );
    });
  });

  group('a room is not a person', () {
    test('a room never takes an occupant name as its title', () {
      // "Bob" is a correct answer to "who is this person" and a catastrophically
      // wrong answer to "what is this conversation called". The two questions
      // share this function because the chat list draws both, and a bug here
      // renames a room.
      expect(
        displayName(
          localNickname: null,
          rosterTitle: 'Bob',
          jid: 'team@muc.example.org',
          isRoom: true,
        ),
        'team@muc.example.org',
      );
    });

    test('a room uses its bookmark/disco name, not a roster occupant', () {
      expect(
        displayName(
          localNickname: null,
          rosterTitle: 'Bob',
          roomTitle: 'Engineering',
          jid: 'team@muc.example.org',
          isRoom: true,
        ),
        'Engineering',
      );
    });

    test('a room the user has named locally takes that name', () {
      expect(
        displayName(
          localNickname: 'The Team',
          rosterTitle: 'Bob',
          roomTitle: 'Engineering',
          jid: 'team@muc.example.org',
          isRoom: true,
        ),
        'The Team',
      );
    });

    test('the same address is a person or a room depending on one flag', () {
      final asPerson = displayName(
        localNickname: null,
        rosterTitle: 'Bob',
        jid: 'team@muc.example.org',
        isRoom: false,
      );
      final asRoom = displayName(
        localNickname: null,
        rosterTitle: 'Bob',
        jid: 'team@muc.example.org',
        isRoom: true,
      );
      expect(asPerson, 'Bob');
      expect(asRoom, 'team@muc.example.org');
    });

    test('a room shows its whole address, not the slug', () {
      // `team` on two servers is two rooms, and the domain is the only part of
      // the address that tells them apart.
      expect(
        displayName(
          localNickname: null,
          rosterTitle: '',
          jid: 'team@a.example',
          isRoom: true,
        ),
        isNot(
          displayName(
            localNickname: null,
            rosterTitle: '',
            jid: 'team@b.example',
            isRoom: true,
          ),
        ),
      );
    });

    test('a room with no address at all is still named something', () {
      expect(
        displayName(
          localNickname: null,
          rosterTitle: 'Bob',
          jid: '   ',
          isRoom: true,
        ),
        unknownName,
      );
    });
  });

  group('mentioning an occupant', () {
    test('the mention is the room nick, never the local name', () {
      // A local nickname is not sent to anybody. A message containing it says
      // nothing to the rest of the room: they see a name nobody calls them and
      // their client highlights nothing.
      final mention = mentionFor(
        nick: 'bob',
        localNickname: 'Bobby',
        occupants: const ['carol'],
      );
      expect(mention, isNotNull);
      expect(mention!.text, '@bob');
    });

    test('a mention is the whole nick behind an @', () {
      expect(mentionFor(nick: 'Bob', occupants: const ['carol'])!.text, '@Bob');
      expect(
        mentionFor(nick: 'Bob Smith', occupants: const ['Bob Smith'])!.text,
        '@Bob Smith',
      );
    });

    test('a nick nothing else in the room shares is unambiguous', () {
      final mention = mentionFor(
        nick: 'bob',
        occupants: const ['bob', 'carol', 'bobby', 'b0b'],
      );
      expect(mention!.ambiguous, isFalse);
      expect(mention.collidesWith, isEmpty);
    });

    test('two occupants with one name are reported, not picked between', () {
      // A room cannot be made unambiguous from here: the nick is what the
      // server and every other client already use.
      final mention = mentionFor(
        nick: 'bob',
        occupants: const ['bob', 'Bob', 'carol'],
      );
      expect(mention!.ambiguous, isTrue);
      expect(mention.collidesWith, const ['Bob']);
      // The text is still the nick — the caller is told, not corrected.
      expect(mention.text, '@bob');
    });

    test('a name that differs only in case is a collision', () {
      // Which clients match a mention case-insensitively is not ours to decide,
      // so a client that folds case highlights two people and one that does not
      // highlights one. Reporting nothing would be a claim about other clients
      // we cannot make.
      expect(
        mentionFor(nick: 'bob', occupants: const ['BOB'])!.collidesWith,
        const ['BOB'],
      );
    });

    test('a name that is only padding around one nick is a collision', () {
      expect(
        mentionFor(nick: 'bob', occupants: const ['  Bob  '])!.collidesWith,
        const ['Bob'],
      );
    });

    test('one occupant listed twice is one occupant', () {
      // The number is shown to the user, so "2 people" has to mean two people.
      final twice = mentionFor(nick: 'bob', occupants: const ['bob', 'bob']);
      expect(twice!.ambiguous, isFalse);
      final mixed = mentionFor(
        nick: 'bob',
        occupants: const ['bob', 'BOB', 'bob'],
      );
      expect(mixed!.collidesWith, const ['BOB']);
    });

    test('a name another occupant merely starts with is not a collision', () {
      // Clients match the whole nick, so `@bob` does not address `bobby`.
      expect(
        mentionFor(nick: 'bob', occupants: const ['bobby', 'bob '])!.ambiguous,
        isFalse,
      );
    });

    test('an occupant with no nick cannot be addressed', () {
      expect(mentionFor(nick: '', occupants: const ['bob']), isNull);
      expect(mentionFor(nick: '   ', occupants: const ['bob']), isNull);
    });

    test('a nick that cannot be drawn is not mentioned', () {
      // Inserting an override into somebody's message makes their own name
      // render as somebody else's text.
      expect(mentionFor(nick: 'bo\u202Eb', occupants: const []), isNull);
      expect(mentionFor(nick: 'bo\u200Bb', occupants: const []), isNull);
    });

    test('a room with one occupant has no collisions', () {
      expect(mentionFor(nick: 'bob', occupants: const [])!.ambiguous, isFalse);
    });
  });

  group('the first letter in the circle', () {
    test('uses the name, not the address', () {
      expect(firstInitial('Alex Chen', 'alex@x.example'), 'A');
      expect(firstInitial('张三', 'zhangsan@x.example'), '张');
    });

    test('falls back to the address when there is no name', () {
      expect(firstInitial('', 'bob@x.example'), 'B');
      expect(firstInitial('   ', 'bob@x.example'), 'B');
    });

    test('skips a leading digit or symbol', () {
      // "404" should not become a circle with a 4 on it.
      expect(firstInitial('404 Not Found', 'x@y.example'), 'N');
      expect(firstInitial('3.14 Pi', 'x@y.example'), 'P');
      expect(firstInitial('  @alex', 'x@y.example'), 'A');
      expect(firstInitial('÷ ÷ ÷ bob', 'x@y.example'), 'B');
    });

    test('a CJK name is one rune, not a lone surrogate', () {
      // `substring(0, 1)` on a CJK character returns half of a surrogate pair,
      // which draws a replacement box. Reading the rune does not.
      final initial = firstInitial('张三', 'x@y.example');
      expect(initial, '张');
      expect(initial.runes.length, 1);
      expect(initial.length, 1);
    });

    test('a character outside the BMP is still one rune', () {
      // Two UTF-16 units, one rune: the case a unit-based reader gets wrong in
      // the other direction, by cutting a surrogate pair in half.
      final initial = firstInitial('𠮷天下', 'x@y.example');
      expect(initial, '𠮷');
      expect(initial.runes.length, 1);
      expect(initial.length, 2);
    });

    test('an astral-plane ideograph is the initial', () {
      // U+20BB7 is a CJK ideograph in extension B: a letter, on a plane the old
      // table of ranges could not even name. Read as a non-letter it was skipped,
      // and the scan walked on to the next character in the name.
      const ideograph = '\u{20BB7}';
      final alone = firstInitial(ideograph, 'x@y.example');
      expect(alone, ideograph);
      expect(alone.runes.length, 1);
      expect(alone.length, 2);
      // Stopping on it rather than past it is the part that was broken.
      expect(firstInitial('$ideograph天下', 'x@y.example'), ideograph);
      // And a name that starts elsewhere still starts there.
      expect(firstInitial('天$ideograph', 'x@y.example'), '天');
      // It is upper case already, so what comes back is the character and not
      // some other member of its block.
      expect(firstInitial(ideograph, ''), ideograph);
    });

    test('a letter is a category, so the fix is not CJK-specific', () {
      // U+1D400 is MATHEMATICAL BOLD CAPITAL A — a supplementary-plane letter
      // in a block with nothing to do with ideographs, and one no hand-written
      // script list would ever have contained. Anything Unicode has added since
      // this file was written is in here for the same reason.
      const boldA = '\u{1D400}';
      final initial = firstInitial('$boldA team', 'x@y.example');
      expect(initial, boldA);
      expect(initial.runes.length, 1);
      expect(initial.length, 2);
      // Skipped over on the way, like any other non-letter.
      expect(firstInitial('404 $boldA team', 'x@y.example'), boldA);
      // And a supplementary-plane *digit* is not a letter either: U+1D7F8 is
      // MATHEMATICAL BOLD DIGIT ZERO, the same "inside a block that reads as
      // letters" problem the old table had holes cut in it for.
      expect(firstInitial('\u{1D7F8} Bob', 'x@y.example'), 'B');
    });

    test('a name with nothing visible in it is a question mark', () {
      // Taken literally, one of these yields one of its own characters, and
      // the circle comes out blank — a placeholder that looks like a spinner.
      for (final invisible in const [
        '\u200B',
        '\u200D',
        '\u2060',
        '\uFE0F',
        '\u00AD',
      ]) {
        expect(
          firstInitial(invisible, ''),
          unknownName,
          reason: 'invisible="$invisible"',
        );
      }
    });

    test('a name of only invisible characters is still a question mark', () {
      // Asking the Unicode tables what a character *is* says nothing about
      // whether it draws anything, so the zero-width blacklist and the "a name
      // has to contain something that draws" companion rule have to keep doing
      // that job on their own. These are the characters that get through a
      // category test and still must not become the glyph in the circle —
      // including two that live outside the BMP, which a BMP-shaped fix would
      // have missed.
      for (final invisible in const [
        '\u200D\uFE0F\u200D',
        '\u{E0020}\u{E007F}', // tag characters
        '\u{10FFFD}', // a supplementary-plane private use character
        '\u200B\u2060\uFEFF',
      ]) {
        expect(
          firstInitial(invisible, ''),
          unknownName,
          reason: 'invisible="$invisible"',
        );
      }
      // One invisible character in front of something that draws is still the
      // thing that draws: the fallback skips invisibles too, not just the
      // letter pass.
      expect(firstInitial('\u200D\u{1F600}', 'x@y.example'), '\u{1F600}');
    });

    test('nothing at all is a question mark, not a crash', () {
      expect(firstInitial('', ''), unknownName);
      expect(firstInitial('   ', '  '), unknownName);
    });

    test('a name of only emoji draws one', () {
      expect(firstInitial('\u{1F600}', 'x@y.example'), '\u{1F600}');
      expect(firstInitial('\u{1F600}\u{1F389}', 'x@y.example'), '\u{1F600}');
      // A letter anywhere in the name still wins over the emoji: the emoji is
      // not a letter, and "🎉 party" is about the party.
      expect(firstInitial('\u{1F389} party', 'x@y.example'), 'P');
    });

    test('invisible characters are skipped before the emoji fallback', () {
      // There is no letter in this name, so the fallback is what runs — and a
      // reader that does not skip invisibles here draws the invisible character
      // instead of the emoji.
      expect(firstInitial('\u200B\u{1F600}', 'x@y.example'), '\u{1F600}');
      expect(firstInitial('\u200B\x1b Bob', 'x@y.example'), 'B');
    });

    test('an emoji sequence comes back whole', () {
      // The first code point of a family is the man, and half of a flag is a
      // letter in a box; both are a different picture rather than a smaller
      // version of the right one.
      const family = '\u{1F468}\u200D\u{1F469}\u200D\u{1F467}\u200D\u{1F466}';
      expect(firstInitial(family, 'x@y.example'), family);
      // An emoji sequence followed by words yields the *letter*, not the
      // sequence. `firstInitial` looks for a letter before it looks for anything
      // else, so a sequence is only what gets drawn when there is no letter at
      // all — which is the assertion above. This one used to expect the family
      // here, which would have made "which glyph is the initial" depend on what
      // happens to follow the picture rather than on what the picture is.
      expect(firstInitial('$family club', 'x@y.example'), 'C');
      const hand = '\u{1F44D}\u{1F3FD}';
      expect(firstInitial(hand, 'x@y.example'), hand);
      const flag = '\u{1F1EF}\u{1F1F5}';
      expect(firstInitial(flag, 'x@y.example'), flag);
    });

    test('a ZWJ sequence that starts with a letter comes back whole', () {
      // Not only emoji: Devanagari joins a letter to a letter with a ZWJ to form
      // a conjunct, so the first letter of the name may be several letters. क्ष
      // is three code points and one glyph; its first rune on its own is not a
      // thing anybody writes, and drawing it would be the same bug as drawing
      // the man of a family instead of the family.
      const conjunct = '\u0915\u200D\u0937';
      final initial = firstInitial(conjunct, 'x@y.example');
      expect(initial, conjunct);
      expect(initial.runes.length, 3);
      // And the sequence ends where the word does.
      expect(firstInitial('$conjunct कमल', 'x@y.example'), conjunct);
      expect(firstInitial('कमल $conjunct', 'x@y.example'), 'क');
    });

    test('the scan skips exactly what validation refuses', () {
      // Two questions, two places, and neither answer may stand in for the
      // other. Validation asks whether this can be a nickname at all, and a
      // zero-width space at the front is a refusal whatever follows it. The scan
      // asks what goes in the circle, and it walks past the same character,
      // because a glyph has to draw. So this name is refused as a nickname, and
      // the circle would still come out right if it reached one from somewhere
      // the rules do not reach — which is the reason the refusal matters and
      // not the reason the scan skips.
      expect(LocalNickname.tryParse('\u200BBob'), isNull);
      expect(firstInitial('\u200BBob', 'x@y.example'), 'B');
      // The control-character half of the same split, including a bell at the
      // front: refused outright, skipped by the scan, never the glyph.
      expect(LocalNickname.tryParse('\u0007Bob'), isNull);
      expect(firstInitial('\u0007Bob', 'x@y.example'), 'B');
      // And a name that is *only* one of them is refused too — the scan has
      // nothing to draw and the validator has nothing to store.
      expect(LocalNickname.tryParse('\u200B'), isNull);
      expect(firstInitial('\u200B', ''), unknownName);

      // The same two-place split for a grapheme. A ZWJ sequence is one glyph, so
      // it comes back whole when it is what the circle draws, and it is a legal
      // nickname in its own right.
      const family = '\u{1F468}\u200D\u{1F469}\u200D\u{1F467}';
      expect(firstInitial(family, 'x@y.example'), family);
      expect(LocalNickname.tryParse(family), isNotNull);
      // A letter in the name is still a letter, so the scan keeps going and
      // draws the letter. The sequence is not a prefix that swallows what comes
      // after it — it ends where the word does, which is the same rule that
      // makes '🎉 party' come out as 'P'.
      expect(firstInitial('$family club', 'x@y.example'), 'C');
      // A joiner with nothing after it does not start a second sequence: this is
      // one glyph, and the letter after the joiner is the next thing in the name
      // rather than part of the picture.
      expect(firstInitial('\u{1F44D}\u200D', 'x@y.example'), '\u{1F44D}');
      expect(firstInitial('\u{1F44D}\u200Dx', 'x@y.example'), 'X');
    });

    test('a letter after an emoji is not swallowed by it', () {
      expect(firstInitial('\u{1F600} Bob', 'x@y.example'), 'B');
      // The letter wins, with no space to justify it. This asserted the emoji
      // instead, which contradicted both the test's own name and the sibling
      // case below — an emoji swallowing the letter is precisely what the name
      // says must not happen.
      expect(firstInitial('\u{1F600}x', 'x@y.example'), 'X');
    });

    test('a letter after an emoji is the initial on any plane', () {
      // The same rule as the case above, where the letter it walks to is outside
      // the BMP: the emoji is not a letter, the letter wins, and the scan has to
      // be able to see that the letter is there at all.
      expect(firstInitial('\u{1F600}\u{20BB7}', 'x@y.example'), '\u{20BB7}');
      expect(
        firstInitial('\u{1F389} \u{1D400} club', 'x@y.example'),
        '\u{1D400}',
      );
      // An invisible one between them is skipped rather than preferred.
      expect(
        firstInitial('\u{1F600}\u200B\u{20BB7}', 'x@y.example'),
        '\u{20BB7}',
      );
    });

    test('a script with no letter ranges falls back to its own character', () {
      // An unlisted script must not become a replacement box, which is what
      // makes an exhaustive list of ranges optional.
      // Since the letter test asks for the category rather than a list, Tamil is
      // a letter like any other and this takes the letter pass, not the
      // fallback — same character either way, which is what the assertion is
      // for. The fallback is still there for names with no letter in them.
      expect(firstInitial('அறிவு', 'x@y.example'), 'அ');
    });

    test('digits inside a letter script are not letters', () {
      // They sit inside the block, so a range test that does not exclude them
      // makes a name beginning with 5 into a circle with a 5 on it.
      // With the category test the exclusion is structural rather than listed:
      // a digit is category `N`, so it is not a letter in any script.
      expect(firstInitial('५ साहित्य', 'x@y.example'), 'स');
      expect(firstInitial('๕๕๕ บ้าน', 'x@y.example'), 'บ');
    });
  });
}
