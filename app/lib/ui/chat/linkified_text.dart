// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Renders [processMessageStyling] output (Gajim MessageWidget pipeline):
// fenced code, nested quotes, XEP-0393 spans, URI/JID links, emoji size.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:moxxmpp/moxxmpp.dart' show JID, XmppUri, XmppUriQuerytype;
import 'package:omemo_dart/omemo_dart_omemo2.dart' show hybridOmemo2Fingerprint;
import 'package:url_launcher/url_launcher.dart';

import 'package:resonchat/account/account_hub.dart';
import 'package:resonchat/account/chat_ref.dart';
import 'package:resonchat/crypto/dual/fingerprint_trust.dart';
import 'package:resonchat/crypto/fingerprint.dart';
import 'package:resonchat/l10n/l10n.dart';
import 'package:resonchat/ui/chat/code_snippet.dart';
import 'package:resonchat/ui/chat/emoji_body.dart';
import 'package:resonchat/ui/chat/message_styling.dart';
import 'package:resonchat/ui/chats/chats_viewmodel.dart';
import 'package:resonchat/ui/home/open_chat.dart';
import 'package:resonchat/ui/room/room_sheet.dart';
import 'package:resonchat/xmpp/account_share_uri.dart';
import 'package:resonchat/xmpp/notify_policy.dart';

/// Message body with Gajim-unified styling.
class LinkifiedText extends StatefulWidget {
  const LinkifiedText({
    super.key,
    required this.text,
    required this.style,
    this.highlightNicks = const [],
    this.mentionStyle,
    this.linkStyle,
    this.quoteColor,
  });

  final String text;
  final TextStyle style;
  final Iterable<String> highlightNicks;
  final TextStyle? mentionStyle;
  final TextStyle? linkStyle;
  final Color? quoteColor;

  @override
  State<LinkifiedText> createState() => _LinkifiedTextState();
}

class _LinkifiedTextState extends State<LinkifiedText> {
  final List<TapGestureRecognizer> _recognizers = [];
  int? _cacheKey;
  List<Widget>? _children;

  @override
  void dispose() {
    for (final r in _recognizers) {
      r.dispose();
    }
    super.dispose();
  }

  TapGestureRecognizer _recognizerFor(String url) {
    final r = TapGestureRecognizer()
      ..onTap = () {
        if (!mounted) return;
        activateMessageLink(context, url);
      };
    _recognizers.add(r);
    return r;
  }

  @override
  Widget build(BuildContext context) {
    final linkStyle =
        widget.linkStyle ??
        widget.style.copyWith(
          color: Theme.of(context).colorScheme.primary,
          decoration: TextDecoration.underline,
          decorationColor: Theme.of(context).colorScheme.primary,
        );
    final quoteColor =
        widget.quoteColor ??
        widget.style.color?.withValues(alpha: 0.75) ??
        Theme.of(context).colorScheme.onSurfaceVariant;
    final key = Object.hash(
      widget.text,
      Object.hashAll(widget.highlightNicks),
      widget.style,
      widget.mentionStyle,
      linkStyle,
      quoteColor,
    );
    if (_children == null || _cacheKey != key) {
      for (final r in _recognizers) {
        r.dispose();
      }
      _recognizers.clear();
      _cacheKey = key;
      _children = buildStyledMessageWidgets(
        widget.text,
        style: widget.style,
        highlightNicks: widget.highlightNicks,
        mentionStyle: widget.mentionStyle,
        linkStyle: linkStyle,
        quoteColor: quoteColor,
        recognizerFor: _recognizerFor,
      );
    }
    if (_children!.length == 1) return _children!.first;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: _children!,
    );
  }
}

