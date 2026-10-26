// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Per-conversation auto-translate. Outgoing text is replaced with one
// translation. The typed original stays on this device.

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:resonchat/l10n/l10n.dart';
import 'package:resonchat/state/providers.dart';
import 'package:resonchat/translate/chat_auto_translate.dart';
import 'package:resonchat/ui/chat/chat_profile_sections.dart';

class ChatAutoTranslateSection extends ConsumerWidget {
  const ChatAutoTranslateSection({super.key, required this.chatJid});

  final String chatJid;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final stored =
        ref.watch(chatAutoTranslateProvider(chatJid)).value ??
        ChatAutoTranslate.off;
    final subtitle = stored.isOff
        ? l10n.autoTranslateOff
        : l10n.autoTranslateReplaceSummary(
            translateLanguageLabel(stored.lang!),
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ChatProfileSectionTitle(l10n.autoTranslate),
        ListTile(
          leading: const Icon(Icons.translate),
          title: Text(l10n.autoTranslate),
          subtitle: Text(subtitle),
          onTap: () => openChatAutoTranslateSheet(context, chatJid, stored),
        ),
      ],
    );
  }
}

void openChatAutoTranslateSheet(
  BuildContext context,
  String chatJid,
  ChatAutoTranslate initial,
) {
  unawaited(
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _AutoTranslateSheet(chatJid: chatJid, initial: initial),
    ),
  );
}

class _AutoTranslateSheet extends ConsumerStatefulWidget {
  const _AutoTranslateSheet({required this.chatJid, required this.initial});

  final String chatJid;
  final ChatAutoTranslate initial;

  @override
  ConsumerState<_AutoTranslateSheet> createState() =>
      _AutoTranslateSheetState();
}

class _AutoTranslateSheetState extends ConsumerState<_AutoTranslateSheet> {
  late bool _enabled = !widget.initial.isOff;
  late String? _lang = widget.initial.lang;

  Future<void> _save() async {
    final setting = !_enabled || _lang == null || _lang!.isEmpty
        ? ChatAutoTranslate.off
        : ChatAutoTranslate(lang: _lang);
    await setChatAutoTranslateSetting(ref, widget.chatJid, setting);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final canSave = !_enabled || (_lang != null && _lang!.isNotEmpty);
    return SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                l10n.autoTranslate,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(l10n.autoTranslateEnable),
                subtitle: Text(l10n.autoTranslateReplaceHint),
                value: _enabled,
                onChanged: (value) => setState(() => _enabled = value),
              ),
              Text(l10n.autoTranslateLanguages),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final lang in kTranslateLanguages)
                    FilterChip(
                      label: Text(lang.label),
                      selected: _enabled && _lang == lang.code,
                      onSelected: _enabled
                          ? (_) => setState(() => _lang = lang.code)
                          : null,
                    ),
                ],
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: canSave ? () => unawaited(_save()) : null,
                child: Text(l10n.autoTranslateSave),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
