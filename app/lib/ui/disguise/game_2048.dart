// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Compact port of gabrielecirulli/2048 GameManager (MIT), for the disguise UI.

import 'dart:math';

enum Move2048 { up, right, down, left }

class Tile2048 {
  Tile2048(this.x, this.y, this.value, {required this.id, this.isNew = false});

  final int id;
  int x;
  int y;
  int value;
  bool merged = false;

  /// Fresh spawn — UI can briefly scale in.
  bool isNew;

  /// Sliding into a merge target; removed after the move animation.
  bool ghost = false;
}

class Game2048 {
  Game2048({this.size = 4, Random? random}) : _random = random ?? Random() {
    reset();
  }

  final int size;
  final Random _random;
  int _nextId = 1;

  late List<List<Tile2048?>> cells;
  final List<Tile2048> _ghosts = [];
  int score = 0;
  int best = 0;
  bool over = false;
  bool won = false;

  /// Merge ghosts first (under), then grid tiles (for slide-into-merge).
  List<Tile2048> get tiles {
    final out = <Tile2048>[..._ghosts];
    for (final col in cells) {
      for (final t in col) {
        if (t != null) out.add(t);
      }
    }
    return out;
  }

  void reset() {
    cells = List.generate(size, (_) => List<Tile2048?>.filled(size, null));
    _ghosts.clear();
    score = 0;
    over = false;
    won = false;
    addRandomTile();
    addRandomTile();
  }

  /// Drop merge ghosts after the UI animation finishes.
  void clearGhosts() => _ghosts.clear();

  Tile2048? at(int x, int y) {
    if (x < 0 || x >= size || y < 0 || y >= size) return null;
    return cells[x][y];
  }

  bool move(Move2048 direction) {
    if (over) return false;
    _ghosts.clear();
    for (final row in cells) {
      for (final t in row) {
        t?.merged = false;
      }
    }
    final vector = switch (direction) {
      Move2048.up => (x: 0, y: -1),
      Move2048.right => (x: 1, y: 0),
      Move2048.down => (x: 0, y: 1),
      Move2048.left => (x: -1, y: 0),
    };
    // Must copy before reverse — `list.reversed` views the same storage,
    // so `setAll(0, list.reversed)` corrupts the order (e.g. [3,2,2,3]).
    final xs = vector.x == 1
        ? List<int>.generate(size, (i) => size - 1 - i)
        : List<int>.generate(size, (i) => i);
    final ys = vector.y == 1
        ? List<int>.generate(size, (i) => size - 1 - i)
        : List<int>.generate(size, (i) => i);

    var moved = false;
    for (final x in xs) {
      for (final y in ys) {
        final tile = cells[x][y];
        if (tile == null) continue;
        var cx = x;
        var cy = y;
        late int px;
        late int py;
        do {
          px = cx;
          py = cy;
          cx = px + vector.x;
          cy = py + vector.y;
        } while (cx >= 0 &&
            cx < size &&
            cy >= 0 &&
            cy < size &&
            cells[cx][cy] == null);

        final next = (cx >= 0 && cx < size && cy >= 0 && cy < size)
            ? cells[cx][cy]
            : null;
        if (next != null && next.value == tile.value && !next.merged) {
          cells[x][y] = null;
          // Slide the source into the merge cell, then drop it after anim.
          tile
            ..x = cx
            ..y = cy
            ..ghost = true
            ..isNew = false;
          _ghosts.add(tile);
          next
            ..value = tile.value * 2
            ..merged = true
            ..isNew = false;
          score += next.value;
          if (score > best) best = score;
          if (next.value == 2048) won = true;
          moved = true;
        } else if (px != x || py != y) {
          cells[x][y] = null;
          tile
            ..x = px
            ..y = py
            ..isNew = false;
          cells[px][py] = tile;
          moved = true;
        }
      }
    }

    if (moved) {
      addRandomTile();
      if (!_movesAvailable()) over = true;
    }
    return moved;
  }

  void addRandomTile() {
    final empty = <(int, int)>[];
    for (var x = 0; x < size; x++) {
      for (var y = 0; y < size; y++) {
        if (cells[x][y] == null) empty.add((x, y));
      }
    }
    if (empty.isEmpty) return;
    final (x, y) = empty[_random.nextInt(empty.length)];
    cells[x][y] = Tile2048(
      x,
      y,
      _random.nextDouble() < 0.9 ? 2 : 4,
      id: _nextId++,
      isNew: true,
    );
  }

  bool _movesAvailable() {
    for (var x = 0; x < size; x++) {
      for (var y = 0; y < size; y++) {
        if (cells[x][y] == null) return true;
        final v = cells[x][y]!.value;
        if (at(x + 1, y)?.value == v || at(x, y + 1)?.value == v) {
          return true;
        }
      }
    }
    return false;
  }
}
