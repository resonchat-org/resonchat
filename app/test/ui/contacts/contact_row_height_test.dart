// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Contact rows share one height: one-line shortcuts and two-line rows
// (title plus a single second line) both use the chat-list row height.

import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';

import 'package:resonchat/l10n/l10n.dart';
import 'package:resonchat/ui/contacts/contacts_tiles.dart';
import 'package:resonchat/ui/dialog_cell.dart';
import 'package:resonchat/ui/theme.dart';

Widget wrap(Widget child) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: AppThemeTokens.light(),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  locale: const Locale('zh'),
  home: Scaffold(body: child),
);

void main() {
  testWidgets('one-line and two-line contact rows are the same height', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        Column(
          children: [
            ContactActionTile(
              icon: Icons.person_add_outlined,
              title: '添加联系人',
              onTap: () {},
            ),
            AddJidTile(jid: 'alice@example.com', onTap: () {}),
            AddGroupTile(jid: 'room@conference.example.com', onTap: () {}),
            const GroupsBookmarkEntry(count: 2),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    final heights = tester
        .renderObjectList<RenderBox>(find.byType(DialogCell))
        .map((box) => box.size.height)
        .toList();
    expect(heights, hasLength(4));
    expect(heights.toSet(), {AppDimens.chatsRowHeight});
  });
}
