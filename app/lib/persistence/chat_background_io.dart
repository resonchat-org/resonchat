// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Native side of Conversations/monocles `ChatBackgroundHelper`:
// `{supportDir}/backgrounds/bg_<jid>.png`.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Conversations max edge before compress (~1920).
const kBackgroundMaxSide = 1920;

Future<Directory> _backgroundsDir() async {
  final root = await getApplicationSupportDirectory();
  final dir = Directory(p.join(root.path, 'backgrounds'));
  if (!await dir.exists()) await dir.create(recursive: true);
  return dir;
}

String _safeKey(String chatJid) =>
    chatJid.replaceAll(RegExp(r'[^A-Za-z0-9._@-]'), '_');

/// Absolute path for this chat's custom background (file may be absent).
Future<String> chatBackgroundPath(String chatJid) async {
  final dir = await _backgroundsDir();
  return p.join(dir.path, 'bg_${_safeKey(chatJid)}.png');
}

/// Path of an existing custom background, or null.
Future<String?> resolveChatBackground(String chatJid) async {
  final path = await chatBackgroundPath(chatJid);
  if (await File(path).exists()) return path;
  return null;
}

/// PNG bytes of an existing custom background, or null.
Future<Uint8List?> readChatBackground(String chatJid) async {
  final path = await resolveChatBackground(chatJid);
  if (path == null) return null;
  try {
    return await File(path).readAsBytes();
  } catch (_) {
    return null;
  }
}

/// Decode / downscale [raw] and write as PNG. Returns the path, or null.
Future<String?> saveChatBackground(String chatJid, Uint8List raw) async {
  final prepared = await prepareBackgroundImage(raw);
  if (prepared == null || prepared.isEmpty) return null;
  final path = await chatBackgroundPath(chatJid);
  await File(path).writeAsBytes(prepared, flush: true);
  return path;
}

Future<void> deleteChatBackground(String chatJid) async {
  try {
    final path = await chatBackgroundPath(chatJid);
    final file = File(path);
    if (await file.exists()) await file.delete();
  } catch (_) {}
}

/// Resize so the longest edge is at most [maxSide], then encode PNG.
Future<Uint8List?> prepareBackgroundImage(
  Uint8List raw, {
  int maxSide = kBackgroundMaxSide,
}) async {
  try {
    final probe = await ui.instantiateImageCodec(raw);
    final probeFrame = await probe.getNextFrame();
    final ow = probeFrame.image.width;
    final oh = probeFrame.image.height;
    probeFrame.image.dispose();
    if (ow <= 0 || oh <= 0) return null;

    final longest = math.max(ow, oh);
    final ui.Codec codec;
    if (longest > maxSide) {
      final scale = maxSide / longest;
      codec = await ui.instantiateImageCodec(
        raw,
        targetWidth: math.max(1, (ow * scale).round()),
        targetHeight: math.max(1, (oh * scale).round()),
      );
    } else {
      codec = await ui.instantiateImageCodec(raw);
    }
    final frame = await codec.getNextFrame();
    final image = frame.image;
    final bd = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return bd?.buffer.asUint8List();
  } catch (_) {
    return null;
  }
}
