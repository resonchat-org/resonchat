// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Lossless strip of removable image metadata (EXIF / XMP / IPTC-ish / PNG
// text) for the "check tracking before send" preference.
//
// Pixels are never re-encoded: JPEG markers / PNG chunks / WebP chunks are
// walked and copied, dropping only known metadata containers. Unsupported
// containers (HEIC, …) are left unchanged.

import 'dart:convert';
import 'dart:typed_data';

/// True when [bytes] look like an image that carries removable metadata.
bool imageHasRemovableMetadata(Uint8List bytes) {
  if (_isJpeg(bytes)) return _jpegHasRemovable(bytes);
  if (_isPng(bytes)) return _pngHasRemovable(bytes);
  if (_isWebp(bytes)) return _webpHasRemovable(bytes);
  return false;
}

/// Returns [bytes] with removable metadata dropped when present and the
/// format is supported; otherwise returns [bytes] unchanged.
///
/// Work stays in memory — callers already hold the attachment as bytes for
/// HTTP upload, so no temp file is required.
Uint8List stripImageMetadata(Uint8List bytes) {
  if (_isJpeg(bytes)) return _stripJpeg(bytes) ?? bytes;
  if (_isPng(bytes)) return _stripPng(bytes) ?? bytes;
  if (_isWebp(bytes)) return _stripWebp(bytes) ?? bytes;
  return bytes;
}

/// When remove-tracking is on: strip if metadata is present, else pass through.
Uint8List prepareImageBytesForSend(Uint8List bytes) {
  if (!imageHasRemovableMetadata(bytes)) return bytes;
  return stripImageMetadata(bytes);
}

bool _isJpeg(Uint8List b) => b.length >= 2 && b[0] == 0xff && b[1] == 0xd8;

bool _isPng(Uint8List b) {
  if (b.length < 8) return false;
  return b[0] == 0x89 &&
      b[1] == 0x50 &&
      b[2] == 0x4e &&
      b[3] == 0x47 &&
      b[4] == 0x0d &&
      b[5] == 0x0a &&
      b[6] == 0x1a &&
      b[7] == 0x0a;
}

bool _isWebp(Uint8List b) {
  if (b.length < 12) return false;
  return b[0] == 0x52 &&
      b[1] == 0x49 &&
      b[2] == 0x46 &&
      b[3] == 0x46 &&
      b[8] == 0x57 &&
      b[9] == 0x45 &&
      b[10] == 0x42 &&
      b[11] == 0x50;
}

// ── JPEG ─────────────────────────────────────────────────

bool _jpegHasRemovable(Uint8List input) {
  var found = false;
  _walkJpeg(input, (marker, payload) {
    if (_dropJpegSegment(marker, payload)) found = true;
  });
  return found;
}

Uint8List? _stripJpeg(Uint8List input) {
  final out = BytesBuilder(copy: false);
  out.add([0xff, 0xd8]);
  var changed = false;
  var ok = true;
  var i = 2;
  while (i + 1 < input.length) {
    if (input[i] != 0xff) {
      ok = false;
      break;
    }
    while (i < input.length && input[i] == 0xff) {
      i++;
    }
    if (i >= input.length) break;
    final marker = input[i++];
    if (marker == 0xd9) {
      out.add([0xff, 0xd9]);
      break;
    }
    if (marker == 0xda) {
      // Entropy-coded scan through EOF — APP segments are before SOS.
      out.add([0xff, 0xda]);
      out.add(input.sublist(i));
      break;
    }
    // Standalone markers (RST / TEM).
    if ((marker >= 0xd0 && marker <= 0xd7) || marker == 0x01) {
      out.add([0xff, marker]);
      continue;
    }
    if (i + 1 >= input.length) {
      ok = false;
      break;
    }
    final len = (input[i] << 8) | input[i + 1];
    if (len < 2 || i + len > input.length) {
      ok = false;
      break;
    }
    final payload = input.sublist(i + 2, i + len);
    if (_dropJpegSegment(marker, payload)) {
      changed = true;
    } else {
      out.add([0xff, marker]);
      out.add(input.sublist(i, i + len));
    }
    i += len;
  }
  if (!ok) return null;
  return changed ? out.toBytes() : input;
}

void _walkJpeg(
  Uint8List input,
  void Function(int marker, Uint8List payload) onSegment,
) {
  var i = 2;
  while (i + 1 < input.length) {
    if (input[i] != 0xff) return;
    while (i < input.length && input[i] == 0xff) {
      i++;
    }
    if (i >= input.length) return;
    final marker = input[i++];
    if (marker == 0xd9 || marker == 0xda) return;
    if ((marker >= 0xd0 && marker <= 0xd7) || marker == 0x01) continue;
    if (i + 1 >= input.length) return;
    final len = (input[i] << 8) | input[i + 1];
    if (len < 2 || i + len > input.length) return;
    onSegment(marker, input.sublist(i + 2, i + len));
    i += len;
  }
}

