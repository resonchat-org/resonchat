// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Composer bar, translated from Telegram for Android's
// `ChatActivityEnterView` (GPL-2.0-or-later); see docs/05 §3.1.
//
// The bar is Telegram's floating "input island" — a 22dp rounded card that
// sits 7dp in from the screen edges and 9dp above the system inset, filled
// with the message-panel colour over a blur of the transcript behind it. The
// card itself is *not* drawn by `ChatActivityEnterView` (that only fills the
// content rect): it is the wrapper `ChatInputViewsContainer`
// (`INPUT_BUBBLE_RADIUS = 22`, `INPUT_BUBBLE_BOTTOM = 9`, `:27`-`:30`), fed a
// `BlurredBackgroundDrawable` with `setPadding(dp(7))`/`setRadius(dp(22))`
// (`:79`-`:88`) and put on screen with 7dp of side margin
// (`ChatActivity.java:8431`, `:4935`). Inside that card the layout is read off
// the enter view item by item:
//
//   * bar and every icon slot are `DEFAULT_HEIGHT` = 44dp with 1dp of top
//     padding (`ChatActivityEnterView.java:6551`, `:2663`);
//   * left: the smiley (`emojiButton`, 44dp, `dp(7.5)` padding → 29dp glyph,
//     `:2723`, `:2760`) on its own rounded tile — the reference gives it a
//     `key_listSelector` fill 1dp in horizontally and 3dp vertically with a
//     19dp radius, i.e. a 42×38 tile, which is the light square behind the
//     smiley in the current design (`:2760`); it becomes a keyboard glyph
//     while the sticker panel is open (`setEmojiButtonImage`, `:13158`);
//   * middle: the message, 18dp, `dp(9)`/`dp(10)` padding, six lines max,
//     starting 8dp after the smiley slot and ending 6dp before the paperclip
//     slot — `createFrame(MATCH_PARENT, WRAP_CONTENT, BOTTOM, 52, 0, 50, 1.5)`
//     with the paperclip slot ending 44dp short of the bar, `:5901`, `:2707`;
//   * then the paperclip (`attachButton`, 44dp, `:2845`);
//   * far right: the reference keeps its own control in the 44dp column — the
//     mic while the field is empty and the paper plane once it has text, which
//     is a 38dp `chat_messagePanelSend` circle inset 3dp (`:3230`-`:3258`,
//     `:10609`). Stock Telegram's empty state shows the chat's menu button as
//     a ⋮ there instead, and that is the picture we are matching: with no text
//     the slot is a plain ⋮ (no circle), with text it is the send circle;
//   * the card is rounded and holds no divider line — the separation from the
//     transcript comes from the blur and the card's own shadow
//     (`ChatInputViewsContainer.java:79`-`:88`);
//   * hold-to-talk: press the right slot (hold), slide left to arm cancel,
//     with a blinking 10dp `chat_recordedVoiceDot` dot, a 15dp medium
//     `chat_recordTime` timer and a centred "slide to cancel" hint
//     (`:1074`-`:1107`, `:14304`-`:14313`, `:9940`-`:9961`). For the travel we
//     deliberately deviate: the reference's `distCanMove` is
//     min(35% of the width, 140dp) (`:731`, `:3188`), ~126dp on a phone, which
//     reads sluggish, so [cancelSlide] is a fixed 64dp.
//
// Branding stays ours (docs/05 §6): the accent is the app theme's, not
// stock Telegram blue, and the glyphs are Material icons.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import '../../platform/linux_cli_types.dart';
import '../../platform/voice_recorder.dart';
import '../theme.dart';
import 'glass_panel.dart';

/// Metrics read off the reference (`ChatActivityEnterView.java`).
class _EnterView {
  const _EnterView._();

  /// `DEFAULT_HEIGHT` — the bar and every icon slot.
  static const double height = 44;

