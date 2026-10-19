// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:moxxmpp/moxxmpp.dart';
import 'package:test/test.dart';

void main() {
  test('a prefixed room stanza-id is still the room id', () {
    final node = XMLNode.fromString(
      "<message xmlns='jabber:client' xmlns:sid='urn:xmpp:sid:0' "
      "from='room@conf.example/nick' type='groupchat'>"
      "<sid:stanza-id id='room-1' by='room@conf.example'/>"
      "<sid:origin-id id='origin-1'/>"
      '</message>',
    );

    final stanzaId = node.firstTag('stanza-id', xmlns: stableIdXmlns);
    expect(stanzaId?.attributes['id'], 'room-1');
    expect(stanzaId?.attributes['by'], 'room@conf.example');
    expect(
      node.firstTag('origin-id', xmlns: stableIdXmlns)?.attributes['id'],
      'origin-1',
    );
  });

  test('an unprefixed stanza-id is unchanged', () {
    final node = XMLNode.fromString(
      "<message xmlns='jabber:client' from='room@conf.example/nick' "
      "type='groupchat'>"
      "<stanza-id xmlns='urn:xmpp:sid:0' id='room-1' by='room@conf.example'/>"
      '</message>',
    );
    expect(
      node.firstTag('stanza-id', xmlns: stableIdXmlns)?.attributes['id'],
      'room-1',
    );
  });

  test('stream features keep their qualified name', () {
    final node = XMLNode.fromString(
      "<stream:features xmlns:stream='http://etherx.jabber.org/streams'/>",
    );
    expect(node.tag, 'stream:features');
  });
}
