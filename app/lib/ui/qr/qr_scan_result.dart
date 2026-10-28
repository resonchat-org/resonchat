// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Conversations `QrCodeProcessingActivity.onMiniUriScanned`: XMPP in-app;
// bare HTTP(S) asks before opening the browser. Other payloads are invalid.

import 'package:flutter/material.dart';

import 'package:moxxmpp/moxxmpp.dart' show XmppUri;
import 'package:url_launcher/url_launcher.dart';

import 'package:resonchat/l10n/l10n.dart';
import 'package:resonchat/ui/chat/linkified_text.dart';

/// Handle a QR payload the way Conversations does after a scan.
Future<void> handleQrScanResult(
  BuildContext context,
  String raw, {
  String? accountId,
}) async {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return;

  final xmpp =
      XmppUri.tryParse(trimmed) ??
      (trimmed.contains('@') && !trimmed.contains('://')
          ? XmppUri.tryParse(
              trimmed.toLowerCase().startsWith('xmpp:')
                  ? trimmed
                  : 'xmpp:$trimmed',
            )
          : null);
  if (xmpp != null) {
    await handleXmppUri(context, xmpp, accountId: accountId);
    return;
  }

  var href = trimmed;
  if (href.toLowerCase().startsWith('www.')) {
    href = 'https://$href';
  }
  final uri = Uri.tryParse(href);
  final scheme = uri?.scheme.toLowerCase() ?? '';
  if (uri != null &&
      (scheme == 'http' || scheme == 'https') &&
      uri.hasAuthority) {
    await _confirmOpenHttp(context, uri);
    return;
  }

  if (!context.mounted) return;
  ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(context.l10n.qrScanUnrecognized)));
}

/// Conversations `qr_code_contains_link` / `open_browser` dialog.
Future<void> _confirmOpenHttp(BuildContext context, Uri uri) async {
  final l10n = context.l10n;
  final open = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(l10n.qrCodeContainsLink),
      content: Text(uri.toString()),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(l10n.cancel),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(l10n.openInBrowser),
        ),
      ],
    ),
  );
  if (open != true || !context.mounted) return;
  try {
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(l10n.couldNotOpenLink)));
    }
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(l10n.couldNotOpenLink)));
    }
  }
}
