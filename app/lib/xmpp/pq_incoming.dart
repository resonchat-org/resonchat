// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Inbound post-quantum (B-track) messages.
//
// moxxmpp's stanza pipeline knows only the A track. Without a handler of this
// kind a PQ message reaches the UI as the literal fallback body — "This
// message is encrypted. Use a supported client to read it." — with no error
// attached, which is indistinguishable from a successful delivery.
//
// The handler sits *before* the standard handlers and does the one thing they
// cannot: swap the B-track ciphertext for the plaintext body. Everything
// downstream (EME reading, carbon handling, MAM, storage) then works exactly
// as it does for the A track, because by the time it runs there is only one
// thing left to disagree about.

import 'package:moxxmpp/moxxmpp.dart';

import '../crypto/omemo/protocol.dart';

/// Turns a stanza's B-track payload into plaintext, or null when the message
/// is not ours to open.
typedef PqIncomingCallback = Future<String?> Function(Stanza stanza);

/// Why an inbound PQ message could not be opened.
///
/// Surfaced rather than swallowed: a message nobody can read is a problem the
/// user has to know about, and "the ciphertext did not parse" and "this was
/// not addressed to our device" need different answers.
class PqDecryptFailure {
  const PqDecryptFailure(this.stanzaId, this.reason);

  final String? stanzaId;
  final String reason;

  @override
  String toString() => reason;
}

/// Manager id, so the handler can be found again for diagnostics.
const pqIncomingManagerId = 'resonchat-pq-incoming';

/// Decrypts inbound `<encrypted xmlns='urn:xmpp:pomemo:0'/>` elements.
class PqIncomingManager extends XmppManagerBase {
  PqIncomingManager(this._decrypt, this._onFailure)
    : super(pqIncomingManagerId);

  final PqIncomingCallback _decrypt;
  final void Function(PqDecryptFailure failure) _onFailure;

  @override
  Future<bool> isSupported() async => true;

  @override
  List<StanzaHandler> getIncomingPreStanzaHandlers() => [
    StanzaHandler(
      stanzaTag: 'message',
      tagName: 'encrypted',
      tagXmlns: pomemoXmlns,
      // Ahead of the A-track handler, though the two never collide:
      // both use the tag <encrypted />, separated by namespace.
      priority: 200,
      callback: _onIncoming,
    ),
  ];

  Future<StanzaHandlerData> _onIncoming(
    Stanza stanza,
    StanzaHandlerData state,
  ) async {
    String? plaintext;
    try {
      plaintext = await _decrypt(stanza);
    } catch (e) {
      // One corrupt or truncated message must not cost the user the whole
      // session: moxxmpp has nowhere to put an exception thrown here, so it
      // would unwind through the stanza pipeline and take the connection with
      // it. Report it as what it is — a message we could not open.
      final reason = 'post-quantum message could not be opened: $e';
      state.encryptionError = reason;
      _onFailure(PqDecryptFailure(stanza.id, reason));
      return state;
    }
    if (plaintext == null) {
      const reason =
          'post-quantum message could not be opened: '
          'not addressed to one of our B-track devices';
      // Without this the placeholder body reaches the UI as if it were the
      // message. "This message is encrypted. Use a supported client to read
      // it." is what a reader sees; "could not decrypt" is what happened,
      // and only the second one is actionable.
      state.encryptionError = reason;
      _onFailure(PqDecryptFailure(stanza.id, reason));
      return state;
    }

    // Replace the ciphertext and the placeholder body with the real text, so
    // nothing downstream can mistake the fallback for the message or try to
    // decrypt it a second time.
    final kept = state.stanza.children
        .where(
          (c) =>
              c.tag != 'body' &&
              !(c.tag == 'encrypted' && c.xmlns == pomemoXmlns),
        )
        .toList();
    state.stanza = state.stanza.copyWith(
      children: <XMLNode>[MessageBodyData(plaintext).toXML(), ...kept],
    );
    // Tells the rest of the pipeline this really was encrypted, which is what
    // keeps an unreadable copy of our own message from being reported as a
    // failed delivery.
    state.encrypted = true;
    return state;
  }
}