bool _dropJpegSegment(int marker, Uint8List payload) {
  // COM — free-form comments.
  if (marker == 0xfe) return true;
  // APP13 — Photoshop / IPTC resource block.
  if (marker == 0xed) return true;
  if (marker != 0xe1) return false; // APP1
  if (payload.length >= 6 &&
      payload[0] == 0x45 &&
      payload[1] == 0x78 &&
      payload[2] == 0x69 &&
      payload[3] == 0x66 &&
      payload[4] == 0x00 &&
      payload[5] == 0x00) {
    return true; // Exif\0\0
  }
  // XMP packet in APP1.
  final head = payload.length > 29 ? payload.sublist(0, 29) : payload;
  final asLatin = latin1.decode(head, allowInvalid: true);
  if (asLatin.startsWith('http://ns.adobe.com/xap/') ||
      asLatin.startsWith('XMP\x00')) {
    return true;
  }
  return false;
}

// ── PNG ──────────────────────────────────────────────────

const _pngDropTypes = {'eXIf', 'tEXt', 'iTXt', 'zTXt', 'tIME'};

bool _pngHasRemovable(Uint8List input) {
  var found = false;
  _walkPng(input, (type, _, _) {
    if (_pngDropTypes.contains(type)) found = true;
  });
  return found;
}

Uint8List? _stripPng(Uint8List input) {
  final out = BytesBuilder(copy: false);
  out.add(input.sublist(0, 8));
  var changed = false;
  var ok = true;
  _walkPng(input, (type, start, end) {
    if (!ok) return;
    if (_pngDropTypes.contains(type)) {
      changed = true;
      return;
    }
    out.add(input.sublist(start, end));
  }, onError: () => ok = false);
  if (!ok) return null;
  return changed ? out.toBytes() : input;
}

void _walkPng(
  Uint8List input,
  void Function(String type, int start, int end) onChunk, {
  void Function()? onError,
}) {
  var i = 8;
  while (i + 12 <= input.length) {
    final length =
        (input[i] << 24) |
        (input[i + 1] << 16) |
        (input[i + 2] << 8) |
        input[i + 3];
    if (length < 0 || i + 12 + length > input.length) {
      onError?.call();
      return;
    }
    final type = String.fromCharCodes(input.sublist(i + 4, i + 8));
    final end = i + 12 + length;
    onChunk(type, i, end);
    i = end;
    if (type == 'IEND') return;
  }
}

// ── WebP ─────────────────────────────────────────────────

bool _webpHasRemovable(Uint8List input) {
  var found = false;
  _walkWebp(input, (fourcc, _, _) {
    if (fourcc == 'EXIF' || fourcc == 'XMP ') found = true;
  });
  return found;
}

Uint8List? _stripWebp(Uint8List input) {
  final kept = <List<int>>[];
  var changed = false;
  var ok = true;
  _walkWebp(input, (fourcc, start, end) {
    if (!ok) return;
    if (fourcc == 'EXIF' || fourcc == 'XMP ') {
      changed = true;
      return;
    }
    if (fourcc == 'VP8X' && end - start >= 18) {
      // Clear EXIF / XMP present flags (bits 3 and 2 of the flags byte).
      final chunk = Uint8List.fromList(input.sublist(start, end));
      final before = chunk[8];
      chunk[8] = before & ~0x0c;
      if (chunk[8] != before) changed = true;
      kept.add(chunk);
      return;
    }
    kept.add(input.sublist(start, end));
  }, onError: () => ok = false);
  if (!ok) return null;
  if (!changed) return input;

  var payload = 4; // 'WEBP'
  for (final c in kept) {
    payload += c.length;
  }
  final out = BytesBuilder(copy: false);
  out.add(ascii.encode('RIFF'));
  out.add(_u32le(payload));
  out.add(ascii.encode('WEBP'));
  for (final c in kept) {
    out.add(c);
  }
  return out.toBytes();
}

void _walkWebp(
  Uint8List input,
  void Function(String fourcc, int start, int end) onChunk, {
  void Function()? onError,
}) {
  if (!_isWebp(input)) {
    onError?.call();
    return;
  }
  final riffSize =
      input[4] | (input[5] << 8) | (input[6] << 16) | (input[7] << 24);
  var i = 12;
  final end = 8 + riffSize;
  if (end > input.length) {
    onError?.call();
    return;
  }
  while (i + 8 <= end) {
    final fourcc = String.fromCharCodes(input.sublist(i, i + 4));
    final size =
        input[i + 4] |
        (input[i + 5] << 8) |
        (input[i + 6] << 16) |
        (input[i + 7] << 24);
    final dataEnd = i + 8 + size;
    final padded = dataEnd + (size.isOdd ? 1 : 0);
    if (padded > end) {
      onError?.call();
      return;
    }
    onChunk(fourcc, i, padded);
    i = padded;
  }
}

List<int> _u32le(int v) => [
  v & 0xff,
  (v >> 8) & 0xff,
  (v >> 16) & 0xff,
  (v >> 24) & 0xff,
];
