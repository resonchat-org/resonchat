// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resonchat/ui/theme.dart';

void main() {
  testWidgets('EncBadge shows the track label with a lock icon',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: EncBadge(label: 'PQ', locked: true)),
      ),
    );
    expect(find.text('PQ'), findsOneWidget);
    expect(find.byIcon(Icons.lock), findsOneWidget);
  });

  testWidgets('EncBadge shows an open lock when unencrypted', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: EncBadge(label: 'Unencrypted', locked: false)),
      ),
    );
    expect(find.byIcon(Icons.lock_open), findsOneWidget);
  });
}