// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:resonchat/ui/disguise/game_2048.dart';

void main() {
  test('starts with two tiles', () {
    final g = Game2048(random: Random(1));
    var n = 0;
    for (var x = 0; x < 4; x++) {
      for (var y = 0; y < 4; y++) {
        if (g.at(x, y) != null) n++;
      }
    }
    expect(n, 2);
  });

  test('move can merge and raise score', () {
    final g = Game2048(random: Random(2));
    // Force a known board: clear then place two 2s in a row.
    for (var x = 0; x < 4; x++) {
      for (var y = 0; y < 4; y++) {
        g.cells[x][y] = null;
      }
    }
    g.cells[0][0] = Tile2048(0, 0, 2, id: 1);
    g.cells[1][0] = Tile2048(1, 0, 2, id: 2);
    final moved = g.move(Move2048.left);
    expect(moved, isTrue);
    expect(g.at(0, 0)?.value, 4);
    expect(g.score, 4);
  });

  test('consecutive right moves slide tiles far from the edge', () {
    final g = Game2048(random: Random(0));
    void clear() {
      for (var x = 0; x < 4; x++) {
        for (var y = 0; y < 4; y++) {
          g.cells[x][y] = null;
        }
      }
    }

    clear();
    g.cells[0][0] = Tile2048(0, 0, 2, id: 1);
    g.cells[3][0] = Tile2048(3, 0, 4, id: 2);
    expect(g.move(Move2048.right), isTrue);
    expect(g.at(2, 0)?.value, 2);
    expect(g.at(3, 0)?.value, 4);

    // Keep settled tiles; add a far-left spawn like addRandomTile would.
    final settled = g.tiles.where((t) => t.id == 1 || t.id == 2).toList();
    clear();
    for (final t in settled) {
      g.cells[t.x][t.y] = t;
    }
    g.cells[0][1] = Tile2048(0, 1, 2, id: 99);

    expect(g.move(Move2048.right), isTrue);
    expect(g.at(3, 1)?.value, 2, reason: 'far-left tile must slide right');
  });
}
