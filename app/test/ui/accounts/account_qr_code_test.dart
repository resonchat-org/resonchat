// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';

import 'package:resonchat/l10n/l10n.dart';
import 'package:resonchat/ui/accounts/account_qr_code.dart';

void main() {
  testWidgets('paints the account QR', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(
          body: AccountQrCode(data: 'xmpp:user@example.com?omemo-sid-1=ab'),
        ),
      ),
    );
    expect(find.byType(AccountQrCode), findsOneWidget);
    expect(find.bySemanticsLabel('QR code'), findsOneWidget);
  });
}
