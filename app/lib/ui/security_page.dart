// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Encryption info page: which track protects this chat, every device that
// can read it, and the fingerprints users compare in person.
//
// Interaction follows the lessons drawn from Briar (docs/09 §1.1): show the
// fingerprint rather than hiding it, and make the verification explicitly
// mutual — a single-sided "I checked" is what produces false confidence.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../crypto/fingerprint.dart';
import '../omemo/track.dart';
import '../omemo/track_resolver.dart';
import '../xmpp/capabilities.dart';
import '../state/providers.dart';
import 'theme.dart';

/// How far this chat's verification has got.
enum VerifyStage {
  /// Nobody has compared fingerprints.
  none,

  /// We showed our fingerprint; waiting for the other side to confirm.
  sent,

  /// Both sides confirmed in person.
  bothConfirmed,
}

class SecurityPage extends ConsumerStatefulWidget {
  const SecurityPage({super.key, required this.chatJid});

  final String chatJid;

  @override
  ConsumerState<SecurityPage> createState() => _SecurityPageState();
}

class _SecurityPageState extends ConsumerState<SecurityPage> {
  String? _fingerprint;
  int? _deviceId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final om = ref.read(xmppServiceProvider).omemo;
    if (om == null) return;
    final id = await om.getDeviceId();
    final fp = await (await om.getDevice()).fingerprint;
    if (!mounted) return;
    setState(() {
      _deviceId = id;
      _fingerprint = fp;
    });
  }

  Future<void> _copyFingerprint() async {
    final fp = _fingerprint;
    if (fp == null) return;
    await Clipboard.setData(ClipboardData(text: formatFingerprint(fp)));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Fingerprint copied')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tg = context.tg;
    final track = ref.watch(chatTrackProvider(widget.chatJid)).value ??
        Track.standard;
    final caps = ref.watch(chatCapabilitiesProvider(widget.chatJid)).value;

    return Scaffold(
      appBar: AppBar(title: const Text('Encryption')),
      body: ListView(
        children: [
          _section(tg, 'This chat'),
          ListTile(
            leading: Icon(
              track.icon,
              color: track == Track.none ? tg.textSecondary : tg.accent,
            ),
            title: Text('You chose ${track.label}'),
            subtitle: Text(_describe(track, caps)),
          ),

          _section(tg, 'Devices'),
          ListTile(
            leading: const Icon(Icons.smartphone),
            title: Text('This device: ${_deviceId ?? '—'}'),
            subtitle: const Text('Counted as a recipient so Carbons work'),
          ),
          if (caps != null)
            ListTile(
              leading: const Icon(Icons.devices_other),
              title: Text(
                'Recipient devices: ${caps.recipientDevices.length}',
              ),
              subtitle: Text(
                caps.recipientDevices.isEmpty
                    ? 'None published yet'
                    : caps.recipientDevices.join(', '),
              ),
            ),
          if (caps != null)
            ListTile(
              leading: Icon(
                caps.pqDevices.isNotEmpty ? Icons.bolt : Icons.bolt_outlined,
                color: caps.pqDevices.isNotEmpty ? tg.accent : tg.textSecondary,
              ),
              title: Text('Post-quantum: ${caps.pqDevices.length} device(s)'),
              subtitle: Text(
                caps.pqDevices.isEmpty
                    ? 'No device publishes a PQ bundle'
                    : 'Upgrade is automatic once every device does',
              ),
            ),

          _section(tg, 'Verify identity'),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Text(
              'Compare this with the other person, in person or over a call '
              'you already trust. It proves you are talking to the right '
              'device and that nobody is in the middle. One comparison covers '
              'both encryption tracks.',
              style: TextStyle(fontSize: 13, color: tg.textSecondary),
            ),
          ),
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: tg.separator),
            ),
            child: SelectableText(
              formatFingerprint(_fingerprint ?? '—'),
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 13,
                color: tg.textPrimary,
                height: 1.6,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Center(
            child: OutlinedButton.icon(
              onPressed: _fingerprint == null ? null : _copyFingerprint,
              icon: const Icon(Icons.copy, size: 18),
              label: const Text('Copy fingerprint'),
            ),
          ),

          _section(tg, 'Verification status'),
          const _VerificationSteps(),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  static Widget _section(TgColors tg, String title) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
        child: Text(
          title,
          style: TextStyle(
            color: tg.accent,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      );

  /// The chosen track, and separately whether it can currently be used.
  static String _describe(Track track, ChatCapabilities? caps) {
    final resolution = resolveTrack(requested: track, capabilities: caps);
    if (!resolution.canSend) {
      return '${resolution.blocked!.consequence} '
          'Nothing is sent on ${track.label} until you choose otherwise.';
    }
    return switch (track) {
      Track.pq => 'End-to-end encrypted with post-quantum keys',
      Track.standard =>
        'End-to-end encrypted (standard OMEMO, works with other apps)',
      Track.none => 'Sent in the clear, as you chose',
    };
  }
}

/// Explicit, two-sided checklist. Briar's post-mortem showed that a
/// one-sided confirmation is what creates false confidence, so both boxes
/// must be ticked (docs/09 §1.1).
class _VerificationSteps extends StatefulWidget {
  const _VerificationSteps();

  @override
  State<_VerificationSteps> createState() => _VerificationStepsState();
}

class _VerificationStepsState extends State<_VerificationSteps> {
  bool _weShowed = false;
  bool _theyConfirmed = false;

  @override
  Widget build(BuildContext context) {
    final tg = context.tg;
    final done = _weShowed && _theyConfirmed;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CheckboxListTile(
          value: _weShowed,
          onChanged: (v) => setState(() => _weShowed = v ?? false),
          controlAffinity: ListTileControlAffinity.leading,
          title: const Text('I showed my fingerprint to them'),
          subtitle: Text(
            'They must see the same digits on their own screen',
            style: TextStyle(fontSize: 12, color: tg.textSecondary),
          ),
        ),
        CheckboxListTile(
          value: _theyConfirmed,
          onChanged: _weShowed
              ? (v) => setState(() => _theyConfirmed = v ?? false)
              : null,
          controlAffinity: ListTileControlAffinity.leading,
          title: const Text('They confirmed theirs matches'),
          subtitle: Text(
            _weShowed
                ? 'Read every group out loud before ticking this'
                : 'Tick the previous box first',
            style: TextStyle(fontSize: 12, color: tg.textSecondary),
          ),
        ),
        if (done)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Row(
              children: [
                Icon(Icons.verified_user, size: 18, color: tg.unreadBadge),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Verified in person. Key changes will now warn you.',
                    style: TextStyle(
                      fontSize: 13,
                      color: tg.unreadBadge,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}