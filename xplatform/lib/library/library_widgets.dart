import 'dart:io';

import 'package:flutter/material.dart';

import '../persistence/library_storage.dart';
import '../platform/form_factor.dart';
import '../theme.dart';
import '../widgets/app_context_menu.dart';

class LibraryEmptyState extends StatelessWidget {
  final InkAndEchoColors colors;
  const LibraryEmptyState({super.key, required this.colors});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 36),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.menu_book_outlined,
                size: 64, color: colors.inkMuted),
            const SizedBox(height: 18),
            Text(
              'Your library is quiet.',
              style: TextStyle(
                color: colors.ink,
                fontSize: 22,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Import an EPUB to begin. Attach an audiobook from the reader.',
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: colors.inkMuted, fontSize: 14, height: 1.4),
            ),
          ],
        ),
      ),
    );
  }
}

enum _BookAction { showInFolder, reimport, remove }

class BookTile extends StatelessWidget {
  final StoredBook book;
  final InkAndEchoColors colors;
  final VoidCallback onTap;
  final VoidCallback onRemove;
  final VoidCallback? onShowInFolder;
  final VoidCallback? onReimport;
  const BookTile({
    super.key,
    required this.book,
    required this.colors,
    required this.onTap,
    required this.onRemove,
    this.onShowInFolder,
    this.onReimport,
  });

  @override
  Widget build(BuildContext context) {
    final items = <AppContextMenuItem<_BookAction>>[
      if (isDesktop && onShowInFolder != null)
        const AppContextMenuItem(
          value: _BookAction.showInFolder,
          icon: Icons.folder_open_outlined,
          label: 'Show in folder',
        ),
      if (onReimport != null)
        const AppContextMenuItem(
          value: _BookAction.reimport,
          icon: Icons.refresh_outlined,
          label: 'Re-import EPUB',
        ),
      const AppContextMenuItem(
        value: _BookAction.remove,
        icon: Icons.delete_outline,
        label: 'Remove from library',
        color: Colors.redAccent,
      ),
    ];
    return AppContextMenu<_BookAction>(
      onPrimaryTap: onTap,
      onSelected: (a) {
        switch (a) {
          case _BookAction.showInFolder:
            onShowInFolder?.call();
          case _BookAction.reimport:
            onReimport?.call();
          case _BookAction.remove:
            onRemove();
        }
      },
      items: items,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 0.66,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: colors.canvasDeep,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: colors.hairline),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.10),
                    blurRadius: 6,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: book.coverPath != null
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: Image.file(
                        File(book.coverPath!),
                        fit: BoxFit.cover,
                      ),
                    )
                  : Center(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(
                          book.title,
                          textAlign: TextAlign.center,
                          maxLines: 4,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: colors.inkSoft,
                            fontSize: 14,
                            height: 1.25,
                          ),
                        ),
                      ),
                    ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            book.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: colors.ink,
              fontSize: 14,
              fontWeight: FontWeight.w500,
              height: 1.25,
            ),
          ),
          Text(
            book.author,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: colors.inkMuted, fontSize: 12),
          ),
          if (book.audioPath != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                children: [
                  Icon(Icons.headphones,
                      size: 12, color: colors.accent),
                  const SizedBox(width: 4),
                  Text(
                    book.alignmentPath != null ? 'aligned' : 'audio',
                    style: TextStyle(
                      color: colors.accent,
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
