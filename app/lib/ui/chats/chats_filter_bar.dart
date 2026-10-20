// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Chats-list filter strip under the search field: account drawer trigger +
// Messages / Unread segments. Filters only change what the list shows.

import 'package:flutter/material.dart';

import 'package:resonchat/account/account_color.dart';
import 'package:resonchat/l10n/l10n.dart';
import 'package:resonchat/persistence/account_store.dart';
import 'package:resonchat/ui/theme.dart';

/// Which conversations the chats list should show.
enum ChatsListScope {
  /// Every non-archived conversation (default).
  messages,

  /// Only rows with unreadCount or unreadMentions > 0.
  unread,
}

/// Search-bar companion: hamburger (account drawer) + Messages / Unread chips.
class ChatsFilterBar extends StatelessWidget {
  const ChatsFilterBar({
    super.key,
    required this.scope,
    required this.onScopeChanged,
    required this.onOpenAccounts,
  });

  final ChatsListScope scope;
  final ValueChanged<ChatsListScope> onScopeChanged;
  final VoidCallback onOpenAccounts;

  static const double _height = 32;

  @override
  Widget build(BuildContext context) {
    final tg = context.tg;
    final l10n = context.l10n;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // Shared chrome with the segment group: greyer track, whiter selected.
    final track = isDark
        ? tg.separator.withValues(alpha: 0.85)
        : const Color(0xFFE8EBEE);
    final selectedFill = isDark ? const Color(0xFF2A3A4A) : tg.pageBackground;
    final selectedFg = tg.textPrimary;
    final idleFg = tg.textSecondary;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        TgDimens.chatsHorizontalPadding,
        0,
        TgDimens.chatsHorizontalPadding,
        8,
      ),
      child: Row(
        children: [
          AccountFilterCircleButton(
            size: _height,
            color: track,
            iconColor: idleFg,
            tooltip: l10n.filterAccounts,
            onPressed: onOpenAccounts,
          ),
          const SizedBox(width: 8),
          _SlidingScopeControl(
            height: _height,
            track: track,
            selectedFill: selectedFill,
            selectedFg: selectedFg,
            idleFg: idleFg,
            scope: scope,
            messagesLabel: l10n.filterMessages,
            unreadLabel: l10n.filterUnread,
            onScopeChanged: onScopeChanged,
          ),
        ],
      ),
    );
  }
}

/// Account picker panel (display filter only). Hosted by [ChatsPage] so it
/// slides from the chats content’s start edge — in landscape that is the
/// right side of the [NavigationRail], not the screen’s left edge.
class ChatsAccountDrawer extends StatelessWidget {
  const ChatsAccountDrawer({
    super.key,
    required this.accounts,
    required this.selectedAccountId,
    required this.onSelected,
  });

  final List<StoredAccount> accounts;
  final String? selectedAccountId;

  /// Called with the chosen account id (null = all). Caller closes the panel.
  final ValueChanged<String?> onSelected;

  static const double width = 280;

  @override
  Widget build(BuildContext context) {
    final tg = context.tg;
    final l10n = context.l10n;
    // Show disabled accounts too — filtering them out made the drawer look
    // empty after the only account was turned off (and clear-cache cannot
    // re-enable Secure Storage rows).
    return Material(
      color: tg.pageBackground,
      elevation: 8,
      child: SafeArea(
        child: SizedBox(
          width: width,
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Text(
                  l10n.filterAccounts,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: tg.textPrimary,
                  ),
                ),
              ),
              _AccountTile(
                title: l10n.filterAllAccounts,
                subtitle: null,
                accent: tg.accent,
                selected: selectedAccountId == null,
                onTap: () => onSelected(null),
              ),
              for (final a in accounts)
                _AccountTile(
                  title: a.label,
                  subtitle: a.enabled
                      ? a.bareJid
                      : '${a.bareJid}\n${l10n.accountDisabled}',
                  accent: a.enabled
                      ? accountAccent(a.bareJid)
                      : tg.textSecondary,
                  selected: selectedAccountId == a.id,
                  onTap: a.enabled ? () => onSelected(a.id) : null,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Round hit target + ink (not the bounding square’s corners).
class AccountFilterCircleButton extends StatelessWidget {
  const AccountFilterCircleButton({
    super.key,
    required this.size,
    required this.color,
    required this.iconColor,
    required this.onPressed,
    this.tooltip,
  });

  final double size;
  final Color color;
  final Color iconColor;
  final VoidCallback onPressed;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    // ClipOval so hover/splash hit-tests follow the circle, not the square
    // bounding box (Material clip alone still lets corners receive pointer).
    final tip = tooltip ?? context.l10n.filterAccounts;
    return Tooltip(
      message: tip,
      child: ClipOval(
        child: Material(
          color: color,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onPressed,
            child: SizedBox(
              width: size,
              height: size,
              child: Icon(Icons.menu, size: 20, color: iconColor),
            ),
          ),
        ),
      ),
    );
  }
}

/// Messages / Unread with a sliding thumb (Material segmented style).
class _SlidingScopeControl extends StatefulWidget {
  const _SlidingScopeControl({
    required this.height,
    required this.track,
    required this.selectedFill,
    required this.selectedFg,
    required this.idleFg,
    required this.scope,
    required this.messagesLabel,
    required this.unreadLabel,
    required this.onScopeChanged,
  });

  final double height;
  final Color track;
  final Color selectedFill;
  final Color selectedFg;
  final Color idleFg;
  final ChatsListScope scope;
  final String messagesLabel;
  final String unreadLabel;
  final ValueChanged<ChatsListScope> onScopeChanged;

  @override
  State<_SlidingScopeControl> createState() => _SlidingScopeControlState();
}

class _SlidingScopeControlState extends State<_SlidingScopeControl> {
  final _keys = <GlobalKey>[GlobalKey(), GlobalKey()];
  List<double>? _widths;

  static const _pad = 2.0;
  static const _slide = Duration(milliseconds: 220);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(_measure);
  }

  @override
  void didUpdateWidget(covariant _SlidingScopeControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.messagesLabel != widget.messagesLabel ||
        oldWidget.unreadLabel != widget.unreadLabel) {
      WidgetsBinding.instance.addPostFrameCallback(_measure);
    }
  }

