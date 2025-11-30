import 'dart:io';
import 'package:flutter/services.dart';
import 'package:drift/drift.dart' as drift;
import 'package:epub_view/epub_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/database.dart';
import '../providers/database_provider.dart';
import '../services/ai_service.dart';

import 'cards_screen.dart';

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
      document: _loadAndHighlightBook(),
      epubCfi: widget.book.lastReadCfi,
    );
  }

  Future<EpubBook> _loadAndHighlightBook() async {
    // 1. Load the book using the standard loader
    EpubBook book = await EpubDocument.openFile(File(widget.book.filePath));

    // 2. Fetch captured items directly from DB to avoid Stream/Provider delays
    final db = ref.read(databaseProvider);
    final items = await (db.select(db.capturedItems)..where((t) => t.bookId.equals(widget.book.id))).get();

    // 3. Inject highlights
    if (items.isNotEmpty) {
      book.Chapters?.forEach((chapter) => _injectHighlightsRecursive(chapter, items));
    }

    return book;
  }

  void _injectHighlightsRecursive(EpubChapter chapter, List<CapturedItem> items) {
    if (chapter.HtmlContent != null && chapter.HtmlContent!.isNotEmpty) {
      String content = chapter.HtmlContent!;
      bool modified = false;
      
      for (final item in items) {
        if (item.content.trim().isNotEmpty) {
           try {
             // Create a more robust regex:
             // 1. Extract meaningful chunks (words or symbols), ignoring original whitespace
             //    Matches alphanumeric sequences OR sequences of non-alphanumeric non-whitespace chars
             final chunks = RegExp(r'[a-zA-Z0-9\u00C0-\u024F]+|[^\w\s]+')
                 .allMatches(item.content)
                 .map((m) => m.group(0)!)
                 .toList();
                 
             if (chunks.isEmpty) continue;
             
             // 2. Escape each chunk
             final escapedChunks = chunks.map((c) => RegExp.escape(c)).toList();
             
             // 3. Create a pattern that allows for:
             //    - Whitespace/Newlines: [\s\n\r\t]
             //    - HTML Tags: <[^>]+>
             //    - HTML Entities: &[^;]+;
             //    Between ANY chunks (using * to allow zero or more, e.g. for punctuation attached to words)
             final separator = r'([\s\n\r\t]|<[^>]+>|&[^;]+;)*'; 
             
             final patternStr = escapedChunks.join(separator);
             
             // 4. Use dotAll to match across lines if tags/whitespace span lines
             final pattern = RegExp(patternStr, caseSensitive: false, multiLine: true, dotAll: true);
             
             if (pattern.hasMatch(content)) {
                content = content.replaceAllMapped(pattern, (match) {
                  // Use a span with a specific class or inline style
                  // Check if already highlighted to avoid double wrapping?
                  // Simple approach: just wrap.
                  return '<span style="background-color: #ADD8E6; color: black;">${match.group(0)}</span>';
                });
                modified = true;
             }
           } catch (e) {
             debugPrint('Highlight error for item ${item.id}: $e');
           }
        }
      }
      
      if (modified) {
        chapter.HtmlContent = content;
      }
    }

    chapter.SubChapters?.forEach((sub) => _injectHighlightsRecursive(sub, items));
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

  void _reloadBook() {
    final currentCfi = _epubController.generateEpubCfi();
    
    // 1. Create new controller
    final newController = EpubController(
      document: _loadAndHighlightBook(),
      epubCfi: currentCfi,
    );
    
    final oldController = _epubController;

    // 2. Update state
    setState(() {
      _epubController = newController;
    });

    // 3. Dispose old controller SAFELY after a frame delay
    // This prevents disposal while the widget tree might still be holding onto it during build/transition
    WidgetsBinding.instance.addPostFrameCallback((_) {
       try {
         oldController.dispose();
       } catch (e) {
         debugPrint('Error disposing old controller: $e');
       }
    });
  }

  Future<void> _showCaptureDialog(String text) async {
    String cfi = '';
    try {
      cfi = _epubController.generateEpubCfi() ?? '';
    } catch (e) {
      debugPrint('Error generating CFI: $e');
      // Fallback: try to proceed without CFI or use dummy
      cfi = 'epubcfi(/0!/0)';
    }
    
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => CaptureDialog(
        initialText: text,
        bookId: widget.book.id,
        cfi: cfi,
      ),
    );

    if (result == true && mounted) {
      _reloadBook();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Sentence captured and highlighted!')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    // We don't need to watch capturedItemsProvider for rendering anymore
    // as highlights are baked in on load. 
    // To support dynamic highlighting, we would need to reload the document,
    // which is heavy. For now, this meets the requirement of "showing highlights".

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
             icon: const Icon(Icons.list),
             tooltip: 'View Captured Cards',
             onPressed: () async {
               await Navigator.push(
                 context,
                 MaterialPageRoute(
                   builder: (context) => CardsScreen(
                     bookId: widget.book.id,
                     onItemTap: (item) {
                       Navigator.pop(context); // Close the cards list
                       if (item.locationCfi.isNotEmpty) {
                         _epubController.gotoEpubCfi(item.locationCfi);
                       }
                     },
                   ),
                 ),
               );
               // Reload to sync highlights (remove deleted ones)
               if (mounted) {
                 _reloadBook();
               }
             },
           ),
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
        contextMenuBuilder: (selectionContext, editableTextState) {
            return AdaptiveTextSelectionToolbar.buttonItems(
                anchors: editableTextState.contextMenuAnchors,
                buttonItems: [
                    ...editableTextState.contextMenuButtonItems,
                    ContextMenuButtonItem(
                        onPressed: () async {
                              debugPrint('Capture button pressed');
                              try {
                                // 1. Show feedback immediately
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('Processing selection...'), 
                                    duration: Duration(milliseconds: 500)
                                  ),
                                );
 
                                // 2. Trigger copy safely
                                try {
                                  // ignore: deprecated_member_use
                                  editableTextState.copySelection(SelectionChangedCause.toolbar);
                                } catch (e) {
                                  debugPrint('Copy selection error (ignored): $e');
                                }
                                
                                // 3. Hide toolbar
                                try {
                                  editableTextState.hideToolbar();
                                } catch (e) {
                                  debugPrint('Hide toolbar error (ignored): $e');
                                }
 
                                // 4. Wait for clipboard
                                await Future.delayed(const Duration(milliseconds: 500));
                                
                                // 5. Read clipboard
                                String capturedText = '';
                                try {
                                  final data = await Clipboard.getData(Clipboard.kTextPlain);
                                  capturedText = data?.text ?? '';
                                  debugPrint('Clipboard text: "$capturedText"');
                                } catch (e) {
                                  debugPrint('Clipboard read error: $e');
                                }
 
                                // 6. Open Dialog
                                // Use 'mounted' (State property) instead of context.mounted to be safer
                                // Use 'context' (State property) which is stable
                                if (mounted) {
                                   debugPrint('Opening dialog with text: "$capturedText"');
                                   if (capturedText.isEmpty) {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        const SnackBar(content: Text('Auto-copy failed. Please paste manually.')),
                                      );
                                   }
                                   await _showCaptureDialog(capturedText);
                                } else {
                                   debugPrint('Skipping dialog: Widget not mounted after delay.');
                                }
                              } catch (e) {
                                debugPrint('CRITICAL ERROR in Capture Button: $e');
                                if (mounted) {
                                  showDialog(
                                    context: context,
                                    builder: (ctx) => AlertDialog(
                                      title: const Text('Capture Error'),
                                      content: Text('An unexpected error occurred:\n$e'),
                                      actions: [
                                        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))
                                      ],
                                    ),
                                  );
                                }
                              }
                         },
                        label: 'Capture',
                    )
                ]
            );
        },
        child: EpubView(
          key: ValueKey(_epubController), // Force recreation when controller changes
          controller: _epubController,
          // No custom builders needed!
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

// ... CaptureDialog ...
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
    if (widget.initialText.isNotEmpty) {
      _analyze();
    }
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
     debugPrint('Starting save process for bookId: ${widget.bookId}');
     
     try {
       // 1. Create Card (Minimal insert)
       final cardId = await db.createCard(CardsCompanion(
         note: drift.Value(_noteController.text.isEmpty ? 'No Note' : _noteController.text),
       ));
       debugPrint('Created card with ID: $cardId');
       
       // 2. Add Captured Item (Minimal insert)
       final itemId = await db.into(db.capturedItems).insert(CapturedItemsCompanion(
         bookId: drift.Value(widget.bookId),
         cardId: drift.Value(cardId),
         content: drift.Value(_textController.text.isEmpty ? 'Empty Content' : _textController.text),
         translation: drift.Value(_translationController.text), 
         locationCfi: drift.Value(widget.cfi.isEmpty ? 'epubcfi(/0!/0)' : widget.cfi),
       ));
       debugPrint('Created captured item with ID: $itemId');
       
       // Verify immediately
       final check = await (db.select(db.capturedItems)..where((t) => t.id.equals(itemId))).getSingleOrNull();
       if (check != null) {
          debugPrint('VERIFICATION SUCCESS: Item found in DB. Content: ${check.content}');
          
          if (mounted) {
             // SUCCESS: Close dialog with true result
             Navigator.pop(context, true);
          }
       } else {
          throw Exception('Database insert appeared to succeed but returned no row.');
       }
       
       // 3. Handle Tags (Async, don't block success)
       try {
         final tags = _tagsController.text.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty);
         for (final tagName in tags) {
            try {
               await db.into(db.tags).insert(TagsCompanion(name: drift.Value(tagName)));
            } catch (e) { /* Ignore unique constraint */ }
            final tag = await (db.select(db.tags)..where((t) => t.name.equals(tagName))).getSingle();
            await db.into(db.cardTags).insert(CardTagsCompanion(cardId: drift.Value(cardId), tagId: drift.Value(tag.id)));
         }
       } catch (e) {
         debugPrint('Tag saving error (ignored): $e');
       }

     } catch (e) {
       debugPrint('CRITICAL ERROR saving capture: $e');
       if (mounted) {
         showDialog(
           context: context,
           builder: (ctx) => AlertDialog(
             title: const Text('Save Error'),
             content: Text('Failed to save capture:\n$e'),
             actions: [
               TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))
             ],
           ),
         );
       }
     }
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
