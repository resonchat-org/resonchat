// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Track selection against live capability data. The invariant under test
// is the one that matters most: never pick a track a recipient device
// cannot read.

import 'package:flutter_test/flutter_test.dart';
import 'package:moxxmpp/moxxmpp.dart';
import 'package:resonchat/crypto/omemo/negotiation.dart';
import 'package:resonchat/crypto/omemo/protocol.dart';

void main() {
  group('decideEncMode invariants', () {
    test('a chat with only our own device still encrypts', () {
      // We are the only device: our own key can read it, so OMEMO is
      // safe even though no peer bundle was fetched.
      expect(
        decideEncMode(
          allDevices: {100},
          pqCapable: const {},
          omemoCapable: {100},
        ),
        EncMode.standardOmemo,
      );
    });

    test('one PQ-capable peer device alone is not enough to upgrade', () {
      // Our own device (100) has no PQ bundle, so the chat must stay on
      // the interoperable track: the PQ track would send our own device
      // a message it cannot open.
      expect(
        decideEncMode(
          allDevices: {100, 7},
          pqCapable: {7},
          omemoCapable: {100, 7},
        ),
        EncMode.standardOmemo,
      );
    });

    test('upgrades only when every device, ours included, is PQ-capable', () {
      expect(
        decideEncMode(
          allDevices: {100, 7},
          pqCapable: {100, 7},
          omemoCapable: {100, 7},
        ),
        EncMode.pqOmemo,
      );
    });

    test('adding a non-PQ peer device downgrades to OMEMO, not to none', () {
      // Regression guard for docs/02 §6 "模式变更": the chat must stay
      // encrypted for everyone, just on the interoperable track.
      expect(
        decideEncMode(
          allDevices: {100, 7, 8},
          pqCapable: {7},
          omemoCapable: {100, 7, 8},
        ),
        EncMode.standardOmemo,
      );
    });

    test('an unknown device blocks encryption entirely', () {
      expect(
        decideEncMode(
          allDevices: {100, 99},
          pqCapable: {100},
          omemoCapable: {100},
        ),
        EncMode.none,
      );
    });

    test('devices outside the chat are ignored in both directions', () {
      // A stale capability cache listing devices that left the chat must
      // neither block nor spuriously upgrade.
      expect(
        decideEncMode(
          allDevices: {100, 7},
          pqCapable: {100, 7, 42},
          omemoCapable: {100, 7},
        ),
        EncMode.pqOmemo,
      );
      expect(
        decideEncMode(
          allDevices: {100, 7},
          pqCapable: {42},
          omemoCapable: {100, 7},
        ),
        EncMode.standardOmemo,
      );
    });

    test('never reports PQ while any device is on neither track', () {
      for (final all in <Set<int>>[
        {1, 2, 3},
        {1},
        {1, 2},
      ]) {
        // Last device omitted from both capability sets → unreachable.
        final omemo = (all.toList()..removeLast()).toSet();
        final mode = decideEncMode(
          allDevices: all,
          pqCapable: omemo, // still missing the last id
          omemoCapable: omemo,
        );
        expect(
          mode,
          EncMode.none,
          reason: 'all=$all omemo=$omemo must block, not pick a track',
        );
      }
    });
  });

  group('label', () {
    test('encModeLabel is stable and human readable', () {
      expect(encModeLabel(EncMode.pqOmemo), 'OMEMO2');
      expect(encModeLabel(EncMode.standardOmemo), 'OMEMO');
      expect(encModeLabel(EncMode.none), 'Unencrypted');
    });
  });

  group('jid handling', () {
    test('bare JIDs compare equal to their full forms', () {
      expect(
        JID.fromString('a@b/c').toBare().toString(),
        JID.fromString('a@b').toString(),
      );
    });
  });
}
