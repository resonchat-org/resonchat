// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sending the B track.
//
// These tests exist because of a bug that was invisible from the inside: the
// PQ ciphertext was handed to moxxmpp as a stanza extension, and moxxmpp
// silently dropped it because it only serialises the extensions it ships
// with. The message went out in plaintext wearing the fallback body, and
// every log line said the message was encrypted.
//
// So: a test that only checks "we produced a ciphertext" is worth nothing.
// These check what actually reaches the stanza.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:moxxmpp/moxxmpp.dart';
import 'package:resonchat/crypto/omemo/message_codec.dart';
import 'package:resonchat/crypto/omemo/protocol.dart';
import 'package:resonchat/crypto/omemo/track.dart';
import 'package:resonchat/xmpp/eme.dart';
import 'package:resonchat/xmpp/pq_stanza.dart';

PqEncryptedMessage _payload({int senderDeviceId = 1}) {
  return PqEncryptedMessage(
    senderDeviceId: senderDeviceId,
    recipients: [
      Omemo2KeysForJid(
        jid: 'bob@example.org',
        keys: [PqKeyEntry(recipientDeviceId: 2, ciphertext: 'd3JhcA==')],
      ),
    ],
    payload: 'Y2lwaGVydGV4dA==',
    commit: base64Encode(List<int>.filled(64, 1)),
  );
}

void main() {
  group('pqSendingCallback', () {
    test('puts the ciphertext on the wire, not just in memory', () {
      // The regression this whole file is about.
      final nodes = pqSendingCallback(
        TypedMap<StanzaHandlerExtension>.fromList([
          MessageBodyData('fallback text'),
          const EmeData(Track.pq, name: 'OMEMO-PQ'),
          PqEncryptedData(_payload()),
        ]),
      );

      final xml = nodes.map((n) => n.toXml()).join();
      expect(xml, contains(pomemoXmlns));
      expect(xml, contains('<payload>'));
      // The declaration travels with it: without it a receiver has no way to
      // tell which track the blob belongs to.
      expect(xml, contains(emePomemo0));
    });

    test('leaves a message with no B-track payload alone', () {
      // Otherwise every A-track and plaintext message would grow a stray
      // <encrypted /> element it has no business carrying.
      expect(
        pqSendingCallback(
          TypedMap<StanzaHandlerExtension>.fromList([
            MessageBodyData('hello'),
            MessageIdData('m1'),
          ]),
        ),
        isEmpty,
      );
    });

    test('the ciphertext is not the last thing in the message', () {
      // Ordering is cosmetic in XMPP, but a reader that bails on the first
      // unreadable element must meet the declaration before the blob.
      final nodes = pqSendingCallback(
        TypedMap<StanzaHandlerExtension>.fromList([
          const EmeData(Track.pq, name: 'OMEMO-PQ'),
          PqEncryptedData(_payload()),
        ]),
      );
      expect(nodes.first.tag, 'encryption');
      expect(nodes.last.tag, 'encrypted');
    });

    test('the sender device id survives serialisation', () {
      // Header/sid is how a receiving device picks the right session; losing
      // it turns every inbound PQ message into "cannot decrypt".
      final nodes = pqSendingCallback(
        TypedMap<StanzaHandlerExtension>.fromList([
          PqEncryptedData(_payload(senderDeviceId: 4242)),
        ]),
      );
      expect(nodes.single.toXml(), contains('4242'));
    });
  });

  group('extractPqPayload', () {
    test('reads back what the sending callback wrote', () {
      // Round trip: what goes out must be what comes back, or the two tests
      // above are both describing a format nobody speaks.
      final nodes = pqSendingCallback(
        TypedMap<StanzaHandlerExtension>.fromList([
          const EmeData(Track.pq),
          PqEncryptedData(_payload(senderDeviceId: 7)),
        ]),
      );
      final stanza = Stanza.message(children: nodes);
      final parsed = extractPqPayload(stanza);

      expect(parsed, isNotNull);
      expect(parsed!.senderDeviceId, 7);
      expect(parsed.payload, 'Y2lwaGVydGV4dA==');
    });

    test('an A-track OMEMO message is not mistaken for a B-track one', () {
      // Both tracks use the tag <encrypted />. Getting this wrong would have
      // us feeding standard OMEMO ciphertext to the PQ decryptor, which fails
      // noisily and looks like a key problem rather than a routing one.
      final stanza = Stanza.message(
        children: [
          XMLNode.xmlns(tag: 'encrypted', xmlns: omemoXmlns, children: []),
        ],
      );
      expect(extractPqPayload(stanza), isNull);
    });

    test('a plaintext message yields nothing rather than throwing', () {
      final stanza = Stanza.message(
        children: [MessageBodyData('just text').toXML()],
      );
      expect(extractPqPayload(stanza), isNull);
    });
  });
}
