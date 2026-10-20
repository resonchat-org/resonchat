// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Renders [processMessageStyling] output (Gajim MessageWidget pipeline):
// fenced code, nested quotes, XEP-0393 spans, URI/JID links, emoji size.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:moxxmpp/moxxmpp.dart' show XmppUri, XmppUriQuerytype;
import 'package:url_launcher/url_launcher.dart';

import 'package:resonchat/account/account_hub.dart';
import 'package:resonchat/account/chat_ref.dart';
import 'package:resonchat/l10n/l10n.dart';
import 'package:resonchat/state/providers.dart';
import 'package:resonchat/ui/chat/code_snippet.dart';
import 'package:resonchat/ui/chat/emoji_body.dart';
import 'package:resonchat/ui/chat/message_styling.dart';
import 'package:resonchat/ui/chats/chats_viewmodel.dart';
import 'package:resonchat/ui/home/open_chat.dart';
import 'package:resonchat/ui/room/room_sheet.dart';
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
    return TextSpan(text: text, style: style);
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

    final link = _linkCovering(block.uris, a, b);
    if (link != null) {
      children.add(
        TextSpan(
          text: chunk,
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
          text: chunk,
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

    children.add(TextSpan(text: chunk, style: segStyle));
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
Future<void> handleXmppUri(BuildContext context, XmppUri uri) async {
  final kind = uri.knownQuerytype;
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
      await _startChatFromUri(context, container, bare);

    case XmppUriQuerytype.roster:
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
  if (result.isMuc) {
    if (result.chatKey != null) {
      openChat(context, result.chatKey!);
      return;
    }
    final room = result.mucJid ?? bare;
    await showJoinRoomSheet(context, initialRoomJid: room);
    return;
  }
  if (result.invalidJid || result.chatKey == null) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(context.l10n.invalidJid)));
    return;
  }
  openChat(context, result.chatKey!);
}
