// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Gajim `CodeWidget` — fenced code block with language label and copy.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:resonchat/l10n/l10n.dart';

/// Monospace code card (Gajim conversation `CodeWidget`, no syntax highlight).
///
/// Lines do not wrap: a visible horizontal scrollbar pans long lines; tall
/// scripts also scroll vertically.
class CodeSnippet extends StatefulWidget {
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
  State<CodeSnippet> createState() => _CodeSnippetState();
}

class _CodeSnippetState extends State<CodeSnippet> {
  final _horizontal = ScrollController();
  final _vertical = ScrollController();

  @override
  void dispose() {
    _horizontal.dispose();
    _vertical.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final label = (widget.language == null || widget.language!.isEmpty)
        ? l10n.codeSnippet
        : widget.language!;
    final mono =
        (widget.textStyle ?? theme.textTheme.bodyMedium)?.copyWith(
          fontFamily: 'monospace',
          fontFamilyFallback: const [
            'Courier',
            'Courier New',
            'Menlo',
            'Monaco',
            'Consolas',
          ],
          fontSize: (widget.textStyle?.fontSize ?? 14) * 0.92,
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
                    await Clipboard.setData(ClipboardData(text: widget.code));
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
            child: Scrollbar(
              controller: _vertical,
              thumbVisibility: true,
              child: SingleChildScrollView(
                controller: _vertical,
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
                child: Scrollbar(
                  controller: _horizontal,
                  thumbVisibility: true,
                  trackVisibility: true,
                  scrollbarOrientation: ScrollbarOrientation.bottom,
                  notificationPredicate: (notification) =>
                      notification.metrics.axis == Axis.horizontal,
                  child: SingleChildScrollView(
                    controller: _horizontal,
                    scrollDirection: Axis.horizontal,
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: SelectionArea(
                        child: Text(widget.code, style: mono, softWrap: false),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
