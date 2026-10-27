// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Two forwarding modes:
//
//   1. **Resend** (multi-select): a new message on the destination track —
//      quoted / attributed body, or a preformatted transcript. Same as before
//      XEP-0297. Encrypted chats stay on their track.
//
//   2. **XEP-0297** (long-press one message): plaintext `<forwarded/>` only.
//      Ciphertext must not be wrapped (wrong keys + leaks original peers).

import 'package:moxxmpp/moxxmpp.dart';

import 'package:resonchat/crypto/dual/track.dart';
import 'package:resonchat/xmpp/chat/replies.dart';
import 'package:resonchat/xmpp/connection.dart';

/// Why a forward could not be sent.
enum ForwardRefusal {
  /// Nothing was selected to forward.
  nothingSelected,

  /// XEP-0297 path: at least one selected message is not plaintext.
  notPlaintext,

  /// The destination conversation rejected the send.
  trackBlocked,
}

/// The outcome of one forward (resend or XEP-0297).
class ForwardOutcome {
  const ForwardOutcome({
    required this.forwarded,
    this.refused,
    this.stanzaId = const [],
    this.wireBodies = const [],
    this.persisted = const [],
  });

  /// How many messages actually went out.
  final int forwarded;

  /// Null when everything was sent.
  final ForwardRefusal? refused;

  /// Stanza ids of what was sent.
  final List<String> stanzaId;

  /// Wire bodies for resend persistence (parallel to [stanzaId]).
  final List<String> wireBodies;

  /// XEP-0297 rows to insert locally (parallel to [stanzaId]).
  final List<ForwardPersisted> persisted;

  bool get ok => refused == null;
}

// --- Resend (multi-select) ---------------------------------------------------

/// One message chosen for resend-style forwarding.
class ForwardItem {
  const ForwardItem({
    required this.body,
    required this.chatJid,
    this.preformatted = false,
  });

  /// The text to forward.
  ///
  /// When [preformatted] is false: the stored body (no nested quote of a quote).
  /// When true: a full transcript (headers + `> ` lines), sent as the message
  /// body without wrapping again.
  final String body;

  /// Where it came from, named in the attribution so the recipient knows it is
  /// second-hand. Unused when [preformatted].
  final String chatJid;

  /// [body] is already the wire text; do not add attribution / extra quoting.
  final bool preformatted;
}

/// The text to put on the wire as the attribution.
String forwardAttribution(String originJid) => 'Forwarded from $originJid';

/// Builds the body that actually goes on the wire for one [item].
String forwardWireBody(ForwardItem item) {
  if (item.preformatted) return item.body;
  // Attribution after the quote (same shape as a reply fallback): readers see
  // the quoted content first, then the label. Must not go through sendReply
  // with an empty targetId — that path drops the quote when replyTo is null.
  return buildReplyFallback(
    item.body,
    forwardAttribution(item.chatJid),
  ).wireBody;
}

/// Sends one message of a resend forward. Injected for tests.
typedef ForwardSender = Future<SendOutcome> Function(
  String wireBody,
  Track track,
);

/// Runs the resend forward loop.
Future<ForwardOutcome> runForward({
  required List<ForwardItem> items,
  required Track track,
  required ForwardSender send,
}) async {
  if (items.isEmpty) {
    return const ForwardOutcome(
      forwarded: 0,
      refused: ForwardRefusal.nothingSelected,
    );
  }
  final sent = <String>[];
  final bodies = <String>[];
  for (final item in items) {
    final wire = forwardWireBody(item);
    final outcome = await send(wire, track);
    if (!outcome.sent) {
      return ForwardOutcome(
        forwarded: sent.length,
        refused: ForwardRefusal.trackBlocked,
        stanzaId: sent,
        wireBodies: bodies,
      );
    }
    if (outcome.stanzaId != null) {
      sent.add(outcome.stanzaId!);
      bodies.add(wire);
    }
  }
  return ForwardOutcome(
    forwarded: sent.length,
    stanzaId: sent,
    wireBodies: bodies,
  );
}

/// Forwards [items] into the conversation with [toJid] as new messages.
Future<ForwardOutcome> forwardMessages(
  XmppService xmpp, {
  required JID toJid,
  required List<ForwardItem> items,
  required Track track,
  String messageType = 'chat',
}) {
  return runForward(
    items: items,
    track: track,
    send: (wireBody, t) =>
        xmpp.sendOnTrack(toJid, wireBody, track: t, messageType: messageType),
  );
}

// --- XEP-0297 (long-press) ---------------------------------------------------