/// Gajim `MessageWidget.add_with_styling` → widgets.
List<Widget> buildStyledMessageWidgets(
  String text, {
  required TextStyle style,
  required Iterable<String> highlightNicks,
  TextStyle? mentionStyle,
  required TextStyle linkStyle,
  required Color quoteColor,
  required TapGestureRecognizer Function(String url) recognizerFor,
}) {
  final result = processMessageStyling(text);
  return _widgetsForBlocks(
    result.blocks,
    style: style,
    highlightNicks: highlightNicks,
    mentionStyle: mentionStyle,
    linkStyle: linkStyle,
    quoteColor: quoteColor,
    recognizerFor: recognizerFor,
    quoteDepth: 0,
  );
}

List<Widget> _widgetsForBlocks(
  List<StyleBlock> blocks, {
  required TextStyle style,
  required Iterable<String> highlightNicks,
  TextStyle? mentionStyle,
  required TextStyle linkStyle,
  required Color quoteColor,
  required TapGestureRecognizer Function(String url) recognizerFor,
  required int quoteDepth,
}) {
  final widgets = <Widget>[];
  for (final block in blocks) {
    if (block is PlainBlock && block.text.isEmpty) continue;

    final Widget child;
    switch (block) {
      case PreBlock():
        final prepared = block.prepared;
        child = CodeSnippet(
          code: prepared.code,
          language: prepared.language,
          textStyle: quoteDepth > 0 ? style.copyWith(color: quoteColor) : style,
        );

      case QuoteBlock():
        final inner = _widgetsForBlocks(
          block.blocks,
          style: style,
          highlightNicks: highlightNicks,
          mentionStyle: mentionStyle,
          linkStyle: linkStyle,
          quoteColor: quoteColor,
          recognizerFor: recognizerFor,
          quoteDepth: quoteDepth + 1,
        );
        final quoted = inner.length == 1
            ? inner.first
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: inner,
              );
        child = Container(
          decoration: BoxDecoration(
            border: Border(left: BorderSide(color: quoteColor, width: 2)),
          ),
          padding: const EdgeInsets.only(left: 8),
          child: quoted,
        );

      case PlainBlock():
        var plainStyle = quoteDepth > 0
            ? style.copyWith(color: quoteColor)
            : style;
        if (quoteDepth == 0 && isEmojiOnlyMessage(block.text)) {
          final base = plainStyle.fontSize ?? 15;
          plainStyle = plainStyle.copyWith(
            fontSize: base * emojiOnlyScale(block.text),
            height: 1.1,
          );
        }
        child = Text.rich(
          plainBlockSpan(
            block,
            style: plainStyle,
            highlightNicks: highlightNicks,
            mentionStyle: mentionStyle,
            linkStyle: linkStyle,
            recognizerFor: recognizerFor,
          ),
          // Long tokens (URLs) get ZWSP breaks in [plainBlockSpan]; clip any
          // remainder so the bubble never paints a yellow/black overflow.
          overflow: TextOverflow.clip,
        );
    }
    if (widgets.isNotEmpty) widgets.add(const SizedBox(height: 6));
    widgets.add(child);
  }
  return widgets.isEmpty ? [Text('', style: style)] : widgets;
}