  /// The floating card: 22dp corners, 7dp of side margin and 9dp under it
  /// (`ChatInputViewsContainer.java:27`-`:30`, `ChatActivity.java:8431`).
  static const double islandRadius = 22;
  static const double islandMargin = 7;
  static const double islandBottom = 9;

  /// Blur of the transcript behind the card lives in [kGlassSigma]: Material
  /// blurs the backdrop once per [BackdropGroup] and shares the snapshot, so
  /// the header cards and this island cost one blur between them, not four.

  /// The smiley's tile: `createInsetRoundRectDrawable(key_listSelector,
  /// dp(19), dp(1), dp(3))` — 1dp off the sides and 3dp off the top and
  /// bottom of the 44dp slot (`ChatActivityEnterView.java:2760`).
  static const double emojiTileWidth = 42;
  static const double emojiTileHeight = 38;
  static const double emojiTileRadius = 19;

  /// `emojiButton` is 44dp with `dp(7.5)` of padding, so its glyph is 29dp.
  static const double emojiGlyph = 29;

  /// `msg_input_attach2` / `input_mic` / `send_plane_24` are 24dp glyphs.
  static const double glyph = 24;

  /// Message text: 18dp with `dp(9)`/`dp(10)` of padding (`:5890`-`:5892`).
  static const double fontSize = 18;
  static const double textPadTop = 9;
  static const double textPadBottom = 10;
  static const int maxLines = 6;

  /// Text inset inside its slot: `52 - 44` on the left of the field and
  /// `94 - 88` on the right of it, per the margins above.
  static const double textPadLeft = 8;
  static const double textPadRight = 6;

  /// The right slot: a 38dp circle inset 3dp in a 44dp column.
  static const double buttonCircle = 38;

  /// The drag that arms "release to cancel". The reference computes
  /// `distCanMove` as min(35% of the width, 140dp) — ~126dp of travel on a
  /// phone, which reads as sluggish next to the rest of the gesture; we keep
  /// a fixed, shorter pull on purpose.
  static const double cancelSlide = 64;

  /// Recording row: 10dp dot (`RecordDot`, `dp(5)` radius) ramping 0→1 over
  /// 600ms, a 28dp slot for it, and 15dp text.
  static const double recordDotSize = 10;
  static const double recordDotSlot = 28;
  static const double recordFontSize = 15;
  static const double recordLeftPad = 13;
  static const Duration dotBlink = Duration(milliseconds: 600);
}

/// Bottom input bar: smiley, text, paperclip, and send-or-mic — or the
/// recording row while the mic is held (Telegram `ChatActivityEnterView`,
/// docs/05 §4.2).
class ChatInputBar extends StatefulWidget {
  const ChatInputBar({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.onChanged,
    required this.onSend,
    required this.onAttach,
    required this.onVoice,
    required this.onStickers,
    required this.stickersOpen,
    required this.attachEnabled,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;
  final VoidCallback onSend;
  final VoidCallback onAttach;
  final Future<void> Function(VoiceClip clip) onVoice;

  /// Opens or closes the sticker panel under the composer.
  final VoidCallback onStickers;

  final bool stickersOpen;

  /// False when the server has no XEP-0363 — attach/mic stay muted.
  final bool attachEnabled;

  @override
  State<ChatInputBar> createState() => _ChatInputBarState();
}

class _ChatInputBarState extends State<ChatInputBar>
    with SingleTickerProviderStateMixin {
  /// Created on the first recording attempt: constructing [VoiceRecorder]
  /// opens a platform channel (the `record` plugin), which a chat screen that
  /// never records should not pay for.
  VoiceRecorder? _recorder;
  var _recording = false;
  var _cancelArmed = false;
  var _starting = false;

  /// Finger still down — used to discard if permission/start outlasts press.
  var _pointerHeld = false;
  Offset? _pointerOrigin;
  Duration _elapsed = Duration.zero;
  Timer? _tick;

  /// `RecordDot` blink: 600ms each way, and only while recording.
  late final AnimationController _dotBlink = AnimationController(
    vsync: this,
    duration: _EnterView.dotBlink,
    value: 1,
  );

  @override
  void dispose() {
    _tick?.cancel();
    _dotBlink.dispose();
    final recorder = _recorder;
    if (recorder != null) unawaited(recorder.dispose());
    super.dispose();
  }

  void _startTick() {
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (!mounted || !_recording) return;
      setState(() => _elapsed = _recorder!.elapsed);
    });
  }

