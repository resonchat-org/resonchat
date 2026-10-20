// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter_test/flutter_test.dart';

import 'package:resonchat/xmpp/channel_discovery.dart';

void main() {
  test('PublicChannel.fromMuclumbusJson maps API fields', () {
    final room = PublicChannel.fromMuclumbusJson({
      'address': 'conversations@conference.siacs.eu',
      'name': 'Conversations',
      'description': 'The very last word in instant messaging.',
      'language': 'en',
      'nusers': 669,
    });
    expect(room, isNotNull);
    expect(room!.address, 'conversations@conference.siacs.eu');
    expect(room.displayName, 'Conversations');
    expect(room.numberOfUsers, 669);
    expect(room.matches('siacs'), isTrue);
    expect(room.matches('zzz'), isFalse);
  });

  test('ChannelDiscoveryMethod defaults to jabber network', () {
    expect(
      ChannelDiscoveryMethod.parse(null),
      ChannelDiscoveryMethod.jabberNetwork,
    );
    expect(
      ChannelDiscoveryMethod.parse('local_server'),
      ChannelDiscoveryMethod.localServer,
    );
  });
}
