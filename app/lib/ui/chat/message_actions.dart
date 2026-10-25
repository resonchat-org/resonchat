// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The menu on a message: a card beside the bubble, not a sheet.
//
// Retract is offered on our own messages (XEP-0424) and, in a group, on
// other people's messages when we are a moderator and the room supports
// XEP-0425. Edit stays limited to our own messages.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'package:resonchat/crypto/dual/track.dart';
import 'package:resonchat/l10n/l10n.dart';
import 'package:resonchat/ui/chat/emoji_data.dart';
import 'package:resonchat/ui/chat/reaction_recents.dart';
import 'package:resonchat/ui/motion.dart';
import 'package:resonchat/ui/theme.dart';
import 'package:resonchat/xmpp/chat/reactions.dart';

/// The actions available on one message.
class MessageActions {
  const MessageActions({
    required this.canReply,
    required this.canForward,
    required this.canReact,
    required this.canCopy,
    required this.canCopySelection,
    required this.canTranslate,
    required this.canSelect,
    required this.canEdit,
    required this.canRetract,
    required this.canSaveFile,
    this.canSaveSticker = false,
    required this.isPinned,
  });

  /// Replies address a message by its origin-id, so they need an addressable
  /// one. A message from a client that published no stable id cannot be
  /// replied to by reference — offering it would produce a reply whose
  /// `> ` quote is the only link to its target.
  final bool canReply;

  /// Forwarding works on anything readable, including an undecryptable
  /// message — but forwarding a placeholder would send the reader a sentence
  /// about the app rather than the message.
  final bool canForward;

  /// Reactions work on anything we can see, including a message we could not
  /// decrypt — that is exactly when the sender most wants to hear that we read
  /// it. The target still needs a stable id, or the reaction has nothing to
  /// address.
  final bool canReact;

  final bool canCopy;

  /// Copy only the range the user has selected in a text message.
  ///
  /// Separate from [canCopy], which copies the whole body. Images and other
  /// files do not offer it.
  final bool canCopySelection;

  /// External HTTP translation for translatable plaintext (not files / emoji).
  final bool canTranslate;

  /// Enter multi-select with this message as the first pick (addressable only).
  final bool canSelect;

  /// Only our own messages: an edit replaces content, and we cannot replace
  /// somebody else's.
  final bool canEdit;

  /// Our own messages (XEP-0424), or someone else's in a group we moderate
  /// (XEP-0425). The message still has to be addressable.
  final bool canRetract;

  /// File / image message with a downloaded private cache copy (Copinc
  /// “Save file”). Hidden for plain text and for undownloaded attachments.
  final bool canSaveFile;

  /// Save this image into the account sticker collection.
  ///
  /// Only an image that is already on disk. Other files, and images that
  /// have not been downloaded, do not offer it.
  final bool canSaveSticker;

  /// Whether this message is already pinned, so the entry can offer the
  /// opposite action rather than a verb that does the wrong thing.
  final bool isPinned;

  factory MessageActions.for_({
    required bool mine,
    required bool retracted,
    required bool decrypted,
    required bool addressable,
    required bool pinned,
    bool canSaveFile = false,
    bool canSaveSticker = false,
    bool canTranslate = false,
    bool canCopySelection = false,
    bool moderate = false,
    bool groupchat = false,
    bool hasRoomStanzaId = true,
  }) {
    return MessageActions(
      canReply: !retracted && addressable,
      canForward: !retracted && decrypted,
      canReact: !retracted && addressable,
      canCopy: decrypted && !retracted,
      canCopySelection: decrypted && !retracted && canCopySelection,
      canTranslate: canTranslate,
      canSelect: !retracted && addressable,
      canEdit: mine && !retracted && decrypted,
      // Group messages are addressed by the room stanza-id. Offering retract
      // without that id sends the origin-id, which other clients cannot match.
      canRetract:
          !retracted &&
          addressable &&
          (moderate || (mine && (!groupchat || hasRoomStanzaId))),
      canSaveFile: !retracted && canSaveFile,
      canSaveSticker: !retracted && canSaveSticker,
      isPinned: pinned,
    );
  }

