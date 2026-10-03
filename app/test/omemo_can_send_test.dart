// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Whether an outgoing OMEMO stanza may be sent.
//
// This lives in `app/test/` rather than only in the package's own suite for one
// reason: `dart test` inside `packages/omemo_dart` has to resolve dependencies
// from pub.dev, and this environment's egress blocks it, so a test written only
// there would never run and therefore never guard anything. The app resolves the
// package from a path, so this one actually executes.
//
// It reaches into the package's `src/` on purpose. That is not the tidy import
// for a published package, and it is the right one here: the rule under test is
// the guarantee we make about an outgoing message, and exposing it through the
// package's public API purely so a test can name it would widen the API surface
// to serve the test rather than the caller.

import 'package:omemo_dart/src/errors.dart';
import 'package:omemo_dart/src/omemo/encryption_result.dart';
import 'package:omemo_dart/src/omemo/errors.dart';
import 'package:test/test.dart';

void main() {
  const peer = 'peer@example.org';
  const mine = 'me@example.org';

  EncryptToJidError failure([int? device]) =>
      EncryptToJidError(device, NoKeyMaterialAvailableError());

  bool canSend(
    List<String> recipients,
    Map<String, int> successes, [
    Map<String, List<EncryptToJidError>> errors = const {},
  ]) =>
      canSendAllDevicesReached(recipients, successes, errors);

  group('a result nobody could reach is not sendable', () {
    test('no recipients at all is not a success', () {
      // `every` over an empty map is vacuously true, which is why the recipient
      // set is an argument rather than being inferred from the counts. This is
      // the encrypt-to-nobody case: a stanza that leaves carrying ciphertext no
      // recipient holds a key for.
      expect(canSend(const [], {}), isFalse);
    });

    test('a recipient reached zero times is not a success', () {
      expect(canSend([peer], {peer: 0}), isFalse);
    });

    test('a recipient missing from the counts is not a success', () {
      // Never attempted, which is not the same as attempted-and-failed — and is
      // indistinguishable from it to anything reading the result by key.
      expect(canSend([peer], {mine: 3}), isFalse);
    });
  });

  group('a fully reached recipient is sendable', () {
    test('one device, no errors', () {
      expect(canSend([peer], {peer: 1}), isTrue);
    });

    test('many devices, no errors', () {
      expect(canSend([peer], {peer: 40}), isTrue);
    });

    test('the carbons copy of our own JID counts as a recipient too', () {
      // Both JIDs are addressed, so both have to be reached. Failing only the
      // self-copy would mean our own other devices get no message.
      expect(canSend([peer, mine], {peer: 2, mine: 0}), isFalse);
      expect(canSend([peer, mine], {peer: 2, mine: 1}), isTrue);
    });
  });

  group('a partial result is refused, which is the whole point', () {
    test('39 of 40 devices reached is not sendable', () {
      // The failure this rule exists for. "At least one device per recipient"
      // passes this — 39 > 0 — and it is exactly the case that produced a stanza
      // Conversations could not open, because the one device it needed was the
      // one that failed. On the sending side it looked completely healthy: a
      // bubble, a delivery receipt, a track label saying OMEMO.
      expect(
        canSend(
          [peer],
          {peer: 39},
          {
            peer: [failure(40)],
          },
        ),
        isFalse,
      );
    });

    test('1 of 2 is not sendable', () {
      expect(
        canSend([peer], {peer: 1}, {peer: [failure(2)]}),
        isFalse,
      );
    });

    test('an error against any recipient at all refuses the send', () {
      // Including one that is not the peer. moxxmpp reads the peer's own error
      // entry to pick its cancel reason, so an error recorded only against the
      // carbons copy used to reach a null-check crash; the refusal has to hold
      // for the whole stanza either way.
      expect(
        canSend([peer, mine], {peer: 2, mine: 1}, {mine: [failure(7)]}),
        isFalse,
      );
    });

    test('an error entry with no device id still refuses', () {
      // `NoKeyMaterialAvailableError` is recorded with a null device id, so the
      // entry exists and must not be filtered out by inspecting its contents.
      expect(
        canSend([peer], {peer: 1}, {peer: [failure()]}),
        isFalse,
      );
    });
  });

  group('the rule is total — every input gives one answer', () {
    test('exhaustive over the small input space', () {
      // Sampled testing of a predicate misses exactly the combination nobody
      // thought of, and this input space is small enough to enumerate: 0..2
      // successes for each of two recipients × error present/absent.
      for (var p = 0; p <= 2; p++) {
        for (var m = 0; m <= 2; m++) {
          for (final withErrors in [false, true]) {
            final verdict = canSend(
              [peer, mine],
              {peer: p, mine: m},
              withErrors ? {peer: [failure(9)]} : const {},
            );
            expect(
              verdict,
              !withErrors && p > 0 && m > 0,
              reason: 'peer=$p mine=$m errors=$withErrors',
            );
          }
        }
      }
    });
  });
}