  Future<void> _beginRecord() async {
    if (_recording || _starting) return;
    final l10n = context.l10n;
    if (!widget.attachEnabled) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(l10n.httpUploadUnavailable)));
      return;
    }
    if (!VoiceRecorder.isSupported) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(l10n.voiceNotSupported)));
      return;
    }
    _starting = true;
    final recorder = _recorder ??= VoiceRecorder();
    try {
      final ok = await recorder.ensurePermission();
      if (!mounted || !_pointerHeld) return;
      if (!ok) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(l10n.voicePermissionDenied)));
        return;
      }
      final probe = await VoiceRecorder.probeSystemMicMute();
      if (!mounted || !_pointerHeld) return;
      if (probe.missingCli.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.linuxCliMissing(probe.missingCli.join(', '))),
          ),
        );
      }
      if (probe.muted == true) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(l10n.voiceMicMuted)));
        return;
      }
      await recorder.start();
      if (!mounted || !_pointerHeld) {
        await recorder.stop(send: false);
        return;
      }
      HapticFeedback.lightImpact();
      setState(() {
        _recording = true;
        _cancelArmed = false;
        _elapsed = Duration.zero;
      });
      _dotBlink.repeat(reverse: true);
      _startTick();
    } on MissingLinuxCli catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.linuxCliMissing(e.toolsJoined))),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(l10n.uploadFailed('$e'))));
      }
    } finally {
      _starting = false;
    }
  }

  Future<void> _endRecord({required bool send}) async {
    _pointerHeld = false;
    final recorder = _recorder;
    if (recorder == null || (!_recording && !recorder.isRecording)) {
      _pointerOrigin = null;
      return;
    }
    _tick?.cancel();
    final clip = await recorder.stop(send: send);
    if (!mounted) return;
    _dotBlink
      ..stop()
      ..value = 1;
    setState(() {
      _recording = false;
      _cancelArmed = false;
      _pointerOrigin = null;
      _elapsed = Duration.zero;
    });
    if (!send) return;
    if (clip == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(context.l10n.voiceTooShort)));
      return;
    }
    HapticFeedback.selectionClick();
    await widget.onVoice(clip);
  }

  void _onMicPointerDown(PointerDownEvent e) {
    _pointerHeld = true;
    _pointerOrigin = e.position;
    unawaited(_beginRecord());
  }

  void _onMicPointerMove(PointerMoveEvent e) {
    if (!_recording || _pointerOrigin == null) return;
    final dx = e.position.dx - _pointerOrigin!.dx;
    final armed = dx <= -_EnterView.cancelSlide;
    if (armed != _cancelArmed) {
      setState(() => _cancelArmed = armed);
      if (armed) HapticFeedback.selectionClick();
    }
  }

  void _onMicPointerUp(PointerUpEvent e) {
    unawaited(_endRecord(send: !_cancelArmed));
  }

  void _onMicPointerCancel(PointerCancelEvent e) {
    unawaited(_endRecord(send: false));
  }

  String _formatElapsed(Duration d) {
    final total = d.inSeconds;
    final m = (total ~/ 60).toString().padLeft(2, '0');
    final s = (total % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  /// Composer glyphs are `glass_defaultIcon` (`0x991B2227` in the day theme):
  /// the primary ink at 60%, which is what keeps the bar reading as chrome
  /// rather than as content.
  Color _glyphColor(TgColors tg) => tg.textPrimary.withValues(alpha: 0.6);

  @override
  Widget build(BuildContext context) {
    final tg = context.tg;
    final l10n = context.l10n;
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: widget.controller,
      builder: (context, value, _) {
        final hasText = value.text.trim().isNotEmpty;
        return Padding(
          // The island: 7dp in from the sides, 9dp above the system inset.
          padding: const EdgeInsets.fromLTRB(
            _EnterView.islandMargin,
            0,
            _EnterView.islandMargin,
            _EnterView.islandBottom,
          ),
          child: GlassPanel(
            radius: _EnterView.islandRadius,
            // The message-panel colour, dropped just short of opaque so the
            // blurred transcript behind it still reads through.
            fill: tg.pageBackground.withValues(alpha: 0.86),
            // Transparent so ink features still paint above the glass.
            child: Material(
              type: MaterialType.transparency,
              child: Padding(
                // `textFieldContainer.setPadding(0, dp(1), 0, 0)`.
                padding: const EdgeInsets.only(top: 1),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    if (!_recording)
                      _glyphButton(
                        tg,
                        icon: widget.stickersOpen
                            ? Icons.keyboard_outlined
                            : Icons.emoji_emotions_outlined,
                        size: _EnterView.emojiGlyph,
                        tooltip: l10n.stickers,
                        onTap: widget.onStickers,
                        tile: true,
                      ),
                    Expanded(
                      child: _recording
                          ? _recordStatus(tg, l10n)
                          : _field(tg, l10n),
                    ),
                    if (!_recording)
                      _glyphButton(
                        tg,
                        icon: Icons.attach_file,
                        tooltip: widget.attachEnabled
                            ? l10n.attachFile
                            : l10n.httpUploadUnavailable,
                        onTap: widget.attachEnabled ? widget.onAttach : null,
                      ),
                    if (!_recording && hasText)
                      _circleButton(
                        tg,
                        fill: tg.accent,
                        onTap: widget.onSend,
                        semanticLabel: l10n.sendMessage,
                        icon: const Icon(
                          Icons.send,
                          size: _EnterView.glyph,
                          color: Colors.white,
                        ),
                      )
                    else
                      _endSlot(tg, l10n),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// Rippled 44dp icon slot (`emojiButton` / `attachButton`). [tile] adds the
  /// smiley's rounded `key_listSelector` background, which is what makes it
  /// read as a button rather than a bare glyph.
  Widget _glyphButton(
    TgColors tg, {
    required IconData icon,
    required String tooltip,
    required VoidCallback? onTap,
    double size = _EnterView.glyph,
    bool tile = false,
  }) {
    final glyph = Icon(
      icon,
      size: size,
      color: onTap == null
          ? tg.textSecondary.withValues(alpha: 0.5)
          : _glyphColor(tg),
    );
    return SizedBox(
      width: _EnterView.height,
      height: _EnterView.height,
      child: Tooltip(
        message: tooltip,
        child: InkResponse(
          onTap: onTap,
          radius: 20,
          child: Center(
            child: tile
                ? Container(
                    width: _EnterView.emojiTileWidth,
                    height: _EnterView.emojiTileHeight,
                    decoration: BoxDecoration(
                      // `key_listSelector`: the primary ink at 6%.
                      color: tg.textPrimary.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(
                        _EnterView.emojiTileRadius,
                      ),
                    ),
                    child: Center(child: glyph),
                  )
                : glyph,
          ),
        ),
      ),
    );
  }

  Widget _field(TgColors tg, AppLocalizations l10n) {
    return TextField(
      controller: widget.controller,
      focusNode: widget.focusNode,
      minLines: 1,
      maxLines: _EnterView.maxLines,
      keyboardType: TextInputType.multiline,
      textInputAction: TextInputAction.newline,
      onChanged: widget.onChanged,
      cursorColor: tg.accent,
      cursorWidth: 2,
      cursorRadius: const Radius.circular(1),
      style: TextStyle(fontSize: _EnterView.fontSize, color: tg.textPrimary),
      decoration: InputDecoration(
        isDense: true,
        border: InputBorder.none,
        hintText: l10n.messageComposerHint,
        hintStyle: TextStyle(
          fontSize: _EnterView.fontSize,
          color: tg.textSecondary,
        ),
        contentPadding: const EdgeInsets.fromLTRB(
          _EnterView.textPadLeft,
          _EnterView.textPadTop,
          _EnterView.textPadRight,
          _EnterView.textPadBottom,
        ),
      ),
    );
  }

  /// `recordPanel`: the timer on the left, the hint centred over it.
  Widget _recordStatus(TgColors tg, AppLocalizations l10n) {
    final timer = TextStyle(
      fontSize: _EnterView.recordFontSize,
      fontWeight: FontWeight.w500,
      fontFeatures: const [FontFeature.tabularFigures()],
      color: tg.textSecondary,
    );
    return SizedBox(
      height: _EnterView.height,
      child: Stack(
        children: [
          Positioned.fill(
            child: Padding(
              padding: const EdgeInsets.only(left: _EnterView.recordLeftPad),
              child: Row(
                children: [
                  SizedBox(
                    width: _EnterView.recordDotSlot,
                    height: _EnterView.recordDotSlot,
                    child: Center(
                      child: FadeTransition(
                        opacity: _dotBlink,
                        child: Container(
                          width: _EnterView.recordDotSize,
                          height: _EnterView.recordDotSize,
                          decoration: BoxDecoration(
                            color: tg.danger,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(_formatElapsed(_elapsed), style: timer),
                ],
              ),
            ),
          ),
          // `slideText` is centred from 45dp rightwards; sliding turns it into
          // the blue "release to cancel".
          Positioned.fill(
            child: Padding(
              padding: const EdgeInsets.only(
                left: _EnterView.height + 1,
                right: 4,
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.chevron_left,
                    size: 20,
                    color: _cancelArmed ? tg.accent : tg.textSecondary,
                  ),
                  Flexible(
                    child: Text(
                      _cancelArmed ? l10n.releaseToCancel : l10n.slideToCancel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: _EnterView.recordFontSize,
                        fontWeight: _cancelArmed
                            ? FontWeight.w500
                            : FontWeight.w400,
                        color: _cancelArmed ? tg.accent : tg.textSecondary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Send button: the reference's 38dp `chat_messagePanelSend` circle.
  Widget _circleButton(
    TgColors tg, {
    required Color fill,
    required Widget icon,
    required VoidCallback onTap,
    required String semanticLabel,
  }) {
    return SizedBox(
      width: _EnterView.height,
      height: _EnterView.height,
      child: Center(
        child: SizedBox(
          width: _EnterView.buttonCircle,
          height: _EnterView.buttonCircle,
          child: Material(
            color: fill,
            shape: const CircleBorder(),
            child: Semantics(
              button: true,
              label: semanticLabel,
              child: InkWell(
                onTap: onTap,
                customBorder: const CircleBorder(),
                splashColor: Colors.white24,
                highlightColor: Colors.white10,
                child: Center(child: icon),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The rightmost slot while the field is empty: hold to record. Once cancel
  /// is armed it becomes the delete glyph. Without an upload slot it greys
  /// out, which is what happens when voice messages are unavailable.
  Widget _endSlot(TgColors tg, AppLocalizations l10n) {
    final enabled = widget.attachEnabled;
    return SizedBox(
      width: _EnterView.height,
      height: _EnterView.height,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: _onMicPointerDown,
        onPointerMove: _onMicPointerMove,
        onPointerUp: _onMicPointerUp,
        onPointerCancel: _onMicPointerCancel,
        child: Semantics(
          button: true,
          label: l10n.holdToRecord,
          child: Center(
            child: Icon(
              _recording && _cancelArmed ? Icons.delete_outline : Icons.mic,
              size: _EnterView.glyph,
              color: enabled
                  ? _glyphColor(tg)
                  : tg.textSecondary.withValues(alpha: 0.5),
            ),
          ),
        ),
      ),
    );
  }
}
