// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Clickable http(s)/www and xmpp: spans (Gajim open_uri / open_xmpp_iri),
// plus Conversations IM styles (`*bold*` `_italic_` `~strike~` `` `code` ``)
// and `>` / `»` quote bars (`QuoteHelper` / `QuoteSpan`).

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:moxxmpp/moxxmpp.dart' show XmppUri, XmppUriQuerytype;
import 'package:url_launcher/url_launcher.dart';

import '../../account/account_hub.dart';
import '../../account/chat_ref.dart';
import '../../l10n/l10n.dart';
import '../../state/providers.dart';
import '../../xmpp/notify_policy.dart';
import '../chats/chats_viewmodel.dart';
import '../home/open_chat.dart';
import '../room/room_sheet.dart';
import 'im_style.dart';
import 'quote_body.dart';

/// Web links + any `xmpp:` URI (Gajim linkifies plain jids too).
///
/// The host/path class must apply to `https?://` / `www.` as well as `xmpp:`;
/// otherwise the scheme alone matches and the rest of the URL is left plain.
final _linkPattern = RegExp(
  r'''(?:(?:https?://|www\.)[^\s<>"']+|xmpp:[^\s<>"']+)''',
  caseSensitive: false,
);

final _tailPunct = RegExp(r'[),.\]>]+$');

