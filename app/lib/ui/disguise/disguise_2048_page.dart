// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Launch disguise: looks like 2048 (gabrielecirulli/2048). Swipe plays;
// tap a cell appends a PIN digit (0–9A–F); tap score submits; tap best clears.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../security/app_lock.dart';
import 'game_2048.dart';

class Disguise2048Page extends StatefulWidget {
  const Disguise2048Page({super.key, required this.onUnlocked});

  final VoidCallback onUnlocked;

  @override
  State<Disguise2048Page> createState() => _Disguise2048PageState();
}

class _Disguise2048PageState extends State<Disguise2048Page> {
  final _game = Game2048();
  final _pin = StringBuffer();
  Offset? _pointerDown;
  int? _downRow;
  int? _downCol;
  var _moveAnimating = false;
  Timer? _moveAnimTimer;

  static const _moveDuration = Duration(milliseconds: 90);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final t in _game.tiles) {
        t.isNew = false;
      }
    });
  }

  @override
  void dispose() {
    _moveAnimTimer?.cancel();
    super.dispose();
  }

  void _beginMoveAnimation() {
    _moveAnimating = true;
    _moveAnimTimer?.cancel();
    _moveAnimTimer = Timer(_moveDuration, () {
      if (!mounted) return;
      setState(() {
        _game.clearGhosts();
        _moveAnimating = false;
        for (final t in _game.tiles) {
          t.isNew = false;
        }
      });
    });
  }

  static const _tileColors = <int, Color>{
    2: Color(0xFFEEE4DA),
    4: Color(0xFFEDE0C8),
    8: Color(0xFFF2B179),
    16: Color(0xFFF59563),
    32: Color(0xFFF67C5F),
    64: Color(0xFFF65E3B),
    128: Color(0xFFEDCF72),
    256: Color(0xFFEDCC61),
    512: Color(0xFFEDC850),
    1024: Color(0xFFEDC53F),
    2048: Color(0xFFEDC22E),
  };

  Future<void> _submitPin() async {
    if (_pin.isEmpty) return;
    final ok = await AppLock.instance.tryUnlock(_pin.toString());
    if (!mounted) return;
    if (ok) {
      widget.onUnlocked();
    }
    // Wrong PIN: silent — do not tip the observer.
  }

  void _clearPin() {
    _pin.clear();
  }

  void _appendCell(int row, int col) {
    if (_pin.length >= 16) return;
    _pin.write(pinSymbolAt(row, col));
  }

  (int, int)? _cellAt(Offset local, Size boardSize) {
    const pad = 8.0;
    const gap = 8.0; // 4+4 padding around each tile
    final inner = boardSize.width - pad * 2;
    final cell = (inner - gap * 3) / 4;
    final x = local.dx - pad;
    final y = local.dy - pad;
    if (x < 0 || y < 0 || x > inner || y > inner) return null;
    final col = (x / (cell + gap)).floor().clamp(0, 3);
    final row = (y / (cell + gap)).floor().clamp(0, 3);
    return (row, col);
  }

  void _onPointerDown(PointerDownEvent e, Size boardSize) {
    _pointerDown = e.localPosition;
    final cell = _cellAt(e.localPosition, boardSize);
    _downRow = cell?.$1;
    _downCol = cell?.$2;
  }

  void _onPointerUp(PointerUpEvent e, Size boardSize) {
    final start = _pointerDown;
    _pointerDown = null;
    if (start == null) return;
    final delta = e.localPosition - start;
    if (delta.distance < 24) {
      // PIN taps still work during move animation.
      final row = _downRow;
      final col = _downCol;
      if (row != null && col != null) {
        _appendCell(row, col);
      }
      return;
    }
    // Wait out the slide — interrupting mid-flight skips tile animations.
    if (_moveAnimating) return;
    final dir = delta.dx.abs() > delta.dy.abs()
        ? (delta.dx > 0 ? Move2048.right : Move2048.left)
        : (delta.dy > 0 ? Move2048.down : Move2048.up);
    if (!_game.move(dir)) return;
    setState(_beginMoveAnimation);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          SystemNavigator.pop();
        }
      },
      child: Scaffold(
        backgroundColor: const Color(0xFFFAF8EF),
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        const Text(
                          '2048',
                          style: TextStyle(
                            fontSize: 48,
                            fontWeight: FontWeight.w800,
                            color: Color(0xFF776E65),
                            height: 1,
                          ),
                        ),
                        const Spacer(),
                        _ScoreBox(
                          label: 'SCORE',
                          value: _game.score,
                          onTap: () => unawaited(_submitPin()),
                        ),
                        const SizedBox(width: 8),
                        _ScoreBox(
                          label: 'BEST',
                          value: _game.best,
                          onTap: _clearPin,
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Join the numbers and get to the 2048 tile!',
                        style: TextStyle(
                          color: Color(0xFF776E65),
                          fontSize: 14,
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    AspectRatio(
                      aspectRatio: 1,
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final boardSize = Size(
                            constraints.maxWidth,
                            constraints.maxHeight,
                          );
                          return Listener(
                            behavior: HitTestBehavior.opaque,
                            onPointerDown: (e) =>
                                _onPointerDown(e, boardSize),
                            onPointerUp: (e) => _onPointerUp(e, boardSize),
                            onPointerCancel: (_) {
                              _pointerDown = null;
                              _downRow = null;
                              _downCol = null;
                            },
                            child: _AnimatedBoard(
                              game: _game,
                              colors: _tileColors,
                              moveDuration: _moveDuration,
                            ),
                          );
                        },
                      ),
                    ),
                    if (_game.over) ...[
                      const SizedBox(height: 12),
                      TextButton(
                        onPressed: () => setState(_game.reset),
                        child: const Text('Try again'),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AnimatedBoard extends StatelessWidget {
  const _AnimatedBoard({
    required this.game,
    required this.colors,
    required this.moveDuration,
  });

  final Game2048 game;
  final Map<int, Color> colors;
  final Duration moveDuration;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const pad = 8.0;
        const gap = 8.0;
        final side = constraints.maxWidth;
        final inner = side - pad * 2;
        final cell = (inner - gap * 3) / 4;

        double left(int x) => pad + x * (cell + gap);
        double top(int y) => pad + y * (cell + gap);

        return Container(
          decoration: BoxDecoration(
            color: const Color(0xFFBBADA0),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Stack(
            children: [
              for (var y = 0; y < 4; y++)
                for (var x = 0; x < 4; x++)
                  Positioned(
                    left: left(x),
                    top: top(y),
                    width: cell,
                    height: cell,
                    child: const DecoratedBox(
                      decoration: BoxDecoration(
                        color: Color(0xFFCDC1B4),
                        borderRadius: BorderRadius.all(Radius.circular(4)),
                      ),
                    ),
                  ),
              for (final tile in game.tiles)
                AnimatedPositioned(
                  key: ValueKey(tile.id),
                  duration: moveDuration,
                  curve: Curves.easeOut,
                  left: left(tile.x),
                  top: top(tile.y),
                  width: cell,
                  height: cell,
                  child: IgnorePointer(
                    child: _TileFace(
                      value: tile.value,
                      colors: colors,
                      popIn: tile.isNew,
                      ghost: tile.ghost,
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _ScoreBox extends StatelessWidget {
  const _ScoreBox({
    required this.label,
    required this.value,
    required this.onTap,
  });

  final String label;
  final int value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFFBBADA0),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Column(
          children: [
            Text(
              label,
              style: const TextStyle(
                color: Color(0xFFEEE4DA),
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
            Text(
              '$value',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TileFace extends StatelessWidget {
  const _TileFace({
    required this.value,
    required this.colors,
    this.popIn = false,
    this.ghost = false,
  });

  final int value;
  final Map<int, Color> colors;
  final bool popIn;
  final bool ghost;

  @override
  Widget build(BuildContext context) {
    final bg = colors[value] ?? const Color(0xFF3C3A32);
    final fg = value <= 4 ? const Color(0xFF776E65) : Colors.white;
    final face = Opacity(
      opacity: ghost ? 0.85 : 1,
      child: Container(
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(4),
        ),
        alignment: Alignment.center,
        child: Text(
          '$value',
          style: TextStyle(
            color: fg,
            fontSize: value < 100
                ? 28
                : value < 1000
                ? 22
                : 18,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
    if (!popIn) return face;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.0, end: 1.0),
      duration: const Duration(milliseconds: 90),
      curve: Curves.easeOut,
      builder: (context, t, child) => Transform.scale(scale: t, child: child),
      child: face,
    );
  }
}
