// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Composer panel under the input: emoji, kaomoji, or saved sticker images.
// Emoji reuse the shared reaction picker; kaomoji sit beside it as a sibling
// tab (they are not valid reactions).

import 'package:flutter/material.dart';

import 'package:resonchat/l10n/l10n.dart';
import 'package:resonchat/persistence/database.dart';
import 'package:resonchat/ui/chat/emoji_picker_panel.dart';
import 'package:resonchat/ui/theme.dart';

/// Kaomoji for the composer only — not offered as reactions.
const List<String> kKaomoji = [
  '(＾▽＾)',
  '(｡♥‿♥｡)',
  '(╯°□°)╯︵ ┻━┻',
  '(づ｡◕‿‿◕｡)づ',
  '¯\\_(ツ)_/¯',
  '(；′⌒`)',
  '(ノಠ益ಠ)ノ',
  '(✿◠‿◠)',
  '(｡•́︿•̀｡)',
  '(￣▽￣)',
  '(*^▽^*)',
  '(๑•̀ㅂ•́)و✧',
  '(´･ω･`)',
  '(≧▽≦)',
  '(T_T)',
  '(￣ω￣)',
  '╮(╯▽╰)╭',
  '(｡･ω･｡)',
  '(ง •_•)ง',
  '(￣ヘ￣)',
];

enum _ComposerPane { emoji, kaomoji, custom }

/// Three parallel tabs under the composer.
class StickerPanel extends StatefulWidget {
  const StickerPanel({
    super.key,
    required this.stickers,
    required this.onInsert,
    required this.onSend,
    required this.onAdd,
    required this.onDelete,
  });

  final Stream<List<Sticker>> stickers;
  final ValueChanged<String> onInsert;
  final ValueChanged<Sticker> onSend;
  final VoidCallback onAdd;
  final ValueChanged<Sticker> onDelete;

  @override
  State<StickerPanel> createState() => _StickerPanelState();
}

class _StickerPanelState extends State<StickerPanel> {
  var _pane = _ComposerPane.emoji;

  Future<void> _confirmDelete(Sticker sticker) async {
    final l10n = context.l10n;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: Text(l10n.deleteStickerConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.deleteSticker),
          ),
        ],
      ),
    );
    if (ok == true) widget.onDelete(sticker);
  }

  @override
  Widget build(BuildContext context) {
    final tg = context.tg;
    final l10n = context.l10n;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tg.pageBackground,
        border: Border(top: BorderSide(color: tg.separator)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              _Tab(
                label: l10n.stickerEmoji,
                selected: _pane == _ComposerPane.emoji,
                onTap: () => setState(() => _pane = _ComposerPane.emoji),
              ),
              _Tab(
                label: l10n.stickerKaomoji,
                selected: _pane == _ComposerPane.kaomoji,
                onTap: () => setState(() => _pane = _ComposerPane.kaomoji),
              ),
              _Tab(
                label: l10n.stickerCustom,
                selected: _pane == _ComposerPane.custom,
                onTap: () => setState(() => _pane = _ComposerPane.custom),
              ),
            ],
          ),
          Expanded(
            child: switch (_pane) {
              _ComposerPane.emoji => EmojiPickerPanel(onPick: widget.onInsert),
              _ComposerPane.kaomoji => _kaomojiMatrix(context),
              _ComposerPane.custom => _custom(context),
            },
          ),
        ],
      ),
    );
  }

  Widget _kaomojiMatrix(BuildContext context) {
    final tg = context.tg;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final value in kKaomoji)
            Material(
              color: tg.barBackground,
              borderRadius: BorderRadius.circular(10),
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () => widget.onInsert(value),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  child: Text(
                    value,
                    style: TextStyle(fontSize: 15, color: tg.textPrimary),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _custom(BuildContext context) {
    final tg = context.tg;
    final l10n = context.l10n;
    return StreamBuilder<List<Sticker>>(
      stream: widget.stickers,
      builder: (context, snapshot) {
        final rows = snapshot.data ?? const <Sticker>[];
        return GridView.builder(
          padding: const EdgeInsets.all(8),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 4,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
          ),
          itemCount: rows.length + 1,
          itemBuilder: (context, index) {
            if (index == rows.length) {
              return Material(
                color: tg.barBackground,
                borderRadius: BorderRadius.circular(8),
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: widget.onAdd,
                  child: Tooltip(
                    message: l10n.addSticker,
                    child: Icon(Icons.add, color: tg.textSecondary, size: 32),
                  ),
                ),
              );
            }
            final sticker = rows[index];
            return Material(
              color: tg.barBackground,
              borderRadius: BorderRadius.circular(8),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () => widget.onSend(sticker),
                onLongPress: () => _confirmDelete(sticker),
                child: Image.memory(
                  sticker.image,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  errorBuilder: (_, _, _) => Icon(
                    Icons.broken_image_outlined,
                    color: tg.textSecondary,
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tg = context.tg;
    return Expanded(
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              color: selected ? tg.accent : tg.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}
