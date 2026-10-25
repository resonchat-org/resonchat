// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// A 1:1 `<displayed/>` marker is often sent from a full JID, so the presence
// of a resource must not send it down the room-occupant path.

import 'package:test/test.dart';

import 'package:resonchat/xmpp/read_marker_target.dart';

void main() {
  test('a 1:1 chat takes the direct path even with a resource', () {
    expect(readMarkerTarget(chatIsGroup: false), ReadMarkerTarget.direct);
  });

  test('a missing chat row cannot be a room we joined', () {
    expect(readMarkerTarget(chatIsGroup: null), ReadMarkerTarget.direct);
  });

  test('only a group chat routes to occupants', () {
    expect(readMarkerTarget(chatIsGroup: true), ReadMarkerTarget.room);
  });
}