/// Render one [PlainBlock] as a rich span (Gajim markers stay styled).
InlineSpan plainBlockSpan(
  PlainBlock block, {
  required TextStyle style,
  required Iterable<String> highlightNicks,
  TextStyle? mentionStyle,
  required TextStyle linkStyle,
  required TapGestureRecognizer Function(String url) recognizerFor,
}) {
  final text = block.text;
  if (text.isEmpty) return TextSpan(text: text, style: style);

  final mentionHits = <({int start, int end})>[];
  for (final name in highlightNicks.where((n) => n.trim().isNotEmpty)) {
    for (final m in nickHighlightPattern(name).allMatches(text)) {
      mentionHits.add((start: m.start, end: m.end));
    }
  }

  if (block.spans.isEmpty && block.uris.isEmpty && mentionHits.isEmpty) {
    return TextSpan(text: softBreakLongRuns(text), style: style);
  }

  final bounds = <int>{0, text.length};
  for (final s in block.spans) {
    bounds.add(s.start);
    bounds.add(s.end);
  }
  for (final u in block.uris) {
    bounds.add(u.start);
    bounds.add(u.end);
  }
  for (final h in mentionHits) {
    bounds.add(h.start);
    bounds.add(h.end);
  }
  final points = bounds.toList()..sort();

  final mentionResolved =
      mentionStyle ?? style.copyWith(fontWeight: FontWeight.w700);

  final children = <InlineSpan>[];
  for (var i = 0; i < points.length - 1; i++) {
    final a = points[i];
    final b = points[i + 1];
    if (a >= b) continue;
    final chunk = text.substring(a, b);

    var segStyle = style;
    for (final s in block.spans) {
      if (a >= s.start && b <= s.end) {
        segStyle = _styleForKind(s.kind, segStyle);
      }
    }

    // Display-only breaks; link targets stay the raw URL.
    final shown = softBreakLongRuns(chunk);

    final link = _linkCovering(block.uris, a, b);
    if (link != null) {
      children.add(
        TextSpan(
          text: shown,
          style: linkStyle.merge(
            TextStyle(
              fontWeight: segStyle.fontWeight,
              fontStyle: segStyle.fontStyle,
              decoration: TextDecoration.combine([
                if (segStyle.decoration != null &&
                    segStyle.decoration != TextDecoration.none)
                  segStyle.decoration!,
                TextDecoration.underline,
              ]),
              fontFamily: segStyle.fontFamily,
            ),
          ),
          recognizer: recognizerFor(link.url),
        ),
      );
      continue;
    }

    final mentioned = mentionHits.any((h) => a >= h.start && b <= h.end);
    if (mentioned) {
      children.add(
        TextSpan(
          text: shown,
          style: mentionResolved.merge(
            TextStyle(
              fontStyle: segStyle.fontStyle,
              decoration: segStyle.decoration,
              fontFamily: segStyle.fontFamily,
            ),
          ),
        ),
      );
      continue;
    }

    children.add(TextSpan(text: shown, style: segStyle));
  }

  return TextSpan(style: style, children: children);
}

TextStyle _styleForKind(StyleKind kind, TextStyle base) => switch (kind) {
  StyleKind.strong => base.copyWith(fontWeight: FontWeight.w700),
  StyleKind.emphasis => base.copyWith(fontStyle: FontStyle.italic),
  StyleKind.strike => base.copyWith(decoration: TextDecoration.lineThrough),
  StyleKind.pre => base.copyWith(
    fontFamily: 'monospace',
    fontFamilyFallback: const [
      'Courier',
      'Courier New',
      'Menlo',
      'Monaco',
      'Consolas',
    ],
  ),
};

StyleLink? _linkCovering(List<StyleLink> links, int a, int b) {
  for (final l in links) {
    if (a >= l.start && b <= l.end) return l;
  }
  return null;
}

/// Zero-width break opportunities in long runs (URLs, tokens). Not used for
/// fenced code — that lives in [CodeSnippet] with horizontal scroll.
String softBreakLongRuns(String text, {int every = 24}) {
  if (text.length < every) return text;
  final out = StringBuffer();
  var run = 0;
  for (final c in text.characters) {
    out.write(c);
    if (c == '\n' || c == '\r' || c == '\t' || c == ' ' || c == '\u200B') {
      run = 0;
      continue;
    }
    run++;
    if (run >= every) {
      out.write('\u200B');
      run = 0;
    }
  }
  return out.toString();
}

/// Builds spans with link taps (and optional IM styles via full pipeline).
InlineSpan linkAwareSpan(
  String text, {
  required TextStyle style,
  required Iterable<String> highlightNicks,
  TextStyle? mentionStyle,
  TextStyle? linkStyle,
  required TapGestureRecognizer Function(String url) recognizerFor,
}) {
  final result = processMessageStyling(text);
  final plain = result.blocks.whereType<PlainBlock>();
  if (plain.length == 1 && result.blocks.length == 1) {
    return plainBlockSpan(
      plain.first,
      style: style,
      highlightNicks: highlightNicks,
      mentionStyle: mentionStyle,
      linkStyle:
          linkStyle ?? style.copyWith(decoration: TextDecoration.underline),
      recognizerFor: recognizerFor,
    );
  }
  // Multi-block: flatten text with links only for callers that need a span.
  return plainBlockSpan(
    PlainBlock(start: 0, end: text.length, text: text, uris: processUris(text)),
    style: style,
    highlightNicks: highlightNicks,
    mentionStyle: mentionStyle,
    linkStyle:
        linkStyle ?? style.copyWith(decoration: TextDecoration.underline),
    recognizerFor: recognizerFor,
  );
}

