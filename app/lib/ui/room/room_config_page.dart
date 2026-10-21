// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// MUC configuration (XEP-0045 §10.2 / Copinc RoomConfigAdapter).
// Fetches the server's data form, translates Prosody-style English labels,
// and submits the filled form.

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:moxxmpp/moxxmpp.dart';

import 'package:resonchat/l10n/l10n.dart';
import 'package:resonchat/ui/room/room_config_viewmodel.dart';
import 'package:resonchat/ui/theme.dart';
import 'package:resonchat/xmpp/muc/room_config_translator.dart';

/// Full-screen room configuration editor (owners only).
class RoomConfigPage extends ConsumerStatefulWidget {
  const RoomConfigPage({super.key, required this.chatKey});

  /// Composite chat key (`accountId` + room bare JID).
  final String chatKey;

  @override
  ConsumerState<RoomConfigPage> createState() => _RoomConfigPageState();
}

class _RoomConfigPageState extends ConsumerState<RoomConfigPage> {
  bool _loading = true;
  bool _saving = false;
  String? _error;
  String? _title;
  List<String> _instructions = const [];
  List<_EditField> _fields = const [];
  bool _formLoaded = false;

  RoomConfigViewModel get _vm => ref.read(roomConfigViewModelProvider.notifier);

  @override
  void initState() {
    super.initState();
    // Localizations / ref must not be read during initState — that throws
    // (dependOnInheritedWidgetOfExactType) and leaves _loading stuck true.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_load());
    });
  }

  @override
  void dispose() {
    if (_formLoaded && !_saving) {
      unawaited(_vm.cancelForm(widget.chatKey));
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final lang = Localizations.maybeLocaleOf(context)?.languageCode;
      final form = await _vm.fetchForm(widget.chatKey, lang: lang);
      if (!mounted) return;
      if (form == null) {
        setState(() {
          _loading = false;
          _error = context.l10n.roomConfigurationLoadFailed;
        });
        return;
      }
      setState(() {
        _loading = false;
        _formLoaded = true;
        _title = form.title;
        _instructions = form.instructions;
        _fields = [for (final f in form.fields) _EditField(f)];
      });
    } catch (e, st) {
      assert(() {
        // ignore: avoid_print
        print('RoomConfigPage._load failed: $e\n$st');
        return true;
      }());
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = context.l10n.roomConfigurationLoadFailed;
      });
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    final form = DataForm(
      type: 'submit',
      title: _title,
      instructions: _instructions,
      fields: [for (final f in _fields) f.toFormField()],
      reported: const [],
      items: const [],
    );
    var ok = false;
    try {
      ok = await _vm.submitForm(widget.chatKey, form);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
    if (!mounted) return;
    final l10n = context.l10n;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok ? l10n.roomConfigurationSaved : l10n.roomConfigurationSaveFailed,
        ),
      ),
    );
    if (ok) {
      _formLoaded = false;
      Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final tg = context.tg;
    final scheme = Theme.of(context).colorScheme;
    // AppBar uses a solid brand bar; M3 TextButton defaults to primary, which
    // matches that bar — force on-bar contrast (same idea as onPrimary).
    final onBar =
        Theme.of(context).appBarTheme.foregroundColor ?? scheme.onPrimary;
    final title = _title == null || _title!.isEmpty
        ? l10n.roomConfiguration
        : translateRoomConfigLabel(l10n, _title);

    return Scaffold(
      appBar: AppBar(
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          if (_formLoaded)
            TextButton(
              style: TextButton.styleFrom(
                foregroundColor: onBar,
                disabledForegroundColor: onBar.withValues(alpha: 0.5),
              ),
              onPressed: _saving ? null : _save,
              child: _saving
                  ? SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: onBar,
                      ),
                    )
                  : Text(l10n.save),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(_error!, textAlign: TextAlign.center),
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                for (final line in _instructions)
                  if (line.trim().isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(
                        translateRoomConfigLabel(l10n, line),
                        style: TextStyle(color: tg.textSecondary, fontSize: 14),
                      ),
                    ),
                for (final field in _fields)
                  if (field.type != 'hidden')
                    _FieldTile(field: field, onChanged: () => setState(() {})),
              ],
            ),
    );
  }
}