  void _measure(Duration _) {
    if (!mounted) return;
    final next = <double>[];
    for (final key in _keys) {
      final box = key.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) return;
      next.add(box.size.width);
    }
    if (_widths == null ||
        _widths!.length != next.length ||
        !_listEq(_widths!, next)) {
      setState(() => _widths = next);
    }
  }

  static bool _listEq(List<double> a, List<double> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if ((a[i] - b[i]).abs() > 0.5) return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final index = widget.scope == ChatsListScope.messages ? 0 : 1;
    final widths = _widths;
    final radius = widget.height / 2;

    // Inset the thumb inside the selected chip so the grey track shows as a
    // 2px gutter around the sliding pill.
    var thumbLeft = _pad;
    var thumbWidth = 0.0;
    if (widths != null) {
      for (var i = 0; i < index; i++) {
        thumbLeft += widths[i];
      }
      thumbWidth = (widths[index] - 2 * _pad).clamp(0.0, widths[index]);
    }

    // ClipRRect clips hit tests to the stadium — track corners that are only
    // in the bounding square do not hover.
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Material(
        color: widget.track,
        child: SizedBox(
          height: widget.height,
          child: Stack(
            children: [
              if (widths != null)
                AnimatedPositioned(
                  duration: _slide,
                  curve: Curves.easeOutCubic,
                  left: thumbLeft,
                  top: _pad,
                  bottom: _pad,
                  width: thumbWidth,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: widget.selectedFill,
                      borderRadius: BorderRadius.circular(radius - _pad),
                    ),
                  ),
                ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _ScopeHit(
                    key: _keys[0],
                    label: widget.messagesLabel,
                    selected: index == 0,
                    selectedFg: widget.selectedFg,
                    idleFg: widget.idleFg,
                    height: widget.height,
                    onTap: () => widget.onScopeChanged(ChatsListScope.messages),
                  ),
                  _ScopeHit(
                    key: _keys[1],
                    label: widget.unreadLabel,
                    selected: index == 1,
                    selectedFg: widget.selectedFg,
                    idleFg: widget.idleFg,
                    height: widget.height,
                    onTap: () => widget.onScopeChanged(ChatsListScope.unread),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Stadium-shaped ink only — corners of the track outside the chip do not
/// receive hover/splash from a rectangular Material.
class _ScopeHit extends StatelessWidget {
  const _ScopeHit({
    super.key,
    required this.label,
    required this.selected,
    required this.selectedFg,
    required this.idleFg,
    required this.height,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final Color selectedFg;
  final Color idleFg;
  final double height;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(height / 2),
    );
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        customBorder: shape,
        onTap: onTap,
        child: SizedBox(
          height: height,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Center(
              child: AnimatedDefaultTextStyle(
                duration: _SlidingScopeControlState._slide,
                curve: Curves.easeOutCubic,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: selected ? selectedFg : idleFg,
                ),
                child: Text(label),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AccountTile extends StatelessWidget {
  const _AccountTile({
    required this.title,
    required this.subtitle,
    required this.accent,
    required this.selected,
    this.onTap,
  });

  final String title;
  final String? subtitle;
  final Color accent;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final tg = context.tg;
    return ListTile(
      enabled: onTap != null,
      leading: CircleAvatar(
        radius: 16,
        backgroundColor: accent.withValues(alpha: 0.2),
        child: Icon(
          selected ? Icons.check : Icons.person_outline,
          size: 18,
          color: accent,
        ),
      ),
      title: Text(
        title,
        style: TextStyle(
          fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
          color: tg.textPrimary,
        ),
      ),
      subtitle: subtitle == null
          ? null
          : Text(subtitle!, style: TextStyle(color: tg.textSecondary)),
      selected: selected,
      selectedTileColor: tg.accent.withValues(alpha: 0.08),
      onTap: onTap,
    );
  }
}
