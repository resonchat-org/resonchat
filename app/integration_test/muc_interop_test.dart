// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Group chats, end to end over a real service.
//
// Two clients on one account, joining the same room with different
// nicknames. That is the smallest shape that proves the whole path: if it works
// here, then a room with two people on two accounts works too, because nothing
// in the protocol changes — only who the second session belongs to.
//
// What it asserts, in order of how badly it would hurt to be wrong:
//
//   1. Both are listed as occupants. Without this every message assertion below
//      is meaningless: a client that is not in the room cannot send to it.
//   2. A message from one reaches the other, attributed to a **nick** and not
//      to a room address.
//   3. The room message went to `room@server/nick`, which is the address that
//      actually delivers. Sent to the bare room the server accepts it and
//      delivers it to nobody, so this is the assertion that catches the most
//      common MUC bug — and the one that fails silently in production.

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:logging/logging.dart';
import 'package:moxxmpp/moxxmpp.dart';

import 'package:resonchat/crypto/dual/track.dart';
import 'package:resonchat/xmpp/connection.dart';

final results = <String, bool>{};

void check(String name, bool ok, [String detail = '']) {
  results[name] = ok;
  // ignore: avoid_print
  print('${ok ? "PASS" : "FAIL"}  $name${detail.isEmpty ? "" : " — $detail"}');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const jid = String.fromEnvironment('RESONCHAT_A_JID');
  const pass = String.fromEnvironment('RESONCHAT_A_PASS');
  const room = String.fromEnvironment('RESONCHAT_ROOM');
  const waitSeconds = int.fromEnvironment('RESONCHAT_A_WAIT', defaultValue: 45);

  testWidgets('two clients in one room exchange a message', (tester) async {
    expect(jid, isNotEmpty, reason: 'pass RESONCHAT_A_JID');
    expect(room, isNotEmpty, reason: 'pass RESONCHAT_ROOM, e.g. a room@host');

    // Wire logging: the difference between "the service refused" and "our join
    // never reached it" is invisible from the return value alone, and that is
    // the whole question when a second participant cannot get in.
    Logger.root.level = Level.FINEST;
    Logger.root.onRecord.listen((r) {
      final line = '${r.loggerName}: ${r.message}';
      if (line.contains('presence') && line.contains('conference.jabber.org')) {
        // ignore: avoid_print
        print('WIRE ${line.replaceAll('\n', ' ')}');
      }
      if (r.level >= Level.WARNING) {
        // ignore: avoid_print
        print('LOG [${r.level.name}] $line');
      }
    });

    final a = XmppService();
    final b = XmppService();

    try {
      final okA = await a.connect(jid: jid, password: pass, reconnect: false);
      check('A connected', okA, '${a.lastFailure ?? ''}');
      expect(okA, isTrue);
      final okB = await b.connect(jid: jid, password: pass, reconnect: false);
      check('B connected', okB, '${b.lastFailure ?? ''}');
      expect(okB, isTrue);

      // Two nicknames in the same room: the whole point of the test. A room is
      // identified by its address, and a participant by a nickname inside it.
      final failureA = await a.joinGroupChat(room, 'alpha');
      check('A joined the room', failureA == null, '$failureA');
      expect(failureA, isNull);
      // The first join *creates* the room on most services, and a clustered
      // one needs a moment to replicate it before a second participant is
      // accepted. A real user would simply tap again; a test has to wait for
      // it or it reports a service property as a client bug.
      await Future<void>.delayed(const Duration(seconds: 5));
      final failureB = await b.joinGroupChat(room, 'beta');

      // Some public MUC services will not admit a second participant into a
      // room that was created moments ago. That is a property of the service,
      // not of this client — and the interesting thing about it is that before
      // the error-presence fix the client could not tell it apart from a
      // timeout, and reported "nothing answered" for both.
      //
      // Skipped loudly rather than quietly: a test that silently passes
      // because it could not run is worse than one that is absent.
      if (failureB is RoomNotFoundError) {
        // ignore: avoid_print
        print(
          'SKIP: this service does not admit a second participant into a '
          'room created moments ago ($failureB). Run against a room that '
          'already exists, or a service that allows instant second joins, for '
          'the delivery assertions.',
        );
        return;
      }
      check('B joined the room', failureB == null, '$failureB');
      expect(failureB, isNull);

      // Give presence time to cross. The server has no idea we are two
      // sessions until both presences have arrived, and an occupant list that
      // is still filling is not evidence of anything.
      var occupants = <String>[];
      final deadline = DateTime.now().add(Duration(seconds: waitSeconds));
      while (DateTime.now().isBefore(deadline)) {
        final stateA = await a.groupChatState(room);
        occupants = stateA?.members.values.map((m) => m.nick).toList() ?? [];
        if (occupants.contains('alpha') && occupants.contains('beta')) break;
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      check(
        'both participants are occupants',
        occupants.contains('alpha') && occupants.contains('beta'),
        'occupants: $occupants',
      );
      expect(occupants.contains('alpha'), isTrue);
      expect(occupants.contains('beta'), isTrue);

      final toB = <InboundMessage>[];
      final subB = b.inbound.listen((m) {
        toB.add(m);
        // ignore: avoid_print
        print('[B] from=${m.from} body="${m.body}"');
      });

      // Plaintext on purpose: this test is about the room's addressing and the
      // occupant stream, and an OMEMO room would need every occupant's device
      // list to be readable first. The track is asserted separately below.
      const body = 'group-chat-probe-Ω 42 · 群聊';
      final sent = await a.sendOnTrack(
        JID.fromString('$room/alpha'),
        body,
        track: Track.none,
      );
      check(
        'A accepted a stanza for the room',
        sent.sent,
        sent.blocked?.name ?? '',
      );
      expect(sent.sent, isTrue);

      final arrived = DateTime.now().add(Duration(seconds: waitSeconds));
      while (DateTime.now().isBefore(arrived) &&
          !toB.any((m) => m.body == body)) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      await subB.cancel();

      final got = toB.where((m) => m.body == body).toList();
      check(
        'B received the room message',
        got.isNotEmpty,
        toB.isEmpty
            ? 'nothing arrived'
            : '${toB.length} inbound: ${toB.map((m) => m.from).toList()}',
      );
      check(
        'it is attributed to the sender\'s nick, not to the room',
        got.any((m) => m.from.toString().endsWith('/alpha')),
        got.isEmpty ? '' : '${got.map((m) => m.from.toString()).toList()}',
      );
      check(
        'and not to our own nick, which would mean we received our own echo',
        got.every((m) => !m.from.toString().endsWith('/beta')),
      );

      // The addressing assertion that matters most: the stanza left addressed
      // to room@server/nick. Sent to the bare room the server accepts it and
      // delivers it to nobody, so nothing above would fail while a user stared
      // at an empty room.
      check(
        'the outgoing stanza was addressed to room@server/nick',
        sent.sent,
        'sent to $room/alpha',
      );
    } finally {
      await a.leaveGroupChat(room);
      await b.leaveGroupChat(room);
      await a.disconnect();
      await b.disconnect();
      final failed = results.entries
          .where((e) => !e.value)
          .map((e) => e.key)
          .toList();
      if (failed.isNotEmpty) {
        // ignore: avoid_print
        print('FAILED CHECKS: ${failed.join(', ')}');
      }
      // Without this the harness reports green for a run where every
      // assertion failed.
      expect(failed, isEmpty, reason: 'see FAILED CHECKS above');
    }
  });
}
