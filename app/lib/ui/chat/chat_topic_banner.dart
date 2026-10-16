// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Floating MUC subject under the AppBar: tap for detail, dismiss only after
// opening the detail; dismissed text is stored so a later subject change
// brings the banner back.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/providers.dart';
import '../theme.dart';

/// Hover-style topic strip for group chats when the subject is non-empty and
/// not yet marked read for the current text.
class ChatTopicBanner extends ConsumerStatefulWidget {
  const ChatTopicBanner({
    super.key,
    required this.chatJid,
    required this.subject,
  });

  final String chatJid;
  final String subject;

  @override
  ConsumerState<ChatTopicBanner> createState() => _ChatTopicBannerState();
}

class _ChatTopicBannerState extends ConsumerState<ChatTopicBanner> {
  /// Subject text for which the detail sheet was opened (enables dismiss).
  String? _viewedSubject;

  String get _subject => widget.subject.trim();

  bool get _canDismiss => _viewedSubject != null && _viewedSubject == _subject;

  @override
  void didUpdateWidget(covariant ChatTopicBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.subject.trim() != _subject) {
      _viewedSubject = null;
    }
  }

  Future<void> _openDetail() async {
    final l10n = context.l10n;
    final tg = context.tg;
    final subject = _subject;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  l10n.subjectHint,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: tg.textPrimary,
                  ),
                ),
                const SizedBox(height: 12),
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.sizeOf(ctx).height * 0.5,
                  ),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      subject,
                      style: TextStyle(
                        fontSize: 15,
                        height: 1.4,
                        color: tg.textPrimary,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: Text(l10n.close),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (!mounted) return;
    setState(() => _viewedSubject = subject);
  }

  Future<void> _dismiss() async {
    if (!_canDismiss) return;
    await markMucSubjectRead(ref, widget.chatJid, _subject);
  }

  @override
  Widget build(BuildContext context) {
    final subject = _subject;
    if (subject.isEmpty) return const SizedBox.shrink();

    final read = ref.watch(mucSubjectReadProvider(widget.chatJid)).value;
    if (read != null && read == subject) return const SizedBox.shrink();

    final tg = context.tg;
    final l10n = context.l10n;

    return Material(
      elevation: 3,
      shadowColor: Colors.black38,
      borderRadius: BorderRadius.circular(10),
      color: Color.alphaBlend(
        tg.textPrimary.withValues(alpha: 0.08),
        tg.pageBackground,
      ),
      child: InkWell(
        onTap: _openDetail,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: tg.separator),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Icon(Icons.campaign_outlined, size: 18, color: tg.accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  subject,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.25,
                    color: tg.textPrimary,
                  ),
                ),
              ),
              if (_canDismiss) ...[
                const SizedBox(width: 4),
                Tooltip(
                  message: l10n.subjectDismiss,
                  child: InkWell(
                    onTap: _dismiss,
                    borderRadius: BorderRadius.circular(12),
                    child: Padding(
                      padding: const EdgeInsets.all(2),
                      child: Icon(
                        Icons.close,
                        size: 16,
                        color: tg.textSecondary,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
