// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Shared emoji palette for reactions and the composer.
//
// One catalogue, one filter (Gajim-aligned `isReactionEmoji`). Kaomoji and
// stickers live beside this panel in the composer, not inside it.

import 'package:flutter/material.dart';

import 'package:resonchat/l10n/l10n.dart';
import 'package:resonchat/ui/chat/emoji_data.dart';
import 'package:resonchat/ui/theme.dart';

/// Single-code-point ❤ without emoji presentation — Linux draws it black.
const String kTextPresentationHeart = '❤';

class _EmojiSection {
  const _EmojiSection(this.categories, this.icon);

  final List<EmojiCategory> categories;
  final IconData icon;
}

/// Smileys+people share a tab (one "faces" intent).
const List<_EmojiSection> _sections = <_EmojiSection>[
  _EmojiSection([
    EmojiCategory.smileys,
    EmojiCategory.people,
  ], Icons.emoji_emotions_outlined),
  _EmojiSection([EmojiCategory.animals], Icons.pets),
  _EmojiSection([EmojiCategory.food], Icons.restaurant),
  _EmojiSection([EmojiCategory.activity], Icons.sports_soccer),
  _EmojiSection([EmojiCategory.travel], Icons.flight),
  _EmojiSection([EmojiCategory.objects], Icons.lightbulb_outline),
  _EmojiSection([EmojiCategory.symbols], Icons.tag),
  _EmojiSection([EmojiCategory.flags], Icons.flag_outlined),
];

List<String> _glyphsFor(_EmojiSection section) {
  final seen = <String>{};
  return <String>[
    for (final category in section.categories)
      for (final entry in emojiIn(category))
        if (isReactionEmoji(entry.emoji) &&
            entry.emoji != kTextPresentationHeart &&
            seen.add(entry.emoji))
          entry.emoji,
  ];
}

String _sectionTitle(AppLocalizations l10n, _EmojiSection section) {
  switch (section.categories.first) {
    case EmojiCategory.smileys:
    case EmojiCategory.people:
      return l10n.emojiCategorySmileysPeople;
    case EmojiCategory.animals:
      return l10n.emojiCategoryAnimals;
    case EmojiCategory.food:
      return l10n.emojiCategoryFood;
    case EmojiCategory.activity:
      return l10n.emojiCategoryActivity;
    case EmojiCategory.travel:
      return l10n.emojiCategoryTravel;
    case EmojiCategory.objects:
      return l10n.emojiCategoryObjects;
    case EmojiCategory.symbols:
      return l10n.emojiCategorySymbols;
    case EmojiCategory.flags:
      return l10n.emojiCategoryFlags;
    case EmojiCategory.recent:
      return l10n.emojiCategorySmileysPeople;
  }
}

/// Full emoji palette: header + swipeable grids + category tabs.
class EmojiPickerPanel extends StatefulWidget {
  const EmojiPickerPanel({super.key, required this.onPick, this.leading});

  final ValueChanged<String> onPick;

  /// Optional leading control in the title row (e.g. back out of reactions).
  final Widget? leading;

  @override
  State<EmojiPickerPanel> createState() => _EmojiPickerPanelState();
}

class _EmojiPickerPanelState extends State<EmojiPickerPanel> {
  static const int _columns = 7;
  static const double _emojiSize = 30;
  static const double _tabHeight = 44;

  late final List<ScrollController> _gridScrolls =
      List<ScrollController>.generate(
        _sections.length,
        (_) => ScrollController(),
      );
  late final PageController _pager = PageController();
  late final List<List<String>> _glyphs = [
    for (final section in _sections) _glyphsFor(section),
  ];

  int _section = 0;

  void _selectSection(int index) {
    if (index == _section) return;
    setState(() => _section = index);
    if (_pager.hasClients) _pager.jumpToPage(index);
    final controller = _gridScrolls[index];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (controller.hasClients) controller.jumpTo(0);
    });
  }

  void _onPageChanged(int index) {
    if (index == _section) return;
    setState(() => _section = index);
  }

  @override
  void dispose() {
    for (final c in _gridScrolls) {
      c.dispose();
    }
    _pager.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final tg = context.tg;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 12, 2),
          child: Row(
            children: [
              if (widget.leading != null) ...[
                widget.leading!,
                const SizedBox(width: 2),
              ],
              Expanded(
                child: Text(
                  _sectionTitle(l10n, _sections[_section]),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: tg.textPrimary,
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: PageView.builder(
            controller: _pager,
            itemCount: _sections.length,
            onPageChanged: _onPageChanged,
            itemBuilder: (context, i) =>
                _emojiGrid(context, _glyphs[i], _gridScrolls[i]),
          ),
        ),
        _tabs(context, l10n),
      ],
    );
  }

  Widget _emojiGrid(
    BuildContext context,
    List<String> emoji,
    ScrollController controller,
  ) {
    return Scrollbar(
      controller: controller,
      thumbVisibility: true,
      thickness: 3,
      radius: const Radius.circular(2),
      child: GridView.builder(
        controller: controller,
        padding: const EdgeInsets.fromLTRB(6, 2, 6, 4),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: _columns,
          mainAxisExtent: 46,
        ),
        itemCount: emoji.length,
        itemBuilder: (context, index) {
          final value = emoji[index];
          return InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => widget.onPick(value),
            child: Center(
              child: Text(value, style: emojiTextStyle(fontSize: _emojiSize)),
            ),
          );
        },
      ),
    );
  }

  Widget _tabs(BuildContext context, AppLocalizations l10n) {
    final theme = Theme.of(context);
    final tg = context.tg;
    return Container(
      height: _tabHeight,
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: tg.separator.withValues(alpha: 0.6)),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: [
          for (var i = 0; i < _sections.length; i++)
            Expanded(
              child: Tooltip(
                message: _sectionTitle(l10n, _sections[i]),
                child: InkWell(
                  borderRadius: BorderRadius.circular(18),
                  onTap: () => _selectSection(i),
                  child: Center(
                    child: Container(
                      width: 30,
                      height: 30,
                      decoration: i == _section
                          ? BoxDecoration(
                              shape: BoxShape.circle,
                              color: theme.colorScheme.onSurface.withValues(
                                alpha: 0.08,
                              ),
                            )
                          : null,
                      child: Center(
                        child: Icon(
                          _sections[i].icon,
                          size: 18,
                          color: i == _section
                              ? theme.colorScheme.onSurface
                              : theme.colorScheme.onSurfaceVariant,
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
