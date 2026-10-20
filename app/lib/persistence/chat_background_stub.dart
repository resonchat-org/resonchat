// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Web / non-IO stub — custom chat backgrounds are native-only.

import 'dart:typed_data';

const kBackgroundMaxSide = 1920;

Future<String> chatBackgroundPath(String chatJid) async =>
    'bg_${chatJid.hashCode}.png';

Future<String?> resolveChatBackground(String chatJid) async => null;

Future<Uint8List?> readChatBackground(String chatJid) async => null;

Future<String?> saveChatBackground(String chatJid, Uint8List raw) async => null;

Future<void> deleteChatBackground(String chatJid) async {}

Future<Uint8List?> prepareBackgroundImage(
  Uint8List raw, {
  int maxSide = kBackgroundMaxSide,
}) async => null;
