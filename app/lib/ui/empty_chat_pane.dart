// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Side pane when no conversation is selected (FluffyChat `EmptyPage`).

import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import 'theme.dart';

class EmptyChatPane extends StatelessWidget {
  const EmptyChatPane({super.key});

  @override
  Widget build(BuildContext context) {
    final tg = context.tg;
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        elevation: 0,
        backgroundColor: Colors.transparent,
      ),
      extendBodyBehindAppBar: true,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.forum_outlined,
                size: 72,
                color: tg.textSecondary.withValues(alpha: 0.45),
              ),
              const SizedBox(height: 16),
              Text(
                l10n.selectConversation,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 16, color: tg.textSecondary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
