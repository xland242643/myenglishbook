import 'dart:io';
import 'package:flutter/services.dart';
import 'package:drift/drift.dart' as drift;
import 'package:epub_view/epub_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/database.dart';
import '../providers/database_provider.dart';
import '../services/ai_service.dart';

class ReaderScreen extends ConsumerStatefulWidget {
  final Book book;

  const ReaderScreen({super.key, required this.book});

  @override
  ConsumerState<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends ConsumerState<ReaderScreen> {
  late EpubController _epubController;

  @override
  void initState() {
    super.initState();
    _epubController = EpubController(
      document: EpubDocument.openFile(File(widget.book.filePath)),
      epubCfi: widget.book.lastReadCfi,
    );
  }

  @override
  void dispose() {
    _epubController.dispose();
    super.dispose();
  }

  void _saveProgress() {
    final cfi = _epubController.generateEpubCfi();
    if (cfi != null) {
       final db = ref.read(databaseProvider);
       (db.update(db.books)..where((t) => t.id.equals(widget.book.id))).write(
         BooksCompanion(lastReadCfi: drift.Value(cfi), lastReadAt: drift.Value(DateTime.now()))
       );
    }
  }

  void _showCaptureDialog(String text) {
    final cfi = _epubController.generateEpubCfi() ?? '';
    // In a real app, we would try to get the precise CFI of the selection, 
    // but for now we use the page CFI.
    
    showDialog(
      context: context,
      builder: (context) => CaptureDialog(
        initialText: text,
        bookId: widget.book.id,
        cfi: cfi,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: EpubViewActualChapter(
          controller: _epubController,
          builder: (chapterValue) => Text(
            chapterValue?.chapter?.Title?.replaceAll('\n', '').trim() ?? '',
            textAlign: TextAlign.start,
            style: const TextStyle(fontSize: 14),
          ),
        ),
        actions: [
           IconButton(
             icon: const Icon(Icons.save),
             onPressed: _saveProgress,
           )
        ],
      ),
      drawer: Drawer(
        child: EpubViewTableOfContents(controller: _epubController),
      ),
      body: SelectionArea(
        contextMenuBuilder: (context, editableTextState) {
            return AdaptiveTextSelectionToolbar.buttonItems(
                anchors: editableTextState.contextMenuAnchors,
                buttonItems: [
                    ...editableTextState.contextMenuButtonItems,
                    ContextMenuButtonItem(
                         onPressed: () {
                              // ignore: deprecated_member_use
                              editableTextState.copySelection(SelectionChangedCause.toolbar);
                              editableTextState.hideToolbar();
                             
                             Future.delayed(const Duration(milliseconds: 50), () async {
                               final data = await Clipboard.getData(Clipboard.kTextPlain);
                               if (data?.text != null && data!.text!.isNotEmpty) {
                                  if (context.mounted) {
                                    // Use the state context
                                    _showCaptureDialog(data.text!);
                                  }
                               }
                             });
                        },
                        label: 'Capture',
                    )
                ]
            );
        },
        child: EpubView(
          controller: _epubController,
          onDocumentLoaded: (document) {
              // Auto restore is handled by controller init
          },
          onChapterChanged: (value) {
               _saveProgress();
          },
        ),
      ),
    );
  }
}

class CaptureDialog extends ConsumerStatefulWidget {
  final String initialText;
  final int bookId;
  final String cfi;

  const CaptureDialog({
    super.key, 
    required this.initialText,
    required this.bookId,
    required this.cfi,
  });

  @override
  ConsumerState<CaptureDialog> createState() => _CaptureDialogState();
}

class _CaptureDialogState extends ConsumerState<CaptureDialog> {
  late TextEditingController _textController;
  late TextEditingController _noteController;
  late TextEditingController _tagsController;
  late TextEditingController _translationController;
  bool _isAnalyzing = false;

  @override
  void initState() {
    super.initState();
    _textController = TextEditingController(text: widget.initialText);
    _noteController = TextEditingController();
    _tagsController = TextEditingController();
    _translationController = TextEditingController();
    _analyze();
  }

  Future<void> _analyze() async {
    setState(() => _isAnalyzing = true);
    try {
      final result = await ref.read(aiServiceProvider).analyzeText(widget.initialText);
      if (!mounted) return;
      
      _translationController.text = result.translation;
      _noteController.text = result.definition;
      _tagsController.text = result.tags.join(', ');
    } catch (e) {
      // Ignore error
    } finally {
      if (mounted) setState(() => _isAnalyzing = false);
    }
  }

  Future<void> _save(WidgetRef ref) async {
     final db = ref.read(databaseProvider);
     
     // 1. Create Card
     final cardId = await db.createCard(CardsCompanion(
       note: drift.Value(_noteController.text),
     ));
     
     // 2. Add Captured Item
     await db.addCapturedItem(CapturedItemsCompanion(
       bookId: drift.Value(widget.bookId),
       cardId: drift.Value(cardId),
       content: drift.Value(_textController.text),
       translation: drift.Value(_translationController.text),
       locationCfi: drift.Value(widget.cfi),
     ));
     
     // 3. Handle Tags (Simple comma separated for now)
     final tags = _tagsController.text.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty);
     for (final tagName in tags) {
        // Find or create tag
        // This requires more DB logic (upsert), skipping for brevity or implementing simply
        // For now, just insert tag if not exists and link.
        // Simple implementation:
        try {
           await db.into(db.tags).insert(TagsCompanion(name: drift.Value(tagName)));
        } catch (e) {
           // Ignore unique constraint error
        }
        
        final tag = await (db.select(db.tags)..where((t) => t.name.equals(tagName))).getSingle();
        await db.into(db.cardTags).insert(CardTagsCompanion(cardId: drift.Value(cardId), tagId: drift.Value(tag.id)));
     }

     if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Capture Sentence'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_isAnalyzing)
               const Padding(
                 padding: EdgeInsets.only(bottom: 8.0),
                 child: LinearProgressIndicator(),
               ),
            TextField(
              controller: _textController,
              decoration: const InputDecoration(labelText: 'Sentence'),
              maxLines: 3,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _translationController,
              decoration: const InputDecoration(labelText: 'Translation'),
              maxLines: 2,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _noteController,
              decoration: const InputDecoration(labelText: 'Meaning / Note'),
              maxLines: 2,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _tagsController,
              decoration: const InputDecoration(labelText: 'Tags (comma separated)'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: () => _save(ref),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
