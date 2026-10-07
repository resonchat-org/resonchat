// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// File / image attachment inside a chat bubble (HTTP File Upload download).

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mime/mime.dart';
import 'package:open_filex/open_filex.dart';

import '../l10n/l10n.dart';
import '../state/providers.dart';
import '../store/database.dart';
import 'theme.dart';

bool isImageMime(String mime, String pathOrName) {
  if (mime.toLowerCase().startsWith('image/')) return true;
  final guessed = lookupMimeType(pathOrName) ?? '';
  return guessed.toLowerCase().startsWith('image/');
}

/// Renders a downloaded image or a download affordance for a file message.
class MediaAttachment extends ConsumerStatefulWidget {
  const MediaAttachment({
    super.key,
    required this.message,
  });

  final Message message;

  @override
  ConsumerState<MediaAttachment> createState() => _MediaAttachmentState();
}

class _MediaAttachmentState extends ConsumerState<MediaAttachment> {
  bool _busy = false;
  String? _error;

  Message get m => widget.message;

  bool get _hasLocal {
    final p = m.localPath;
    return p.isNotEmpty && File(p).existsSync();
  }

  Future<void> _download() async {
    if (_busy || m.mediaUrl.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final xmpp = ref.read(xmppServiceProvider);
      final file = await xmpp.httpFiles.downloadToCache(
        m.mediaUrl,
        preferredName: m.mediaName.isNotEmpty
            ? m.mediaName
            : (m.mediaUrl.split('/').last.split('#').first),
      );
      await ref.read(databaseProvider).setMessageLocalPath(m.id, file.path);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openLocal() async {
    if (!_hasLocal) return;
    final result = await OpenFilex.open(
      m.localPath,
      type: m.mediaMime.isNotEmpty ? m.mediaMime : null,
    );
    if (!mounted) return;
    if (result.type != ResultType.done) {
      setState(() => _error = context.l10n.couldNotOpenFile);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final name = m.mediaName.isNotEmpty
        ? m.mediaName
        : (m.mediaUrl.isNotEmpty ? l10n.fileAttachment : '');
    final image =
        isImageMime(m.mediaMime, m.localPath.isNotEmpty ? m.localPath : name);

    if (_hasLocal && image) {
      return Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: _openLocal,
          borderRadius: BorderRadius.circular(8),
          child: Image.file(
            File(m.localPath),
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
      );
    }

    if (_hasLocal) {
      return _FileRow(
        name: name,
        busy: false,
        error: _error,
        subtitle: l10n.tapToOpen,
        onTap: _openLocal,
      );
    }

    return _FileRow(
      name: name.isEmpty ? l10n.fileAttachment : name,
      busy: _busy,
      error: _error,
      subtitle: l10n.tapToDownload,
      onTap: _busy ? null : _download,
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
  });

  final String name;
  final bool busy;
  final String? error;
  final String? subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final tg = context.tg;
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
                    Icons.insert_drive_file_outlined,
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
                          fontSize: TgDimens.messageFontSize,
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
