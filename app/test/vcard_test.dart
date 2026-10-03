// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// vCard-temp / XEP-0054 contact cards.
//
// The register throughout is that this data belongs to other people. A card
// arrives from a client we do not control, it is stored as-is, and it is drawn
// in the chat list, the chat header and the profile page. So each function is
// asked one question — "what is the worst thing a contact could put in that
// field?" — and the answer is a test.
//
// Three things are load-bearing enough that losing them would not be visible in
// a code review:
//
//   * Nothing here throws. One bad field must not cost us the name next to it,
//     and no combination of missing fields may stop a profile page opening.
//   * Nothing reaches a widget that it cannot draw. An unrenderable glyph in a
//     name is an ordinary accident; an RTL override in one is not, and it
//     renders as a *different* string than the one that was sent.
//   * The name we show is the one the contact chose. NICKNAME beating FN is a
//     product decision, and the fallback chain is the only thing standing
//     between "Alex" and "alexsmith1987".

import 'package:test/test.dart';
import 'package:xml/xml.dart';
import 'package:resonchat/xmpp/vcard.dart';

/// Parses a card body exactly as a server would have sent it inside the
/// vcard-temp namespace.
VCard? parse(String body) => parseVCard(
      XmlDocument.parse('<vCard xmlns="$vCardTempNamespace">$body</vCard>')
          .rootElement,
    );

/// The name a contact carrying this card body would be shown as.
String nameFor(String body, [String jid = 'bob@example.test']) {
  final card = parse(body);
  return card == null ? '<no card>' : preferredDisplayName(card, jid);
}

/// Every property this module reads, with a value that is recognisably its own.
const Map<String, String> everyField = <String, String>{
  'FN': 'Robert Smith',
  'N': '<FAMILY>Smith</FAMILY><GIVEN>Robert</GIVEN>',
  'NICKNAME': 'Rob',
  'ORG': 'Example Corp',
  'TITLE': 'Engineer',
  'ROLE': 'Keeper of the build',
  'URL': 'https://example.test/~rob',
  'ADR': '<STREET>1 Example Way</STREET><LOCALITY>Woodstock</LOCALITY>',
  'TEL': '+44 1234 567890',
  'EMAIL': 'rob@example.test',
  'BDAY': '1970-01-01',
  'NOTE': 'Met at a conference.',
  'PHOTO': '<BINVAL>AAAA</BINVAL>',
};

