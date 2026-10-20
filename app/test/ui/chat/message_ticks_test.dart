// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Receipt ticks. Outgoing only: a clock while queued or still in flight,
// nothing once the stanza is on the socket, one tick on delivery, two on read.

import 'package:flutter/material.dart' show IconData, Icons;

import 'package:flutter_test/flutter_test.dart';

import 'package:resonchat/ui/chat/message_bubble.dart';
import 'package:resonchat/xmpp/message_send_status.dart';

/// The mapping as the bubble applies it.
IconData? ticksForStatus(int status) => receiptTicks(
  mine: true,
  failed: status == MessageSendStatus.sendFailed,
  pending: MessageSendStatus.isPending(status),
  delivered: status == MessageSendStatus.sendReceived,
  read: status == MessageSendStatus.sendDisplayed,
);

void main() {
  test('incoming messages carry no ticks at all', () {
    expect(
      receiptTicks(
        mine: false,
        failed: false,
        pending: false,
        delivered: true,
        read: true,
      ),
      isNull,
    );
  });

  test('queued locally is a clock, not a tick', () {
    expect(ticksForStatus(MessageSendStatus.waiting), Icons.schedule);
    expect(ticksForStatus(MessageSendStatus.unsend), Icons.schedule);
  });

  test('on the socket with no receipt draws nothing', () {
    expect(ticksForStatus(MessageSendStatus.send), isNull);
  });

  test('delivery receipt is one tick and a read marker is two', () {
    expect(ticksForStatus(MessageSendStatus.sendReceived), Icons.done);
    expect(ticksForStatus(MessageSendStatus.sendDisplayed), Icons.done_all);
  });

  test('failure outranks everything else', () {
    expect(
      receiptTicks(
        mine: true,
        failed: true,
        pending: true,
        delivered: true,
        read: true,
      ),
      Icons.error_outline,
    );
  });

  test('send is neither pending nor delivered', () {
    expect(MessageSendStatus.isPending(MessageSendStatus.send), isFalse);
    expect(MessageSendStatus.isDelivered(MessageSendStatus.send), isFalse);
  });
}
