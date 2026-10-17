// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// External message translation (LibreTranslate / DeepL). Prefs in [appPrefs].

import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../translate/translation_engine.dart';
import '../../translate/translation_prefs.dart';
import '../../translate/translation_service.dart';

/// Bottom sheet: engine, base URL, API key, DeepL Pro host, test connection.
Future<void> showTranslationSettingsSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
      child: const _TranslationSettingsSheet(),
    ),
  );
}

class _TranslationSettingsSheet extends StatefulWidget {
  const _TranslationSettingsSheet();

  @override
  State<_TranslationSettingsSheet> createState() =>
      _TranslationSettingsSheetState();
}

class _TranslationSettingsSheetState extends State<_TranslationSettingsSheet> {
  bool _ready = false;
  bool _testing = false;
  TranslationEngineId _engine = TranslationEngineId.libreTranslate;
  bool _deepLPro = false;
  final _baseUrl = TextEditingController();
  final _apiKey = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await TranslationPrefs.load();
    if (!mounted) return;
    setState(() {
      _engine = prefs.engine;
      _deepLPro = prefs.deepLPro;
      _baseUrl.text = prefs.baseUrl;
      _apiKey.text = prefs.apiKey;
      _ready = true;
    });
  }

  TranslationPrefs _current() => TranslationPrefs(
    engine: _engine,
    baseUrl: _baseUrl.text,
    apiKey: _apiKey.text,
    deepLPro: _deepLPro,
  );

  Future<void> _save() async {
    await _current().save();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.l10n.translationSettingsSaved)),
    );
  }

  Future<void> _test() async {
    final l10n = context.l10n;
    final prefs = _current();
    if (!translationService.isConfigured(prefs)) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(l10n.translationNotConfigured)));
      return;
    }
    final lang = Localizations.localeOf(context).languageCode;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _testing = true);
    try {
      await prefs.save();
      await translationService.testConnection(
        prefs: prefs,
        uiLanguageCode: lang,
      );
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text(l10n.translationTestOk)));
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.translationTestFailed('$e'))),
      );
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  @override
  void dispose() {
    if (_ready) {
      unawaited(_current().save());
    }
    _baseUrl.dispose();
    _apiKey.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    if (!_ready) {
      return const SizedBox(
        height: 160,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  l10n.translationSummary,
                  style: TextStyle(
                    fontSize: 13,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.translate),
                title: Text(l10n.translationEngine),
                subtitle: Text(_engineLabel(l10n, _engine)),
                onTap: () => unawaited(_pickEngine()),
              ),
              if (_engine == TranslationEngineId.libreTranslate)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: TextField(
                    controller: _baseUrl,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    decoration: InputDecoration(
                      labelText: l10n.translationBaseUrl,
                      hintText: l10n.translationBaseUrlHint,
                      helperText: l10n.translationBaseUrlHelper,
                    ),
                    onEditingComplete: () => unawaited(_save()),
                  ),
                ),
              if (_engine == TranslationEngineId.deepL)
                SwitchListTile(
                  secondary: const Icon(Icons.cloud_outlined),
                  title: Text(l10n.translationDeepLPro),
                  subtitle: Text(l10n.translationDeepLProSummary),
                  value: _deepLPro,
                  onChanged: (v) {
                    setState(() => _deepLPro = v);
                    unawaited(_save());
                  },
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: TextField(
                  controller: _apiKey,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: l10n.translationApiKey,
                    helperText: _engine == TranslationEngineId.deepL
                        ? l10n.translationApiKeyRequired
                        : l10n.translationApiKeyOptional,
                  ),
                  onEditingComplete: () => unawaited(_save()),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: FilledButton.tonal(
                  onPressed: _testing ? null : () => unawaited(_test()),
                  child: _testing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(l10n.translationTestConnection),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _engineLabel(AppLocalizations l10n, TranslationEngineId id) {
    return switch (id) {
      TranslationEngineId.libreTranslate => l10n.translationLibreTranslate,
      TranslationEngineId.deepL => l10n.translationDeepL,
    };
  }

  Future<void> _pickEngine() async {
    final l10n = context.l10n;
    final picked = await showModalBottomSheet<TranslationEngineId>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final id in TranslationEngineId.values)
              ListTile(
                title: Text(_engineLabel(l10n, id)),
                trailing: id == _engine
                    ? Icon(
                        Icons.check,
                        color: Theme.of(ctx).colorScheme.primary,
                      )
                    : null,
                onTap: () => Navigator.of(ctx).pop(id),
              ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    setState(() => _engine = picked);
    await _save();
  }
}