void main() {
  group('a card with fields missing', () {
    test('one at a time, from a card that had everything', () {
      // Taking each field out of an otherwise complete card is the shape this
      // failure takes in the field: a client that publishes six of the seven
      // properties it knows. Nothing may throw, and the name has to survive
      // every one of them — including the case where what survives is FN
      // rather than the nickname, because that is the fallthrough this whole
      // module exists to make.
      for (final field in everyField.keys) {
        final body = everyField.entries
            .where((e) => e.key != field)
            .map((e) => '<${e.key}>${e.value}</${e.key}>')
            .join();
        expect(
          nameFor(body),
          field == 'NICKNAME' ? 'Robert Smith' : 'Rob',
          reason: '$field missing',
        );
      }
    });

    test('one at a time, from an otherwise empty card', () {
      // The other shape: a card that publishes exactly one property. Every one
      // of these has to produce a name rather than an exception, and that name
      // is the JID for every field except the three that carry a name.
      for (final field in everyField.keys) {
        final name = nameFor('<${field}>${everyField[field]}</${field}>');
        expect(name.isNotEmpty, isTrue, reason: '$field alone');
        expect(
          name.runes.every((r) => r != 0x202E && r != 0x200D),
          isTrue,
          reason: '$field alone must not carry an invisible control',
        );
      }
    });

    test('no fields at all', () {
      expect(parse(''), isNotNull);
      expect(nameFor(''), 'bob@example.test');
    });

    test('every field present and empty', () {
      final body = everyField.keys.map((f) => '<$f/>').join();
      expect(nameFor(body), 'bob@example.test');
    });

    test('every field present and whitespace only', () {
      final body = everyField.keys.map((f) => '<$f>   </$f>').join();
      expect(nameFor(body), 'bob@example.test');
    });

    test('no fallback either', () {
      expect(nameFor('', ''), '');
    });

    test('there is no card in the element at all', () {
      final iq = XmlDocument.parse('<iq type="result"/>').rootElement;
      expect(parseVCard(iq), isNull);
    });
  });

  group('parsing', () {
    test('reads every property clients actually send', () {
      final card = parse('''
        <FN>Robert Smith</FN>
        <N><FAMILY>Smith</FAMILY><GIVEN>Robert</GIVEN><ADDITIONAL>Q</ADDITIONAL></N>
        <NICKNAME>Rob</NICKNAME>
        <ORG>Example Corp</ORG>
        <TITLE>Engineer</TITLE>
        <ROLE>Keeper of the build</ROLE>
        <URL>https://example.test/~rob</URL>
        <ADR><STREET>1 Example Way</STREET><LOCALITY>Woodstock</LOCALITY><REGION>NY</REGION><POSTCODE>12401</POSTCODE><COUNTRY>US</COUNTRY></ADR>
        <TEL>+44 1234 567890</TEL>
        <EMAIL>rob@example.test</EMAIL>
        <BDAY>1970-01-01</BDAY>
        <NOTE>Met at a conference.</NOTE>
      ''')!;
      expect(card.formattedName, 'Robert Smith');
      expect(card.structuredName?.family, 'Smith');
      expect(card.structuredName?.given, 'Robert');
      expect(card.structuredName?.additional, 'Q');
      expect(card.nickname, 'Rob');
      expect(card.organisation, 'Example Corp');
      expect(card.jobTitle, 'Engineer');
      expect(card.role, 'Keeper of the build');
      expect(card.url, 'https://example.test/~rob');
      expect(card.phone, '+44 1234 567890');
      expect(card.email, 'rob@example.test');
      expect(card.birthday, '1970-01-01');
      expect(card.note, 'Met at a conference.');
      expect(
        card.address?.oneLine,
        '1 Example Way, Woodstock, NY, 12401, US',
      );
    });

    test('the structured name renders given name first, as FN does', () {
      // Otherwise a contact with both N and FN can be shown under two different
      // names in two screens of the same app.
      final card = parse('<N><FAMILY>Smith</FAMILY><GIVEN>Robert</GIVEN></N>')!;
      expect(card.structuredName?.formatted, 'Robert Smith');
    });

    test('prefix and suffix survive, so a title is not lost', () {
      final card = parse(
        '<N><PREFIX>Dr</PREFIX><FAMILY>Smith</FAMILY><GIVEN>Robert</GIVEN>'
        '<SUFFIX>PhD</SUFFIX></N>',
      )!;
      expect(card.structuredName?.formatted, 'Dr Robert Smith PhD');
    });

    test('an N with missing components still yields what it had', () {
      final card = parse('<N><FAMILY>Cher</FAMILY></N>')!;
      expect(card.structuredName?.formatted, 'Cher');
      expect(card.structuredName?.isEmpty, isFalse);
    });

    test('an N whose components are all empty is no N at all', () {
      // Five empty components is not a person with no first name; it is a
      // client that emitted a template. Treating it as a name renders "".
      final card = parse('<N><FAMILY></FAMILY><GIVEN> </GIVEN></N>')!;
      expect(card.structuredName, isNull);
      expect(preferredDisplayName(card, 'bob@example.test'), 'bob@example.test');
    });

    test('property names are case-insensitive, as RFC 2426 says', () {
      // A capitalisation difference is not a reason to show a contact their
      // JID, and the nickname is the one field the display name depends on.
      final card = parse('<fn>Alex</fn><nickname>ali</nickname>')!;
      expect(card.formattedName, 'Alex');
      expect(card.nickname, 'ali');
      expect(preferredDisplayName(card, 'bob@example.test'), 'ali');
    });

    test('the root may be spelled vcard', () {
      final el =
          XmlDocument.parse('<vcard xmlns="vcard-temp"><FN>Alex</FN></vcard>')
              .rootElement;
      expect(parseVCard(el)?.formattedName, 'Alex');
    });

    test('a card two levels down an iq response is found', () {
      final el = XmlDocument.parse(
        '<iq type="result" id="1"><vCard xmlns="vcard-temp">'
        '<FN>Alex</FN></vCard></iq>',
      ).rootElement;
      expect(parseVCard(el)?.formattedName, 'Alex');
    });

    test('a child element inside a value is not part of the value', () {
      // In vCard-temp the child elements of a property are its parameters —
      // that is how TYPE and PREF are spelled. Reading the value as "all the
      // text underneath" therefore concatenates the parameters into it, which
      // is how a phone number arrives as "pref+441234". Here the name is 'Alex'
      // and the <b> is discarded rather than read.
      final card = parse('<FN>Alex <b>Chen</b></FN>')!;
      expect(card.formattedName, 'Alex');
    });

    test('a TYPE parameter is not folded into the value', () {
      final card = parse(
        '<TEL><TYPE>WORK</TYPE><PREF/>+441234</TEL>',
      )!;
      expect(card.phone, '+441234');
    });

    test('unknown properties are ignored, not treated as fields', () {
      // X- extensions are everywhere in real cards and none of them is a name.
      final card = parse(
        '<X-ABSHOWMarvellous/><FN>Alex</FN><CATEGORIES><CATEGORY>friends</CATEGORY></CATEGORIES>',
      )!;
      expect(card.formattedName, 'Alex');
    });

    test('a duplicate FN takes the first', () {
      expect(parse('<FN>Alex</FN><FN>Alexandra</FN>')!.formattedName, 'Alex');
    });
  });

  group('which of several values means anything', () {
    test('the PREF-marked nickname wins', () {
      // RFC 2426 §2.5.1: with several nicknames, the PREF one is the one to
      // use. Taking the first means the name depends on serialisation order.
      expect(
        parse('<NICKNAME>work</NICKNAME><NICKNAME><PREF/>Rob</NICKNAME>')!
            .nickname,
        'Rob',
      );
    });

    test('the PREF-marked phone number wins', () {
      // A phone that syncs several numbers serialises them in whatever order
      // the OS lists them, which is not the number the person answers.
      expect(
        parse('<TEL><PREF/>+441234</TEL><TEL>+449999</TEL>')!.phone,
        '+441234',
      );
    });

    test('PREF marked the vCard 2.1 way is understood', () {
      expect(parse('<TEL><TYPE>pref</TYPE>+441234</TEL>')!.phone, '+441234');
    });

    test('without PREF the first is used', () {
      expect(parse('<TEL>+441234</TEL><TEL>+449999</TEL>')!.phone, '+441234');
    });

    test('an empty first value does not hide a real one behind it', () {
      // The failure this prevents is a contact who clears a nickname in one
      // place and has it still set in another, ending up nameless.
      expect(parse('<NICKNAME></NICKNAME><NICKNAME>Rob</NICKNAME>')!.nickname, 'Rob');
    });
  });

  group('what we refuse to draw', () {
    test('a zero-width joiner in a name is removed', () {
      // Common by accident: "family emoji" sequences, and copy-paste out of a
      // word processor. A ZWJ that survives renders as nothing at all, so the
      // name silently loses a character or becomes invisible.
      expect(nameFor('<FN>A\u200Dlex</FN>'), 'Alex');
    });

    test('a zero-width non-joiner and a zero-width space are removed too', () {
      expect(sanitiseVCardLine('A\u200Clex'), 'Alex');
      expect(sanitiseVCardLine('A\u200Dlex'), 'Alex');
      expect(sanitiseVCardLine('A\uFEFFlex'), 'Alex');
    });

    test('an RTL override is removed', () {
      // The sharp end of the list. U+202E reverses what follows it, so a card
      // whose name is "gnp\u202Etxt.exe" is *displayed* as "exe.txt". A name
      // that shows something other than what it says is the one field in a
      // messenger that cannot be treated as decoration.
      final cleaned = sanitiseVCardLine('gnp\u202Etxt.exe')!;
      expect(cleaned, isNot(contains('\u202E')));
      expect(cleaned, 'gnptxt.exe');
    });

    test('an LTR override is removed as well', () {
      expect(sanitiseVCardLine('a\u202Db\u202Cc'), 'abc');
    });

    test('control characters are removed', () {
      expect(sanitiseVCardLine('A\u0000b\u0007c\u007Fd'), 'Abcd');
    });

    test('a soft hyphen is removed', () {
      // Invisible unless a line break happens to land on it, which is exactly
      // what makes it a way to smuggle text past a reader.
      expect(sanitiseVCardLine('Alex\u00ADChen'), 'AlexChen');
    });

    test('a stray quote or ampersand survives', () {
      // Ordinary characters in a name must not be escaped or dropped: we are
      // parsing text, not producing markup.
      expect(sanitiseVCardLine("Ann & Bob <O'Brien>"), "Ann & Bob <O'Brien>");
    });

    test('an emoji in a note survives', () {
      // Only the initial extractor refuses emoji; a name or a note is not
      // clipped for being decorative.
      expect(sanitiseVCardText('happy 🎂'), 'happy 🎂');
    });
  });

  group('length', () {
    test('a ten-thousand-character name is capped', () {
      final name = nameFor('<FN>${'A' * 10000}</FN>');
      expect(name.length, maxVCardNameLength);
      expect(name, 'A' * maxVCardNameLength);
    });

    test('a ten-thousand-character nickname is capped', () {
      expect(
        nameFor('<NICKNAME>${'N' * 10000}</NICKNAME>').length,
        maxVCardNameLength,
      );
    });

    test('a ten-thousand-character note is capped', () {
      expect(
        parse('<NOTE>${'n' * 10000}</NOTE>')!.note!.length,
        maxVCardTextLength,
      );
    });

    test('the cap lands on a character boundary, never inside one', () {
      // An emoji is two UTF-16 units. Cutting at 120 *units* would leave half
      // of one, which draws as a replacement box — the exact failure this
      // module exists to prevent, reintroduced by the fix.
      final body = '<FN>${'a' * 119}${'😀'}${'b' * 50}</FN>';
      final name = nameFor(body);
      expect(name.runes.length, maxVCardNameLength);
      expect(name.endsWith('😀'), isTrue);
      expect(name.runes.every((r) => r != 0xFFFD), isTrue);
    });

    test('the cap never leaves a mark without a letter to attach to', () {
      // One letter *fewer* than the cap, then the combining acute — so the mark
      // is the last code point and there is nothing for it to attach to.
      //
      // 120 letters *plus* the mark, which is what this used to build, exercised
      // nothing: 121 code points truncated to 120 excludes the mark entirely, so
      // the result was 120 plain letters with nothing dangling. It passed by being
      // one character too long.
      final body = '<FN>${'a' * (maxVCardNameLength - 1)}́</FN>';
      final name = nameFor(body);
      expect(name.runes.length, lessThan(maxVCardNameLength));
      expect(name.endsWith('́'), isFalse);
    });

    test('a name exactly at the cap still drops a trailing mark', () {
      // The case the test above used to be unable to reach. Whether a name ends
      // in a dangling accent has nothing to do with how long it is, so this must
      // hold at exactly the cap and not only past it — otherwise a contact can
      // get a stray glyph by having a name one character shorter than another.
      final exact = '<FN>${'a' * maxVCardNameLength}́</FN>';
      expect(nameFor(exact).endsWith('́'), isFalse);
      // And the truncated form is still capped.
      expect(
        nameFor('<FN>${'a' * (maxVCardNameLength * 2)}́</FN>').runes.length,
        lessThanOrEqualTo(maxVCardNameLength),
      );
    });
  });

  group('whitespace', () {
    test('a newline in a name becomes a space', () {
      // Two lines in a single-line list row is not a name, it is a layout
      // accident the user reads as two contacts.
      expect(nameFor('<FN>Alex\nChen</FN>'), 'Alex Chen');
    });

    test('a carriage return does not survive as a glyph', () {
      expect(sanitiseVCardLine('Alex\r\nChen'), 'Alex Chen');
    });

    test('runs of spaces collapse', () {
      expect(sanitiseVCardLine('Alex     Chen'), 'Alex Chen');
    });

    test('a no-break space collapses like any other space', () {
      // It is invisible in the source and a wide gap on screen, so two
      // contacts whose names differ only by one are indistinguishable in a
      // list.
      expect(sanitiseVCardLine('Alex\u00A0Chen'), 'Alex Chen');
    });

    test('leading and trailing space is dropped', () {
      expect(sanitiseVCardLine('   Alex   '), 'Alex');
    });

    test('a name of nothing but whitespace is nothing', () {
      expect(sanitiseVCardLine('   \t\n  '), isNull);
      expect(sanitiseVCardLine(''), isNull);
      expect(sanitiseVCardLine(null), isNull);
    });

    test('a note keeps at most one blank line', () {
      // How tall the profile page becomes is not a stranger's decision.
      expect(sanitiseVCardText('one\n\n\n\n\ntwo'), 'one\n\ntwo');
    });

    test('sanitising is idempotent', () {
      // The parser and [preferredDisplayName] both apply it, so it has to be.
      const nasty = ' A\u200D B\n\n C  ';
      final once = sanitiseVCardLine(nasty)!;
      expect(sanitiseVCardLine(once), once);
      expect(
        sanitiseVCardText(sanitiseVCardText(nasty)!),
        sanitiseVCardText(nasty),
      );
    });
  });

  group('the name we show', () {
    test('a nickname beats the formatted name', () {
      // The point of the whole module. Somebody who set a nickname did so
      // because they wanted to be called that; FN is whatever the account was
      // created with and they may not have looked at it since.
      expect(
        nameFor('<FN>Robert Smith</FN><NICKNAME>Rob</NICKNAME>'),
        'Rob',
      );
    });

    test('an empty nickname falls through to FN rather than rendering blank', () {
      expect(nameFor('<FN>Robert Smith</FN><NICKNAME></NICKNAME>'), 'Robert Smith');
      expect(nameFor('<FN>Robert Smith</FN><NICKNAME> </NICKNAME>'), 'Robert Smith');
    });

    test('a nickname of only invisible characters falls through too', () {
      expect(nameFor('<FN>Robert Smith</FN><NICKNAME>\u200D\u200D</NICKNAME>'), 'Robert Smith');
    });

    test('FN beats a reconstructed structured name', () {
      // FN is the publisher's own answer to the question we cannot answer —
      // which order this person writes their name. Preferring our guess means
      // one contact renders two ways in one app.
      expect(
        nameFor('<FN>Wei Chen</FN><N><FAMILY>Chen</FAMILY><GIVEN>Wei</GIVEN></N>'),
        'Wei Chen',
      );
    });

    test('a nickname beats FN even when N is present', () {
      expect(
        nameFor(
          '<N><FAMILY>Chen</FAMILY><GIVEN>Wei</GIVEN></N>'
          '<FN>Wei Chen</FN><NICKNAME>小陈</NICKNAME>',
        ),
        '小陈',
      );
    });

    test('the structured name is used when there is no FN', () {
      // Older Android clients and several servers send N with no FN at all, so
      // ignoring N means showing a JID for a contact who told us their name.
      expect(
        nameFor('<N><FAMILY>Smith</FAMILY><GIVEN>Robert</GIVEN></N>'),
        'Robert Smith',
      );
    });

    test('a whitespace-only FN falls through to the JID', () {
      expect(nameFor('<FN>   </FN>'), 'bob@example.test');
      expect(nameFor('<FN>\n\t</FN>'), 'bob@example.test');
    });

    test('an organisation is never a person\'s name', () {
      // The decision most likely to be got wrong by putting ORG in as a last
      // resort before the JID. In the title slot of a 1:1 chat it says "this
      // conversation is with a company", which is false; and on a domain with a
      // shared address it is the same string on every contact, so the field
      // that would have disambiguated them is the one that removes the
      // distinction.
      expect(nameFor('<ORG>Example Corp</ORG>'), 'bob@example.test');
      expect(
        nameFor('<ORG>Example Corp</ORG><FN>Robert Smith</FN>'),
        'Robert Smith',
      );
      expect(
        nameFor('<ORG>Example Corp</ORG><N><GIVEN>Robert</GIVEN></N>'),
        'Robert',
      );
    });

    test('the organisation is still available for the profile page', () {
      // Where "works at" is a true and useful thing to say.
      expect(parse('<ORG>Example Corp</ORG>')!.organisation, 'Example Corp');
    });

    test('the JID is sanitised too', () {
      // It arrives from a roster push or a presence; a name column is not a
      // place where an unsanitised string is acceptable because the protocol
      // field was one we trust for routing.
      expect(nameFor('', 'b\u200Dob@example.test'), 'bob@example.test');
    });

    test('a hand-built card is sanitised on the way out too', () {
      // A VCard does not have to come from the parser, and the function that
      // feeds the UI does not care which it got.
      const card = VCard(formattedName: 'A\u200Dlex   Chen');
      expect(preferredDisplayName(card, 'bob@example.test'), 'Alex Chen');
    });
  });

  group('the placeholder initial', () {
    test('uses the first letter of the name, not of the JID', () {
      expect(vcardInitial('Alex Chen', 'bob@example.test'), 'A');
    });

    test('a non-Latin name yields exactly one rune', () {
      // `substring(0, 1)` on a CJK character returns a lone surrogate, which
      // draws as a replacement box. Every initial has to be a whole rune.
      for (final name in ['张三', 'こんにちは', 'Привет', 'العربية', 'דָּוִד']) {
        final initial = vcardInitial(name, 'bob@example.test');
        expect(initial.runes.length, 1, reason: name);
        expect(
          initial.runes.single >= 0xD800 && initial.runes.single <= 0xDFFF,
          isFalse,
          reason: '$name must not yield a surrogate',
        );
      }
    });

    test('scripts outside the Latin/CJK/Cyrillic/Hebrew/Arabic set work', () {
      expect(vcardInitial('ชื่อ', 'bob@example.test'), 'ช');
      expect(vcardInitial('Đức', 'bob@example.test'), 'Đ');
      expect(vcardInitial('አበበ', 'bob@example.test'), 'አ');
      expect(vcardInitial('ᏣᎳᎩ', 'bob@example.test'), 'Ꮳ');
      // Georgian has a case mapping whose capital is in a different block, so
      // the *glyph* is not worth asserting — the shape is.
      expect(vcardInitial('ქართველი', 'bob@example.test').runes.length, 1);
    });

    test('a case mapping that changes length is declined', () {
      // "ß".toUpperCase() is "SS", and two glyphs in a 32-pixel circle read as
      // a typo. One rune or nothing.
      expect(vcardInitial('ß', 'bob@example.test').runes.length, 1);
    });

    test('skips a leading digit or symbol', () {
      // "404" should not become a circle with a 4 on it; the user's own name
      // is in there.
      expect(vcardInitial('404 Not Found', 'x@y.test'), 'N');
    });

    test('a name with no letters at all falls back to its digits', () {
      expect(vcardInitial('404', 'x@y.test'), '4');
    });

    test('a name with nothing drawable in it falls back to the JID', () {
      // An emoji is not an initial: at circle font size it overflows, and a
      // contact list where one circle is a coloured pictograph and the rest are
      // letters is a contact list that looks broken.
      expect(vcardInitial('🔥🔥', 'bob@example.test'), 'B');
      expect(vcardInitial('!!!', 'bob@example.test'), 'B');
      expect(vcardInitial('\u200D\u200D', 'bob@example.test'), 'B');
    });

    test('a name that is only a combining mark falls back too', () {
      // A mark with nothing in front of it does not draw.
      expect(vcardInitial('́', 'bob@example.test'), 'B');
    });

    test('a leading combining mark is skipped, not drawn', () {
      expect(vcardInitial('́bob', 'bob@example.test'), 'B');
    });

    test('a normal name still uppercases', () {
      expect(vcardInitial('alex', 'bob@example.test'), 'A');
    });

    test('nothing anywhere is a question mark, not a crash or an empty circle', () {
      expect(vcardInitial('', ''), '?');
      expect(vcardInitial('\u200D', ''), '?');
    });

    test('works on the name the display rule actually chose', () {
      // The two functions are a pair: this is what the chat list draws.
      final card = parse('<FN>Robert Smith</FN><NICKNAME>Роберт</NICKNAME>')!;
      expect(vcardInitial(preferredDisplayName(card, 'x@y.test'), 'x@y.test'), 'Р');
    });
  });

  group('a card from the wire', () {
    test('a raw response parses', () {
      expect(
        parseVCardResponse(
          '<iq type="result" id="1"><vCard xmlns="vcard-temp">'
          '<FN>Alex</FN></vCard></iq>',
        )?.formattedName,
        'Alex',
      );
    });

    test('a result with no card is no card, not an exception', () {
      // Most contacts have no card published, and the IQ that says so is
      // ordinary traffic rather than a failure worth reporting.
      expect(parseVCardResponse('<iq type="result"/>'), isNull);
    });

    test('an error response is no card', () {
      expect(
        parseVCardResponse('<iq type="error"><error/></iq>'),
        isNull,
      );
    });

    test('malformed XML is no card', () {
      expect(parseVCardResponse('<vCard><FN>Alex</vCard>'), isNull);
      expect(parseVCardResponse('not xml at all <<<'), isNull);
      expect(parseVCardResponse(''), isNull);
    });
  });

  group('photos', () {
    // base64 of 89 50 4E 47 — the first four bytes of a PNG. Small enough to
    // spell out and check by hand, which matters more here than looking like a
    // real picture: the module sniffs these bytes and nothing else.
    const png = 'iVBORw==';

    // base64 of "nope".
    const notAnImage = 'bm9wZQ==';

    test('an inline PNG is taken, with its type guessed from the bytes', () {
      final photo = parse('<PHOTO><BINVAL>$png</BINVAL></PHOTO>')!.photo;
      expect(photo, isNotNull);
      expect(photo!.mimeType, 'image/png');
      expect(photo.bytes, hasLength(4));
    });

    test('a declared type is not believed over the bytes', () {
      // The publisher chose the label; the bytes are what get decoded.
      final photo = parse(
        '<PHOTO><TYPE>image/gif</TYPE><BINVAL>$png</BINVAL></PHOTO>',
      )!.photo;
      expect(photo!.mimeType, 'image/png');
    });

    test('base64 that is not base64 is dropped, not thrown', () {
      expect(
        parse('<PHOTO><BINVAL>!!!! not base64 !!!!</BINVAL></PHOTO>')!.photo,
        isNull,
      );
    });

    test('something that is not an image is dropped', () {
      // Decoding on trust is how a peer hands the image decoder bytes it was
      // not written for. These bytes decode cleanly — they just are not a
      // picture, so this is the sniff refusing and not the decoder.
      expect(
        parse('<PHOTO><BINVAL>$notAnImage</BINVAL></PHOTO>')!.photo,
        isNull,
      );
    });

    test('a photo URL is not followed', () {
      // Fetching it would turn every profile the user opens into a request to
      // a server the stranger controls, carrying an id they can correlate.
      expect(
        parse('<PHOTO><EXTVAL>https://evil.test/p.gif</EXTVAL></PHOTO>')!.photo,
        isNull,
      );
    });

    test('an absurdly large photo is refused before it is decoded', () {
      final huge = 'A' * (maxVCardPhotoBase64 + 1);
      expect(parse('<PHOTO><BINVAL>$huge</BINVAL></PHOTO>')!.photo, isNull);
    });

    test('a card with no photo is not an error', () {
      expect(parse('<FN>Alex</FN>')!.photo, isNull);
    });
  });
}