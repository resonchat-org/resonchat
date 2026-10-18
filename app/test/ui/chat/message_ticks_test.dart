// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Receipt ticks. The mapping is the user-visible contract for an outgoing
// message: nothing while it is queued, one tick once the server has it, two
// once the peer's client has confirmed. A message that has been accepted by
// the server must never look the same as one still sitting in the queue.

import 'package:flutter/material.dart' show IconData, Icons;
import 'package:flutter_test/flutter_test.dart';
import 'package:resonchat/store/message_send_status.dart';
import 'package:resonchat/ui/chat/message_bubble.dart';

/// The mapping as the bubble applies it: status → pending/delivered flags.
IconData? ticksForStatus(int status) => receiptTicks(
  mine: true,
  failed: status == MessageSendStatus.sendFailed,
  pending: MessageSendStatus.isPending(status),
  delivered: MessageSendStatus.isDelivered(status),
);

void main() {
  test('incoming messages carry no ticks at all', () {
    expect(
      receiptTicks(mine: false, failed: false, pending: false, delivered: true),
      isNull,
    );
  });

  test('queued locally is a clock, not a tick', () {
    expect(ticksForStatus(MessageSendStatus.waiting), Icons.schedule);
    expect(ticksForStatus(MessageSendStatus.unsend), Icons.schedule);
  });

  test('accepted by the server is exactly one tick', () {
    // The regression this guards: `send` used to draw nothing, so a message
    // already on the wire looked like one still queued.
    expect(ticksForStatus(MessageSendStatus.send), Icons.done);
  });

  test('delivery receipt and read marker are two ticks', () {
    expect(ticksForStatus(MessageSendStatus.sendReceived), Icons.done_all);
    expect(ticksForStatus(MessageSendStatus.sendDisplayed), Icons.done_all);
  });

  test('failure outranks everything else', () {
    expect(
      receiptTicks(mine: true, failed: true, pending: true, delivered: true),
      Icons.error_outline,
    );
  });

  test('send is neither pending nor delivered', () {
    expect(MessageSendStatus.isPending(MessageSendStatus.send), isFalse);
    expect(MessageSendStatus.isDelivered(MessageSendStatus.send), isFalse);
  });
}
