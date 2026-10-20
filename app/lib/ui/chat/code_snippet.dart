// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Gajim `CodeWidget` — fenced code block with language label and copy.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:resonchat/l10n/l10n.dart';

/// Monospace code card (Gajim conversation `CodeWidget`, no syntax highlight).
class CodeSnippet extends StatelessWidget {
  const CodeSnippet({
    super.key,
    required this.code,
    this.language,
    this.textStyle,
  });

  final String code;
  final String? language;
  final TextStyle? textStyle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final label = (language == null || language!.isEmpty)
        ? l10n.codeSnippet
        : language!;
    final mono =
        (textStyle ?? theme.textTheme.bodyMedium)?.copyWith(
          fontFamily: 'monospace',
          fontFamilyFallback: const [
            'Courier',
            'Courier New',
            'Menlo',
            'Monaco',
            'Consolas',
          ],
          fontSize: (textStyle?.fontSize ?? 14) * 0.92,
          height: 1.35,
        ) ??
        const TextStyle(fontFamily: 'monospace', fontSize: 13);

    final surface = theme.colorScheme.surfaceContainerHighest.withValues(
      alpha: theme.brightness == Brightness.dark ? 0.55 : 0.85,
    );

    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxHeight: 400),
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 4, 4, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    label,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  tooltip: l10n.copyCodeSnippet,
                  icon: const Icon(Icons.copy_outlined, size: 18),
                  visualDensity: VisualDensity.compact,
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: code));
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context)
                        .showSnackBar(SnackBar(content: Text(l10n.copied)));
                  },
                ),
              ],
            ),
          ),
          Divider(height: 1, color: theme.colorScheme.outlineVariant),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
              child: SelectableText(code, style: mono),
            ),
          ),
        ],
      ),
    );
  }
}
