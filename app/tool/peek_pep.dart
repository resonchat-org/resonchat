// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// What does the server actually hold for an account?
//
// This exists because the previous version of this tool only dumped the device
// list, and that was not enough to diagnose anything: a device list saying
// "account X has device 1234" is a *claim*, and the only thing that settles
// whether a peer can actually encrypt to us is whether the bundle behind that
// id is fetchable. Those two facts disagree in exactly the situation that
// matters, and the disagreement is what a real client reports as "Could not
// fetch encryption keys".
//
// So this reads the list, derives every bundle node from it, and fetches each
// one — printing PASS/FAIL per id. A list of 2 devices where only 1 bundle
// resolves is the finding, and it is invisible to any tool that only reads the
// list.
//
// Usage:
//   dart run tool/peek_pep.dart <jid> <password> <peerJid> [moreJids...]
//
// Exit code is 0 when every advertised device resolves to a bundle, 1 otherwise,
// so this doubles as a gate in the interop script rather than only a thing a
// human reads.

import 'dart:io';

import 'package:logging/logging.dart';
import 'package:moxxmpp/moxxmpp.dart';
import 'package:moxxmpp/socket_tcp.dart';
import 'package:xml/xml.dart';

/// Progress and findings, on stderr.
///
/// stderr rather than stdout because stdout is block-buffered when redirected to
/// a file, which makes a probe that hangs on a single unanswered IQ print
/// *nothing at all* — the one thing a diagnostic tool must never do.
void _out(String line) {
  // ignore: avoid_print
  stderr.writeln(line);
}

const defactoDevices = 'eu.siacs.conversations.axolotl.devicelist';
const defactoBundles = 'eu.siacs.conversations.axolotl.bundles';
const specDevices = 'urn:xmpp:omemo:2:devices';
const specBundles = 'urn:xmpp:omemo:2:bundles';

Future<void> main(List<String> args) async {
  if (args.length < 3) {
    stderr.writeln('usage: peek_pep <jid> <password> <peerJid> [moreJids...]');
    exitCode = 64;
    return;
  }
  Logger.root.level = Level.WARNING;

  final jid = JID.fromString(args[0]);
  final pubsub = PubSubManager();
  final connection = XmppConnection(
    TestingReconnectionPolicy(),
    AlwaysConnectedConnectivityManager(),
    ClientToServerNegotiator(),
    TCPSocketWrapper(false),
  )..connectionSettings = ConnectionSettings(jid: jid, password: args[1]);

  await connection.registerManagers([pubsub]);

  final result = await connection.connect(
    shouldReconnect: false,
    waitUntilLogin: true,
  );
  if (!result.isType<bool>() || !result.get<bool>()) {
    // The full failure, not the runtime type: `Result<bool, XmppError>` says
    // nothing about *which* error, and the whole point of this tool is that a
    // refusal is never allowed to be a shrug.
    stderr.writeln(
      'FAIL  could not log in as ${jid.toString()}: '
      '${result.isType<XmppError>() ? result.get<XmppError>() : result}',
    );
    exitCode = 1;
    return;
  }
  _out('OK    logged in as ${jid.toString()}');

  var allResolvable = true;
  for (final target in args.sublist(2)) {
    allResolvable =
        await _report(JID.fromString(target).toBare(), pubsub) && allResolvable;
  }

  await connection.disconnect();
  exitCode = allResolvable ? 0 : 1;
}

/// Prints what the server holds for [peer], one line per advertised device.
Future<bool> _report(JID peer, PubSubManager pubsub) async {
  _out('--- ${peer.toBare().toString()} ---');

  final ids = <int>{};
  final readable = <String>[];

  for (final entry in const [
    (node: defactoDevices, bundles: defactoBundles),
    (node: specDevices, bundles: specBundles),
  ]) {
    final res = await pubsub.getItems(peer, entry.node);
    if (!res.isType<List<PubSubItem>>()) {
      _out('  ---- ${entry.node}: not published (${res.dataRuntimeType})');
      continue;
    }
    final found = _idsFromItems(res.get<List<PubSubItem>>());
    if (found.isEmpty) continue;
    readable.add(entry.node);
    ids.addAll(found);
    _out('  OK   ${entry.node}: ${found.length} device(s)');
  }

  if (ids.isEmpty) {
    _out('  ---- no device list readable on either dialect');
    return false;
  }

  var resolvable = 0;
  for (final id in ids) {
    // Every dialect the list was published under, because a client may read
    // either. A bundle that exists in one and not the other is half-published,
    // and half-published is what produces a peer that encrypts to nobody.
    final outcomes = <String>[];
    for (final prefix in const [defactoBundles, specBundles]) {
      outcomes.add(await _bundleState(pubsub, peer, '$prefix:$id'));
    }
    final ok = outcomes.any((s) => s.startsWith('OK'));
    if (ok) {
      resolvable++;
    } else {
      _out('  FAIL device $id: ${outcomes.join("  ")}');
      continue;
    }
    _out('  OK   device $id: ${outcomes.join("  ")}');
  }

  _out(
    '  ==> $resolvable/${ids.length} advertised device(s) have a fetchable '
    'bundle',
  );
  return resolvable == ids.length;
}

/// 'OK' or the server's refusal, spelled out.
Future<String> _bundleState(PubSubManager pubsub, JID peer, String node) async {
  final res = await pubsub.getItems(peer, node);
  if (res.isType<List<PubSubItem>>()) {
    final items = res.get<List<PubSubItem>>();
    if (items.isEmpty) return 'empty($node)';
    // A bundle that parses as a bundle is what a client needs; one that is
    // merely present is not enough, so parse it rather than trusting the item.
    for (final item in items) {
      try {
        final doc = XmlDocument.parse(item.payload.toXml());
        if (doc.rootElement.name.local == 'bundle') {
          return 'OK($node)';
        }
      } catch (_) {
        return 'unparseable($node)';
      }
    }
    return 'not-a-bundle($node)';
  }
  if (res.isType<PubSubError>()) {
    // The whole stanza, not a field: `PubSubError`'s shape differs across
    // moxxmpp versions and the condition is the one thing worth reading, so the
    // reliable way to name the refusal is to look at what came back.
    return 'error:${res.toString().replaceAll('\n', ' ')}($node)';
  }
  return '${res.dataRuntimeType}($node)';
}

Set<int> _idsFromItems(List<PubSubItem> items) {
  final ids = <int>{};
  for (final item in items) {
    for (final child in item.payload.children) {
      if (child.tag != 'list' && child.tag != 'deviceList') continue;
      for (final device in child.children) {
        if (device.tag != 'device') continue;
        final id = int.tryParse('${device.attributes['id']}');
        if (id != null) ids.add(id);
      }
    }
  }
  return ids;
}
