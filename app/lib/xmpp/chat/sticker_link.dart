// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// When a saved sticker may be sent with the link already stored for one
// encryption mode. The three modes do not share a link or a clock.

import 'package:cryptography/cryptography.dart';

/// Which send path a sticker link belongs to.
///
/// Plaintext uploads are `https://`. OMEMO and PQ uploads are `aesgcm://`.
/// A link from one mode is never reused for another.
enum StickerSendKind { plain, omemo, pq }

/// How long a stored upload stays sendable before it is uploaded again.
const Duration stickerLinkMaxAge = Duration(days: 30);

/// True when [url] was stored for [kind] and is still inside [stickerLinkMaxAge].
///
/// An empty URL is none: nothing has been uploaded for this mode yet. A link
/// whose scheme belongs to a different mode is also unused, so a plaintext
/// `https://` URL cannot be sent as an encrypted sticker.
bool stickerLinkUsable({
  required String url,
  required DateTime? uploadedAt,
  required StickerSendKind kind,
  required DateTime now,
}) {
  final trimmed = url.trim();
  if (trimmed.isEmpty || uploadedAt == null) return false;
  final schemeOk = switch (kind) {
    StickerSendKind.plain => trimmed.startsWith('https://'),
    StickerSendKind.omemo ||
    StickerSendKind.pq => trimmed.startsWith('aesgcm://'),
  };
  if (!schemeOk) return false;
  final age = now.difference(uploadedAt);
  if (age.isNegative) return true;
  return age <= stickerLinkMaxAge;
}

/// SHA-256 of the image bytes, lowercase hex.
///
/// Two stickers are the same picture when this matches. Mime and file name
/// are not part of the hash.
Future<String> stickerContentHash(List<int> bytes) async {
  final digest = await Sha256().hash(bytes);
  final out = StringBuffer();
  for (final b in digest.bytes) {
    out.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return out.toString();
}

/// What [AppDatabase.addSticker] did.
class StickerSave {
  const StickerSave({required this.id, required this.hashMatched});

  final int id;

  /// An existing row already had this exact image hash.
  final bool hashMatched;
}

/// File name used when a sticker is uploaded for the first time on a mode.
String stickerUploadName(int id, String mime) {
  final ext = switch (mime.toLowerCase()) {
    'image/jpeg' || 'image/jpg' => 'jpg',
    'image/gif' => 'gif',
    'image/webp' => 'webp',
    _ => 'png',
  };
  return 'sticker-$id.$ext';
}
