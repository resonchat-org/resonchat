// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Keeps stacked `/chat` routes and column-mode [selectedChatKeyProvider] in
// sync when the window crosses the wide-layout breakpoint.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../account/chat_ref.dart';
import '../state/providers.dart';
import 'column_mode.dart';

/// Watches viewport width and remaps navigation when entering/leaving column
/// mode (narrow push `/chat` ↔ wide side pane).
class ColumnModeSync extends ConsumerStatefulWidget {
  const ColumnModeSync({
    super.key,
    required this.navigatorKey,
    required this.child,
  });

  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;

  @override
  ConsumerState<ColumnModeSync> createState() => _ColumnModeSyncState();
}

class _ColumnModeSyncState extends ConsumerState<ColumnModeSync> {
  bool? _wasWide;

  @override
  Widget build(BuildContext context) {
    final wide = isColumnMode(context);
    if (_wasWide != wide) {
      final previous = _wasWide;
      _wasWide = wide;
      if (previous != null) {
        final from = previous;
        final to = wide;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _onBreakpointChanged(fromWide: from, toWide: to);
        });
      }
    }
    return widget.child;
  }

  void _onBreakpointChanged({required bool fromWide, required bool toWide}) {
    final nav = widget.navigatorKey.currentState;
    if (nav == null) return;

    if (!fromWide && toWide) {
      _absorbStackedChatIntoColumn(nav);
    } else if (fromWide && !toWide) {
      _pushSelectedChatOntoStack(nav);
    }
  }

  /// Narrow → wide: pop `/chat` (and anything above `/chats`) into the side pane.
  void _absorbStackedChatIntoColumn(NavigatorState nav) {
    String? chatKey;
    nav.popUntil((route) {
      if (route.settings.name == '/chat') {
        chatKey = _chatKeyOf(route.settings.arguments);
      }
      return route.settings.name == '/chats' || route.isFirst;
    });
    if (chatKey != null && chatKey!.isNotEmpty) {
      ref.read(selectedChatKeyProvider.notifier).state = chatKey;
    }
  }

  /// Wide → narrow: keep the open conversation via a stacked `/chat` route.
  void _pushSelectedChatOntoStack(NavigatorState nav) {
    final key = ref.read(selectedChatKeyProvider);
    if (key == null || key.isEmpty) return;

    // Already showing a stacked chat (e.g. search push) — leave it.
    var topIsChat = false;
    nav.popUntil((route) {
      topIsChat = route.settings.name == '/chat';
      return true;
    });
    if (topIsChat) return;

    nav.pushNamed('/chat', arguments: key);
  }

  static String? _chatKeyOf(Object? arguments) {
    if (arguments is String && arguments.isNotEmpty) return arguments;
    if (arguments is ChatRef) return arguments.key;
    return null;
  }
}
