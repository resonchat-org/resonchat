// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Receipt ticks. Outgoing only: a clock while queued or still in flight,
// one tick once the stanza is on the socket, two on delivery. Read is the ring.

import 'package:flutter/material.dart' show IconData, Icons;

import 'package:flutter_test/flutter_test.dart';

import 'package:resonchat/ui/chat/message_bubble.dart';
import 'package:resonchat/xmpp/message_send_status.dart';

/// The mapping as the bubble applies it.
IconData? ticksForStatus(int status) => receiptTicks(
  mine: true,
  failed: status == MessageSendStatus.sendFailed,
  pending: MessageSendStatus.isPending(status),
  delivered:
      status == MessageSendStatus.sendReceived ||
      status == MessageSendStatus.sendDisplayed,
  sent: status == MessageSendStatus.send,
);

void main() {
  test('incoming messages carry no ticks at all', () {
    expect(
      receiptTicks(
        mine: false,
        failed: false,
        pending: false,
        delivered: true,
        sent: true,
      ),
      isNull,
    );
  });

  test('queued locally is a clock, not a tick', () {
    expect(ticksForStatus(MessageSendStatus.waiting), Icons.schedule);
    expect(ticksForStatus(MessageSendStatus.unsend), Icons.schedule);
  });

  test('on the socket with no receipt is one tick', () {
    expect(ticksForStatus(MessageSendStatus.send), Icons.done);
  });

  test('delivery and a later read marker are both two ticks', () {
    expect(ticksForStatus(MessageSendStatus.sendReceived), Icons.done_all);
    expect(ticksForStatus(MessageSendStatus.sendDisplayed), Icons.done_all);
  });

  test('failure outranks everything else', () {
    expect(
      receiptTicks(
        mine: true,
        failed: true,
        pending: true,
        delivered: true,
        sent: true,
      ),
      Icons.error_outline,
    );
  });

  test('send is neither pending nor delivered', () {
    expect(MessageSendStatus.isPending(MessageSendStatus.send), isFalse);
    expect(MessageSendStatus.isDelivered(MessageSendStatus.send), isFalse);
  });
}
