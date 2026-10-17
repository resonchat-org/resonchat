// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Startup used to run straight through `main()` before `runApp`. Anything that
// threw on the way — an unreadable keystore, a database that refused to open
// unencrypted, storage that is simply not there — produced a process with no
// window and no message: the reason existed only in logcat. These tests hold the
// replacement: the failure reaches a person, and it can be retried.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resonchat/main.dart';

/// A boot that fails, standing in for the platform-touching real one — which
/// cannot run here at all (its first step, `getApplicationDocumentsDirectory`,
/// never completes without a real platform behind it).
Future<StartupResult> _failingBoot() async {
  throw StateError(
    'The database key is unavailable, so /data/.../resonchat.sqlite3 cannot be '
    'opened. Not falling back to an unencrypted database.',
  );
}

void main() {
  testWidgets('a startup failure is explained on screen, not swallowed', (
    tester,
  ) async {
    await tester.pumpWidget(const StartupGate(boot: _failingBoot));
    await tester.pumpAndSettle();

    expect(find.text('ResonChat could not start'), findsOneWidget);
    expect(
      find.textContaining('will not fall back to storing it unencrypted'),
      findsOneWidget,
    );
    expect(find.widgetWithText(FilledButton, 'Try again'), findsOneWidget);
  });

  testWidgets('the failure screen carries the underlying reason', (
    tester,
  ) async {
    // A bug report needs the actual exception, not a paraphrase of it.
    await tester.pumpWidget(const StartupGate(boot: _failingBoot));
    await tester.pumpAndSettle();

    expect(find.text('Technical details'), findsOneWidget);
    expect(
      tester.widget<SelectableText>(find.byType(SelectableText)).data,
      contains('Not falling back to an unencrypted database'),
    );
  });

  testWidgets('retrying runs the boot again', (tester) async {
    var attempts = 0;
    await tester.pumpWidget(
      StartupGate(
        boot: () {
          attempts++;
          return _failingBoot();
        },
      ),
    );
    await tester.pumpAndSettle();
    expect(attempts, 1);

    await tester.tap(find.widgetWithText(FilledButton, 'Try again'));
    await tester.pumpAndSettle();
    expect(attempts, 2, reason: 'the button must actually retry');
    // Still on the failure screen, since this boot failed too. The point is
    // that an attempt happened without a relaunch.
    expect(find.text('ResonChat could not start'), findsOneWidget);
  });

  testWidgets('booting shows progress rather than a blank window', (
    tester,
  ) async {
    // A boot that never finishes is not an error, and must not look like one.
    final gate = StartupGate(boot: () => Completer<StartupResult>().future);
    await tester.pumpWidget(gate);
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Try again'), findsNothing);
  });
}
