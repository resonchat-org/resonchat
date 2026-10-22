// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:resonchat/untracker/image_metadata.dart';

void main() {
  group('JPEG', () {
    test('no APP1 Exif → unchanged and not flagged', () {
      // SOI + APP0 (JFIF) + EOI — no Exif.
      final jpeg = Uint8List.fromList([
        0xff,
        0xd8,
        0xff,
        0xe0,
        0x00,
        0x10,
        ...ascii.encode('JFIF\x00'),
        0x01,
        0x01,
        0x00,
        0x00,
        0x01,
        0x00,
        0x01,
        0x00,
        0x00,
        0xff,
        0xd9,
      ]);
      expect(imageHasRemovableMetadata(jpeg), isFalse);
      expect(identical(prepareImageBytesForSend(jpeg), jpeg), isTrue);
    });

    test('APP1 Exif is dropped; JFIF kept', () {
      final exifPayload = <int>[
        ...ascii.encode('Exif\x00\x00'),
        0x00, 0x01, 0x02, 0x03, // dummy TIFF-ish bytes
      ];
      final exifLen = exifPayload.length + 2;
      final jpeg = Uint8List.fromList([
        0xff,
        0xd8,
        0xff,
        0xe0,
        0x00,
        0x10,
        ...ascii.encode('JFIF\x00'),
        0x01,
        0x01,
        0x00,
        0x00,
        0x01,
        0x00,
        0x01,
        0x00,
        0x00,
        0xff,
        0xe1,
        (exifLen >> 8) & 0xff,
        exifLen & 0xff,
        ...exifPayload,
        0xff,
        0xd9,
      ]);
      expect(imageHasRemovableMetadata(jpeg), isTrue);
      final out = prepareImageBytesForSend(jpeg);
      expect(out.length, lessThan(jpeg.length));
      expect(imageHasRemovableMetadata(out), isFalse);
      expect(_contains(out, ascii.encode('JFIF')), isTrue);
      expect(_contains(out, ascii.encode('Exif')), isFalse);
    });
  });

  group('PNG', () {
    test('eXIf chunk is dropped', () {
      // Minimal PNG: signature + IHDR + eXIf + IEND (CRCs are unchecked).
      final ihdrData = List<int>.filled(13, 0);
      final ihdr = _pngChunk('IHDR', ihdrData);
      final exif = _pngChunk('eXIf', [1, 2, 3, 4]);
      final iend = _pngChunk('IEND', const []);
      final png = Uint8List.fromList([
        0x89,
        0x50,
        0x4e,
        0x47,
        0x0d,
        0x0a,
        0x1a,
        0x0a,
        ...ihdr,
        ...exif,
        ...iend,
      ]);
      expect(imageHasRemovableMetadata(png), isTrue);
      final out = prepareImageBytesForSend(png);
      expect(imageHasRemovableMetadata(out), isFalse);
      expect(_contains(out, ascii.encode('eXIf')), isFalse);
      expect(_contains(out, ascii.encode('IHDR')), isTrue);
      expect(_contains(out, ascii.encode('IEND')), isTrue);
    });
  });
}

bool _contains(Uint8List hay, List<int> needle) {
  for (var i = 0; i + needle.length <= hay.length; i++) {
    var ok = true;
    for (var j = 0; j < needle.length; j++) {
      if (hay[i + j] != needle[j]) {
        ok = false;
        break;
      }
    }
    if (ok) return true;
  }
  return false;
}

List<int> _pngChunk(String type, List<int> data) {
  final typeBytes = ascii.encode(type);
  final len = data.length;
  return [
    (len >> 24) & 0xff,
    (len >> 16) & 0xff,
    (len >> 8) & 0xff,
    len & 0xff,
    ...typeBytes,
    ...data,
    0, 0, 0, 0, // CRC ignored by our walker
  ];
}