  bool get isEmpty =>
      !canReply &&
      !canReact &&
      !canCopy &&
      !canCopySelection &&
      !canTranslate &&
      !canSelect &&
      !canEdit &&
      !canForward &&
      !canRetract &&
      !canSaveFile &&
      !canSaveSticker;
}

/// What the message menu returned: a command, or an emoji to toggle.
sealed class MessageMenuResult {
  const MessageMenuResult();
}

class MessageMenuAction extends MessageMenuResult {
  const MessageMenuAction(this.action);

  final MessageAction action;
}

class MessageMenuReaction extends MessageMenuResult {
  const MessageMenuReaction(this.emoji, {this.fromMore = false});

  final String emoji;

  /// True when the emoji came from the full palette rather than the front row.
  /// The caller promotes those into the front row so the next menu shows it.
  final bool fromMore;
}

/// A command picked from the message menu.
enum MessageAction {
  reply,
  copy,
  copySelection,
  translate,
  select,
  edit,
  forward,
  pin,
  retract,
  saveFile,
  saveSticker,
}

/// One row in the menu.
class _MenuItem {
  const _MenuItem({
    required this.icon,
    required this.label,
    required this.action,
    this.danger = false,
  });

  final IconData icon;
  final String label;
  final MessageAction action;
  final bool danger;
}

/// Action grid + selecting body share this so selection taps are not "outside".
const Object messageMenuTapRegionGroup = Object();

VoidCallback? _dismissActiveMessageMenu;

/// Drops the open menu, if any (also used before opening another).
void dismissActiveMessageMenu() {
  final dismiss = _dismissActiveMessageMenu;
  if (dismiss == null) return;
  _dismissActiveMessageMenu = null;
  dismiss();
}

/// One tab in the full emoji palette.
///
/// Smileys and people share a tab, as they do in the reference picker: they
/// are one browsing intent ("faces") and splitting them leaves two short
/// grids. Flags are deliberately absent — every flag is a regional-indicator
/// pair, so none of them is a sendable reaction.
class _EmojiSection {
  const _EmojiSection(this.categories, this.icon);

  final List<EmojiCategory> categories;
  final IconData icon;
}

const List<_EmojiSection> _emojiSections = <_EmojiSection>[
  _EmojiSection(<EmojiCategory>[
    EmojiCategory.smileys,
    EmojiCategory.people,
  ], Icons.emoji_emotions_outlined),
  _EmojiSection(<EmojiCategory>[EmojiCategory.animals], Icons.pets),
  _EmojiSection(<EmojiCategory>[EmojiCategory.food], Icons.restaurant),
  _EmojiSection(<EmojiCategory>[EmojiCategory.activity], Icons.sports_soccer),
  _EmojiSection(<EmojiCategory>[EmojiCategory.travel], Icons.flight),
  _EmojiSection(<EmojiCategory>[
    EmojiCategory.objects,
  ], Icons.lightbulb_outline),
  _EmojiSection(<EmojiCategory>[EmojiCategory.symbols], Icons.tag),
];