/// Message body with quotes, IM styles, mention highlights, and tappable links.
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

  /// Conversations `QuoteSpan` bar / quote text colour.
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
      _children = _buildBlocks(
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

List<Widget> _buildBlocks(
  String text, {
  required TextStyle style,
  required Iterable<String> highlightNicks,
  TextStyle? mentionStyle,
  required TextStyle linkStyle,
  required Color quoteColor,
  required TapGestureRecognizer Function(String url) recognizerFor,
}) {
  final blocks = parseBodyBlocks(text);
  if (blocks.isEmpty) {
    return [Text('', style: style)];
  }

  final widgets = <Widget>[];
  for (var i = 0; i < blocks.length; i++) {
    final block = blocks[i];
    final isQuote = block.quoteDepth > 0;
    final blockStyle = isQuote ? style.copyWith(color: quoteColor) : style;
    final span = styledMessageSpan(
      block.text,
      style: blockStyle,
      highlightNicks: highlightNicks,
      mentionStyle: mentionStyle,
      linkStyle: linkStyle,
      recognizerFor: recognizerFor,
    );

    Widget child = Text.rich(span);

    if (isQuote) {
      // Nested Conversations QuoteSpans → stacked leading bars.
      for (var d = 0; d < block.quoteDepth; d++) {
        child = Container(
          decoration: BoxDecoration(
            border: Border(left: BorderSide(color: quoteColor, width: 2)),
          ),
          padding: const EdgeInsets.only(left: 8),
          child: child,
        );
      }
    }

    // Conversations DividerSpan padding between quote and neighbouring text.
    if (i > 0) {
      widgets.add(const SizedBox(height: 6));
    }
    widgets.add(child);
  }
  return widgets;
}

/// Builds spans with IM styles, link taps, and nick bolding.
InlineSpan styledMessageSpan(
  String text, {
  required TextStyle style,
  required Iterable<String> highlightNicks,
  TextStyle? mentionStyle,
  TextStyle? linkStyle,
  required TapGestureRecognizer Function(String url) recognizerFor,
}) {
  if (text.isEmpty) return TextSpan(text: text, style: style);

  final styles = parseImStyles(text);
  final links = <({int start, int end, String url})>[];
  for (final m in _linkPattern.allMatches(text)) {
    var match = m.group(0)!;
    match = match.replaceFirst(_tailPunct, '');
    if (match.isEmpty) continue;
    final start = m.start;
    final end = start + match.length;
    links.add((start: start, end: end, url: match));
  }

  final mentionHits = <({int start, int end})>[];
  final names = highlightNicks.where((n) => n.trim().isNotEmpty).toList();
  for (final name in names) {
    for (final m in nickHighlightPattern(name).allMatches(text)) {
      mentionHits.add((start: m.start, end: m.end));
    }
  }

  if (styles.isEmpty && links.isEmpty && mentionHits.isEmpty) {
    return TextSpan(text: text, style: style);
  }

  final bounds = <int>{0, text.length};
  for (final s in styles) {
    bounds.add(s.start);
    bounds.add(s.contentStart);
    bounds.add(s.contentEnd);
    bounds.add(s.end + 1);
  }
  for (final l in links) {
    bounds.add(l.start);
    bounds.add(l.end);
  }
  for (final h in mentionHits) {
    bounds.add(h.start);
    bounds.add(h.end);
  }
  final points = bounds.toList()..sort();

  final linkStyleResolved =
      linkStyle ?? style.copyWith(decoration: TextDecoration.underline);
  final mentionResolved =
      mentionStyle ?? style.copyWith(fontWeight: FontWeight.w700);
  final keywordColor = imKeywordColor(style.color ?? const Color(0xFF000000));

  final children = <InlineSpan>[];
  for (var i = 0; i < points.length - 1; i++) {
    final a = points[i];
    final b = points[i + 1];
    if (a >= b) continue;
    final chunk = text.substring(a, b);

    var segStyle = style;
    for (final s in styles) {
      if (a >= s.contentStart && b <= s.contentEnd) {
        segStyle = imStyleForKeyword(s.keyword, segStyle);
      }
    }
    var isKeyword = false;
    for (final s in styles) {
      for (final (ks, ke) in s.keywordRanges) {
        if (a >= ks && b <= ke) {
          isKeyword = true;
          break;
        }
      }
      if (isKeyword) break;
    }
    if (isKeyword) {
      segStyle = segStyle.copyWith(color: keywordColor);
    }

    final link = _linkCovering(links, a, b);
    if (link != null) {
      children.add(
        TextSpan(
          text: chunk,
          style: linkStyleResolved.merge(
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
          text: chunk,
          style: mentionResolved.merge(
            TextStyle(
              fontStyle: segStyle.fontStyle,
              decoration: segStyle.decoration,
              fontFamily: segStyle.fontFamily,
              color: isKeyword ? keywordColor : mentionResolved.color,
            ),
          ),
        ),
      );
      continue;
    }

    children.add(TextSpan(text: chunk, style: segStyle));
  }

  return TextSpan(style: style, children: children);
}

({int start, int end, String url})? _linkCovering(
  List<({int start, int end, String url})> links,
  int a,
  int b,
) {
  for (final l in links) {
    if (a >= l.start && b <= l.end) return l;
  }
  return null;
}

/// Builds spans with link taps and nick bolding (no IM styles / quotes).
InlineSpan linkAwareSpan(
  String text, {
  required TextStyle style,
  required Iterable<String> highlightNicks,
  TextStyle? mentionStyle,
  TextStyle? linkStyle,
  required TapGestureRecognizer Function(String url) recognizerFor,
}) {
  return styledMessageSpan(
    text,
    style: style,
    highlightNicks: highlightNicks,
    mentionStyle: mentionStyle,
    linkStyle: linkStyle,
    recognizerFor: recognizerFor,
  );
}

/// Open a web URL externally, or handle an `xmpp:` URI in-app (Gajim).
Future<void> activateMessageLink(BuildContext context, String raw) async {
  final xmpp = XmppUri.tryParse(raw);
  if (xmpp != null) {
    await handleXmppUri(context, xmpp);
    return;
  }

  var href = raw;
  if (href.toLowerCase().startsWith('www.')) {
    href = 'https://$href';
  }
  final uri = Uri.tryParse(href);
  if (uri == null ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      !uri.hasAuthority) {
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

/// Gajim `MainWindow.open_xmpp_iri`: `join` / `roster` / `message`|`""`;
/// unknown querytypes are ignored.
Future<void> handleXmppUri(BuildContext context, XmppUri uri) async {
  final kind = uri.knownQuerytype;
  // Unknown registered-looking querytype (e.g. `?vcard`) — no handler.
  if (kind == null) return;

  final container = ProviderScope.containerOf(context);
  final bare = uri.jid.toString();

  switch (kind) {
    case XmppUriQuerytype.join:
      final db = container.read(databaseProvider);
      final existing = await db.getChat(bare);
      if (!context.mounted) return;
      if (existing != null && existing.isGroup) {
        final accountId = accountHub.primarySession?.account.id;
        final chatKey = accountId == null
            ? bare
            : ChatRef(accountId: accountId, jid: bare).key;
        openChat(context, chatKey);
        return;
      }
      await showJoinRoomSheet(context, initialRoomJid: bare);

    case XmppUriQuerytype.message:
    case XmppUriQuerytype.none:
      // Gajim: `message | ""` → start-chat (optional body).
      await _startChatFromUri(context, container, bare);

    case XmppUriQuerytype.roster:
      // Gajim: add-contact; we upsert chat + roster via openChatByJid.
      await _startChatFromUri(context, container, bare);
  }
}

Future<void> _startChatFromUri(
  BuildContext context,
  ProviderContainer container,
  String bare,
) async {
  final result = await container
      .read(chatsViewModelProvider.notifier)
      .openChatByJid(bare);
  if (!context.mounted) return;
  if (result.invalidJid || result.chatKey == null) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(context.l10n.invalidJid)));
    return;
  }
  openChat(context, result.chatKey!);
}
