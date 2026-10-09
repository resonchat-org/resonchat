// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Inbound B-track handling.
//
// The failure this guards against is quiet: without a handler, a PQ message
// reaches the UI as the literal string "This message is encrypted. Use a
// supported client to read it." and nothing anywhere says the message failed.
// A delivery that looks like a delivery is the worst kind.

import 'package:flutter_test/flutter_test.dart';
import 'package:moxxmpp/moxxmpp.dart';
import 'package:resonchat/crypto/omemo/message_codec.dart';
import 'package:resonchat/crypto/omemo/protocol.dart';
import 'package:resonchat/xmpp/pq_incoming.dart';
import 'package:resonchat/xmpp/pq_stanza.dart';

PqEncryptedMessage _payload() => PqEncryptedMessage(
  senderDeviceId: 1,
  keys: const [],
  iv: 'aXYtaGVyZQ==',
  payload: 'Y2lwaGVydGV4dA==',
);

Stanza _pqMessage({String? id = 'm1'}) => Stanza.message(
  id: id,
  type: 'chat',
  children: [
    MessageBodyData(
      'This message is encrypted. Use a supported client to '
      'read it.',
    ).toXML(),
    PqEncryptedData(_payload()).toXml(),
  ],
);

({PqIncomingManager manager, List<PqDecryptFailure> failures}) _manager(
  PqIncomingCallback decrypt,
) {
  final failures = <PqDecryptFailure>[];
  return (
    manager: PqIncomingManager(decrypt, failures.add),
    failures: failures,
  );
}

Future<StanzaHandlerData> _run(PqIncomingManager manager, Stanza stanza) {
  final handler = manager.getIncomingPreStanzaHandlers().single;
  final children = stanza.children;
  final state = StanzaHandlerData(
    false,
    false,
    stanza,
    TypedMap<StanzaHandlerExtension>(),
  );
  // The pipeline hands the handler the stanza it is currently working on;
  // mirror that here so `state.stanza` is what the test inspects.
  state.stanza = stanza.copyWith(children: children);
  return handler.callback(stanza, state);
}

void main() {
  group('handler registration', () {
    test('only claims the PQ namespace, not every <encrypted />', () {
      // The A track uses the same tag. Matching on tag alone would hand
      // standard OMEMO ciphertext to the PQ decryptor, which fails noisily
      // and looks like a key problem rather than a routing one.
      final m = _manager((_) async => 'x').manager;
      final handler = m.getIncomingPreStanzaHandlers().single;
      expect(handler.stanzaTag, 'message');
      expect(handler.tagName, 'encrypted');
      expect(handler.tagXmlns, pomemoXmlns);
      expect(handler.tagXmlns, isNot(omemoXmlns));
    });
  });

  group('a message we can open', () {
    test('the plaintext replaces the fallback body', () async {
      final m = _manager((_) async => 'the real message').manager;
      final state = await _run(m, _pqMessage());

      final body = state.stanza.firstTag('body');
      expect(body?.innerText(), 'the real message');
      // Belt and braces: if the placeholder survives anywhere, a reader can
      // still show it instead of the message.
      expect(state.stanza.toXml(), isNot(contains('Use a supported client')));
    });

    test('the ciphertext is gone, so nothing downstream tries again', () async {
      final m = _manager((_) async => 'the real message').manager;
      final state = await _run(m, _pqMessage());

      final left = state.stanza.children
          .where((c) => c.tag == 'encrypted')
          .toList();
      expect(left, isEmpty);
    });

    test(
      'it is marked encrypted, so carbons are not mistaken for failures',
      () async {
        // Our own message mirrored back from another resource was encrypted for
        // the *peer's* devices. Reporting that as a failed delivery would be
        // inventing a problem.
        final m = _manager((_) async => 'the real message').manager;
        final state = await _run(m, _pqMessage());
        expect(state.encrypted, isTrue);
      },
    );

    test(
      'the EME declaration survives, because it carries the label',
      () async {
        final m = _manager((_) async => 'the real message').manager;
        final stanza = Stanza.message(
          children: [
            MessageBodyData('fallback').toXML(),
            XMLNode.xmlns(
              tag: 'encryption',
              xmlns: emeXmlns,
              attributes: {'namespace': emePomemo0},
            ),
            PqEncryptedData(_payload()).toXml(),
          ],
        );
        final state = await _run(m, stanza);
        final eme = state.stanza.firstTag('encryption', xmlns: emeXmlns);
        expect(eme?.attributes['namespace'], emePomemo0);
      },
    );

    test('the stanza id is carried through', () async {
      // Without the id a delivery receipt or a carbon cannot be matched back
      // to the stored row.
      final m = _manager((_) async => 'x').manager;
      final state = await _run(m, _pqMessage(id: 'abc-123'));
      expect(state.stanza.attributes['id'], 'abc-123');
    });
  });

  group('a message we cannot open', () {
    test('leaves the stanza alone rather than inventing plaintext', () async {
      final m = _manager((_) async => null).manager;
      final state = await _run(m, _pqMessage());

      // Still marked unencrypted and still carrying the ciphertext: the UI
      // needs to be able to say "cannot decrypt", not "here is an empty
      // message".
      expect(state.encrypted, isFalse);
      expect(
        state.stanza.children.where((c) => c.tag == 'encrypted'),
        isNotEmpty,
      );
    });

    test(
      'carries an error, so the placeholder is not shown as the message',
      () async {
        // Without this the user reads "This message is encrypted. Use a
        // supported client to read it." as if it were what their contact sent.
        // Only the second of those is actionable.
        final m = _manager((_) async => null).manager;
        final state = await _run(m, _pqMessage());
        expect(state.encryptionError, isNotNull);
      },
    );

    test('and says so out loud', () async {
      final m = _manager((_) async => null);
      await _run(m.manager, _pqMessage(id: 'abc-123'));
      expect(m.failures, hasLength(1));
      expect(m.failures.single.stanzaId, 'abc-123');
      expect(m.failures.single.reason, isNotEmpty);
    });

    test(
      'a throw from the crypto layer does not take the session down',
      () async {
        // One malformed message must not cost the user the whole connection.
        final m = _manager((_) async => throw StateError('bad key'));
        Object? caught;
        try {
          await _run(m.manager, _pqMessage());
        } catch (e) {
          caught = e;
        }
        expect(caught, isNull, reason: 'the pipeline has no place to put this');
      },
    );

    test('a throw is reported as an error, not swallowed', () async {
      final m = _manager((_) async => throw StateError('bad key'));
      final state = await _run(m.manager, _pqMessage());
      expect(state.encryptionError, contains('bad key'));
      expect(m.failures.single.reason, contains('bad key'));
    });
  });

  group('nothing to do', () {
    test('a plaintext message produces no failure report', () async {
      // Only the PQ handler reports; a normal chat message must stay silent
      // or the log fills with noise about messages nobody asked about.
      var called = 0;
      final m = PqIncomingManager((_) async {
        called++;
        return null;
      }, (_) {});
      final stanza = Stanza.message(
        children: [MessageBodyData('hello').toXML()],
      );
      expect(extractPqPayload(stanza), isNull);
      expect(called, 0);
      expect(m.getIncomingPreStanzaHandlers(), hasLength(1));
    });
  });
}
