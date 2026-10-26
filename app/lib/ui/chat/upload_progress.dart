// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// In-memory HTTP upload progress for one outgoing file bubble.
// Keyed by stanza id. Cleared when the PUT finishes or fails.

import 'package:flutter_riverpod/flutter_riverpod.dart';

class FileUploadProgress {
  const FileUploadProgress({required this.sent, required this.total});

  final int sent;
  final int total;

  /// 0..1. Unknown or empty totals stay at 0 so the bar can still render.
  double get fraction {
    if (total <= 0) return 0;
    final value = sent / total;
    if (value < 0) return 0;
    if (value > 1) return 1;
    return value;
  }
}

final fileUploadProgressProvider =
    StateProvider.family<FileUploadProgress?, String>((ref, stanzaId) => null);