/// Open a web / mailto / tel / geo URL, or handle an `xmpp:` URI in-app.
Future<void> activateMessageLink(BuildContext context, String raw) async {
  final xmpp =
      XmppUri.tryParse(raw) ??
      (raw.contains('@') && !raw.contains('://')
          ? XmppUri.tryParse(
              raw.toLowerCase().startsWith('xmpp:') ? raw : 'xmpp:$raw',
            )
          : null);
  if (xmpp != null) {
    await handleXmppUri(context, xmpp);
    return;
  }

  var href = raw;
  if (href.toLowerCase().startsWith('www.')) {
    href = 'https://$href';
  }
  final uri = Uri.tryParse(href);
  if (uri == null || uri.scheme.isEmpty) return;

  const launchable = {'http', 'https', 'mailto', 'ftp', 'ftps', 'geo', 'tel'};
  if (!launchable.contains(uri.scheme.toLowerCase())) return;
  if ((uri.scheme == 'http' || uri.scheme == 'https') && !uri.hasAuthority) {
    return;
  }

  final l10n = context.l10n;
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

/// Gajim `MainWindow.open_xmpp_iri`: `join` / `roster` / `message`|`""`.
///
/// When the IRI carries `omemo-sid-*` fingerprints (Conversations share URI),
/// ask whether to mark them [FingerprintTrust.verified]; skip keeps the
/// usual new-device default.
Future<void> handleXmppUri(
  BuildContext context,
  XmppUri uri, {
  String? accountId,
}) async {
  final kind = uri.knownQuerytype;
  if (kind == null) return;

  final container = ProviderScope.containerOf(context);
  final bare = uri.jid.toString();
  final effectiveAccount = accountId ?? accountHub.primarySession?.account.id;
  final fingerprints = parseOmemoSidFingerprints(uri.params);
  final pqFingerprints = parseOmemoPqFingerprints(uri.params);
  if (fingerprints.isNotEmpty || pqFingerprints.isNotEmpty) {
    final markVerified = await _promptVerifyOmemoFingerprints(
      context,
      bare,
      fingerprints,
      pqFingerprints: pqFingerprints,
    );
    if (!context.mounted) return;
    if (markVerified == true) {
      await _applyVerifiedOmemoFingerprints(
        bare,
        fingerprints,
        accountId: effectiveAccount,
      );
      await _applyVerifiedOmemoPqFingerprints(
        bare,
        pqFingerprints,
        accountId: effectiveAccount,
      );
      if (!context.mounted) return;
    }
  }

  switch (kind) {
    case XmppUriQuerytype.join:
      final session = effectiveAccount == null
          ? accountHub.primarySession
          : accountHub.session(effectiveAccount);
      final existing = session == null ? null : await session.db.getChat(bare);
      if (!context.mounted) return;
      if (existing != null && existing.isGroup && session != null) {
        openChat(
          context,
          ChatRef(accountId: session.account.id, jid: bare).key,
        );
        return;
      }
      await showJoinRoomSheet(
        context,
        initialRoomJid: bare,
        accountId: effectiveAccount,
      );

    case XmppUriQuerytype.message:
    case XmppUriQuerytype.none:
      await _startChatFromUri(
        context,
        container,
        bare,
        accountId: effectiveAccount,
      );

    case XmppUriQuerytype.roster:
      await _startChatFromUri(
        context,
        container,
        bare,
        accountId: effectiveAccount,
      );
  }
}

/// Returns true when the user chose Verified; false/null → leave default trust.
Future<bool?> _promptVerifyOmemoFingerprints(
  BuildContext context,
  String bare,
  List<OmemoSidFingerprint> fingerprints, {
  List<OmemoPqUriFingerprint> pqFingerprints = const [],
}) {
  final l10n = context.l10n;
  final pretty = <String>[
    for (final f in fingerprints)
      formatFingerprint(fingerprintForTrustStore(f.fingerprint)),
    for (final f in pqFingerprints)
      formatFingerprint(f.hybrid ?? fingerprintForTrustStore(f.classical)),
  ].join('\n\n');
  return showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(l10n.verifyOmemoKeysTitle),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.verifyOmemoKeysBody(bare)),
            const SizedBox(height: 12),
            SelectableText(
              pretty,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(l10n.skipVerifyFingerprint),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(l10n.markFingerprintVerified),
        ),
      ],
    ),
  );
}

