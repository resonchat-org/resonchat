// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Chat transcript background: pattern painter or monocles-style custom image.

import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../utils/appearance.dart';
import '../../utils/chat_background.dart';

/// Fills the transcript area with [appearance]'s wallpaper.
class ChatWallpaper extends StatefulWidget {
  const ChatWallpaper({
    super.key,
    required this.chatJid,
    required this.appearance,
    required this.base,
    required this.accent,
    required this.child,
    this.imageEpoch = 0,
  });

  final String chatJid;
  final ChatAppearance appearance;
  final Color base;
  final Color accent;
  final Widget child;

  /// Bumped when the on-disk custom image may have changed.
  final int imageEpoch;

  @override
  State<ChatWallpaper> createState() => _ChatWallpaperState();
}

class _ChatWallpaperState extends State<ChatWallpaper> {
  Future<Uint8List?>? _customBytes;

  @override
  void initState() {
    super.initState();
    _loadIfCustom();
  }

  @override
  void didUpdateWidget(covariant ChatWallpaper oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.chatJid != widget.chatJid ||
        oldWidget.appearance.wallpaper != widget.appearance.wallpaper ||
        oldWidget.imageEpoch != widget.imageEpoch) {
      _loadIfCustom();
    }
  }

  void _loadIfCustom() {
    if (widget.appearance.wallpaper == Wallpaper.custom) {
      _customBytes = readChatBackground(widget.chatJid);
    } else {
      _customBytes = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.appearance.wallpaper != Wallpaper.custom) {
      return ColoredBox(
        color: widget.base,
        child: CustomPaint(
          painter: WallpaperPainter(
            wallpaper: widget.appearance.wallpaper,
            base: widget.base,
            accent: widget.accent,
            seed: widget.chatJid,
          ),
          child: widget.child,
        ),
      );
    }

    return FutureBuilder<Uint8List?>(
      future: _customBytes,
      builder: (context, snap) {
        final bytes = snap.data;
        if (bytes == null || bytes.isEmpty) {
          return ColoredBox(color: widget.base, child: widget.child);
        }
        return Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: widget.base),
            Image.memory(
              bytes,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            ),
            widget.child,
          ],
        );
      },
    );
  }
}
