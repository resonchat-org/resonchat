// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Whether the home shell (`/chats`) is still in the root stack.
// Landscape draws its rail outside that stack, so the flag has to live on
// the navigator, not inside the shell route.

import 'package:flutter/widgets.dart';

/// Tracks if `/chats` is under the current route.
///
/// A page pushed on top does not clear it: the shell is still there, and the
/// landscape rail stays beside the new page.
class ShellChrome extends NavigatorObserver {
  final visible = ValueNotifier<bool>(false);

  int _depth = 0;
  bool _want = false;
  bool _scheduled = false;

  void _change(Route<dynamic>? route, int delta) {
    if (route?.settings.name != '/chats') return;
    _depth += delta;
    if (_depth < 0) _depth = 0;
    _want = _depth > 0;
    if (visible.value == _want || _scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (visible.value != _want) visible.value = _want;
    });
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _change(route, 1);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _change(route, -1);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _change(route, -1);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    _change(oldRoute, -1);
    _change(newRoute, 1);
  }
}