Future<void> _applyVerifiedOmemoFingerprints(
  String bare,
  List<OmemoSidFingerprint> fingerprints, {
  String? accountId,
}) async {
  final xmpp = accountId == null
      ? accountHub.primarySession?.xmpp
      : accountHub.session(accountId)?.xmpp;
  if (xmpp == null) return;
  for (final item in fingerprints) {
    final fp = fingerprintForTrustStore(item.fingerprint);
    await xmpp.setPeerFingerprintTrust(
      bareJid: bare,
      fingerprint: fp,
      trust: FingerprintTrust.verified,
    );
  }
}

/// Mark PQ OMEMO2 classical keys verified; pin `<pq-ik>` when hybrid matches.
Future<void> _applyVerifiedOmemoPqFingerprints(
  String bare,
  List<OmemoPqUriFingerprint> fingerprints, {
  String? accountId,
}) async {
  final xmpp = accountId == null
      ? accountHub.primarySession?.xmpp
      : accountHub.session(accountId)?.xmpp;
  if (xmpp == null || fingerprints.isEmpty) return;
  final trust = xmpp.fingerprintTrust;
  final pins = xmpp.bTrack?.pqPins;
  for (final item in fingerprints) {
    final classical = fingerprintForTrustStore(item.classical);
    await trust?.rememberDevice(
      jid: bare,
      deviceId: item.deviceId,
      fingerprint: classical,
      omemo2: true,
    );
    await xmpp.setPeerFingerprintTrust(
      bareJid: bare,
      fingerprint: classical,
      trust: FingerprintTrust.verified,
    );
    final hybrid = item.hybrid;
    if (hybrid == null || pins == null) continue;
    // Fetch bundle so a scanned hybrid can (re)pin the post-quantum half
    // (proto-XEP §10.1 — only out-of-band input allowed to replace a pin).
    try {
      final bundle = await xmpp.tracks?.getPqBundle(
        JID.fromString(bare),
        item.deviceId,
      );
      if (bundle == null || !bundle.hasPqIdentity) continue;
      final pqIk = Uint8List.fromList(base64Decode(bundle.pqIk));
      final computed = hybridOmemo2Fingerprint(bundle.ikSerialized, pqIk);
      if (computed != hybrid) continue;
      await pins.pinReplace(bare, classical, pqIk);
    } catch (_) {
      // Offline / bad bundle — classical trust still recorded.
    }
  }
}

Future<void> _startChatFromUri(
  BuildContext context,
  ProviderContainer container,
  String bare, {
  String? accountId,
}) async {
  final result = await container
      .read(chatsViewModelProvider.notifier)
      .openChatByJid(bare, accountId: accountId);
  if (!context.mounted) return;
  if (result.isMuc) {
    if (result.chatKey != null) {
      openChat(context, result.chatKey!);
      return;
    }
    final room = result.mucJid ?? bare;
    await showJoinRoomSheet(
      context,
      initialRoomJid: room,
      accountId: accountId,
    );
    return;
  }
  if (result.invalidJid || result.chatKey == null) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(context.l10n.invalidJid)));
    return;
  }
  openChat(context, result.chatKey!);
}
