// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:test/test.dart';
import 'package:resonchat/xmpp/file_preview.dart';

void main() {
  test('size cap covers images and other files the same way', () {
    expect(
      shouldAutoDownload(
        maxBytes: 0,
        incoming: true,
        isGroup: false,
        membersOnly: false,
      ),
      isFalse,
    );
    expect(
      shouldAutoDownload(
        maxBytes: 1024,
        incoming: true,
        isGroup: false,
        membersOnly: false,
      ),
      isTrue,
    );
    expect(
      shouldAutoDownload(
        maxBytes: 1024,
        incoming: false,
        isGroup: true,
        membersOnly: false,
      ),
      isTrue,
    );
    expect(
      shouldAutoDownload(
        maxBytes: 1024,
        incoming: true,
        isGroup: true,
        membersOnly: false,
      ),
      isFalse,
    );
    expect(
      shouldAutoDownload(
        maxBytes: 1024,
        incoming: true,
        isGroup: true,
        membersOnly: true,
      ),
      isTrue,
    );
  });
}