/// Shows the menu beside [anchor] and returns what the user picked, or null.
///
/// [anchor] is the bubble in global coordinates. Taps outside the bubble and
/// the menu dismiss it; taps on the bubble pass through so a text selection
/// can be adjusted. At most one menu is open; [dismissActiveMessageMenu]
/// closes it from the caller's side.
Future<MessageMenuResult?> showMessageMenu(
  BuildContext context, {
  required MessageActions actions,
  required bool trackIsPlaintext,
  required Rect anchor,
  List<String> quickReactions = kQuickReactions,
}) {
  // One menu at a time. Dismiss the previous overlay before measuring a new
  // anchor, so its barrier cannot survive and swallow the next tap.
  dismissActiveMessageMenu();

  final overlay = Overlay.of(context);
  final overlayBox = overlay.context.findRenderObject() as RenderBox?;
  final localAnchor = overlayBox == null
      ? anchor
      : Rect.fromPoints(
          overlayBox.globalToLocal(anchor.topLeft),
          overlayBox.globalToLocal(anchor.bottomRight),
        );
  final completer = Completer<MessageMenuResult?>();
  late OverlayEntry entry;
  late final VoidCallback dismissThis;
  void finish(MessageMenuResult? result) {
    if (completer.isCompleted) return;
    if (identical(_dismissActiveMessageMenu, dismissThis)) {
      _dismissActiveMessageMenu = null;
    }
    entry.remove();
    completer.complete(result);
  }

  dismissThis = () => finish(null);
  _dismissActiveMessageMenu = dismissThis;

  entry = OverlayEntry(
    builder: (context) => _AnchoredMessageMenu(
      anchor: localAnchor,
      actions: actions,
      trackIsPlaintext: trackIsPlaintext,
      quickReactions: quickReactions,
      onPick: finish,
    ),
  );
  overlay.insert(entry);
  return completer.future;
}

/// A vertical action list with the reaction row on top.
///
/// The grid was compact but its two-line cells made the labels hard to scan.
/// A list keeps the icon beside the verb, so the destructive row can sit last
/// and the reaction row can be reached without closing the menu. The trailing
/// arrow opens a fuller palette in place of the action list: a reaction should
/// not force the reader to choose between emoji and commands.
class _AnchoredMessageMenu extends StatefulWidget {
  const _AnchoredMessageMenu({
    required this.anchor,
    required this.actions,
    required this.trackIsPlaintext,
    required this.quickReactions,
    required this.onPick,
  });

  final Rect anchor;
  final MessageActions actions;
  final bool trackIsPlaintext;
  final List<String> quickReactions;
  final void Function(MessageMenuResult? result) onPick;

  @override
  State<_AnchoredMessageMenu> createState() => _AnchoredMessageMenuState();
}

