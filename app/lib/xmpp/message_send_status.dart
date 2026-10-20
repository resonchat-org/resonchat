// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Outgoing-message send status — Conversations `Message.STATUS_*` values.

/// Conversations `eu.siacs.conversations.entities.Message` status constants.
abstract final class MessageSendStatus {
  /// Inbound message (or unused for outgoing).
  static const int received = 0;

  /// On the wire / awaiting SM or MUC reflection (Conversations STATUS_UNSEND).
  static const int unsend = 1;

  /// Accepted by the server without waiting for further ack (rare for us).
  static const int send = 2;

  /// Permanent failure (error stanza, blocked track after queue, …).
  static const int sendFailed = 3;

  /// Queued locally; not yet put on the socket (offline / join in progress).
  static const int waiting = 5;

  /// Peer delivery receipt (0184) or MUC reflection confirmed.
  static const int sendReceived = 7;

  /// Peer displayed marker (0333).
  static const int sendDisplayed = 8;

  /// Migrate legacy [delivered]/[displayed]/[deliveryError] flags.
  static int fromLegacy({
    required bool incoming,
    required bool delivered,
    required bool displayed,
    required String deliveryError,
  }) {
    if (incoming) return received;
    if (deliveryError.isNotEmpty) return sendFailed;
    if (displayed) return sendDisplayed;
    if (delivered) return sendReceived;
    // Legacy rows were inserted only after a successful socket write.
    return send;
  }

  /// True while queued locally or still mid-flight (`unsend`).
  ///
  /// [send] is not pending: the stanza is already on the socket. The bubble
  /// draws a clock for this set, one tick for [send], and two for a delivery
  /// receipt. Read is the ring.
  static bool isPending(int status) => status == waiting || status == unsend;

  /// Delivery or read confirmed ([sendDisplayed] implies delivered).
  static bool isDelivered(int status) =>
      status == sendReceived || status == sendDisplayed;
}
