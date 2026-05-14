import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../main.dart' show AppThemeChoice;
import '../persistence/library_storage.dart';
import '../platform/form_factor.dart';
import '../reader/reader_screen.dart';
import '../settings/settings_screen.dart';
import '../state/library_store.dart';
import '../theme.dart';
import '../widgets/app_dialog.dart';
import '../widgets/app_header.dart';
import '../widgets/app_primary_action.dart';
import '../widgets/app_scaffold.dart';
import 'library_widgets.dart';

class LibraryScreen extends StatefulWidget {
  final LibraryStore store;
  final AppThemeChoice currentTheme;
  final ValueChanged<AppThemeChoice> onThemeChanged;
  final bool animationsEnabled;
  final ValueChanged<bool> onAnimationsChanged;
  final ValueChanged<String?> onOpenBook;

  const LibraryScreen({
    super.key,
    required this.store,
    required this.currentTheme,
    required this.onThemeChanged,
    required this.animationsEnabled,
    required this.onAnimationsChanged,
    required this.onOpenBook,
  });

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  @override
  void initState() {
    super.initState();
    if (!widget.store.isLoaded) widget.store.load();
  }

  Future<void> _pickAndImport() async {
    final FilePickerResult? result;
    try {
      result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['epub', 'mobi', 'pdf'],
        withData: false,
      );
    } catch (e) {
      if (!mounted) return;
      // file_picker on Linux throws UnimplementedError when none of
      // zenity/qarma/kdialog is installed; tell the user how to fix it.
      final msg = Platform.isLinux
          ? 'File picker failed: install zenity (`sudo apt install zenity`) '
              'or kdialog and try again.'
          : 'File picker failed: $e';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
      return;
    }
    if (result == null || result.files.single.path == null) return;
    final picked = File(result.files.single.path!);
    final book = await widget.store.importBook(picked);
    if (!mounted) return;
    if (book == null && widget.store.lastError != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(widget.store.lastError!)),
      );
    } else if (book != null) {
      _openReader(book);
    }
  }

  void _openReader(StoredBook book) {
    widget.onOpenBook(book.id);
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ReaderScreen(
        store: widget.store,
        book: book,
        animationsEnabled: widget.animationsEnabled,
        onOpened: widget.onOpenBook,
      ),
    ));
  }

  Future<void> _confirmDelete(StoredBook book) async {
    final confirmed = await showAppConfirmDialog(
      context: context,
      title: 'Remove "${book.title}"?',
      message: 'Removes the EPUB, audio, alignment, and annotations '
          'for this book from this device.',
      confirmLabel: 'Remove',
      destructive: true,
    );
    if (confirmed) await widget.store.delete(book);
  }

  void _openSettings() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SettingsScreen(
        currentTheme: widget.currentTheme,
        onThemeChanged: widget.onThemeChanged,
        animationsEnabled: widget.animationsEnabled,
        onAnimationsChanged: widget.onAnimationsChanged,
      ),
    ));
  }

  String get _importLabel => isMobile ? 'Import EPUB' : 'Import book';

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      header: AppHeader(
        title: 'Palimpsest',
        leading: AppHeaderAction(
          icon: Icons.settings_outlined,
          onTap: _openSettings,
          tooltip: 'Settings',
        ),
      ),
      primaryAction: ListenableBuilder(
        listenable: widget.store,
        builder: (_, _) => AppPrimaryAction(
          icon: Icons.add,
          label: widget.store.isImporting ? 'Importing…' : _importLabel,
          busy: widget.store.isImporting,
          onPressed: _pickAndImport,
        ),
      ),
      body: ListenableBuilder(
        listenable: widget.store,
        builder: (_, _) {
          if (!widget.store.isLoaded) {
            return const Center(child: CircularProgressIndicator());
          }
          if (widget.store.books.isEmpty) {
            return LibraryEmptyState(colors: context.colors);
          }
          return GridView.builder(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 200,
              mainAxisSpacing: 20,
              crossAxisSpacing: 20,
              childAspectRatio: 0.52,
            ),
            itemCount: widget.store.books.length,
            itemBuilder: (_, i) => BookTile(
              book: widget.store.books[i],
              colors: context.colors,
              onTap: () => _openReader(widget.store.books[i]),
              onRemove: () => _confirmDelete(widget.store.books[i]),
            ),
          );
        },
      ),
    );
  }
}
