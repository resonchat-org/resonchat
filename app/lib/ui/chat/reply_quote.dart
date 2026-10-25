// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Reply-quote display, following monocles chat.
//
// monocles does not keep a second copy of the quote for the card: the leading
// `>` block in the message body *is* the quote, and `inReplyTo` is only used
// for the author line. Doing the same here means a reply written by an older
// build — or by a client whose fallback offsets we never stored — still shows
// the right quote, and the bubble text never starts with the quote markers.

import 'package:resonchat/persistence/database.dart';
import 'package:resonchat/ui/chat/chat_nicks.dart';

/// The body split into the reply's own text and its leading quote.
class ReplyBodySplit {
  const ReplyBodySplit({required this.body, required this.quote});

  /// The reply text, with the quote block removed.
  final String body;

  /// The quoted text, with the `> ` markers removed.
  final String quote;
}

/// Splits a leading `>` quote block off [body] the way monocles does.
///
/// Null when the body does not start with a quote, so callers can fall back to
/// the quote stored on the row.
ReplyBodySplit? splitLeadingQuote(String body) {
  if (!body.startsWith('>')) return null;
  final lines = body.split('\n');
  var end = 0;
  while (end < lines.length && _isQuoteLine(lines[end])) {
    end++;
  }
  if (end == 0) return null;

  final quote = lines.sublist(0, end).map(_unquoteLine).join('\n').trim();
  final rest = lines.sublist(end);
  // Conversations and monocles put a blank line between the quote and the
  // reply. The card already provides that separation, so drop it here.
  while (rest.isNotEmpty && rest.first.trim().isEmpty) {
    rest.removeAt(0);
  }
  return ReplyBodySplit(body: rest.join('\n'), quote: quote);
}

/// What one reply should show: bubble text, quote text, and quote author.
class ReplyPresentation {
  const ReplyPresentation({
    required this.body,
    required this.quote,
    required this.author,
  });

  final String body;
  final String quote;
  final String author;
}

/// Resolves one reply for display, using [quoted] when it is in the list.
///
/// [quoted] is the message `replyTo` points at. When it is missing (MAM gap,
/// retraction, a very old row) the quote stored on the reply stands in, which
/// is the one thing monocles cannot do — it only has the live target.
ReplyPresentation replyPresentation(
  Message message, {
  required Message? quoted,
  required bool isGroup,
  required String peerName,
  required String selfLabel,
}) {
  final split = splitLeadingQuote(message.body);
  var quote = split?.quote ?? '';

  // Prefer the quote that actually travelled with the reply. The stored copy
  // is usually that same text; fall back to it when there was no `>` block.
  if (quote.isEmpty) quote = message.replyBody.trim();

  // The old build stored the reply text in `replyBody` and left the quote in
  // the body. After the split above the quote is already right. When neither
  // source has a quote, the target's current text is the best remaining
  // answer (and matches monocles).
  if (quote.isEmpty || quote == message.body.trim()) {
    final targetBody = quoted == null || quoted.retracted
        ? ''
        : quoted.body.trim();
    if (targetBody.isNotEmpty) quote = targetBody;
  }

  return ReplyPresentation(
    body: split?.body ?? message.body,
    quote: quote,
    author: replyAuthorLabel(
      isGroup: isGroup,
      peerName: peerName,
      selfLabel: selfLabel,
      quotedIncoming: quoted?.incoming,
      quotedSender: quoted?.sender ?? '',
      storedAuthor: message.replyAuthor,
    ),
  );
}

/// Author line for a reply card.
///
/// monocles shows the quoted message's display name, not the person who sent
/// the reply. [quotedIncoming] is null when that message is not in the list;
/// then only a stored nickname is usable — a stored bare JID is not a name and
/// is left out.
String replyAuthorLabel({
  required bool isGroup,
  required String peerName,
  required String selfLabel,
  bool? quotedIncoming,
  String quotedSender = '',
  String storedAuthor = '',
}) {
  if (quotedIncoming != null) {
    if (!quotedIncoming) return selfLabel;
    if (isGroup) return occupantNick(quotedSender) ?? quotedSender;
    return _oneToOneName(peerName);
  }

  final stored = storedAuthor.trim();
  if (stored.isEmpty) return '';
  if (stored == 'me' || stored.toLowerCase() == 'you') return selfLabel;
  if (isGroup) return occupantNick(stored) ?? stored;
  // A 1:1 quote is either the peer or us; a raw JID names neither usefully.
  return stored.contains('@') ? '' : stored;
}

/// monocles' 1:1 fallback is the JID's local part, never the full address.
String _oneToOneName(String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return '';
  final at = trimmed.indexOf('@');
  return at > 0 ? trimmed.substring(0, at) : trimmed;
}

bool _isQuoteLine(String line) => line.startsWith('>');

String _unquoteLine(String line) {
  if (line.startsWith('> ')) return line.substring(2);
  if (line == '>') return '';
  return line.substring(1);
}
