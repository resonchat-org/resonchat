// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Chat page. Layout and interactions follow Telegram for Android's
// `ChatActivity` (GPL-2.0-or-later), translated to Flutter.

import 'dart:async';

import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:moxxmpp/moxxmpp.dart' show JID;

import '../omemo/track.dart';
import '../omemo/track_advice.dart';
import '../omemo/track_resolver.dart';
import '../state/app_wiring.dart';
import '../state/providers.dart';
import '../store/database.dart';
import '../xmpp/connection.dart';
import '../xmpp/reactions.dart';
import 'message_bubble.dart';
import 'track_dialogs.dart';
import 'theme.dart';

class ChatPage extends ConsumerStatefulWidget {
  const ChatPage({super.key, required this.chatJid});

  final String chatJid;

  @override
  ConsumerState<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends ConsumerState<ChatPage> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _focus = FocusNode();

  bool _typingNotified = false;
  bool _atBottom = true;
  /// Guards against a double tap sending twice while the first send awaits.
  bool _sending = false;
  StreamSubscription<DeliveryFailure>? _failureSub;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    // A message the server refused must stop looking sent.
    _failureSub = ref
        .read(xmppServiceProvider)
        .deliveryFailures
        .listen(_onDeliveryFailure);
    _adviceSub = trackAdvice.listen(_onAdvice);
  }

  @override
  void didUpdateWidget(ChatPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Advice names the conversation it is about, so switching chats clears it.
    // Keeping it would show the previous contact's devices above this
    // contact's messages.
    if (oldWidget.chatJid != widget.chatJid && _advice != null) {
      setState(() => _advice = null);
    }
  }

  Future<void> _onDeliveryFailure(DeliveryFailure failure) async {
    if (failure.from.toBare().toString() != widget.chatJid) return;
    await ref.read(databaseProvider).markDeliveryFailure(
          failure.stanzaId,
          failure.reason,
        );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Not delivered: ${failure.reason}'),
        action: SnackBarAction(
          label: 'Details',
          onPressed: () => _showRefusalHelp(failure.reason),
        ),
      ),
    );
  }

  /// Turns the server's error into something actionable.
  ///
  /// `auth/forbidden` in practice means the server refuses stanzas outside a
  /// mutual subscription, which is the single most common reason a fresh
  /// contact sees every message silently vanish.
  void _showRefusalHelp(String reason) {
    final mutual =
        ref.read(contactStateProvider(widget.chatJid)).value;
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Message not delivered'),
        content: Text(
          'The server refused this message:\n\n$reason\n\n'
          '${(mutual?.isMutual ?? false) ? '' : 'This contact is not a '
              'mutual subscription yet (currently ${mutual?.summary ?? 'unknown'}). '
              'Many servers refuse messages until both sides have accepted '
              'each other.\n\n'}'
          'Ask them to accept your contact request, or wait for the other '
          'side to accept yours.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _failureSub?.cancel();
    _adviceSub?.cancel();
    _scroll
      ..removeListener(_onScroll)
      ..dispose();
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final distance = _scroll.position.maxScrollExtent - _scroll.offset;
    final atBottom = distance < 80;
    if (atBottom != _atBottom) setState(() => _atBottom = atBottom);
  }

  void _scrollToBottom() {
    if (!_scroll.hasClients) return;
    _scroll.animateTo(
      _scroll.position.maxScrollExtent,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  /// XEP-0085: notify once per typing burst, not per keystroke.
  void _onInputChanged(String value) {
    final composing = value.trim().isNotEmpty;
    if (composing == _typingNotified) return;
    _typingNotified = composing;
    if (!composing) return;
    unawaited(
      ref
          .read(xmppServiceProvider)
          .sendChatState(JID.fromString(widget.chatJid), TypingState.composing),
    );
  }

  /// Sends the input on [track], asking the user when it cannot be used.
  ///
  /// Returns the outcome so the caller can store what actually went out.
  /// Returns null when the user cancelled or nothing was sent — in both cases
  /// the text must go back into the box, because the user did not send it.
  Future<SendOutcome?> _sendOn(Track track) async {
    final text = _input.text.trim();
    if (text.isEmpty) return null;

    var chosen = track;
    final xmpp = ref.read(xmppServiceProvider);
    final peer = JID.fromString(widget.chatJid).toBare();

    final caps = await xmpp.capabilitiesFor(peer);
    final resolution = resolveTrack(requested: chosen, capabilities: caps);

    // Choosing plaintext always asks, whatever the peer supports. The
    // confirmation is about the act, not about the capability check.
    if (chosen == Track.none) {
      final alternative = resolution.alternative ?? Track.standard;
      if (!mounted) return null;
      // Asked once per conversation, not once per message. A warning that
      // fires on every send is a warning nobody reads, and the message it
      // would have covered is exactly the one that goes out in the clear
      // unread.
      final db = ref.read(databaseProvider);
      final acknowledged = await db.plaintextAcknowledged(widget.chatJid);
      if (!mounted) return null;
      if (!acknowledged) {
        final agreed = await confirmPlaintext(
          context,
          contact: widget.chatJid,
          alternative: alternative,
        );
        if (!agreed || !mounted) return null;
        await db.acknowledgePlaintext(widget.chatJid);
      }
    } else if (!resolution.canSend) {
      // Refuse and explain. Nothing is sent here, and nothing is sent on
      // another track without a separate decision from the user.
      final alternative = resolution.alternative ?? Track.standard;
      if (!mounted) return null;
      final substituted = await askTrackSubstitute(
        context,
        blocked: resolution.blocked!,
        alternative: alternative,
      );
      if (substituted == null || !mounted) return null;
      if (substituted == Track.none) {
        if (!mounted) return null;
        // Deliberate downgrade to plaintext, reached from a dialog rather than
        // from the picker: worth confirming even in a conversation that has
        // already acknowledged plaintext, because the user did not choose this
        // one — they were offered it as the only way the message gets through.
        final agreed = await confirmPlaintext(
          context,
          contact: widget.chatJid,
          alternative: Track.standard,
        );
        if (!agreed || !mounted) return null;
      }
      chosen = substituted;
    }

    final outcome = await xmpp.sendOnTrack(peer, text, track: chosen);
    if (!outcome.sent) {
      // It was sendable a moment ago and is not now — a bundle went stale, or
      // the session dropped. Say so rather than showing a bubble that looks
      // sent.
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Not sent: ${outcome.blocked?.title ?? 'unknown reason'}')),
        );
      }
      return null;
    }

    await ref.read(databaseProvider).insertMessage(
          MessagesCompanion(
            chatJid: Value(widget.chatJid),
            sender: const Value('me'),
            stanzaId: Value(outcome.stanzaId ?? ''),
            body: Value(text),
            timestamp: Value(DateTime.now()),
            // What went out, as reported by the send — never the track we
            // hoped for. A bubble labelled PO that travelled as plaintext is
            // the one lie this app must not tell.
            encMode: Value(EncModeToken.of(outcome.track).wire),
            incoming: const Value(false),
          ),
        );
    return outcome;
  }

  Future<void> _send() async {
    if (_sending) return;
    final track = await ref.read(chatTrackProvider(widget.chatJid).future);
    _sending = true;
    final outcome = await _sendOn(track);
    _sending = false;

    final text = _input.text.trim();
    if (outcome?.sent ?? false) {
      _input.clear();
      _typingNotified = false;
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    } else if (text.isNotEmpty && mounted) {
      // Put the text back. It was never sent, and a user who typed a message
      // and watched the box empty has no way to know what happened to it.
      _showUnsentNotice();
    }
  }

  /// Adds or withdraws [emoji] on the message addressed by [targetId].
  ///
  /// Withdrawing sends an *empty* set, not a set without that emoji: XEP-0444
  /// broadcasts are complete lists, so anything else leaves the withdrawn row
  /// on the sender's device forever.
  ///
  /// Optimistic in both directions, and rolled back if the send fails — a chip
  /// that appears a second late feels broken, and one that stays after a
  /// failure is a lie.
  Future<void> _toggleReaction(String targetId, String emoji) async {
    final db = ref.read(databaseProvider);
    final myJid = ref.read(myBareJidProvider).value;
    if (myJid == null || targetId.isEmpty) return;

    final before = await reactionsFor(db, targetId, myJid);
    final mine = before.where((g) => g.mine).toList();
    final next = <String>{for (final g in mine) g.emoji};
    if (next.remove(emoji)) {
      // withdrawing
    } else {
      next.add(emoji);
    }

    final chatJid = widget.chatJid;
    await storeReaction(
      db,
      ReactionUpdate(
        targetId: targetId,
        reactor: myJid,
        emojis: next.toList(),
      ),
    );
    _bumpReactions();

    final sent = await sendReaction(
      ref.read(xmppServiceProvider),
      to: JID.fromString(chatJid).toBare(),
      targetId: targetId,
      emojis: next.toList(),
    );
    if (sent || !mounted) return;
    if (!mounted) return;

    // Put the chips back exactly as they were. Re-sending the whole previous
    // set rather than just undoing this one emoji keeps the local state equal
    // to what the last successful broadcast said.
    final previous = <String>{for (final g in mine) g.emoji};
    await storeReaction(
      db,
      ReactionUpdate(
        targetId: targetId,
        reactor: myJid,
        emojis: previous.toList(),
      ),
    );
    _bumpReactions();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Reaction could not be sent.')),
    );
  }

  void _bumpReactions() {
    final rev = ref.read(reactionRevisionProvider);
    ref.read(reactionRevisionProvider.notifier).state = rev + 1;
  }

  void _showUnsentNotice() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Message not sent. It is still in the box.'),
        duration: Duration(seconds: 4),
      ),
    );
  }

  Future<void> _loadHistory() async {
    final count = await ref
        .read(xmppServiceProvider)
        .fetchHistory(JID.fromString(widget.chatJid));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          count == null
              ? 'Could not load history (server may not support MAM)'
              : 'Loaded $count archived message(s)',
        ),
      ),
    );
  }

  StreamSubscription<TrackAdvice>? _adviceSub;

  /// The most recent advice about *this* conversation, or null.
  ///
  /// Advice about other conversations is dropped rather than stored: showing a
  /// banner for one contact's devices above another contact's messages is worse
  /// than showing nothing, and the chat page has no way to display advice for a
  /// conversation it is not showing.
  TrackAdvice? _advice;

  void _onAdvice(TrackAdvice advice) {
    if (advice.chatJid != widget.chatJid) return;
    if (!mounted) return;
    setState(() => _advice = advice);
  }

  void _dismissAdvice() {
    if (_advice == null) return;
    setState(() => _advice = null);
  }

  void _adoptAdvice() {
    final advice = _advice;
    if (advice == null) return;
    setState(() => _advice = null);
    unawaited(setChatTrack(ref, widget.chatJid, advice.suggestion));
  }

  @override
  Widget build(BuildContext context) {
    final tg = context.tg;
    final messages = ref.watch(messagesProvider(widget.chatJid));
    // The chosen track, not the negotiated one. The header says what the user
    // picked; whether it can actually be used is decided at send time and
    // explained there if not.
    final track = ref.watch(chatTrackProvider(widget.chatJid)).value ??
        Track.standard;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(
          children: [
            // Tapping the avatar opens the profile, as in every other
            // messenger; an inert avatar is a dead end.
            GestureDetector(
              onTap: () =>
                  Navigator.of(context).pushNamed('/profile', arguments: widget.chatJid),
              child: Hero(
                tag: 'avatar-${widget.chatJid}',
                child: CircleAvatar(
                  radius: TgDimens.avatarChat / 2,
                  backgroundColor: tg.accent.withValues(alpha: 0.18),
                  child: Text(
                    widget.chatJid.isEmpty ? '?' : widget.chatJid[0].toUpperCase(),
                    style: TextStyle(
                      color: tg.accent,
                      fontSize: 18,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    widget.chatJid,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    track.description.split(' — ').first,
                    style: TextStyle(
                      fontSize: TgDimens.timeFontSize,
                      fontWeight: FontWeight.w400,
                      color: Colors.white70,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          EncBadge(
            label: track.label,
            locked: track != Track.none,
            onTap: () => showTrackPicker(context, ref, widget.chatJid),
          ),
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: 'Load history (MAM)',
            onPressed: _loadHistory,
          ),
        ],
      ),
      body: Column(
        children: [
          _SubscriptionBanner(chatJid: widget.chatJid),
          if (_advice != null)
            TrackAdviceBanner(
              advice: _advice!,
              onSwitch: _adoptAdvice,
              onDismiss: _dismissAdvice,
            ),
          Expanded(
            child: Container(
              color: tg.pageBackground,
              child: messages.when(
                data: (list) => _MessageList(
                  messages: list,
                  scroll: _scroll,
                  onRetryDecrypt: () =>
                      _loadHistory(),
                  onReact: _toggleReaction,
                ),
                loading: () =>
                    const Center(child: CircularProgressIndicator()),
                error: (e, _) => Center(child: Text('$e')),
              ),
            ),
          ),
          _InputBar(
            controller: _input,
            focusNode: _focus,
            onChanged: _onInputChanged,
            onSend: _send,
          ),
        ],
      ),
      floatingActionButton: _atBottom
          ? null
          : FloatingActionButton.small(
              backgroundColor: tg.peerBubble,
              foregroundColor: tg.accent,
              onPressed: _scrollToBottom,
              child: const Icon(Icons.keyboard_arrow_down),
            ),
    );
  }
}

/// Message list with day separators and an unread marker.
class _MessageList extends StatelessWidget {
  const _MessageList({
    required this.messages,
    required this.scroll,
    required this.onRetryDecrypt,
    required this.onReact,
  });

  final List<Message> messages;
  final ScrollController scroll;
  final VoidCallback onRetryDecrypt;

  /// Toggling one emoji on one message. Takes the addressable id, because that
  /// is what a reaction refers to.
  final void Function(String targetId, String emoji) onReact;

  @override
  Widget build(BuildContext context) {
    if (messages.isEmpty) {
      return const Center(child: Text('No messages yet'));
    }

    final rows = <Widget>[];
    DateTime? lastDay;
    bool unreadMarked = false;

    for (final m in messages) {
      final day = DateTime(m.timestamp.year, m.timestamp.month, m.timestamp.day);
      if (lastDay == null || day != lastDay) {
        rows.add(DateSeparator(date: m.timestamp));
        lastDay = day;
        if (!unreadMarked) {
          // Mark the boundary once: everything above is history.
          unreadMarked = true;
        }
      }
      if (EncModeToken.parse(m.encMode) == EncModeToken.error) {
        rows.add(
          ListTile(
            dense: true,
            leading: Icon(
              Icons.lock_outline,
              size: 18,
              color: context.tg.danger,
            ),
            title: Text(
              'Unable to decrypt this message.',
              style: TextStyle(
                fontStyle: FontStyle.italic,
                color: context.tg.textSecondary,
              ),
            ),
            trailing: TextButton(
              onPressed: onRetryDecrypt,
              child: const Text('Retry'),
            ),
          ),
        );
        continue;
      }
      rows.add(
        _ReactionBubble(
          message: m,
          onReact: (emoji) =>
              onReact(m.stanzaId, emoji),
        ),
      );
    }

    return ListView(
      controller: scroll,
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: rows,
    );
  }
}

/// Bottom input bar: attach button, text field, and a button that becomes
/// a microphone whenever the field is empty (docs/05 §4.2).
class _InputBar extends StatelessWidget {
  const _InputBar({
    required this.controller,
    required this.focusNode,
    required this.onChanged,
    required this.onSend,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final tg = context.tg;
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        final empty = value.text.trim().isEmpty;
        return Container(
          decoration: BoxDecoration(
            color: tg.pageBackground,
            border: Border(top: BorderSide(color: tg.separator)),
          ),
          padding: const EdgeInsets.fromLTRB(4, 6, 4, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              IconButton(
                icon: const Icon(Icons.attach_file),
                color: tg.textSecondary,
                onPressed: () {},
              ),
              Expanded(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 120),
                  child: TextField(
                    controller: controller,
                    focusNode: focusNode,
                    minLines: 1,
                    maxLines: 5,
                    textInputAction: TextInputAction.newline,
                    onChanged: onChanged,
                    style: TextStyle(
                      fontSize: TgDimens.messageFontSize,
                      color: tg.textPrimary,
                    ),
                    decoration: InputDecoration(
                      isDense: true,
                      filled: true,
                      fillColor: tg.pageBackground,
                      hintText: 'Message',
                      hintStyle: TextStyle(color: tg.textSecondary),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(18),
                        borderSide: BorderSide(color: tg.separator),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(18),
                        borderSide: BorderSide(color: tg.separator),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(18),
                        borderSide: BorderSide(color: tg.accent),
                      ),
                    ),
                  ),
                ),
              ),
              IconButton(
                icon: Icon(empty ? Icons.mic_none : Icons.send),
                color: tg.accent,
                onPressed: empty ? () {} : onSend,
              ),
            ],
          ),
        );
      },
    );
  }
}



