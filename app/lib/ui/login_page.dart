// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Unattended login for smoke tests (see tool/smoke_test.sh).
//
// Enabled only in debug builds via --dart-define=RESONCHAT_SMOKE=<jid>:<pass>
// so automated runs never need to drive the on-screen keyboard, and no
// credential can be baked into a release build. Repeated logins reuse the
// persisted OMEMO device instead of registering a new one.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart';
import '../state/providers.dart';
import '../store/account_store.dart';
import '../store/roster_state.dart';
import '../xmpp/connection.dart';
import 'theme.dart';

/// Parsed `--dart-define` credentials, or null when unset.
({String jid, String password})? smokeCredentials() {
  if (!kDebugMode) return null;
  const raw = String.fromEnvironment('RESONCHAT_SMOKE');
  if (raw.isEmpty) return null;
  final split = raw.indexOf(':');
  if (split <= 0) return null;
  return (
    jid: raw.substring(0, split),
    password: raw.substring(split + 1),
  );
}

class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key});

  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage> {
  final _jid = TextEditingController();
  final _password = TextEditingController();
  final _host = TextEditingController();
  bool _busy = false;
  bool _smokeRan = false;
  bool _restoredRan = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final smoke = smokeCredentials();
    if (smoke != null) {
      _jid.text = smoke.jid;
      _password.text = smoke.password;
      // Run once the first frame is up so Riverpod overrides are ready.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _smokeRan) return;
        _smokeRan = true;
        _connect();
      });
      return;
    }
    // Restore the last account and log in without being asked.
    //
    // A messenger that greets you with a password box every time the socket
    // drops is not a client you can leave running, and the drops are normal:
    // servers close idle connections, radios switch, laptops sleep. So the
    // keystore copy of the credential is spent here to reconnect by itself.
    //
    // The fields are filled first, before the attempt, so that a *failed*
    // auto-login still leaves the form usable instead of blank — the user sees
    // their own account and the real error, rather than an empty page and a
    // button.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || _restoredRan) return;
      _restoredRan = true;
      final stored = await AccountStore().load();
      if (stored == null || !mounted) return;
      _jid.text = stored.jid;
      _password.text = stored.password;
      if (stored.hasHost) _host.text = stored.host!;
      await _connect();
    });
  }

  @override
  void dispose() {
    _jid.dispose();
    _password.dispose();
    _host.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final xmpp = ref.read(xmppServiceProvider);
      final ok = await xmpp.connect(
        jid: _jid.text.trim(),
        password: _password.text,
        host: _host.text.trim().isEmpty ? null : _host.text.trim(),
        rosterState: DriftRosterStateManager(ref.read(databaseProvider)),
      );
      if (!ok) {
        setState(
          () => _error =
              xmpp.lastError ?? context.l10n.authenticationFailed,
        );
        // A stored password that the server no longer accepts must not be
        // retried on every launch: the user would watch the app fail the same
        // way forever and never reach the field they could fix it in.
        await AccountStore().clear();
        return;
      }

      // Saved only after the server has accepted it, so a wrong password is
      // never remembered — which is what makes "log in once" safe.
      await AccountStore().save(
        StoredAccount(
          jid: _jid.text.trim(),
          password: _password.text,
          host: _host.text.trim().isEmpty ? null : _host.text.trim(),
        ),
      );
      ref.read(connectionStateProvider.notifier).state =
          XmppConnectionState.connected;
      final items = await xmpp.requestRoster();
      for (final item in items) {
        await ref.read(databaseProvider).upsertChat(
              item.jid,
              title: item.name ?? item.jid,
            );
      }
      await xmpp.ensureOmemoDevice();
      // Keep the one-time-prekey pool full so new inbound sessions keep
      // forward secrecy.
      await xmpp.replenishPrekeys();
      // Publish our post-quantum bundle so peers can upgrade to the B track.
      await xmpp.initialiseBTrack();
      final db = ref.read(databaseProvider);
      // Conversations connectMultiModeConversations: rejoin stored rooms.
      final rooms = await db.groupChatsForJoin();
      await xmpp.rejoinGroupChats([
        for (final c in rooms) (roomJid: c.jid, nick: c.mucNick),
      ]);
      // Pull missed messages from the account archive (XEP-0313).
      // Conversations MessageArchiveManager.catchup(): RSM after archive id
      // when known, otherwise start from last local message timestamp
      // (getLastMessageReceived), capped to MAM_MAX_CATCHUP (5 days).
      final afterId = await db.metaValue(XmppService.mamCatchupIdKey);
      final startRaw = await db.metaValue(XmppService.mamCatchupTsKey);
      final metaTs =
          startRaw != null ? DateTime.tryParse(startRaw) : null;
      final dbTs = await db.latestMessageTimestamp();
      // Prefer the later of meta cursor and last stored message — same idea
      // as Conversations MamReference.max(...).
      DateTime? start;
      if (afterId == null || afterId.isEmpty) {
        if (metaTs != null && dbTs != null) {
          start = metaTs.isAfter(dbTs) ? metaTs : dbTs;
        } else {
          start = metaTs ?? dbTs;
        }
      }
      await xmpp.catchUpHistory(
        afterId: afterId,
        start: start,
        saveCursor: (id, ts) async {
          if (id != null && id.isNotEmpty) {
            await db.setMetaValue(XmppService.mamCatchupIdKey, id);
          }
          if (ts != null) {
            await db.setMetaValue(
              XmppService.mamCatchupTsKey,
              ts.toUtc().toIso8601String(),
            );
          }
        },
      );
      if (mounted) Navigator.of(context).pushReplacementNamed('/chats');
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tg = context.tg;
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.appName)),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _jid,
                decoration: InputDecoration(labelText: l10n.jid),
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _password,
                decoration: InputDecoration(labelText: l10n.password),
                obscureText: true,
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _host,
                decoration: InputDecoration(
                  labelText: l10n.hostOptional,
                ),
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _connect(),
              ),
              const SizedBox(height: 24),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    _error!,
                    style: TextStyle(color: tg.danger),
                    textAlign: TextAlign.center,
                  ),
                ),
              ElevatedButton(
                onPressed: _busy ? null : _connect,
                style: ElevatedButton.styleFrom(
                  backgroundColor: tg.accent,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                child: Text(_busy ? l10n.connecting : l10n.connect),
              ),
            ],
          ),
        ),
      ),
    );
  }
}