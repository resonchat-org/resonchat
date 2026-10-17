// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter_test/flutter_test.dart';
import 'package:resonchat/security/app_lock.dart';

void main() {
  test('PIN symbols map top-left → bottom-right', () {
    expect(pinSymbolAt(0, 0), '0');
    expect(pinSymbolAt(0, 3), '3');
    expect(pinSymbolAt(1, 0), '4');
    expect(pinSymbolAt(3, 3), 'F');
  });

  test('isValidAppLockPin accepts 4–16 hex digits', () {
    expect(isValidAppLockPin('0123'), isTrue);
    expect(isValidAppLockPin('abcd'), isTrue);
    expect(isValidAppLockPin('0123456789ABCDEF'), isTrue);
    expect(isValidAppLockPin('01'), isFalse);
    expect(isValidAppLockPin('0123456789ABCDEF0'), isFalse);
    expect(isValidAppLockPin('12G4'), isFalse);
  });

  test('hashAppLockPin is case-insensitive', () async {
    final a = await hashAppLockPin('abcd');
    final b = await hashAppLockPin('ABCD');
    expect(a, b);
    expect(a.length, 64);
  });
}