/// Warns when the contact is not a mutual subscription.
///
/// Without this, a server that refuses stanzas outside a mutual
/// subscription looks exactly like silent data loss: messages vanish and
/// nothing in the interface explains why.
class _SubscriptionBanner extends ConsumerWidget {
  const _SubscriptionBanner({required this.chatJid});

  final String chatJid;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tg = context.tg;
    final state = ref.watch(contactStateProvider(chatJid)).value;
    // Nothing to say before the roster has loaded, or when all is well.
    if (state == null || state.isMutual) return const SizedBox.shrink();

    final text = switch (state.subscription) {
      'none' => 'Not a contact yet — the server may refuse messages.',
      'to' => state.asked
          ? 'They can see you. Waiting for them to accept.'
          : 'They can see you, but you cannot see them.',
      'from' => state.asked
          ? 'You can see them. Waiting for them to accept your request.'
          : 'You can see them, but they cannot see you.',
      _ => 'Subscription state: ${state.subscription}',
    };

    return Material(
      color: tg.danger.withValues(alpha: 0.12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        child: Row(
          children: [
            Icon(Icons.info_outline, size: 18, color: tg.danger),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                text,
                style: TextStyle(fontSize: 13, color: tg.textPrimary),
              ),
            ),
            if (state.subscription != 'both')
              TextButton(
                onPressed: () => ref
                    .read(xmppServiceProvider)
                    .requestSubscription(JID.fromString(chatJid)),
                child: const Text('Ask again'),
              ),
          ],
        ),
      ),
    );
  }
}

/// A bubble plus whatever reactions its message carries.
///
/// Split out so the chips can come from their own provider: they change
/// whenever anyone reacts, which is independent of the message list rebuilding.
class _ReactionBubble extends ConsumerWidget {
  const _ReactionBubble({required this.message, required this.onReact});

  final Message message;
  final void Function(String emoji) onReact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Keyed on the stored id, which is the origin-id when the sender published
    // one. Empty means the message cannot be addressed, so it is drawn without
    // chips rather than with chips nobody could add to.
    final targetId = message.stanzaId;
    final reactions = targetId.isEmpty
        ? const <ReactionGroup>[]
        : ref.watch(reactionGroupsProvider(targetId)).value ?? const [];
    return MessageBubble(
      text: message.body,
      time: message.timestamp,
      side: message.incoming ? BubbleSide.incoming : BubbleSide.outgoing,
      delivered: message.delivered,
      failed: message.deliveryError.isNotEmpty,
      // What the message actually used, from what the sender declared — not
      // what we would have chosen. Read back from the row rather than
      // recomputed, so the label survives a change of mind afterwards.
      track: EncModeToken.parse(message.encMode).track ?? Track.none,
      reactions: reactions,
      onReact: onReact,
    );
  }
}
