// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter_test/flutter_test.dart';
import 'package:resonchat/xmpp/message_expiry.dart';

void main() {
  group('AutomaticMessageDeletion', () {
    test('fromStored maps Conversations second values', () {
      expect(
        AutomaticMessageDeletion.fromStored('0'),
        AutomaticMessageDeletion.never,
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
        AutomaticMessageDeletion.fromStored('2592000'),
        AutomaticMessageDeletion.thirtyDays,
      );
      expect(
        AutomaticMessageDeletion.fromStored('15811200'),
        AutomaticMessageDeletion.sixMonths,
      );
    });

    test('unknown or empty storage fails closed to never', () {
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

    test('cutoff is now minus duration; never has none', () {
      expect(AutomaticMessageDeletion.never.cutoffAt(), isNull);
      final now = DateTime.utc(2026, 10, 9, 12);
      final cut = AutomaticMessageDeletion.oneDay.cutoffAt(now)!;
      expect(cut, DateTime.utc(2026, 10, 8, 12));
    });
  });
}
