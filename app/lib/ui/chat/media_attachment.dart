// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// File / image attachment inside a chat bubble (HTTP File Upload download).

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mime/mime.dart';
import 'package:open_filex/open_filex.dart';

import 'package:resonchat/account/account_hub.dart';
import 'package:resonchat/account/resolve.dart';
import 'package:resonchat/l10n/l10n.dart';
import 'package:resonchat/persistence/database.dart';
import 'package:resonchat/persistence/media_store.dart';
import 'package:resonchat/platform/linux_cli_io.dart'
    if (dart.library.js_interop) 'package:resonchat/platform/linux_cli_stub.dart';
import 'package:resonchat/platform/linux_cli_types.dart';
import 'package:resonchat/ui/chat/upload_progress.dart';
import 'package:resonchat/ui/theme.dart';
import 'package:resonchat/xmpp/media/file_preview.dart';
import 'package:resonchat/xmpp/media/http_files.dart';

bool isImageMime(String mime, String pathOrName) {
  if (mime.toLowerCase().startsWith('image/')) return true;
  final guessed = lookupMimeType(pathOrName) ?? '';
  return guessed.toLowerCase().startsWith('image/');
}

bool isAudioMime(String mime, String pathOrName) {
  if (mime.toLowerCase().startsWith('audio/')) return true;
  final guessed = lookupMimeType(pathOrName) ?? '';
  return guessed.toLowerCase().startsWith('audio/');
}

/// Renders a downloaded image or a download affordance for a file message.
class MediaAttachment extends ConsumerStatefulWidget {
  const MediaAttachment({super.key, required this.message, this.chatKey});

  final Message message;

  /// [ChatRef.key] when known; otherwise primary session is used.
  final String? chatKey;

  @override
  ConsumerState<MediaAttachment> createState() => _MediaAttachmentState();
}

class _MediaAttachmentState extends ConsumerState<MediaAttachment> {
  bool _busy = false;
  bool _tooBig = false;
  String? _error;
  Uint8List? _imageBytes;

  Message get m => widget.message;

  bool get _hasLocal => mediaStore.existsSync(m.localPath);

  @override
  void initState() {
    super.initState();
    unawaited(_loadImageBytes());
    unawaited(_maybeAutoDownload());
  }

