// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter_test/flutter_test.dart';

import 'package:resonchat/untracker/rule.dart';
import 'package:resonchat/untracker/rules.dart';
import 'package:resonchat/untracker/untracker.dart';
import 'package:resonchat/untracker/url.dart';

void main() {
  group('normalizeUrlString', () {
    test('collapses empty path segments', () {
      expect(
        normalizeUrlString('https://example.com/a//b'),
        'https://example.com/a/b',
      );
    });

    test('keeps query and fragment', () {
      expect(
        normalizeUrlString('https://example.com/a//b?x=1#f'),
        'https://example.com/a/b?x=1#f',
      );
    });
  });

  group('path regularization is not tracking', () {
    test('inspect ignores // → / alone', () {
      final u = Untracker('see https://example.com/foo//bar');
      expect(u.inspect(), isFalse);
    });

    test('untrack keeps original // when only normalizing', () async {
      const body = 'see https://example.com/foo//bar please';
      final result = await Untracker(body).untrack();
      expect(result.changed, isFalse);
      expect(result.text, body);
    });

    test('utm tracking still detected after normalize', () {
      final u = Untracker(
        'https://example.com/foo//bar?utm_source=x&utm_medium=y',
      );
      expect(u.inspect(), isTrue);
    });

    test('untrack removes utm and uses cleaned path', () async {
      final result = await Untracker(
        'https://example.com/foo//bar?utm_source=x',
      ).untrack();
      expect(result.changed, isTrue);
      expect(result.text, 'https://example.com/foo/bar');
    });
  });

  group('builtin rules', () {
    test('youtube retains v and list', () {
      final rules = builtinUntrackRules();
      final yt = rules.firstWhere((r) => r.description.contains('Youtube'));
      final url = TrackUrl(
        'https://www.youtube.com/watch?v=abc&list=PL1&si=track&feature=share',
      );
      expect(yt.inspect(url), isTrue);
      final cleaned = (yt as LocalUntrackRule).clean(url);
      expect(cleaned.contains('v=abc'), isTrue);
      expect(cleaned.contains('list=PL1'), isTrue);
      expect(cleaned.contains('si='), isFalse);
      expect(cleaned.contains('feature='), isFalse);
    });

    test('x strips query', () {
      final rules = builtinUntrackRules();
      final x = rules.firstWhere((r) => r.description.contains('X ('));
      final url = TrackUrl('https://x.com/user/status/1?s=20&t=abc');
      expect(x.inspect(url), isTrue);
      expect((x as LocalUntrackRule).clean(url), 'https://x.com/user/status/1');
    });

    test('short link inspect without fetch', () {
      final u = Untracker('https://b23.tv/abc123');
      expect(u.inspect(), isTrue);
    });

    test('network failure surfaces after inspect', () async {
      Future<
        ({int status, Map<String, String> headers, String body, String url})
      >
      failingFetch(String url, {required bool followRedirects}) async {
        throw Exception('offline');
      }

      final u = Untracker('https://b23.tv/abc123', fetch: failingFetch);
      expect(u.inspect(), isTrue);
      await expectLater(u.untrack(), throwsA(isA<Exception>()));
    });
  });
}
