// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// AppBar "accounts" action — SVG asset tinted like Android VectorDrawable.

import 'package:flutter/material.dart';

import 'package:flutter_svg/flutter_svg.dart';

/// Manage-accounts glyph from [assets/icons/ic_accounts.svg].
///
/// Prefer a single-color silhouette SVG; [color] tints it via [BlendMode.srcIn].
class AccountsIcon extends StatelessWidget {
  const AccountsIcon({super.key, this.color = Colors.white, this.size = 24});

  final Color color;
  final double size;

  static const assetPath = 'assets/icons/ic_accounts.svg';

  @override
  Widget build(BuildContext context) {
    return SvgPicture.asset(
      assetPath,
      width: size,
      height: size,
      colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
    );
  }
}
