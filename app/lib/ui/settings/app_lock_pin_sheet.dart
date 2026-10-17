// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Set / confirm the app-lock PIN. Digits are 0–9A–F (16 board cells).

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../security/app_lock.dart';

/// Returns the confirmed PIN, or null if cancelled.
Future<String?> showAppLockPinSheet(BuildContext context) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    builder: (_) => const _AppLockPinSheet(),
  );
}

class _AppLockPinSheet extends StatefulWidget {
  const _AppLockPinSheet();

  @override
  State<_AppLockPinSheet> createState() => _AppLockPinSheetState();
}

class _AppLockPinSheetState extends State<_AppLockPinSheet> {
  final _first = StringBuffer();
  final _second = StringBuffer();
  var _confirming = false;
  String? _error;

  String get _active =>
      (_confirming ? _second : _first).toString().toUpperCase();

  void _append(String symbol) {
    final buf = _confirming ? _second : _first;
    if (buf.length >= 16) return;
    setState(() {
      buf.write(symbol);
      _error = null;
    });
  }

  void _backspace() {
    final buf = _confirming ? _second : _first;
    if (buf.isEmpty) return;
    setState(() {
      final s = buf.toString();
      buf
        ..clear()
        ..write(s.substring(0, s.length - 1));
      _error = null;
    });
  }

  void _nextOrFinish() {
    final l10n = context.l10n;
    if (!_confirming) {
      if (!isValidAppLockPin(_first.toString())) {
        setState(() => _error = l10n.appLockPinInvalid);
        return;
      }
      setState(() {
        _confirming = true;
        _error = null;
      });
      return;
    }
    if (_first.toString().toUpperCase() != _second.toString().toUpperCase()) {
      setState(() {
        _second.clear();
        _error = l10n.appLockPinMismatch;
      });
      return;
    }
    Navigator.of(context).pop(_first.toString().toUpperCase());
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                _confirming ? l10n.appLockPinConfirm : l10n.appLockPinSet,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 4),
              Text(
                l10n.appLockPinHint,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              Text(
                _active.isEmpty ? '·' : _active,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 22,
                  letterSpacing: 4,
                  fontWeight: FontWeight.w600,
                  fontFamily: 'monospace',
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontSize: 13,
                  ),
                ),
              ],
              const SizedBox(height: 12),
              for (var row = 0; row < 4; row++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    children: [
                      for (var col = 0; col < 4; col++)
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 3),
                            child: FilledButton.tonal(
                              onPressed: () => _append(pinSymbolAt(row, col)),
                              child: Text(pinSymbolAt(row, col)),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              Row(
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(l10n.cancel),
                  ),
                  TextButton(
                    onPressed: _backspace,
                    child: Text(l10n.appLockPinDelete),
                  ),
                  const Spacer(),
                  FilledButton(
                    onPressed: _nextOrFinish,
                    child: Text(
                      _confirming ? l10n.appLockPinSave : l10n.appLockPinNext,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
