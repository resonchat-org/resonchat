// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Avatars (XEP-0084) on the pubsub avatar node, plus helpers shared with
// MUC vCard PHOTO publishing.
//
// Publish path: prepareAvatarImage → publishOwnAvatar (account) or
// VCardManager.publishPhoto (room). Fetch / cache / fallback live here too.
//
// "No avatar" must not look like "this person chose to hide their face": the
// UI draws the circle in the contact's own accent colour rather than a uniform
// grey, so an absent avatar reads as *unknown* instead of *refused*.

import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cryptography/cryptography.dart';

import 'package:moxlib/moxlib.dart';
import 'package:moxxmpp/moxxmpp.dart';

import '../store/database.dart';

/// The shared SHA-1 used for XEP-0084 item ids.
///
/// One instance rather than one per call: this runs on the chat-list path, and
/// a fresh hash context per avatar fetch is exactly the wrong shape for it.
/// (XEP-0084 specifies SHA-1 for the item id; it is an identifier here, not a
/// security decision.)
final _sha1 = Sha1();

/// One contact's avatar, as bytes plus the facts we need to cache it.
class AvatarData {
  const AvatarData({required this.bytes, required this.mimeType});

  final Uint8List bytes;
  final String mimeType;

  /// The XEP-0084 item id: the SHA-1 of the data, lowercase hex.
  ///
  /// Used as the pubsub item id, which is how a change is detected at all — a
  /// republished identical avatar produces no notification, and a changed one
  /// produces exactly one. It therefore has to be the hash of the *bytes* and
  /// not of the base64 text, whose line breaks are transport detail.
  Future<String> get hash async =>
      (await _sha1.hash(bytes)).bytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();

  String get base64 => base64Encode(bytes);
}

/// Fetches [jid]'s avatar, or null when they have none or it cannot be read.
///
/// Null rather than an exception for every failure, because "we could not tell"
/// and "they have none" lead to the same UI and treating them differently would
/// mean an error state for something that is completely ordinary.
///
/// [id] is the pubsub item id, which is the SHA-1 of the avatar bytes. It has
/// to come from the *metadata* node: fetching the data node needs an item id,
/// and the only place that publishes one is the metadata.
Future<AvatarData?> fetchAvatar(
  UserAvatarManager manager,
  JID jid, {
  required String id,
  int timeoutSeconds = 8,
}) async {
  final result = await manager
      .getUserAvatarData(jid, id)
      .timeout(
        Duration(seconds: timeoutSeconds),
        // A timeout is an ordinary outcome here — peers without avatars answer
        // slowly or not at all — so it becomes the same "no avatar" the UI already
        // knows how to draw, rather than an exception on the chat-list path.
        onTimeout: () =>
            Result<AvatarError, UserAvatarData>(UnknownAvatarError()),
      );
  if (!result.isType<UserAvatarData>()) return null;
  final data = result.get<UserAvatarData>();
  try {
    final bytes = Uint8List.fromList(data.data);
    if (bytes.isEmpty) return null;
    return AvatarData(bytes: bytes, mimeType: sniffMimeType(bytes));
  } catch (_) {
    // A malformed base64 payload from the other end. Showing the initial
    // letter is a fine outcome for a corrupt avatar.
    return null;
  }
}

/// The item id of [jid]'s current avatar, or null when they have none.
///
/// Two round trips, and the first one usually comes back empty: most contacts
/// have not published an avatar, and asking for one item id per contact on the
/// chat-list path is a query storm. So this is done once per contact and
/// cached, and only the ones that answer are fetched again.
Future<String?> latestAvatarId(
  UserAvatarManager manager,
  JID jid, {
  int timeoutSeconds = 8,
}) async {
  final result = await manager
      .getLatestMetadata(jid)
      .timeout(
        Duration(seconds: timeoutSeconds),
        onTimeout: () =>
            Result<AvatarError, List<UserAvatarMetadata>>(UnknownAvatarError()),
      );
  if (!result.isType<List<UserAvatarMetadata>>()) return null;
  final items = result.get<List<UserAvatarMetadata>>();
  if (items.isEmpty) return null;
  // Newest first. The metadata node keeps every avatar the user ever
  // published, so taking the first entry we are given without ordering is how a
  // client ends up permanently showing somebody's 2019 haircut.
  return items.first.id;
}

/// The image type, guessed from the magic bytes.
///
/// Not from the pubsub metadata: that field is supplied by whoever published
/// the avatar, and trusting it means a peer can make this client hand a blob to
/// the image decoder that claims to be something else. The bytes are what
/// actually get decoded, so they are what decides.
String sniffMimeType(List<int> bytes) {
  if (bytes.length >= 3 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E) {
    return 'image/png';
  }
  if (bytes.length >= 3 &&
      bytes[0] == 0xFF &&
      bytes[1] == 0xD8 &&
      bytes[2] == 0xFF) {
    return 'image/jpeg';
  }
  if (bytes.length >= 6 &&
      bytes[0] == 0x47 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x38 &&
      (bytes[4] == 0x37 || bytes[4] == 0x39) &&
      bytes[5] == 0x61) {
    return 'image/gif';
  }
  if (bytes.length >= 12 &&
      bytes[0] == 0x52 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x46 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50) {
    return 'image/webp';
  }
  return 'application/octet-stream';
}

