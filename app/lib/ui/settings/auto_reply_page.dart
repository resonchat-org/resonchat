// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Auto-reply rules. Order is the match order; drag a row to change it.

import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../xmpp/auto_reply.dart';
import '../theme.dart';

class AutoReplyPage extends StatefulWidget {
  const AutoReplyPage({super.key});

  @override
  State<AutoReplyPage> createState() => _AutoReplyPageState();
}

class _AutoReplyPageState extends State<AutoReplyPage> {
  AutoReplyConfig _config = AutoReplyConfig.empty;
  var _loaded = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final config = await loadAutoReply();
    if (!mounted) return;
    setState(() {
      _config = config;
      _loaded = true;
    });
  }

  Future<void> _save(AutoReplyConfig config) async {
    setState(() => _config = config);
    await saveAutoReply(config);
  }

  Future<void> _edit({AutoReplyRule? existing}) async {
    final result = await showModalBottomSheet<_RuleResult>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _RuleSheet(existing: existing),
    );
    if (result == null || !mounted) return;
    final rules = [..._config.rules];
    if (result.deleted) {
      rules.removeWhere((rule) => rule.id == existing?.id);
    } else {
      final rule = result.rule!;
      final index = rules.indexWhere((item) => item.id == rule.id);
      if (index >= 0) {
        rules[index] = rule;
      } else {
        rules.add(rule);
      }
    }
    await _save(AutoReplyConfig(enabled: _config.enabled, rules: rules));
  }

  void _reorder(int oldIndex, int newIndex) {
    final rules = [..._config.rules];
    final rule = rules.removeAt(oldIndex);
    rules.insert(newIndex, rule);
    unawaited(_save(AutoReplyConfig(enabled: _config.enabled, rules: rules)));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final tg = context.tg;
    final rules = _config.rules;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.autoReply)),
      floatingActionButton: FloatingActionButton(
        tooltip: l10n.autoReplyAdd,
        onPressed: _loaded ? () => unawaited(_edit()) : null,
        child: const Icon(Icons.add),
      ),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                SwitchListTile(
                  secondary: const Icon(Icons.quickreply_outlined),
                  title: Text(l10n.autoReplyEnabled),
                  subtitle: Text(l10n.autoReplyEnabledSummary),
                  value: _config.enabled,
                  onChanged: (value) => unawaited(
                    _save(AutoReplyConfig(enabled: value, rules: rules)),
                  ),
                ),
                Expanded(
                  child: rules.isEmpty
                      ? Center(
                          child: Text(
                            l10n.autoReplyNone,
                            style: TextStyle(color: tg.textSecondary),
                          ),
                        )
                      : ReorderableListView.builder(
                          buildDefaultDragHandles: false,
                          itemCount: rules.length,
                          onReorderItem: _reorder,
                          itemBuilder: (context, index) {
                            final rule = rules[index];
                            return ListTile(
                              key: ValueKey(rule.id),
                              title: Text(
                                rule.pattern,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 14,
                                ),
                              ),
                              subtitle: Text(
                                rule.reply,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: ReorderableDragStartListener(
                                index: index,
                                child: Icon(
                                  Icons.drag_handle,
                                  color: tg.textSecondary,
                                ),
                              ),
                              onTap: () => unawaited(_edit(existing: rule)),
                            );
                          },
                        ),
                ),
              ],
            ),
    );
  }
}

class _RuleResult {
  const _RuleResult.save(this.rule) : deleted = false;
  const _RuleResult.delete() : rule = null, deleted = true;

  final AutoReplyRule? rule;
  final bool deleted;
}

class _RuleSheet extends StatefulWidget {
  const _RuleSheet({this.existing});

  final AutoReplyRule? existing;

  @override
  State<_RuleSheet> createState() => _RuleSheetState();
}

class _RuleSheetState extends State<_RuleSheet> {
  late final TextEditingController _pattern;
  late final TextEditingController _reply;
  var _invalid = false;

  @override
  void initState() {
    super.initState();
    _pattern = TextEditingController(text: widget.existing?.pattern ?? '');
    _reply = TextEditingController(text: widget.existing?.reply ?? '');
  }

  @override
  void dispose() {
    _pattern.dispose();
    _reply.dispose();
    super.dispose();
  }

  String? _replyError(AppLocalizations l10n) {
    if (!_invalid) return null;
    final reply = _reply.text.trim();
    if (reply.isEmpty) return l10n.autoReplyReplyEmpty;
    if (!autoReplyWithinLimit(reply)) {
      return l10n.autoReplyReplyTooLong(autoReplyMaxChars);
    }
    return null;
  }

  void _save() {
    final pattern = _pattern.text;
    final reply = _reply.text.trim();
    if (!isAutoReplyPatternValid(pattern) ||
        reply.isEmpty ||
        !autoReplyWithinLimit(reply)) {
      setState(() => _invalid = true);
      return;
    }
    final existing = widget.existing;
    Navigator.pop(
      context,
      _RuleResult.save(
        AutoReplyRule(
          id: existing?.id ?? '${DateTime.now().microsecondsSinceEpoch}',
          pattern: pattern,
          reply: reply,
        ),
      ),
    );
  }

  Future<void> _delete() async {
    final l10n = context.l10n;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(l10n.autoReplyDeleteConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.autoReplyDelete),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    Navigator.pop(context, const _RuleResult.delete());
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    final existing = widget.existing != null;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 16, 20, bottom + 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            existing ? l10n.autoReplyEdit : l10n.autoReplyAdd,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _pattern,
            autofocus: true,
            decoration: InputDecoration(
              labelText: l10n.autoReplyPattern,
              errorText: _invalid && !isAutoReplyPatternValid(_pattern.text)
                  ? l10n.autoReplyPatternInvalid
                  : null,
            ),
            onChanged: (_) {
              if (_invalid) setState(() {});
            },
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _reply,
            minLines: 2,
            maxLines: 5,
            onChanged: (_) {
              if (_invalid) setState(() {});
            },
            decoration: InputDecoration(
              labelText: l10n.autoReplyReply,
              helperText: l10n.autoReplyReplyTooLong(autoReplyMaxChars),
              errorText: _replyError(l10n),
            ),
          ),
          if (existing) ...[
            const SizedBox(height: 8),
            TextButton(onPressed: _delete, child: Text(l10n.autoReplyDelete)),
          ],
          const SizedBox(height: 8),
          FilledButton(onPressed: _save, child: Text(l10n.save)),
        ],
      ),
    );
  }
}
