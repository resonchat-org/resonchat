// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter_test/flutter_test.dart';

import 'package:resonchat/xmpp/message_expiry.dart';

void main() {
  group('AutomaticMessageDeletion', () {
    test('fromStored uses Gajim seconds, never is -1', () {
      expect(
        AutomaticMessageDeletion.fromStored('-1'),
        AutomaticMessageDeletion.never,
      );
      expect(
        AutomaticMessageDeletion.fromStored('0'),
        AutomaticMessageDeletion.untilClosed,
      );
      expect(
        AutomaticMessageDeletion.fromStored('86400'),
        AutomaticMessageDeletion.oneDay,
      );
      expect(
        AutomaticMessageDeletion.fromStored('604800'),
        AutomaticMessageDeletion.oneWeek,
      );
      expect(
        AutomaticMessageDeletion.fromStored('2629743'),
        AutomaticMessageDeletion.oneMonth,
      );
      expect(
        AutomaticMessageDeletion.fromStored('7889229'),
        AutomaticMessageDeletion.threeMonths,
      );
      expect(
        AutomaticMessageDeletion.fromStored('15778458'),
        AutomaticMessageDeletion.sixMonths,
      );
      expect(
        AutomaticMessageDeletion.fromStored('31556926'),
        AutomaticMessageDeletion.oneYear,
      );
    });

    test('unknown or empty storage is never', () {
      expect(
        AutomaticMessageDeletion.fromStored(null),
        AutomaticMessageDeletion.never,
      );
      expect(
        AutomaticMessageDeletion.fromStored(''),
        AutomaticMessageDeletion.never,
      );
      expect(
        AutomaticMessageDeletion.fromStored('999'),
        AutomaticMessageDeletion.never,
      );
    });

    test('slider order puts until-closed first and never last', () {
      expect(
        AutomaticMessageDeletion.values.first,
        AutomaticMessageDeletion.untilClosed,
      );
      expect(
        AutomaticMessageDeletion.values.last,
        AutomaticMessageDeletion.never,
      );
      expect(AutomaticMessageDeletion.never.seconds, -1);
      expect(AutomaticMessageDeletion.untilClosed.seconds, 0);
    });

    test('until-closed is not swept while the app is open', () {
      expect(AutomaticMessageDeletion.never.cutoffAt(), isNull);
      expect(AutomaticMessageDeletion.untilClosed.cutoffAt(), isNull);
      final now = DateTime.utc(2026, 10, 9, 12);
      expect(AutomaticMessageDeletion.untilClosed.shutdownCutoff(now), now);
      expect(AutomaticMessageDeletion.never.shutdownCutoff(now), isNull);
      final cut = AutomaticMessageDeletion.oneDay.cutoffAt(now)!;
      expect(cut, DateTime.utc(2026, 10, 8, 12));
      expect(AutomaticMessageDeletion.oneDay.shutdownCutoff(now), cut);
    });
  });
}
