// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Refusing a blocked contact's messages before anything opens them.
//
// Why this has to be a stanza handler rather than a check inside our own
// message-handling code: by the time a `MessageEvent` reaches us, moxxmpp's
// OMEMO manager has **already decrypted** the message. A check there would be
// checking after reading the letter — the keys were used, the plaintext
// existed, and no amount of not-showing-it undoes that.
//
// So this sits in the incoming *pre*-stanza phase, ahead of the OMEMO handler,
// and cancels the stanza. Cancelling alone is not enough: `cancel` stops the
// remaining pre-handlers, but the incoming handlers still run and would emit a
// MessageEvent for a message nobody decrypted. `skip` is what actually stops
// the message from being built at all.

import 'package:moxxmpp/moxxmpp.dart';

/// Manager id, so the handler can be found again for diagnostics.
const blockedInboundManagerId = 'resonchat-blocked-inbound';

/// The set of blocked bare JIDs, resolved when the handler runs.
///
/// A callback rather than a captured set: the list changes while the
/// connection lives, and a captured one would keep enforcing a block that was
/// lifted — or stop enforcing one that was added.
typedef BlockedLookup = Set<String> Function();

class BlockedInboundManager extends XmppManagerBase {
  BlockedInboundManager(this._blocked, this._onDropped)
      : super(blockedInboundManagerId);

  final BlockedLookup _blocked;
  final void Function(JID from) _onDropped;

  @override
  Future<bool> isSupported() async => true;

  @override
  List<StanzaHandler> getIncomingPreStanzaHandlers() => [
        StanzaHandler(
          stanzaTag: 'message',
          // Ahead of the OMEMO handler, which is the whole point: this has to
          // run before anything decrypts.
          priority: 300,
          callback: _onMessage,
        ),
      ];

  Future<StanzaHandlerData> _onMessage(
    Stanza stanza,
    StanzaHandlerData state,
  ) async {
    final from = stanza.attributes['from'];
    if (from == null) return state;
    final bare = JID.fromString(from).toBare().toString();
    if (!_blocked().contains(bare)) return state;


    _onDropped(JID.fromString(from));
    return state
      // Stops the remaining pre-handlers.
      ..cancel = true
      // Stops the incoming handlers, which is what actually prevents the
      // message from being decrypted and stored.
      ..skip = true;
  }
}