  @override
  void didUpdateWidget(covariant MediaAttachment oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.message.localPath != m.localPath) {
      unawaited(_loadImageBytes());
    }
  }

  Future<void> _loadImageBytes() async {
    if (!_hasLocal) {
      if (_imageBytes != null) setState(() => _imageBytes = null);
      return;
    }
    if (!isImageMime(m.mediaMime, m.localPath)) return;
    final bytes = await mediaStore.readBytes(m.localPath);
    if (!mounted) return;
    setState(() => _imageBytes = bytes);
  }

  Future<void> _maybeAutoDownload() async {
    if (_hasLocal || m.mediaUrl.isEmpty) return;
    final maxBytes = await loadPreviewMaxFileSize();
    if (!mounted) return;
    var isGroup = false;
    var membersOnly = false;
    final key = widget.chatKey;
    if (key != null && key.isNotEmpty) {
      final resolved = resolveChatKey(key);
      final chat = await resolved.session.db.getChat(resolved.jid);
      isGroup = chat?.isGroup ?? false;
      if (isGroup) {
        membersOnly = resolved.session.xmpp.isMembersOnly(resolved.jid);
      }
    }
    if (!shouldAutoDownload(
      maxBytes: maxBytes,
      incoming: m.incoming,
      isGroup: isGroup,
      membersOnly: membersOnly,
    )) {
      return;
    }
    await _download(maxBytes: maxBytes);
  }

  Future<void> _download({int? maxBytes}) async {
    if (_busy || m.mediaUrl.isEmpty || _hasLocal) return;
    setState(() {
      _busy = true;
      _error = null;
      _tooBig = false;
    });
    try {
      final session = _session();
      final file = await session.xmpp.httpFiles.downloadToCache(
        m.mediaUrl,
        preferredName: m.mediaName.isNotEmpty
            ? m.mediaName
            : (m.mediaUrl.split('/').last.split('#').first),
        maxBytes: maxBytes,
      );
      await session.db.setMessageLocalPath(m.id, file.path);
      await _loadImageBytes();
    } on DownloadTooLarge {
      if (mounted) setState(() => _tooBig = true);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _openInApp(BuildContext context) {
    final bytes = _imageBytes;
    if (bytes == null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black,
            foregroundColor: Colors.white,
          ),
          body: Center(child: InteractiveViewer(child: Image.memory(bytes))),
        ),
      ),
    );
  }

  AccountSession _session() {
    final key = widget.chatKey;
    if (key != null && key.isNotEmpty) {
      return resolveChatKey(key).session;
    }
    final primary = accountHub.primarySession;
    if (primary == null) throw StateError('no account session');
    return primary;
  }

  Future<void> _openLocal() async {
    if (!_hasLocal) return;
    // Web stores bytes under opaque mem:// keys — no OS path to hand off.
    // Images already render inline; other types stay a no-op toast for now.
    if (kIsWeb) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(context.l10n.tapToOpen)));
      return;
    }
    try {
      await ensureLinuxXdgOpen();
    } on MissingLinuxCli catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.linuxCliMissing(e.toolsJoined))),
      );
      return;
    }
    final result = await OpenFilex.open(m.localPath);
    if (!mounted) return;
    if (result.type != ResultType.done) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result.message.isNotEmpty
                ? result.message
                : context.l10n.couldNotOpenFile,
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final progress = ref.watch(fileUploadProgressProvider(m.stanzaId));
    final name = m.mediaName.isNotEmpty
        ? m.mediaName
        : (m.mediaUrl.isNotEmpty ? l10n.fileAttachment : '');
    final pathOrName = m.localPath.isNotEmpty ? m.localPath : name;
    final image = isImageMime(m.mediaMime, pathOrName);
    final audio = isAudioMime(m.mediaMime, pathOrName);

    if (_hasLocal && image && _imageBytes != null) {
      return _withUploadProgress(
        progress,
        Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => _openInApp(context),
            borderRadius: BorderRadius.circular(8),
            child: Image.memory(
              _imageBytes!,
              width: 220,
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) => _FileRow(
                name: name,
                busy: false,
                error: _error ?? l10n.couldNotOpenFile,
                subtitle: l10n.tapToOpen,
                onTap: _openLocal,
              ),
            ),
          ),
        ),
      );
    }

    if (_hasLocal) {
      return _withUploadProgress(
        progress,
        _FileRow(
          name: name,
          busy: false,
          error: _error,
          subtitle: l10n.tapToOpen,
          onTap: _openLocal,
          audio: audio,
        ),
      );
    }

    return _withUploadProgress(
      progress,
      _FileRow(
        name: name.isEmpty ? l10n.fileAttachment : name,
        busy: _busy,
        error: _error,
        subtitle: _tooBig ? l10n.fileTooBigForPreview : l10n.tapToDownload,
        onTap: _busy ? null : () => _download(),
        audio: audio,
      ),
    );
  }

  /// Determinate bar and percent across the bottom of the file, the same
  /// idea as Gajim's preview progress (`progress / total` and "42 %").
  Widget _withUploadProgress(FileUploadProgress? progress, Widget child) {
    if (progress == null) return child;
    final percent = (progress.fraction * 100).round();
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Stack(
        alignment: Alignment.bottomCenter,
        children: [
          child,
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: ColoredBox(
              color: const Color(0xCC000000),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
                child: Row(
                  children: [
                    Expanded(
                      child: LinearProgressIndicator(
                        value: progress.total <= 0 ? null : progress.fraction,
                        minHeight: 4,
                        color: Colors.white,
                        backgroundColor: Colors.white24,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '$percent %',
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FileRow extends StatelessWidget {
  const _FileRow({
    required this.name,
    required this.busy,
    required this.error,
    this.subtitle,
    this.onTap,
    this.audio = false,
  });

  final String name;
  final bool busy;
  final String? error;
  final String? subtitle;
  final VoidCallback? onTap;
  final bool audio;

  @override
  Widget build(BuildContext context) {
    final tg = context.appColors;
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(8),
    );
    return Material(
      color: Colors.transparent,
      shape: shape,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        customBorder: shape,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 240),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (busy)
                  const SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  Icon(
                    audio ? Icons.mic : Icons.insert_drive_file_outlined,
                    color: tg.textSecondary,
                  ),
                const SizedBox(width: 8),
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: AppDimens.messageFontSize,
                          color: tg.textPrimary,
                        ),
                      ),
                      if (error != null)
                        Text(
                          error!,
                          style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context).colorScheme.error,
                          ),
                        )
                      else if (subtitle != null)
                        Text(
                          subtitle!,
                          style: TextStyle(
                            fontSize: 12,
                            color: tg.textSecondary,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
