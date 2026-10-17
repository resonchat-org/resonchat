// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// App policy mirrors Gajim open_xmpp_iri: empty querytype → start chat.

import 'package:flutter_test/flutter_test.dart';
import 'package:moxxmpp/moxxmpp.dart' show XmppUri, XmppUriQuerytype;

void main() {
  test('plain xmpp jid is none (Gajim: start-chat)', () {
    final u = XmppUri.tryParse('xmpp:juliet@capulet.lit');
    expect(u!.hasQuery, isFalse);
    expect(u.knownQuerytype, XmppUriQuerytype.none);
  });

  test('join remains join', () {
    final u = XmppUri.tryParse('xmpp:romeo@montague.net?join');
    expect(u!.knownQuerytype, XmppUriQuerytype.join);
  });
}
