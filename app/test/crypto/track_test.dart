// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Track labelling.
//
// The rule these tests exist to protect: the mark under a message must be the
// track it actually used. Everything else — the negotiation, the fallback, the
// dialogs — is only trustworthy if this holds.
//
// A related consequence of the same rule: an inbound message's label comes
// from what the *sender* declared, not from whether we managed to open it.

import 'package:flutter_test/flutter_test.dart';
import 'package:moxxmpp/moxxmpp.dart' show ExplicitEncryptionType;
import 'package:resonchat/crypto/omemo/track.dart';
import 'package:resonchat/xmpp/eme.dart';

void main() {
  group('labels', () {
    test('each track has a distinct two-letter code', () {
      expect(Track.pq.label, 'O2');
      expect(Track.standard.label, 'OM');
      expect(Track.none.label, 'NO');
      expect(
        {Track.pq.label, Track.standard.label, Track.none.label}.length,
        3,
      );
    });

    test('each track has its own icon', () {
      expect(Track.pq.icon, isNot(Track.standard.icon));
      expect(Track.pq.icon, isNot(Track.none.icon));
      expect(Track.standard.icon, isNot(Track.none.icon));
    });

    test('each track explains itself without jargon alone', () {
      for (final track in Track.values) {
        expect(track.description, isNotEmpty);
      }
      expect(Track.pq.description, contains('monocles'));
      expect(Track.standard.description, contains('OMEMO'));
    });
  });

  group('EME namespace mapping', () {
    test('no declaration means plaintext', () {
      expect(Track.fromEme(null), Track.none);
    });

    test('our post-quantum namespace maps to OMEMO2', () {
      expect(Track.fromEme(ExplicitEncryptionType.pomemo0), Track.pq);
      expect(Track.pq.emeNamespace, 'urn:monocles:omemo-pq:1');
    });

    test('every OMEMO spelling maps to OM', () {
      // `omemo` is the namespace Conversations and Signal actually send; the
      // other two are the XEP-0384 spellings. Missing any of them would
      // label a real client's encrypted messages as unencrypted.
      expect(Track.fromEme(ExplicitEncryptionType.omemo), Track.standard);
      expect(Track.fromEme(ExplicitEncryptionType.omemo1), Track.standard);
      expect(Track.fromEme(ExplicitEncryptionType.omemo2), Track.standard);
    });

    test('a namespace we cannot read is not mislabelled as plaintext', () {
      // Claiming "NO" for an OTR message would tell the user their message
      // was readable by anyone, which is the opposite of the truth.
      for (final foreign in [
        ExplicitEncryptionType.otr,
        ExplicitEncryptionType.legacyOpenPGP,
        ExplicitEncryptionType.openPGP,
        ExplicitEncryptionType.unknown,
      ]) {
        expect(Track.fromEme(foreign), isNull, reason: '$foreign');
        expect(Track.isForeignEncryption(foreign), isTrue, reason: '$foreign');
      }
    });

    test('our own tracks are not treated as foreign', () {
      expect(
        Track.isForeignEncryption(ExplicitEncryptionType.pomemo0),
        isFalse,
      );
      expect(Track.isForeignEncryption(ExplicitEncryptionType.omemo), isFalse);
      expect(Track.isForeignEncryption(null), isFalse);
    });
  });

  group('outgoing EME element', () {
    test('carries the namespace of the track it was given', () {
      final xml = const EmeData(Track.pq, name: 'PQ OMEMO2').toXML().toXml();
      expect(xml, contains('urn:xmpp:eme:0'));
      expect(xml, contains('urn:monocles:omemo-pq:1'));
      expect(xml, contains('PQ OMEMO2'));
    });

    test('standard uses the namespace real clients send', () {
      final xml = const EmeData(Track.standard).toXML().toXml();
      expect(xml, contains('eu.siacs.conversations.axolotl'));
    });

    test('the name is optional', () {
      final xml = const EmeData(Track.standard).toXML().toXml();
      expect(xml, isNot(contains('name=')));
    });

    test('declaring encryption on a plaintext message is rejected', () {
      // A <encryption/> element with no namespace reads as a claim we cannot
      // back up, so this has to be impossible rather than merely discouraged.
      expect(() => EmeData(Track.none), throwsA(isA<AssertionError>()));
    });
  });

  group('stored tokens', () {
    test('the vocabulary is closed and lossless', () {
      for (final token in EncModeToken.values) {
        expect(EncModeToken.parse(token.wire), token);
      }
    });

    test('the column and the per-chat setting use one spelling', () {
      // Two vocabularies in one database is how a column ends up holding
      // 'pq' from an old build and 'PO' from a new one, and every read has
      // to guess which it got.
      for (final token in EncModeToken.values) {
        final track = token.track;
        if (track != null) expect(token.wire, track.stored);
      }
    });

    test('of() and parse() are inverses for every track', () {
      for (final track in Track.values) {
        expect(EncModeToken.parse(EncModeToken.of(track).wire).track, track);
      }
    });

    test('legacy values from earlier builds still resolve', () {
      // Without this, every message stored before the rename would silently
      // become "unencrypted" the next time it was read.
      expect(EncModeToken.parse('standardOmemo'), EncModeToken.standard);
      expect(EncModeToken.parse('pqOmemo'), EncModeToken.pq);
    });

    test('an unrecognised value falls back to none rather than throwing', () {
      expect(EncModeToken.parse(null), EncModeToken.none);
      expect(EncModeToken.parse('something-else'), EncModeToken.none);
      expect(EncModeToken.parse(''), EncModeToken.none);
    });

    test('error is a condition, not a track', () {
      expect(EncModeToken.error.track, isNull);
      expect(EncModeToken.none.track, Track.none);
      expect(EncModeToken.standard.track, Track.standard);
      expect(EncModeToken.pq.track, Track.pq);
    });
  });
}
