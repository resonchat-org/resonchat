// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
// Composer bar: attach, text, send, or hold-to-talk mic (Telegram enter view).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import '../../platform/linux_cli_types.dart';
import '../../platform/voice_recorder.dart';
import '../theme.dart';

/// Bottom input bar: attach, text field, send — or hold-to-talk mic when empty
/// (Telegram `ChatActivityEnterView`, docs/05 §4.2).
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

class _ChatInputBarState extends State<ChatInputBar> {
  final _recorder = VoiceRecorder();
  var _recording = false;
  var _cancelArmed = false;
  var _starting = false;

  /// Finger still down — used to discard if permission/start outlasts press.
  var _pointerHeld = false;
  Offset? _pointerOrigin;
  Duration _elapsed = Duration.zero;
  Timer? _tick;

  /// Telegram slide-to-cancel threshold (~dp 80).
  static const _cancelDx = -64.0;

  @override
  void dispose() {
    _tick?.cancel();
    unawaited(_recorder.dispose());
    super.dispose();
  }

  void _startTick() {
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (!mounted || !_recording) return;
      setState(() => _elapsed = _recorder.elapsed);
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
    try {
      final ok = await _recorder.ensurePermission();
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
      await _recorder.start();
      if (!mounted || !_pointerHeld) {
        await _recorder.stop(send: false);
        return;
      }
      HapticFeedback.lightImpact();
      setState(() {
        _recording = true;
        _cancelArmed = false;
        _elapsed = Duration.zero;
      });
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
    if (!_recording && !_recorder.isRecording) {
      _pointerOrigin = null;
      return;
    }
    _tick?.cancel();
    final clip = await _recorder.stop(send: send);
    if (!mounted) return;
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
    final armed = dx <= _cancelDx;
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

  @override
  Widget build(BuildContext context) {
    final tg = context.tg;
    final l10n = context.l10n;
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: widget.controller,
      builder: (context, value, _) {
        final empty = value.text.trim().isEmpty;
        return Container(
          decoration: BoxDecoration(
            color: tg.pageBackground,
            border: Border(top: BorderSide(color: tg.separator)),
          ),
          padding: const EdgeInsets.fromLTRB(4, 6, 4, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (!_recording)
                IconButton(
                  icon: const Icon(Icons.attach_file),
                  color: widget.attachEnabled
                      ? tg.textPrimary
                      : tg.textSecondary,
                  disabledColor: tg.textSecondary,
                  tooltip: widget.attachEnabled
                      ? l10n.attachFile
                      : l10n.httpUploadUnavailable,
                  onPressed: widget.attachEnabled ? widget.onAttach : null,
                )
              else
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 12,
                  ),
                  child: Icon(
                    Icons.mic,
                    size: 22,
                    color: _cancelArmed ? tg.danger : tg.accent,
                  ),
                ),
              Expanded(
                child: _recording
                    ? Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 10,
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                color: _cancelArmed
                                    ? tg.danger
                                    : const Color(0xFFE53935),
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              _formatElapsed(_elapsed),
                              style: TextStyle(
                                fontSize: 15,
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                                color: tg.textPrimary,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                _cancelArmed
                                    ? l10n.releaseToCancel
                                    : l10n.slideToCancel,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: _cancelArmed
                                      ? tg.danger
                                      : tg.textSecondary,
                                  fontSize: 14,
                                ),
                              ),
                            ),
                          ],
                        ),
                      )
                    : ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 120),
                        child: TextField(
                          controller: widget.controller,
                          focusNode: widget.focusNode,
                          minLines: 1,
                          maxLines: 5,
                          textInputAction: TextInputAction.newline,
                          onChanged: widget.onChanged,
                          style: TextStyle(
                            fontSize: TgDimens.messageFontSize,
                            color: tg.textPrimary,
                          ),
                          decoration: InputDecoration(
                            isDense: true,
                            filled: true,
                            fillColor: tg.pageBackground,
                            hintText: l10n.messageComposerHint,
                            hintStyle: TextStyle(color: tg.textSecondary),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 10,
                            ),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(18),
                              borderSide: BorderSide(color: tg.separator),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(18),
                              borderSide: BorderSide(color: tg.separator),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(18),
                              borderSide: BorderSide(color: tg.accent),
                            ),
                          ),
                        ),
                      ),
              ),
              if (!_recording)
                IconButton(
                  tooltip: l10n.stickers,
                  icon: Icon(
                    widget.stickersOpen
                        ? Icons.emoji_emotions
                        : Icons.emoji_emotions_outlined,
                  ),
                  color: widget.stickersOpen ? tg.accent : tg.textPrimary,
                  onPressed: widget.onStickers,
                ),
              if (empty || _recording)
                Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: _onMicPointerDown,
                  onPointerMove: _onMicPointerMove,
                  onPointerUp: _onMicPointerUp,
                  onPointerCancel: _onMicPointerCancel,
                  child: Tooltip(
                    message: l10n.holdToRecord,
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Icon(
                        _cancelArmed ? Icons.delete_outline : Icons.mic,
                        color: _cancelArmed ? tg.danger : tg.accent,
                        size: 28,
                      ),
                    ),
                  ),
                )
              else
                IconButton(
                  icon: const Icon(Icons.send),
                  color: tg.accent,
                  onPressed: widget.onSend,
                ),
            ],
          ),
        );
      },
    );
  }
}