/// What the sender's own history should store for one XEP-0297 forward.
class ForwardPersisted {
  const ForwardPersisted({
    required this.forwardFromJid,
    required this.forwardAuthor,
    required this.forwardBody,
    this.forwardOriginId = '',
    this.forwardStamp,
    this.outerBody = '',
  });

  final String forwardFromJid;
  final String forwardAuthor;
  final String forwardBody;
  final String forwardOriginId;
  final DateTime? forwardStamp;

  /// Optional comment on the outer message (shown under the forward card).
  final String outerBody;
}

/// One plaintext message chosen for XEP-0297 `<forwarded/>`.
class StanzaForwardItem {
  const StanzaForwardItem({
    required this.body,
    required this.originChatJid,
    required this.author,
    this.messageType = 'chat',
    this.originId,
    this.fromFull,
    this.toFull,
    this.receivedAt,
    this.plaintext = true,
  });

  final String body;
  final String originChatJid;
  final String author;
  final String messageType;
  final String? originId;
  final String? fromFull;
  final String? toFull;
  final DateTime? receivedAt;
  final bool plaintext;
}

/// Bare JID to open when the user taps a forward card.
String forwardOriginJid({
  required String? from,
  required String? type,
  String fallback = '',
}) {
  if (from == null || from.isEmpty) return fallback;
  final jid = JID.fromString(from);
  return jid.toBare().toString();
}

/// Returns a refusal before any XEP-0297 send, or null when [items] may go out.
ForwardRefusal? refuseStanzaForward(List<StanzaForwardItem> items) {
  if (items.isEmpty) return ForwardRefusal.nothingSelected;
  for (final item in items) {
    if (!item.plaintext || item.body.trim().isEmpty) {
      return ForwardRefusal.notPlaintext;
    }
  }
  return null;
}

/// Builds the inner stanza snapshot for one [item].
Stanza stanzaForwardInner(StanzaForwardItem item) {
  final from =
      item.fromFull ??
      (item.messageType == 'groupchat'
          ? '${item.originChatJid}/${item.author}'
          : item.author);
  return Stanza.message(
    from: from,
    to: item.toFull,
    id: item.originId,
    type: item.messageType,
    children: [MessageBodyData(item.body).toXML()],
  );
}

/// Sends one XEP-0297 forward. Injected so the loop can be tested without a
/// live connection.
typedef PlaintextForwardSender = Future<String?> Function({
  required Stanza original,
  required DateTime? receivedAt,
  required String outerBody,
});

/// Runs the XEP-0297 forward loop with an injected [send].
Future<ForwardOutcome> runPlaintextForward({
  required List<StanzaForwardItem> items,
  required PlaintextForwardSender send,
  String outerBody = '',
}) async {
  final refusal = refuseStanzaForward(items);
  if (refusal != null) {
    return ForwardOutcome(forwarded: 0, refused: refusal);
  }

  final sent = <String>[];
  final persisted = <ForwardPersisted>[];
  for (final item in items) {
    final original = stanzaForwardInner(item);
    final stanzaId = await send(
      original: original,
      receivedAt: item.receivedAt,
      outerBody: outerBody,
    );
    if (stanzaId == null) {
      return ForwardOutcome(
        forwarded: sent.length,
        refused: ForwardRefusal.trackBlocked,
        stanzaId: sent,
        persisted: persisted,
      );
    }
    sent.add(stanzaId);
    final from = original.from;
    persisted.add(
      ForwardPersisted(
        forwardFromJid: forwardOriginJid(
          from: from,
          type: item.messageType,
          fallback: item.originChatJid,
        ),
        forwardAuthor: item.author,
        forwardBody: item.body,
        forwardOriginId: item.messageType == 'groupchat'
            ? (item.originId?.trim() ?? '')
            : '',
        forwardStamp: item.receivedAt,
        outerBody: outerBody,
      ),
    );
  }
  return ForwardOutcome(
    forwarded: sent.length,
    stanzaId: sent,
    persisted: persisted,
  );
}

/// Sends [items] as plaintext XEP-0297 forwards to [toJid].
Future<ForwardOutcome> forwardStanzaMessages(
  XmppService xmpp, {
  required JID toJid,
  required List<StanzaForwardItem> items,
  String messageType = 'chat',
  String outerBody = '',
}) {
  return runPlaintextForward(
    items: items,
    outerBody: outerBody,
    send: ({required original, required receivedAt, required outerBody}) =>
        xmpp.sendPlaintextForward(
          toJid,
          original: original,
          receivedAt: receivedAt,
          messageType: messageType,
          outerBody: outerBody,
        ),
  );
}
