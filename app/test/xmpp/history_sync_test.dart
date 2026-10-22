// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:test/test.dart';

import 'package:resonchat/xmpp/history_sync.dart';

void main() {
  group('options stay finite', () {
    test('count choices are the round steps up to 5000', () {
      expect(HistorySyncSetting.countOptions, [
        50,
        100,
        200,
        500,
        1000,
        2000,
        5000,
      ]);
      expect(HistorySyncSetting.defaultCount, 500);
      expect(HistorySyncSetting.countOptions, contains(500));
      expect(HistorySyncSetting.countOptions.last, 5000);
    });

    test('day choices extend Gajim and stop at a year', () {
      expect(HistorySyncSetting.dayOptions.first, 1);
      expect(HistorySyncSetting.dayOptions, contains(90));
      expect(HistorySyncSetting.dayOptions.last, 365);
      expect(HistorySyncSetting.dayOptions, isNot(contains(0)));
    });

    test('zero days snaps to the shortest window, not unlimited', () {
      expect(HistorySyncSetting.snapDays(0), 1);
      expect(HistorySyncSetting.snapDays(400), 365);
      expect(HistorySyncSetting.snapDays(90), 90);
    });

    test('a count outside the list cannot mean unlimited', () {
      expect(HistorySyncSetting.snapCount(0), 50);
      expect(HistorySyncSetting.snapCount(9000), 5000);
      expect(HistorySyncSetting.snapCount(500), 500);
    });

    test('a missing mode is the default count of 500', () {
      final setting = HistorySyncSetting.fromStored();
      expect(setting.mode, HistorySyncMode.count);
      expect(setting.count, 500);
      expect(setting.days, HistorySyncSetting.defaultDays);
    });

    test('a stored no-threshold day value is rewritten to a real window', () {
      final setting = HistorySyncSetting.fromStored(mode: 'days', days: '0');
      expect(setting.mode, HistorySyncMode.days);
      expect(setting.days, 1);
    });
  });

  group('paging', () {
    test('days mode does not stop because of how many messages arrived', () {
      expect(
        historySyncShouldContinue(
          mode: HistorySyncMode.days,
          complete: false,
          fetched: 20000,
          cursorAdvanced: true,
          messageLimit: 500,
        ),
        isTrue,
      );
    });

    test('days mode stops when the archive is finished', () {
      expect(
        historySyncShouldContinue(
          mode: HistorySyncMode.days,
          complete: true,
          fetched: 10,
          cursorAdvanced: true,
        ),
        isFalse,
      );
    });

    test('count mode stops at the chosen limit', () {
      expect(
        historySyncShouldContinue(
          mode: HistorySyncMode.count,
          complete: false,
          fetched: 500,
          cursorAdvanced: true,
          messageLimit: 500,
        ),
        isFalse,
      );
      expect(
        historySyncShouldContinue(
          mode: HistorySyncMode.count,
          complete: false,
          fetched: 450,
          cursorAdvanced: true,
          messageLimit: 500,
        ),
        isTrue,
      );
    });

    test('off never asks for another page', () {
      expect(
        historySyncShouldContinue(
          mode: HistorySyncMode.off,
          complete: false,
          fetched: 0,
          cursorAdvanced: true,
        ),
        isFalse,
      );
    });

    test('a cursor that did not move stops either mode', () {
      expect(
        historySyncShouldContinue(
          mode: HistorySyncMode.days,
          complete: false,
          fetched: 50,
          cursorAdvanced: false,
        ),
        isFalse,
      );
    });
  });
}