/// Decode / downscale [raw] to a square PNG suitable for XEP-0084 / vCard.
///
/// Returns null when the bytes are not a decodable image.
Future<AvatarData?> prepareAvatarImage(
  Uint8List raw, {
  int maxSide = 192,
}) async {
  try {
    final codec = await ui.instantiateImageCodec(
      raw,
      targetWidth: maxSide,
      targetHeight: maxSide,
    );
    final frame = await codec.getNextFrame();
    final image = frame.image;
    final bd = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (bd == null) return null;
    final bytes = bd.buffer.asUint8List();
    if (bytes.isEmpty) return null;
    return AvatarData(bytes: bytes, mimeType: 'image/png');
  } catch (_) {
    return null;
  }
}

/// Publishes [avatar] as our own, visible to [public] contacts.
Future<bool> publishOwnAvatar(
  UserAvatarManager manager,
  AvatarData avatar, {
  bool public = true,
}) async {
  final hash = await avatar.hash;
  final result = await manager.publishUserAvatar(avatar.base64, hash, public);
  if (!result.isType<bool>()) return false;
  // The metadata is a second publish. Skipping it does not break the avatar on
  // clients that fall back to reading the data node, but leaves this one showing
  // no size or type, which some clients use to decide whether to fetch at all.
  final meta = await manager.publishUserAvatarMetadata(
    UserAvatarMetadata(
      hash,
      avatar.bytes.length,
      0, // Width unknown; generated images are square by construction.
      0,
      avatar.mimeType,
      // No URL: the data is inline. Advertising an empty one makes some clients
      // try to fetch it and show nothing.
      '',
    ),
    public,
  );
  return meta.isType<bool>();
}

/// vCard-temp PHOTO for a contact or MUC occupant (XEP-0153 / Gajim).
///
/// Pass a bare JID for a contact or the room itself. Pass a full
/// `room@server/nick` for an occupant — Gajim keys participant avatars that
/// way; baring would fetch the room photo instead.
Future<AvatarData?> fetchVCardAvatar(VCardManager manager, JID jid) async {
  final result = await manager.requestVCard(jid);
  if (!result.isType<VCard>()) return null;
  final binval = result.get<VCard>().photo?.binval;
  if (binval == null || binval.isEmpty) return null;
  try {
    final compact = binval.replaceAll(RegExp(r'\s'), '');
    final bytes = Uint8List.fromList(base64Decode(compact));
    if (bytes.isEmpty) return null;
    return AvatarData(bytes: bytes, mimeType: sniffMimeType(bytes));
  } catch (_) {
    return null;
  }
}

/// Records that [jid]'s avatar changed so the next view re-fetches it.
///
/// The hash is stored rather than the bytes: the point of the hash is that it
/// changes exactly when the image does, so a re-fetch is only needed when the
/// notification says so.
Future<void> noteAvatarChanged(AppDatabase db, String jid, String hash) async {
  await db.setMetaValue('avatar:$jid', hash);
}

/// The last known avatar hash for [jid], or null when never seen.
Future<String?> lastAvatarHash(AppDatabase db, String jid) =>
    db.metaValue('avatar:$jid');

/// The initial letter shown when there is no avatar.
///
/// Uses the nickname when the contact has one, so "Alex Chen" gives A rather
/// than the X of a bare JID — the whole point of a nickname is that it should
/// be what identifies the person.
String avatarInitial(String title, String jid) {
  final source = title.trim().isNotEmpty ? title.trim() : jid;
  if (source.isEmpty) return '?';
  // Find the first letter rather than taking source[0]: a nickname in Chinese,
  // Japanese or Korean starts with a character whose first UTF-16 unit is a
  // lone surrogate, and `substring(0, 1)` on that produces a broken glyph.
  for (final rune in source.runes) {
    if (_isLetter(rune)) return String.fromCharCode(rune).toUpperCase();
  }
  return String.fromCharCode(source.runes.first).toUpperCase();
}

bool _isLetter(int rune) {
  // Latin, Greek, Cyrillic, Hebrew, Arabic and the CJK-ish ranges we actually
  // meet. Numbers and punctuation are skipped so a nickname like "404" still
  // falls through to something readable rather than showing "4".
  return (rune >= 0x41 && rune <= 0x5A) ||
      (rune >= 0x61 && rune <= 0x7A) ||
      (rune >= 0xC0 && rune <= 0x24F) ||
      (rune >= 0x370 && rune <= 0x5FF) ||
      (rune >= 0x600 && rune <= 0x6FF) ||
      (rune >= 0x4E00 && rune <= 0x9FFF) ||
      (rune >= 0x3040 && rune <= 0x30FF) ||
      (rune >= 0xAC00 && rune <= 0xD7AF);
}
