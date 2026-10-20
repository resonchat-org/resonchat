// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Composer panel under the input: built-in emoji and kaomoji, or saved images.

import 'package:flutter/material.dart';

import 'package:resonchat/l10n/l10n.dart';
import 'package:resonchat/persistence/database.dart';
import 'package:resonchat/ui/chat/emoji_data.dart';
import 'package:resonchat/ui/theme.dart';

/// Kaomoji offered next to the emoji catalogue. Text, not images.
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

const List<EmojiCategory> _emojiCategories = [
  EmojiCategory.smileys,
  EmojiCategory.people,
  EmojiCategory.animals,
  EmojiCategory.food,
  EmojiCategory.activity,
  EmojiCategory.travel,
  EmojiCategory.objects,
  EmojiCategory.symbols,
  EmojiCategory.flags,
];

/// 0 is kaomoji. 1 and up index [_emojiCategories].
const int _kaomojiSection = 0;

/// Two tabs under the composer. Emoji inserts text. A saved image sends.
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
  var _images = false;

  /// Smileys, not kaomoji: that is the set people open this panel for.
  var _builtin = 1;

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
                selected: !_images,
                onTap: () => setState(() => _images = false),
              ),
              _Tab(
                label: l10n.stickerCustom,
                selected: _images,
                onTap: () => setState(() => _images = true),
              ),
            ],
          ),
          Expanded(
            child: _images ? _custom(context) : _builtinPane(context, l10n),
          ),
        ],
      ),
    );
  }

  Widget _builtinPane(BuildContext context, AppLocalizations l10n) {
    final tg = context.tg;
    return Column(
      children: [
        SizedBox(
          height: 40,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: ChoiceChip(
                  label: Text(l10n.stickerKaomoji),
                  selected: _builtin == _kaomojiSection,
                  onSelected: (_) => setState(() => _builtin = _kaomojiSection),
                ),
              ),
              for (var i = 0; i < _emojiCategories.length; i++)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: ChoiceChip(
                    label: Text(_emojiCategories[i].label),
                    selected: _builtin == i + 1,
                    onSelected: (_) => setState(() => _builtin = i + 1),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: _builtin == _kaomojiSection
              ? SingleChildScrollView(
                  padding: const EdgeInsets.all(8),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final text in kKaomoji)
                        ActionChip(
                          label: Text(text),
                          onPressed: () => widget.onInsert(text),
                        ),
                    ],
                  ),
                )
              : GridView.builder(
                  padding: const EdgeInsets.all(4),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 8,
                  ),
                  itemCount: emojiIn(_emojiCategories[_builtin - 1]).length,
                  itemBuilder: (context, index) {
                    final emoji = emojiIn(
                      _emojiCategories[_builtin - 1],
                    )[index].emoji;
                    return InkWell(
                      onTap: () => widget.onInsert(emoji),
                      child: Center(
                        child: Text(
                          emoji,
                          style: TextStyle(fontSize: 24, color: tg.textPrimary),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
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