class _EditField {
  _EditField(DataFormField source)
    : varAttr = source.varAttr,
      type = source.type ?? 'text-single',
      label = source.label,
      description = source.description,
      isRequired = source.isRequired,
      values = List<String>.of(source.values),
      options = List<DataFormOption>.of(source.options);

  final String? varAttr;
  final String type;
  final String? label;
  final String? description;
  final bool isRequired;
  final List<String> values;
  final List<DataFormOption> options;

  DataFormField toFormField() => DataFormField(
    varAttr: varAttr,
    type: type,
    label: label,
    description: description,
    isRequired: isRequired,
    values: List<String>.of(values),
    options: List<DataFormOption>.of(options),
  );
}

class _FieldTile extends StatelessWidget {
  const _FieldTile({required this.field, required this.onChanged});

  final _EditField field;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final tg = context.tg;
    final label = translateRoomConfigLabel(l10n, field.label ?? field.varAttr);
    final desc = field.description == null || field.description!.isEmpty
        ? null
        : translateRoomConfigLabel(l10n, field.description);

    if (field.type == 'fixed') {
      final text = field.values.isEmpty ? label : field.values.first;
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Text(
          translateRoomConfigLabel(l10n, text),
          style: Theme.of(context).textTheme.titleSmall
              ?.copyWith(color: tg.textPrimary),
        ),
      );
    }

    if (field.type == 'boolean') {
      final checked =
          field.values.isNotEmpty &&
          (field.values.first == '1' || field.values.first == 'true');
      return SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(label),
        subtitle: desc == null ? null : Text(desc),
        value: checked,
        onChanged: (v) {
          field.values
            ..clear()
            ..add(v ? '1' : '0');
          onChanged();
        },
      );
    }

    if (field.type == 'list-multi') {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: Theme.of(context).textTheme.titleSmall),
            if (desc != null)
              Padding(
                padding: const EdgeInsets.only(top: 4, bottom: 4),
                child: Text(desc, style: TextStyle(color: tg.textSecondary)),
              ),
            for (final opt in field.options)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: Text(
                  translateRoomConfigLabel(l10n, opt.label ?? opt.value),
                ),
                value: field.values.contains(opt.value),
                onChanged: (v) {
                  if (v == true) {
                    if (!field.values.contains(opt.value)) {
                      field.values.add(opt.value);
                    }
                  } else {
                    field.values.remove(opt.value);
                  }
                  onChanged();
                },
              ),
          ],
        ),
      );
    }

    if (field.type == 'list-single' || field.options.isNotEmpty) {
      final current = field.values.isEmpty ? null : field.values.first;
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: InputDecorator(
          decoration: InputDecoration(
            labelText: label,
            helperText: desc,
            border: const OutlineInputBorder(),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              isExpanded: true,
              value: field.options.any((o) => o.value == current)
                  ? current
                  : null,
              hint: Text(l10n.roomConfNone),
              items: [
                for (final opt in field.options)
                  DropdownMenuItem(
                    value: opt.value,
                    child: Text(
                      translateRoomConfigLabel(l10n, opt.label ?? opt.value),
                    ),
                  ),
              ],
              onChanged: (v) {
                if (v == null) return;
                field.values
                  ..clear()
                  ..add(v);
                onChanged();
              },
            ),
          ),
        ),
      );
    }

    final obscure = field.type == 'text-private';
    final multi = field.type == 'text-multi' || field.type == 'jid-multi';
    final keyboard = field.type == 'jid-single' || field.type == 'jid-multi'
        ? TextInputType.emailAddress
        : (multi ? TextInputType.multiline : TextInputType.text);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: TextFormField(
        initialValue: field.values.join('\n'),
        obscureText: obscure,
        maxLines: multi ? 4 : 1,
        keyboardType: keyboard,
        decoration: InputDecoration(
          labelText: label,
          helperText: desc,
          border: const OutlineInputBorder(),
        ),
        onChanged: (text) {
          field.values
            ..clear()
            ..addAll(
              multi
                  ? text
                        .split(RegExp(r'[\n,]'))
                        .map((s) => s.trim())
                        .where((s) => s.isNotEmpty)
                  : [text],
            );
        },
      ),
    );
  }
}
