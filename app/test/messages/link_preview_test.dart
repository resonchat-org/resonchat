// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Link previews: URL detection, the fetch policy, and the inline/on-demand call.
//
// The register of this file is restraint and failure modes. A feature that fetches
// a URL somebody else chose, from the user's own phone, has three ways to be
// wrong that matter: it fetches something the user did not agree to, it acts for a
// person the user blocked, and it acts on text the client never decrypted. Each of
// those is a test below. The happy path is one test, and it is there so the
// refusals cannot pass by refusing everything.

import 'package:test/test.dart';
import 'package:resonchat/xmpp/link_preview.dart';

/// A fetcher that records what it was asked for and never touches a network.
class RecordingFetcher implements LinkPreviewFetcher {
  final List<String> asked = <String>[];

  @override
  Future<LinkPreview> fetch(PreviewAllowed approved) async {
    asked.add(approved.url);
    return mergePreview(detectedUrl: approved.url, announced: null)!;
  }
}

/// The plain case: an unblocked sender, previews on, a readable message.
const plainContext = PreviewContext(sender: 'peer@example.org');

/// Previews switched on, which is not the default and is named everywhere so
/// that no test accidentally passes because nothing was fetched.
const onPolicy = LinkPreviewPolicy(previewsEnabled: true);

void main() {
  group('a blocked sender gets nothing fetched', () {
    const blocked = PreviewContext(sender: 'peer@example.org', blocked: true);

    test('the policy refuses, and says which rule refused', () {
      final verdict = onPolicy.mayFetch(
        context: blocked,
        url: 'https://example.com/post',
      );
      expect(verdict, isA<PreviewRefused>());
      expect((verdict as PreviewRefused).reason, PreviewRefusal.senderBlocked);
    });

    test('and the refusal is not an empty one', () {
      // A refusal with no reason behind it cannot be shown to the user and cannot
      // be told apart from a bug, so "no preview" has to name the rule.
      const reasons = PreviewRefusal.values;
      expect(reasons, contains(PreviewRefusal.senderBlocked));
      for (final reason in reasons) {
        expect(reason.title, isNotEmpty, reason: '$reason has no title');
        expect(reason.consequence, isNotEmpty, reason: '$reason says nothing');
      }
    });

    test('no card is drawn either', () {
      // Refusing the fetch but drawing the card would still have fetched the
      // image on it, which is the same request with a picture attached.
      final preview = mergePreview(
        detectedUrl: 'https://example.com/post',
        announced: OutOfBandData.tryParse(
          url: 'https://example.com/post',
          title: 'A post',
        ),
      )!;
      expect(
        onPolicy.display(context: blocked, preview: preview),
        PreviewDisplay.none,
      );
    });

    test(
      'the fetcher is never reached, so nothing leaves the device',
      () async {
        final fetcher = RecordingFetcher();
        final loaded = await loadPreview(
          policy: onPolicy,
          fetcher: fetcher,
          body: 'look at this https://example.com/post',
          context: blocked,
        );
        expect(loaded, isNull);
        expect(fetcher.asked, isEmpty);
      },
    );

    test('even when the block arrives after the message was stored', () {
      // The usual path drops blocked messages before they are stored at all
      // (`blocked_inbound.dart`), so a body from a blocked sender reaching this
      // module means the block landed later. It still must not produce a request.
      final verdict = onPolicy.mayFetch(
        context: blocked,
        url: 'https://example.com/post',
      );
      expect(verdict, isA<PreviewRefused>());
    });
  });

  group('a message we could not open is never previewed', () {
    const unread = PreviewContext(
      sender: 'peer@example.org',
      undecryptable: true,
    );

    test('the policy refuses it', () {
      final verdict = onPolicy.mayFetch(
        context: unread,
        url: 'https://example.com/post',
      );
      expect(
        (verdict as PreviewRefused).reason,
        PreviewRefusal.unreadableMessage,
      );
    });

    test('and the reason is not the blocked one', () {
      // They are different promises about different things. Merging them would
      // mean a fix for one — a late key, a lifted block — silently unlocking the
      // other, and the UI would blame a contact for a decryption failure.
      final blocked = onPolicy.mayFetch(
        context: const PreviewContext(sender: 'p@example.org', blocked: true),
        url: 'https://example.com/',
      );
      final unreadable = onPolicy.mayFetch(
        context: unread,
        url: 'https://example.com/',
      );
      expect(
        (blocked as PreviewRefused).reason,
        isNot((unreadable as PreviewRefused).reason),
      );
    });

    test('neither is the sender, so an unblocked stranger still gets nothing', () {
      // The obvious objection to the rule: "but they are not blocked". The
      // address came out of a blob this device never opened, so there is no way
      // to know whose it is or whether it is even the address that was sent.
      expect(
        onPolicy.mayFetch(context: unread, url: 'https://example.com/post'),
        isA<PreviewRefused>(),
      );
    });

    test('and the URL in the body is not used even if there is one', () {
      // An undecryptable row's body is empty by construction, and a rule that
      // said "it has a URL, so preview it" would start working the day a stale
      // decryption attempt left text in the column.
      final scan = scanUrls('https://example.com/post');
      expect(scan.links, isNotEmpty);
      final verdict = onPolicy.mayFetch(context: unread, url: scan.links.first);
      expect(verdict, isA<PreviewRefused>());
    });
  });

  group('the switch is a switch', () {
    const off = LinkPreviewPolicy(previewsEnabled: false);

    test('nothing is fetched when previews are off', () async {
      final fetcher = RecordingFetcher();
      final loaded = await loadPreview(
        policy: off,
        fetcher: fetcher,
        body: 'https://example.com/post',
        context: plainContext,
      );
      expect(loaded, isNull);
      expect(fetcher.asked, isEmpty);
    });

    test('and nothing is drawn', () {
      final preview = mergePreview(
        detectedUrl: 'https://example.com/post',
        announced: OutOfBandData.tryParse(
          url: 'https://example.com/post',
          title: 'A post',
        ),
      )!;
      expect(
        off.display(context: plainContext, preview: preview),
        PreviewDisplay.none,
      );
    });

    test('a blocked sender is refused before the switch is consulted', () {
      // The reason a caller might report has to be the one the user can act on.
      // "Previews are off" when the real problem is a block sends them to the
      // wrong setting.
      final verdict = off.mayFetch(
        context: const PreviewContext(sender: 'p@example.org', blocked: true),
        url: 'https://example.com/',
      );
      expect((verdict as PreviewRefused).reason, PreviewRefusal.senderBlocked);
    });
  });

  group('the approval cannot be had without the policy', () {
    test('the approved address is the one that was checked', () {
      // The approval and the address are one object, so there is no way to ask
      // about a harmless URL and then fetch a different one. That is the whole
      // reason `PreviewAllowed` has a private constructor.
      final verdict = onPolicy.mayFetch(
        context: plainContext,
        url: 'https://example.com/ok',
      );
      expect(verdict, isA<PreviewAllowed>());
      expect((verdict as PreviewAllowed).url, 'https://example.com/ok');
    });

    test('a refusal is not an approval', () {
      // Stated from the other end: there is no way to get hold of an approval
      // without a passing verdict, so "we fetched but the policy said no" cannot
      // be written. The refusal here is the block, not the switch, so it is not a
      // test that passes for the wrong reason.
      const blocked = PreviewContext(sender: 'p@example.org', blocked: true);
      expect(
        onPolicy.mayFetch(context: blocked, url: 'https://example.com/'),
        isNot(isA<PreviewAllowed>()),
      );
    });

    test('the thumbnail is a second address and is refused on its own', () {
      // An approval for the page says nothing about the picture beside it, and
      // the picture is fetched from a host the sender picked separately. Reusing
      // the page's approval for it is the mistake the interface is shaped to make
      // awkward — so this checks the shape of the answer, not a comment.
      const policy = LinkPreviewPolicy(previewsEnabled: true);
      const blocked = PreviewContext(sender: 'p@example.org', blocked: true);
      expect(
        policy.mayFetch(context: blocked, url: 'https://example.com/t.jpg'),
        isA<PreviewRefused>(),
      );
      expect(
        policy.mayFetch(
          context: plainContext,
          url: 'https://example.com/t.jpg',
        ),
        isA<PreviewAllowed>(),
      );
    });
  });

  group('a message with no sender is not acted for', () {
    test('refused, with its own reason', () {
      final verdict = onPolicy.mayFetch(
        context: const PreviewContext(sender: ''),
        url: 'https://example.com/post',
      );
      expect((verdict as PreviewRefused).reason, PreviewRefusal.unknownSender);
    });

    test('and whitespace is not a sender either', () {
      final verdict = onPolicy.mayFetch(
        context: const PreviewContext(sender: '   '),
        url: 'https://example.com/post',
      );
      expect(verdict, isA<PreviewRefused>());
    });
  });

  group('what the fetcher is asked for', () {
    test('the link in the body, once', () async {
      final fetcher = RecordingFetcher();
      await loadPreview(
        policy: onPolicy,
        fetcher: fetcher,
        body: 'see https://example.com/a and https://example.org/b',
        // The title is what makes this card drawable inline, and a card holding
        // only an address is deliberately not drawn — so without it this test
        // would be asserting that a preview is fetched for something the app
        // would then refuse to show. The property under test is *which* link and
        // *how many times*, and neither depends on the title.
        announced: OutOfBandData.tryParse(
          url: 'https://example.com/a',
          title: 'A',
        ),
        context: plainContext,
      );
      expect(fetcher.asked, ['https://example.com/a']);
    });

    test('the body wins over an element that names another address', () {
      // The element travels outside the encrypted payload, so for an encrypted
      // message its URL is a claim in the clear. A link the ciphertext carried is
      // authenticated; one only the element carried is not, and acting on it is
      // invisible to the reader.
      final preview = mergePreview(
        detectedUrl: 'https://example.org/real',
        announced: OutOfBandData.tryParse(
          url: 'https://tracker.example/pixel',
          title: 'Totally the same thing',
        ),
      )!;
      expect(preview.url, 'https://example.org/real');

      // The address we could act on is still the body's, and it is approved —
      // the refusal here is not about the address, it is that the sender's
      // description of a *different* address is not evidence about this one.
      expect(
        onPolicy.mayFetchPreview(context: plainContext, preview: preview),
        isA<PreviewAllowed>(),
      );
    });

    test('and the sender\'s title for that other address is dropped', () {
      // A description attached to a link it was not written for is the most
      // valuable text in a preview: it reads like our own words about their link.
      // With the title gone there is nothing to draw, so the card waits for a
      // tap rather than being drawn on the strength of a text that was not
      // written about this link.
      final preview = mergePreview(
        detectedUrl: 'https://example.org/real',
        announced: OutOfBandData.tryParse(
          url: 'https://tracker.example/pixel',
          title: 'Totally the same thing',
        ),
      )!;
      expect(preview.title, isNull);
      expect(preview.hasSomethingToShow, isFalse);
      expect(
        onPolicy.display(context: plainContext, preview: preview),
        PreviewDisplay.onDemand,
      );
      expect(preview.announcedUrl, 'https://tracker.example/pixel');
    });

    test('the disagreement is kept, not resolved', () {
      // Silently preferring one of two addresses is how a client ends up fetching
      // something the reader cannot account for. The loser has to survive long
      // enough for the UI to mention it.
      final preview = mergePreview(
        detectedUrl: 'https://example.org/real',
        announced: OutOfBandData.tryParse(url: 'https://tracker.example/'),
      )!;
      expect(preview.announcedUrl, isNotNull);
      expect(preview.announcedUrl, isNot(preview.url));
    });

    test('a matching element supplies the text', () {
      final preview = mergePreview(
        detectedUrl: 'https://example.org/real',
        announced: OutOfBandData.tryParse(
          url: 'https://example.org/real',
          title: 'Real title',
        ),
      )!;
      expect(preview.title, 'Real title');
      expect(preview.announcedUrl, isNull);
      expect(preview.urlFromStanza, isFalse);
    });

    test('an element alone is a preview, marked as coming from the stanza', () {
      final preview = mergePreview(
        detectedUrl: null,
        announced: OutOfBandData.tryParse(url: 'https://example.org/x'),
      )!;
      expect(preview.url, 'https://example.org/x');
      expect(preview.urlFromStanza, isTrue);
    });

    test('nothing at all is no preview', () {
      expect(mergePreview(detectedUrl: null, announced: null), isNull);
      expect(previewForBody('no links here'), isNull);
    });
  });

  group('finding links', () {
    test('an empty body yields no previews', () async {
      // `''.split('\n')` is `['']`, which is a line, and a line is where links are
      // looked for. A body with nothing in it has to produce a scan of nothing
      // rather than a scan of one empty line.
      final scan = scanUrls('');
      expect(scan.links, isEmpty);
      expect(scan.distinctFound, 0);
      expect(scan.droppedForCap, isFalse);
      expect(previewForBody(''), isNull);
      final fetcher = RecordingFetcher();
      expect(
        await loadPreview(
          policy: onPolicy,
          fetcher: fetcher,
          body: '',
          context: plainContext,
        ),
        isNull,
      );
      expect(fetcher.asked, isEmpty);
    });

    test('a whitespace body yields no previews', () {
      expect(scanUrls('   \n\t\n  ').links, isEmpty);
    });

    test('the same link twice is one link', () {
      final scan = scanUrls('https://example.com/a and https://example.com/a');
      expect(scan.links, ['https://example.com/a']);
    });

    test('case in the host does not make two links', () {
      // Hosts are case-insensitive, so these are one host and two fetches for one
      // page otherwise. The sender's spelling is the one that is kept, because
      // nothing in this file rewrites an address — lowercasing it here would be a
      // request to a URL that is not the one in the message.
      final scan = scanUrls('HTTPS://EXAMPLE.COM/a https://example.com/a');
      expect(scan.links, ['HTTPS://EXAMPLE.COM/a']);
    });

    test('but case in the path does', () {
      // Paths are case-sensitive: /Post and /post are two documents and folding
      // them would show the preview of the wrong one.
      final scan = scanUrls(
        'https://example.com/Post https://example.com/post',
      );
      expect(scan.links.length, 2);
    });

    test('a fragment is the same page', () {
      final scan = scanUrls('https://example.com/a#one https://example.com/a');
      expect(scan.links, ['https://example.com/a#one']);
    });

    test('trailing sentence punctuation is not part of the link', () {
      final scan = scanUrls('go to https://example.com/page.');
      expect(scan.links, ['https://example.com/page']);
    });

    test('a balanced bracket stays in the link', () {
      // `Foo_(bar)` is one article. Cutting at the `)` gives a 404 whose cause
      // the reader cannot see.
      final scan = scanUrls('https://en.example.org/wiki/Foo_(bar) is good');
      expect(scan.links, ['https://en.example.org/wiki/Foo_(bar)']);
    });

    test('an unbalanced bracket is punctuation', () {
      final scan = scanUrls('(see https://example.com/page)');
      expect(scan.links, ['https://example.com/page']);
    });

    test('a scheme inside a longer word is not a link', () {
      // `xhttps://` is a token, not an address, and treating the tail of one as a
      // URL means fetching a host the sender never named.
      final scan = scanUrls('xhttps://example.com/a .https://example.com/b');
      expect(scan.links, isEmpty);
    });

    test('a bare www is not a link', () {
      // Completing `www.x` into `https://www.x` would mean fetching an address
      // that is not in the text, under a line that does not contain it.
      final scan = scanUrls('see www.example.com for details');
      expect(scan.links, isEmpty);
    });

    test('a non-http scheme is not a preview', () {
      // `xmpp:` is a link the reader can act on and is not something to fetch
      // behind their back.
      final scan = scanUrls('xmpp:peer@example.org and file:///etc/passwd');
      expect(scan.links, isEmpty);
    });
  });

  group('a link in somebody else\'s words', () {
    test('a quoted line is not treated as new', () {
      // The whole failure: a stranger's message is quoted into a conversation the
      // user is in, and the URL in it belongs to a third party the user never
      // chose to hear from. Fetching it contacts a tracker on their schedule.
      final scan = scanUrls('> look at this https://tracker.example/pixel');
      expect(scan.links, isEmpty);
      expect(scan.insideQuote, ['https://tracker.example/pixel']);
    });

    test('a reply is previewed for its own link, not the quoted one', () {
      // The reply is what this message is; the quote is a copy of an earlier
      // one that somebody else chose to put a URL in.
      final reply =
          '> https://tracker.example/p\nlook at https://example.org/a';
      final scan = scanUrls(reply);
      expect(scan.links, ['https://example.org/a']);
      expect(scan.insideQuote, ['https://tracker.example/p']);
    });

    test('a reply whose only link is quoted previews nothing', () {
      // The obvious objection: what if the reply *is* "look at this"? The answer
      // is the same, because the user can tap the link, which is visible and is
      // theirs to do. Previews are not how this client says yes.
      final onlyQuote = '> https://tracker.example/p\n\nlook at it';
      expect(scanUrls(onlyQuote).links, isEmpty);
    });

    test('a quoted link is still reported, so the UI can mention it', () {
      final scan = scanUrls('> https://tracker.example/p');
      expect(scan.distinctFound, 1);
      expect(scan.links, isEmpty);
    });

    test('a link the sender writes after the quote is theirs', () {
      // De-duplicated per region, not globally: quoting a link and then writing
      // it again is writing it again, and the second one is the sender's own.
      final scan = scanUrls('> https://example.com/a\nhttps://example.com/a');
      expect(scan.links, ['https://example.com/a']);
      expect(scan.insideQuote, ['https://example.com/a']);
    });

    test('three quote markers deep still counts as quoted', () {
      final scan = scanUrls('>>> https://example.com/a');
      expect(scan.links, isEmpty);
      expect(scan.insideQuote, ['https://example.com/a']);
    });
  });

  group('a link inside code', () {
    test('an inline code span is not shared, only offered', () {
      // A URL in backticks is text that *mentions* an address: a sample
      // endpoint, a log line, a signature. A card under it says "this is what they
      // are sharing", and they were not sharing that.
      final scan = scanUrls('try `curl https://api.example.com/v1` first');
      expect(scan.links, isEmpty);
      expect(scan.insideCode, ['https://api.example.com/v1']);
    });

    test('a fenced block is code throughout', () {
      final scan = scanUrls(
        '```\nhttps://example.com/a\nhttps://example.com/b\n```',
      );
      expect(scan.links, isEmpty);
      expect(scan.insideCode, [
        'https://example.com/a',
        'https://example.com/b',
      ]);
    });

    test('a link after the fence is the message\'s own', () {
      final scan = scanUrls(
        '```\nhttps://example.com/a\n```\nhttps://b.example/c',
      );
      expect(scan.links, ['https://b.example/c']);
    });

    test('an unmatched backtick swallows the rest of the line', () {
      // Wrong in the other direction this costs one stray character, and the cost
      // there is a request to a host nobody chose. Right this way it costs a
      // missing preview, which is recoverable.
      final scan = scanUrls('oops ` https://example.com/a');
      expect(scan.links, isEmpty);
      expect(scan.insideCode, ['https://example.com/a']);
    });

    test('code links do not spend the budget of real ones', () {
      // The cap bounds automatic fetching, and a code link is only ever fetched
      // after a tap. If they shared a budget, three sample URLs in a fence would
      // cost the message its real preview — a strange thing to have done to
      // somebody for free.
      final body = [
        '`https://a.example/1`',
        '`https://a.example/2`',
        '`https://a.example/3`',
        'https://real.example/x',
      ].join('\n');
      final scan = scanUrls(body);
      expect(scan.links, ['https://real.example/x']);
      expect(scan.insideCode.length, 3);
    });
  });

  group('the cap', () {
    String manyLinks(int n) =>
        List.generate(n, (i) => 'https://example.com/$i').join(' ');

    test('the first links are the ones kept', () {
      // The decision, so a reviewer can see it: reading order, first three. The
      // first link is the one a message is about when a person writes one, and
      // dropping it in favour of the tail would make "the link I sent first has
      // no preview" the ordinary outcome — which reads as a bug, and the reader
      // cannot tell a limit from a fault.
      final scan = scanUrls(manyLinks(5));
      expect(scan.links, [
        'https://example.com/0',
        'https://example.com/1',
        'https://example.com/2',
      ]);
    });

    test('the first one is not silently dropped', () {
      final scan = scanUrls(manyLinks(4));
      expect(scan.links.first, 'https://example.com/0');
      expect(scan.links, contains('https://example.com/0'));
    });

    test('what was left out is counted, so the UI can say so', () {
      // "Silently" is the operative word. A cap that quietly discards links makes
      // the message look like it had three of them.
      final scan = scanUrls(manyLinks(5));
      expect(scan.droppedForCap, isTrue);
      expect(scan.distinctFound, 5);
      expect(scan.links.length, lessThan(scan.distinctFound));
    });

    test('a message at the cap reports no truncation', () {
      // Otherwise the UI says "2 more links" over a message that has none, which
      // teaches users not to read that line.
      final scan = scanUrls(manyLinks(kMaxPreviewUrls));
      expect(scan.droppedForCap, isFalse);
      expect(scan.links.length, kMaxPreviewUrls);
    });

    test('the cap counts the sender\'s links only once each', () {
      // Four occurrences of the same three links is three links, not seven. If
      // duplicates consumed the budget, pasting the same link twice would cost
      // the message a preview of the next one.
      final scan = scanUrls('${manyLinks(3)} ${manyLinks(3)}');
      expect(scan.links.length, kMaxPreviewUrls);
      expect(scan.droppedForCap, isFalse);
    });
  });

  group('addresses this client will not fetch', () {
    test('the loopback interface, from a one-line message', () {
      // The worst thing that happens if this rule is missing: a stranger's
      // message reaches a service on the phone's own loopback.
      expect(scanUrls('http://127.0.0.1:8080/admin').links, isEmpty);
      expect(scanUrls('http://[::1]:9000/x').links, isEmpty);
      expect(scanUrls('http://localhost/x').links, isEmpty);
    });

    test('the router, and the rest of the local network', () {
      expect(scanUrls('http://192.168.1.1/').links, isEmpty);
      expect(scanUrls('http://10.0.0.5/').links, isEmpty);
      expect(scanUrls('http://172.16.4.4/').links, isEmpty);
    });

    test('the cloud metadata endpoint', () {
      // 169.254.169.254 hands out credentials to anything that asks, which is
      // the whole reason it is worth naming in a test.
      expect(
        scanUrls('http://169.254.169.254/latest/meta-data/').links,
        isEmpty,
      );
    });

    test('a hostname is not refused for being a name', () {
      // The refusal list is not the SSRF defence and must not be mistaken for it:
      // nothing here knows what a name resolves to. The fetcher has to check the
      // address it connected to, and a rule that refused all names would just be
      // a rule that breaks every link preview.
      expect(scanUrls('https://example.com/').links, ['https://example.com/']);
      expect(scanUrls('https://a.example.org/x?y=1#z').links, isNotEmpty);
    });

    test('userinfo, where the text and the address disagree quietly', () {
      // `https://archive.example@tracker.example` reads as archive.example to
      // anybody skimming it, and the request goes to tracker.example. Stripping
      // the userinfo would leave a URL we fetched that is not the one written.
      expect(
        scanUrls('https://archive.example@tracker.example/').links,
        isEmpty,
      );
    });

    test('an address longer than the limit is refused, not shortened', () {
      final long = 'https://example.com/${'a' * (kMaxUrlLength + 10)}';
      expect(scanUrls(long).links, isEmpty);
    });

    test('an element naming a private address is refused outright', () {
      expect(OutOfBandData.tryParse(url: 'http://192.168.0.1/'), isNull);
    });

    test('an empty or whitespace address is not an address', () {
      expect(OutOfBandData.tryParse(url: ''), isNull);
      expect(OutOfBandData.tryParse(url: '   '), isNull);
      expect(OutOfBandData.tryParse(url: null), isNull);
    });
  });

  group('adversarial input', () {
    test('percent signs are not a URL and do not blow up the scan', () {
      // `%%%` is not an address, and the first version of this scanner used a
      // pattern with a repetition that made a line of them take exponential time.
      final scan = scanUrls('%%% https://example.com/%%%');
      expect(scan.links, ['https://example.com/%%%']);
    });

    test('a long run of brackets is punctuation, not a hang', () {
      final body = 'https://example.com/a${')' * 5000}';
      final scan = scanUrls(body);
      expect(scan.links, ['https://example.com/a']);
    });

    test('a line of angle brackets is just a line', () {
      final scan = scanUrls('<' * 5000);
      expect(scan.links, isEmpty);
      expect(scan.distinctFound, 0);
    });

    test('a huge body does not produce a huge request count', () {
      // The cap is a bound on what one message can make the device do, so a body
      // full of links must not be a body full of fetches.
      final body = List.generate(
        2000,
        (i) => 'https://example.com/$i',
      ).join('\n');
      final scan = scanUrls(body);
      expect(scan.links.length, kMaxPreviewUrls);
      expect(scan.distinctFound, 2000);
      expect(scan.droppedForCap, isTrue);
    });

    test('a body that is only a scheme is not a URL', () {
      expect(scanUrls('https://').links, isEmpty);
      expect(scanUrls('http://').links, isEmpty);
    });

    test('a data: URI in the body is not a preview', () {
      expect(scanUrls('data:image/png;base64,AAAA').links, isEmpty);
    });

    test('an enormous title does not reach the card', () {
      final preview = mergePreview(
        detectedUrl: 'https://example.com/a',
        announced: OutOfBandData.tryParse(
          url: 'https://example.com/a',
          title: 'x' * (kMaxTitleLength + 1),
        ),
      )!;
      expect(preview.title, isNull);
      expect(preview.displayTitle, isEmpty);
    });

    test('a huge description that survives is still cut for drawing', () {
      // What we keep and what we draw are different decisions. If they were one,
      // a hostile sender would decide how much memory the bubble spends.
      final preview = mergePreview(
        detectedUrl: 'https://example.com/a',
        announced: OutOfBandData.tryParse(
          url: 'https://example.com/a',
          description: 'y' * (kMaxDescriptionLength - 1),
        ),
      )!;
      expect(preview.description!.length, kMaxDescriptionLength - 1);
      expect(
        preview.displayDescription.length,
        lessThanOrEqualTo(kMaxPreviewDescriptionChars),
      );
    });

    test('a negative size claim does not become a small one', () {
      final data = OutOfBandData.tryParse(
        url: 'https://example.com/a',
        size: -1,
      )!;
      expect(data.size, isNull);
    });

    test('a broken data URI yields no bytes rather than an exception', () {
      expect(
        thumbnailBytes(
          const OutOfBandThumbnail(uri: 'data:image/png;base64,%%%'),
        ),
        isNull,
      );
      expect(thumbnailBytes(const OutOfBandThumbnail(uri: 'data:,')), isNull);
      expect(
        thumbnailBytes(
          const OutOfBandThumbnail(uri: 'https://x.example/t.png'),
        ),
        isNull,
      );
      expect(thumbnailBytes(null), isNull);
    });

    test(
      'a thumbnail too big to decode is refused on the bytes, not the claim',
      () {
        // The claim and the bytes disagree often enough that the claim has to
        // lose: the limit bounds what this client allocates, and only the bytes
        // say what that is.
        final lying = OutOfBandThumbnail.inline(
          uri: 'https://x.example/t.png',
          bytes: List<int>.filled(kMaxInlineThumbnailBytes + 1, 0),
          size: 1,
        );
        expect(thumbnailBytes(lying), isNull);

        final modest = OutOfBandThumbnail.inline(
          uri: 'https://x.example/t.png',
          bytes: const [1, 2, 3],
          size: kMaxInlineThumbnailBytes * 100,
        );
        expect(thumbnailBytes(modest), isNotNull);
      },
    );
  });

  group('inline, on demand, or nothing', () {
    LinkPreview withTitle() => mergePreview(
      detectedUrl: 'https://example.com/a',
      announced: OutOfBandData.tryParse(
        url: 'https://example.com/a',
        title: 'Something',
      ),
    )!;

    test('a card that says more than the message is drawn inline', () {
      expect(
        onPolicy.display(context: plainContext, preview: withTitle()),
        PreviewDisplay.inline,
      );
    });

    test('a card holding only the URL is not', () {
      // A card with nothing but the address in it is the message again, and it
      // costs the reader a screen to learn nothing.
      final bare = mergePreview(detectedUrl: 'https://example.com/a')!;
      expect(
        onPolicy.display(context: plainContext, preview: bare),
        PreviewDisplay.onDemand,
      );
    });

    test('a card for an address the body never mentioned is not drawn inline', () {
      // The body is what the message is about. A picture drawn under a sentence
      // that never named the address is a picture of something the sender chose.
      final fromElement = mergePreview(
        detectedUrl: null,
        announced: OutOfBandData.tryParse(
          url: 'https://example.com/a',
          title: 'Something',
        ),
      )!;
      expect(
        onPolicy.display(context: plainContext, preview: fromElement),
        PreviewDisplay.onDemand,
      );
    });

    test('a code-span link is on demand, and still goes through the policy', () {
      // On demand is not a weaker `inline`: the fetch behind it runs the same
      // rules, and the only difference is that somebody has to press something.
      final policy = onPolicy;
      final preview = withTitle();
      expect(
        policy.display(
          context: plainContext,
          preview: preview,
          fromCodeSpan: true,
        ),
        PreviewDisplay.onDemand,
      );
      expect(
        policy.mayFetch(context: plainContext, url: preview.url),
        isA<PreviewAllowed>(),
      );
      expect(
        policy.mayFetch(
          context: const PreviewContext(sender: 'p@example.org', blocked: true),
          url: preview.url,
        ),
        isA<PreviewRefused>(),
      );
    });

    test('a thumbnail with no bytes we can decode is not drawn', () {
      // Drawing a picture we have to fetch first is a second request to a second
      // host, so a card that cannot be drawn without one waits for a tap.
      final preview = mergePreview(
        detectedUrl: 'https://example.com/a',
        announced: OutOfBandData.tryParse(
          url: 'https://example.com/a',
          title: 'Something',
          thumbnail: const OutOfBandThumbnail(uri: 'https://cdn.example/t.png'),
        ),
      )!;
      expect(
        onPolicy.display(context: plainContext, preview: preview),
        PreviewDisplay.onDemand,
      );
    });

    test('a small thumbnail is drawn', () {
      final preview = mergePreview(
        detectedUrl: 'https://example.com/a',
        announced: OutOfBandData.tryParse(
          url: 'https://example.com/a',
          thumbnail: OutOfBandThumbnail.inline(
            uri: 'data:image/png;base64,AAAA',
            bytes: const [1, 2, 3],
          ),
        ),
      )!;
      expect(
        onPolicy.display(context: plainContext, preview: preview),
        PreviewDisplay.inline,
      );
    });

    test('an on-demand preview is not fetched anyway', () async {
      // The button exists so that a request is not made before somebody asked
      // for one. A helper whose name does not mention buttons fetching them is
      // how that promise gets broken.
      final fetcher = RecordingFetcher();
      final loaded = await loadPreview(
        policy: onPolicy,
        fetcher: fetcher,
        body: 'https://example.com/a',
        context: plainContext,
      );
      expect(loaded, isNull);
      expect(fetcher.asked, isEmpty);
    });

    test('a blocked sender is not fetched even for an inline card', () async {
      // The combination that matters most: a card that *would* have been drawn,
      // from somebody the user blocked. Everything here says yes except the one
      // rule that must not bend.
      final fetcher = RecordingFetcher();
      final loaded = await loadPreview(
        policy: onPolicy,
        fetcher: fetcher,
        body: 'https://example.com/a',
        announced: OutOfBandData.tryParse(
          url: 'https://example.com/a',
          title: 'Something',
        ),
        context: const PreviewContext(sender: 'p@example.org', blocked: true),
      );
      expect(loaded, isNull);
      expect(fetcher.asked, isEmpty);
    });

    test('a message with nothing to show is not fetched', () async {
      // A request nobody asked for is still a request somebody's server can see.
      final fetcher = RecordingFetcher();
      expect(
        await loadPreview(
          policy: onPolicy,
          fetcher: fetcher,
          body: 'see https://example.com/a',
          context: plainContext,
        ),
        isNull,
      );
      expect(fetcher.asked, isEmpty);
    });
  });

  group('the plain case still works', () {
    test('a normal message is previewed', () async {
      // One happy path, and it is here so the refusals above cannot pass by
      // refusing everything. A policy that refuses all messages is a policy with
      // no bugs and no feature.
      final fetcher = RecordingFetcher();
      final loaded = await loadPreview(
        policy: onPolicy,
        fetcher: fetcher,
        body: 'have a look at https://example.com/post when you can',
        announced: OutOfBandData.tryParse(
          url: 'https://example.com/post',
          title: 'A post',
        ),
        context: plainContext,
      );
      expect(loaded, isNotNull);
      expect(loaded!.url, 'https://example.com/post');
      expect(loaded.title, 'A post');
      expect(fetcher.asked, ['https://example.com/post']);
    });

    test('and the policy allows it explicitly', () {
      final verdict = onPolicy.mayFetch(
        context: plainContext,
        url: 'https://example.com/',
      );
      expect(verdict, isA<PreviewAllowed>());
    });

    test('and nothing is allowed until the switch is turned on', () {
      // The one default in this file that is not "on", and it is pinned here
      // because it is the kind of default that gets quietly flipped to match the
      // rest of the industry. A feature whose whole job is to request a host a
      // stranger typed, from the user's phone, does not ship switched on.
      final verdict = LinkPreviewPolicy().mayFetch(
        context: plainContext,
        url: 'https://example.com/',
      );
      expect(verdict, isA<PreviewRefused>());
      expect(
        (verdict as PreviewRefused).reason,
        PreviewRefusal.previewsDisabled,
      );
    });
  });
}