class _AnchoredMessageMenuState extends State<_AnchoredMessageMenu>
    with SingleTickerProviderStateMixin {
  static const double _menuWidth = 248;
  static const double _rowHeight = 44;
  static const double _emojiRowHeight = 40;
  static const double _quickRowHeight = 48;
  static const double _warningHeight = 24;
  static const double _bottomPad = 4;

  /// The full palette is a picker card, not a wider copy of the action card.
  static const double _pickerWidth = 360;
  static const double _pickerHeight = 440;
  static const int _pickerColumns = 7;
  static const double _pickerEmojiSize = 30;
  static const double _pickerTabHeight = 44;

  /// Single-code-point emoji without default emoji presentation. U+2764 is
  /// sendable by the code-point rule but Linux draws it black; the front row
  /// and the picker use 💗 instead.
  static const String _textPresentationHeart = '❤';

  /// One controller per category, so each category keeps its own scroll
  /// position. Only the visible grid is mounted at a time; one controller may
  /// not be attached to two scroll views at once.
  late final List<ScrollController> _gridScrolls =
      List<ScrollController>.generate(
        _emojiSections.length,
        (_) => ScrollController(),
      );

  late final AnimationController _entrance = AnimationController(
    vsync: this,
    duration: kMotionFast,
  );
  late final Animation<double> _entranceFade = CurvedAnimation(
    parent: _entrance,
    curve: kMotionEnter,
  );
  late final Animation<Offset> _entranceSlide = Tween<Offset>(
    begin: const Offset(0, 0.025),
    end: Offset.zero,
  ).animate(_entranceFade);

  bool _moreReactions = false;
  bool _closing = false;
  int _section = 0;

  ScrollController get _gridScroll => _gridScrolls[_section];

  List<String> get _quick =>
      widget.quickReactions.take(kQuickReactionSlots).toList(growable: false);

  /// The emoji shown by the selected tab.
  ///
  /// The catalogue is display-complete (flags, ZWJ families, variation
  /// selectors); a reaction must be one code point, so the picker reads the
  /// category and filters rather than showing entries that cannot be sent.
  List<String> get _sectionEmoji {
    final seen = <String>{};
    return <String>[
      for (final category in _emojiSections[_section].categories)
        for (final entry in emojiIn(category))
          if (_isPickerEmoji(entry.emoji) && seen.add(entry.emoji)) entry.emoji,
    ];
  }

  static bool _isPickerEmoji(String emoji) =>
      isSendableEmoji(emoji) && emoji != _textPresentationHeart;

  bool _entranceStarted = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_entranceStarted) return;
    _entranceStarted = true;
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
      _entrance.value = 1;
    } else {
      _entrance.forward();
    }
  }

  @override
  void dispose() {
    for (final controller in _gridScrolls) {
      controller.dispose();
    }
    _entrance.dispose();
    super.dispose();
  }

  /// Runs the exit animation before handing the result back, so the overlay
  /// does not disappear in one frame after the user taps an item.
  void _pick(MessageMenuResult? result) {
    if (_closing) return;
    _closing = true;
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
      widget.onPick(result);
      return;
    }
    _entrance.reverse().whenComplete(() => widget.onPick(result));
  }

  void _closePalette() {
    setState(() => _moreReactions = false);
  }

  void _selectSection(int index) {
    if (index == _section) return;
    setState(() => _section = index);
    // Returning to a category starts at its first row; the old grid may have
    // been left halfway down.
    final controller = _gridScrolls[index];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (controller.hasClients) controller.jumpTo(0);
    });
  }

  String _sectionTitle(AppLocalizations l10n, int index) {
    switch (index) {
      case 0:
        return l10n.emojiCategorySmileysPeople;
      case 1:
        return l10n.emojiCategoryAnimals;
      case 2:
        return l10n.emojiCategoryFood;
      case 3:
        return l10n.emojiCategoryActivity;
      case 4:
        return l10n.emojiCategoryTravel;
      case 5:
        return l10n.emojiCategoryObjects;
      default:
        return l10n.emojiCategorySymbols;
    }
  }

  List<_MenuItem> _items(AppLocalizations l10n) {
    final actions = widget.actions;
    return [
      if (actions.canReply)
        _MenuItem(
          icon: Icons.reply,
          label: l10n.reply,
          action: MessageAction.reply,
        ),
      if (actions.canCopy)
        _MenuItem(
          icon: Icons.copy,
          label: l10n.copyText,
          action: MessageAction.copy,
        ),
      if (actions.canCopySelection)
        _MenuItem(
          icon: Icons.highlight_alt,
          label: l10n.copySelection,
          action: MessageAction.copySelection,
        ),
      if (actions.canTranslate)
        _MenuItem(
          icon: Icons.translate,
          label: l10n.translate,
          action: MessageAction.translate,
        ),
      if (actions.canForward)
        _MenuItem(
          icon: Icons.forward,
          label: l10n.forward,
          action: MessageAction.forward,
        ),
      if (actions.canSaveFile)
        _MenuItem(
          icon: Icons.save_alt,
          label: l10n.saveFile,
          action: MessageAction.saveFile,
        ),
      if (actions.canSaveSticker)
        _MenuItem(
          icon: Icons.emoji_emotions_outlined,
          label: l10n.saveSticker,
          action: MessageAction.saveSticker,
        ),
      if (actions.canEdit)
        _MenuItem(
          icon: Icons.edit_outlined,
          label: l10n.edit,
          action: MessageAction.edit,
        ),
      if (actions.canEdit)
        _MenuItem(
          icon: Icons.push_pin_outlined,
          label: actions.isPinned ? l10n.unpin : l10n.pin,
          action: MessageAction.pin,
        ),
      if (actions.canSelect)
        _MenuItem(
          icon: Icons.checklist,
          label: l10n.selectMessages,
          action: MessageAction.select,
        ),
      if (actions.canRetract)
        _MenuItem(
          icon: Icons.undo,
          label: l10n.retractMessage,
          action: MessageAction.retract,
          danger: true,
        ),
    ];
  }

  /// One tap target for an emoji. [fromMore] tells the caller to promote it
  /// into the front row, so the next menu shows it without reopening the
  /// palette.
  Widget _emojiTap(String emoji, {required bool fromMore}) {
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => _pick(MessageMenuReaction(emoji, fromMore: fromMore)),
      child: Center(child: Text(emoji, style: emojiTextStyle(fontSize: 24))),
    );
  }

  Widget _quickEmoji(String emoji) {
    return Expanded(
      child: SizedBox(
        height: _emojiRowHeight,
        child: _emojiTap(emoji, fromMore: false),
      ),
    );
  }

  Widget _reactionRow(BuildContext context, AppLocalizations l10n) {
    final theme = Theme.of(context);
    final tg = context.tg;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 6, 6, 2),
          child: Row(
            children: [
              for (final emoji in _quick) _quickEmoji(emoji),
              SizedBox(
                width: 30,
                height: 30,
                child: IconButton(
                  padding: EdgeInsets.zero,
                  iconSize: 18,
                  tooltip: l10n.react,
                  style: IconButton.styleFrom(
                    backgroundColor: theme.colorScheme.onSurface.withValues(
                      alpha: 0.06,
                    ),
                    foregroundColor: theme.colorScheme.onSurfaceVariant,
                  ),
                  onPressed: () => setState(() => _moreReactions = true),
                  icon: const Icon(Icons.keyboard_arrow_down),
                ),
              ),
            ],
          ),
        ),
        Divider(
          height: 1,
          thickness: 1,
          color: tg.separator.withValues(alpha: 0.6),
        ),
      ],
    );
  }

  Widget _pickerHeader(BuildContext context, String title) {
    final tg = context.tg;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 12, 2),
      child: Row(
        children: [
          IconButton(
            onPressed: _closePalette,
            iconSize: 20,
            tooltip: MaterialLocalizations.of(context).backButtonTooltip,
            icon: const Icon(Icons.arrow_back),
          ),
          const SizedBox(width: 2),
          Expanded(
            child: AnimatedSwitcher(
              duration: motionDuration(context, kMotionFast),
              switchInCurve: kMotionEnter,
              switchOutCurve: kMotionExit,
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation,
                child: SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0, 0.18),
                    end: Offset.zero,
                  ).animate(animation),
                  child: child,
                ),
              ),
              child: Text(
                title,
                key: ValueKey(title),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: tg.textPrimary,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _pickerGrid(
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
          crossAxisCount: _pickerColumns,
          mainAxisExtent: 46,
        ),
        itemCount: emoji.length,
        itemBuilder: (context, index) {
          final value = emoji[index];
          return InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => _pick(MessageMenuReaction(value, fromMore: true)),
            child: Center(
              child: Text(
                value,
                style: emojiTextStyle(fontSize: _pickerEmojiSize),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _pickerTabs(BuildContext context, AppLocalizations l10n) {
    final theme = Theme.of(context);
    final tg = context.tg;
    return Container(
      height: _pickerTabHeight,
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: tg.separator.withValues(alpha: 0.6)),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: [
          for (var i = 0; i < _emojiSections.length; i++)
            Expanded(
              child: Tooltip(
                message: _sectionTitle(l10n, i),
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
                          _emojiSections[i].icon,
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

  Widget _pickerCard(BuildContext context, AppLocalizations l10n) {
    final theme = Theme.of(context);
    final emoji = _sectionEmoji;
    return Material(
      elevation: 8,
      color: theme.colorScheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          _pickerHeader(context, _sectionTitle(l10n, _section)),
          Expanded(
            // A fade-in of the new section, rather than a cross-fade that
            // keeps the previous grid alive: the outgoing grid would still be
            // attached to the same per-category controller if the user
            // switched A→B→A quickly, and one ScrollController may not drive
            // two ScrollPositions.
            child: TweenAnimationBuilder<double>(
              key: ValueKey('emoji-section-$_section'),
              tween: Tween<double>(begin: 0, end: 1),
              duration: motionDuration(context, kMotionFast),
              curve: kMotionEnter,
              builder: (context, t, child) => Opacity(
                opacity: t,
                child: Transform.scale(scale: 0.985 + 0.015 * t, child: child),
              ),
              child: _pickerGrid(context, emoji, _gridScroll),
            ),
          ),
          _pickerTabs(context, l10n),
        ],
      ),
    );
  }

  Widget _actionRow(BuildContext context, _MenuItem item) {
    final theme = Theme.of(context);
    final color = item.danger
        ? theme.colorScheme.error
        : theme.colorScheme.onSurface;
    return InkWell(
      onTap: () => _pick(MessageMenuAction(item.action)),
      child: SizedBox(
        height: _rowHeight,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(
            children: [
              Icon(item.icon, size: 20, color: color),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  item.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 14, color: color),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final items = _items(l10n);
    final warn = widget.actions.canRetract && widget.trackIsPlaintext;
    final showActions = !_moreReactions;

    final baseHeight =
        (widget.actions.canReact ? _quickRowHeight + 1 : 0.0) +
        items.length * _rowHeight +
        (warn ? _warningHeight : 0) +
        _bottomPad;

    final size = MediaQuery.sizeOf(context);
    final pad = MediaQuery.paddingOf(context);
    final availableHeight = size.height - pad.top - pad.bottom - 16;
    final pickerHeight = math.min(
      _pickerHeight,
      math.max(220.0, availableHeight),
    );
    final pickerWidth = math.min(_pickerWidth, size.width - 16);
    final cardWidth = _moreReactions ? pickerWidth : _menuWidth;
    final cardHeight = _moreReactions ? pickerHeight : baseHeight;

    // Keep the card inside the window and prefer the space above the bubble;
    // the picker is taller than the action list, so it can flip below when the
    // bubble is near the top. The bubble remains the anchor in both views.
    var top = widget.anchor.top - cardHeight - 8;
    if (top < pad.top + 8) top = widget.anchor.bottom + 8;
    if (top + cardHeight > size.height - pad.bottom - 8) {
      top = math.max(pad.top + 8, size.height - pad.bottom - cardHeight - 8);
    }
    final maxHeight = math.max(120.0, size.height - pad.bottom - 8 - top);
    // Align the card's inner edge with the bubble's: an incoming bubble near
    // the pane's left edge opens to the right, an outgoing one opens to the
    // left. Centring a narrow bubble near an edge would hang the card over the
    // neighbouring pane.
    var left = widget.anchor.center.dx < size.width / 2
        ? widget.anchor.left
        : widget.anchor.right - cardWidth;
    left = left.clamp(8.0, math.max(8.0, size.width - cardWidth - 8));

    return FadeTransition(
      opacity: _entranceFade,
      child: SlideTransition(
        position: _entranceSlide,
        child: Stack(
          children: [
            Positioned.fill(
              child: _MenuBarrier(
                hole: widget.anchor.inflate(28),
                onDismiss: () => _pick(null),
              ),
            ),
            AnimatedPositioned(
              duration: motionDuration(context, kMotionBase),
              curve: kMotionStandard,
              left: left,
              top: top,
              width: cardWidth,
              child: AnimatedSize(
                duration: motionDuration(context, kMotionBase),
                curve: kMotionStandard,
                alignment: Alignment.topLeft,
                child: AnimatedSwitcher(
                  duration: motionDuration(context, kMotionBase),
                  switchInCurve: kMotionEnter,
                  switchOutCurve: kMotionExit,
                  layoutBuilder: (current, previous) => Stack(
                    alignment: Alignment.topLeft,
                    children: [
                      // The outgoing card is only a fading image; taps belong
                      // to the incoming one (or to the bubble through the
                      // barrier hole), never to a button that is leaving.
                      for (final child in previous)
                        IgnorePointer(child: ExcludeSemantics(child: child)),
                      ?current,
                    ],
                  ),
                  transitionBuilder: (child, animation) => FadeTransition(
                    opacity: animation,
                    child: SlideTransition(
                      position: Tween<Offset>(
                        begin: const Offset(0, 0.02),
                        end: Offset.zero,
                      ).animate(animation),
                      child: child,
                    ),
                  ),
                  child: _moreReactions
                      ? SizedBox(
                          key: const ValueKey('emoji-picker'),
                          height: pickerHeight,
                          child: _pickerCard(context, l10n),
                        )
                      : Material(
                          key: const ValueKey('message-actions'),
                          elevation: 8,
                          color: theme.colorScheme.surfaceContainerHigh,
                          borderRadius: BorderRadius.circular(16),
                          clipBehavior: Clip.antiAlias,
                          child: ConstrainedBox(
                            constraints: BoxConstraints(maxHeight: maxHeight),
                            child: SingleChildScrollView(
                              padding: const EdgeInsets.only(
                                bottom: _bottomPad,
                              ),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (widget.actions.canReact)
                                    _reactionRow(context, l10n),
                                  if (showActions)
                                    for (final item in items)
                                      _actionRow(context, item),
                                  if (showActions && warn)
                                    Padding(
                                      padding: const EdgeInsets.fromLTRB(
                                        14,
                                        0,
                                        14,
                                        8,
                                      ),
                                      child: Text(
                                        l10n.retractUnencryptedWarning,
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: theme
                                              .colorScheme
                                              .onSurfaceVariant,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Full-screen tap target with a hole over the bubble.
class _MenuBarrier extends LeafRenderObjectWidget {
  const _MenuBarrier({required this.hole, required this.onDismiss});

  final Rect hole;
  final VoidCallback onDismiss;

  @override
  RenderObject createRenderObject(BuildContext context) {
    return _MenuBarrierBox(hole: hole, onDismiss: onDismiss);
  }

  @override
  void updateRenderObject(BuildContext context, _MenuBarrierBox renderObject) {
    renderObject
      ..hole = hole
      ..onDismiss = onDismiss;
  }
}

class _MenuBarrierBox extends RenderBox {
  _MenuBarrierBox({required this._hole, required this._onDismiss});

  Rect _hole;
  VoidCallback _onDismiss;

  set hole(Rect value) {
    if (_hole == value) return;
    _hole = value;
    markNeedsPaint();
  }

  set onDismiss(VoidCallback value) => _onDismiss = value;

  @override
  bool get sizedByParent => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (_hole.contains(position)) return false;
    result.add(BoxHitTestEntry(this, position));
    return true;
  }

  @override
  void handleEvent(PointerEvent event, BoxHitTestEntry entry) {
    if (event is PointerDownEvent) _onDismiss();
  }

  @override
  void paint(PaintingContext context, Offset offset) {}
}

/// The action bar shown while messages are selected.
///
/// Replaces the input bar rather than sitting above it, for the same reason the
/// edit composer does: two things that both accept input in one chat is
/// ambiguous about where a keystroke goes.
class SelectionBar extends StatelessWidget {
  const SelectionBar({
    super.key,
    required this.count,
    required this.onForward,
    required this.onDelete,
    required this.onCancel,
  });

  final int count;
  final VoidCallback onForward;
  final VoidCallback onDelete;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    return Material(
      color: theme.colorScheme.surfaceContainerHigh,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
          child: Row(
            children: [
              IconButton(
                onPressed: onCancel,
                icon: const Icon(Icons.close),
                tooltip: l10n.cancel,
              ),
              Expanded(
                child: Text(
                  count == 0 ? l10n.selectMessages : l10n.selectedCount(count),
                  style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
              IconButton(
                onPressed: count == 0 ? null : onForward,
                icon: const Icon(Icons.forward),
                tooltip: l10n.forward,
              ),
              IconButton(
                // Retract only our own messages, and only where it can
                // actually work: XEP-0424 is per message, so a mixed selection
                // retracts the subset we sent and says so.
                onPressed: count == 0 ? null : onDelete,
                icon: const Icon(Icons.undo),
                tooltip: l10n.retractMine,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The strip above the input bar while a reply is being written.
///
/// Above the input rather than in it: the text being typed is the reply, and
/// mixing a quote into the same field means the user edits their own reply by
/// accident.
class ReplyPreview extends StatelessWidget {
  const ReplyPreview({
    super.key,
    required this.author,
    required this.body,
    required this.onCancel,
    this.onTap,
  });

  final String author;
  final String body;
  final VoidCallback onCancel;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tg = context.tg;
    final l10n = context.l10n;
    return Material(
      color: theme.colorScheme.surfaceContainerHigh,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 40),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const SizedBox(width: 12),
            Icon(Icons.reply, size: 20, color: tg.accent),
            Expanded(
              child: InkWell(
                onTap: onTap,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(13, 6, 15, 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (author.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 2),
                          child: Text(
                            author,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: tg.accent,
                            ),
                          ),
                        ),
                      if (body.isNotEmpty)
                        Text(
                          body,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14,
                            height: 1.25,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            IconButton(
              onPressed: onCancel,
              icon: const Icon(Icons.cancel_outlined, size: 22),
              tooltip: l10n.cancelReply,
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
            ),
            const SizedBox(width: 4),
          ],
        ),
      ),
    );
  }
}

/// Shown instead of the message while it is being corrected.
class EditComposer extends StatefulWidget {
  const EditComposer({
    super.key,
    required this.initialText,
    required this.onSubmit,
    required this.onCancel,
  });

  final String initialText;
  final Future<void> Function(String body) onSubmit;
  final VoidCallback onCancel;

  @override
  State<EditComposer> createState() => _EditComposerState();
}

class _EditComposerState extends State<EditComposer> {
  late final _controller = TextEditingController(text: widget.initialText);
  final _focus = FocusNode();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // Select-all, so the common case — fixing a typo — is a straight
    // overwrite rather than a dance with the cursor.
    _controller.selection = TextSelection(
      baseOffset: 0,
      extentOffset: widget.initialText.length,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _busy) return;
    setState(() => _busy = true);
    try {
      await widget.onSubmit(text);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  controller: _controller,
                  focusNode: _focus,
                  minLines: 1,
                  maxLines: 6,
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: l10n.editMessageHint,
                    border: const OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _submit(),
                ),
              ),
              const SizedBox(width: 4),
              IconButton(
                onPressed: _busy ? null : widget.onCancel,
                icon: const Icon(Icons.close),
                tooltip: l10n.cancel,
              ),
              IconButton(
                onPressed: _busy ? null : _submit,
                icon: const Icon(Icons.check),
                tooltip: l10n.save,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The plain-text notice shown above an unencrypted conversation.
///
/// Persistent rather than a one-time banner, because the condition does not
/// change while the user reads it: a message sent now is readable by whoever
/// stores it, and no later event makes that untrue.
class PlaintextNotice extends StatelessWidget {
  const PlaintextNotice({super.key, required this.visible});

  final bool visible;

  @override
  Widget build(BuildContext context) {
    if (!visible) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Row(
          children: [
            Icon(
              Icons.lock_open,
              size: 14,
              color: theme.colorScheme.onErrorContainer,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                context.l10n.messagesNotEncrypted,
                style: TextStyle(
                  fontSize: 12,
                  color: theme.colorScheme.onErrorContainer,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The track of a stored message, for callers that only need the enum.
Track storedTrack(String encMode) =>
    EncModeToken.parse(encMode).track ?? Track.none;
