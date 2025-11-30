import 'dart:io';
import 'package:flutter/services.dart';
import 'package:drift/drift.dart' as drift;
import 'package:epub_view/epub_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/database.dart';
import '../providers/database_provider.dart';
import '../services/ai_service.dart';
import '../utils/cfi_utils.dart';

import 'cards_screen.dart';

class ReaderScreen extends ConsumerStatefulWidget {
  final Book book;

  const ReaderScreen({super.key, required this.book});

  @override
  ConsumerState<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends ConsumerState<ReaderScreen> {
  late EpubController _epubController;

  String? _pendingJumpCfi;

  int? _pendingJumpItemId;

  // Map to store the correct Spine Index for each highlight ID
  final Map<int, int> _highlightIdToSpineIndex = {};
  
  // Map to store the correct CFI Path (after !) for each highlight ID
  final Map<int, String> _highlightIdToCfiPath = {};

  String? _pendingCrossChapterCfi;
  int? _currentChapterIndex;
  String? _currentSelectedText;

  @override
  void initState() {
    super.initState();
    // Clean CFI: remove [null] which might be generated incorrectly
    final cleanCfi = (widget.book.lastReadCfi ?? '').replaceAll('[null]', '');
    
    _epubController = EpubController(
      document: _loadAndHighlightBook(),
      epubCfi: cleanCfi.isEmpty ? null : cleanCfi,
    );
    _pendingJumpCfi = cleanCfi.isEmpty ? null : cleanCfi;
    _pendingJumpItemId = null;
    _pendingCrossChapterCfi = null;
  }

  Future<EpubBook> _loadAndHighlightBook() async {
    // 1. Load the book using the standard loader
    EpubBook book = await EpubDocument.openFile(File(widget.book.filePath));

    // 2. Fetch captured items directly from DB to avoid Stream/Provider delays
    final db = ref.read(databaseProvider);
    final items = await (db.select(db.capturedItems)..where((t) => t.bookId.equals(widget.book.id))).get();
      
      // Populate highlight-to-chapter map immediately from DB if available
      _highlightIdToSpineIndex.clear();
      _highlightIdToCfiPath.clear();
      for (final item in items) {
         if (item.chapterIndex != null) {
            _highlightIdToSpineIndex[item.id] = item.chapterIndex!;
         }
      }

      // 3. Inject highlights
    if (items.isNotEmpty) {
      debugPrint('Injecting ${items.length} highlights into book...');
      
      // Prepare Spine Map: ContentFileName -> Spine Index
      final Map<String, int> fileNameToSpineIndex = {};
      if (book.Schema?.Package?.Spine?.Items != null && book.Schema?.Package?.Manifest?.Items != null) {
         final spineItems = book.Schema!.Package!.Spine!.Items!;
         final manifestItems = book.Schema!.Package!.Manifest!.Items!;
         
         for (int i = 0; i < spineItems.length; i++) {
            final idRef = spineItems[i].IdRef;
            // Find manifest item with this id
            final manifestItem = manifestItems.firstWhere((m) => m.Id == idRef, orElse: () => EpubManifestItem());
            if (manifestItem.Href != null) {
               fileNameToSpineIndex[manifestItem.Href!] = i;
            }
         }
      }

      // If map was populated from DB, we don't clear it here, but we might update it or fill missing ones.
      // Actually, the injection logic fills it based on WHERE the text is found.
      // If the text is found in Chapter X, we trust that over the DB if DB is null.
      // But if DB has it, we trust DB? 
      // Let's prefer the Injection result as it's the ground truth of where the text IS in the book file.
      // So we clear it only if we want to rebuild it from scratch.
      // However, the injection logic is recursive and fills it.
      // Let's keep the previous logic of clearing it to ensure we don't have stale data, 
      // UNLESS we want to rely on DB for items not found (e.g. modified book).
      // But the request is to "record" it so we can jump to it.
      // The injection logic is reliable for finding the chapter.
      // The DB is reliable for "what we saw last time".
      
      // Let's NOT clear it if we just populated it from DB, but allow overwrite.
      // _highlightIdToSpineIndex.clear(); // Removed to keep DB values as fallback/initial
      
      book.Chapters?.forEach((chapter) => _injectHighlightsRecursive(book, chapter, items, fileNameToSpineIndex));
    }

    return book;
  }

  void _injectHighlightsRecursive(EpubBook book, EpubChapter chapter, List<CapturedItem> items, Map<String, int> fileNameToSpineIndex) {
    // Determine Spine Index for this chapter
    int? spineIndex;
    if (chapter.ContentFileName != null) {
       spineIndex = fileNameToSpineIndex[chapter.ContentFileName];
       // Also try matching without path if needed, or decoding URI
       if (spineIndex == null) {
          // Fallback: try simple filename match
          final simpleName = chapter.ContentFileName!.split('/').last;
          for (final entry in fileNameToSpineIndex.entries) {
             if (entry.key.endsWith(simpleName)) {
                spineIndex = entry.value;
                break;
             }
          }
       }
    }

    if (chapter.HtmlContent != null && chapter.HtmlContent!.isNotEmpty) {
      String content = chapter.HtmlContent!;
      bool modified = false;
      int injectedCount = 0;
      
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
                  // Use a Custom Tag Scheme to avoid nested anchor issues
                  // The browser renderer will ignore unknown tags like <captured-highlight> but render their children.
                  // However, we style it as a span.
                  // Wait, if we don't use <a>, we can't click it easily in standard EpubView unless we inject JS or use builders.
                  // Since EpubView doesn't easily expose builders in this version (it seems), 
                  // we will try a safer injection:
                  // We wrap in <span class="captured-highlight" data-id="...">...</span>
                  // And we hope to catch taps? No.
                  
                  // Fallback: We use <a> but we STRIP nested <a> tags from the content to prevent breakage.
                   String innerContent = match.group(0)!;
                   // Remove any existing <a> tags but keep their content (simple regex replace)
                   // This is a heuristic to prevent nesting.
                   innerContent = innerContent.replaceAll(RegExp(r'</?a[^>]*>', caseSensitive: false), '');
                   
                  // 将唯一 id 放在 span 上，便于 CFI 精确定位到文本第一个字符
                  return '<div id="hlblock-${item.id}" style="display:block">'
                         '<a href="highlight://${item.id}" style="text-decoration: none; color: inherit;">'
                         '<span style="background-color: #ADD8E6; color: black;">$innerContent</span>'
                         '</a>'
                         '</div>';
                });
                if (content.contains('id="hlblock-${item.id}"')) {
                    debugPrint('Successfully injected highlight-${item.id} into chapter ${chapter.Title}');
                    // Store Spine Index
                    if (spineIndex != null) {
                       _highlightIdToSpineIndex[item.id] = spineIndex;
                       debugPrint('  -> Mapped highlight-${item.id} to Spine Index: $spineIndex');
                    } else {
                       debugPrint('  -> Warning: Could not determine Spine Index for highlight-${item.id} (File: ${chapter.ContentFileName})');
                    }
                    modified = true;
                    injectedCount++;
                } else {
                    debugPrint('Failed to verify injection of highlight-${item.id}');
                }
             }
           } catch (e) {
             debugPrint('Highlight error for item ${item.id}: $e');
           }
        }
      }
      
      if (modified) {
        debugPrint('Chapter ${chapter.Title} modified. Injected $injectedCount highlights.');
        
        // Calculate CFIs for injected items using accurate DOM parsing
        try {
           final ids = items.where((i) => content.contains('id="hlblock-${i.id}"'))
                            .map((i) => 'hlblock-${i.id}')
                            .toList();
           if (ids.isNotEmpty) {
              final cfis = CfiUtils.calculateCfiPaths(content, ids);
              cfis.forEach((idStr, path) {
                  final id = int.tryParse(idStr.replaceFirst('highlight-', ''));
                  if (id != null) {
                     _highlightIdToCfiPath[id] = path;
                     // debugPrint('  -> Calculated CFI Path for $id: $path');
                  }
              });
           }
        } catch (e) {
           debugPrint('Error calculating CFIs: $e');
        }

        chapter.HtmlContent = content;
        
        // CRITICAL: Update the central Content store so that the viewer sees the changes.
        // EpubView likely reads from book.Content.Html[fileName]
        if (chapter.ContentFileName != null && book.Content?.Html != null) {
            if (book.Content!.Html!.containsKey(chapter.ContentFileName)) {
               // We use 'Content' assuming it's the field for string content in EpubTextContentFile
               // If it doesn't exist, this dynamic cast might fail at runtime, but based on docs/usage it should be there.
               // However, since we had compilation errors, let's try to be safer or use reflection if needed?
               // Actually, the compilation error was on EpubChapter.Content (which doesn't exist).
               // EpubTextContentFile.Content DOES exist (it's a String).
               book.Content!.Html![chapter.ContentFileName]!.Content = content;
            }
        }
      }
    }
    
    // Correctly pass the map recursively
    chapter.SubChapters?.forEach((sub) => _injectHighlightsRecursive(book, sub, items, fileNameToSpineIndex));
  }

  @override
  void dispose() {
    _epubController.dispose();
    super.dispose();
  }

  void _saveProgress({bool showFeedback = false}) {
    String? cfi = _epubController.generateEpubCfi();
    
    if (cfi != null) {
       // Clean CFI before saving
       cfi = cfi.replaceAll('[null]', '');
       
       final db = ref.read(databaseProvider);
       (db.update(db.books)..where((t) => t.id.equals(widget.book.id))).write(
         BooksCompanion(lastReadCfi: drift.Value(cfi), lastReadAt: drift.Value(DateTime.now()))
       );
       debugPrint('Progress saved: $cfi');
       if (showFeedback && mounted) {
         ScaffoldMessenger.of(context).showSnackBar(
           const SnackBar(content: Text('Bookmark saved successfully!'), duration: Duration(seconds: 1)),
         );
       }
    }
  }

  void _reloadBook({String? targetCfi, int? targetItemId, int? targetChapterIndex, bool isCapture = false}) {
    // 1. Determine the CFI to use
    // Priority: 
    // 1. Explicit targetCfi (if provided)
    // 2. Current position from controller
    // 3. Last saved position from DB (as fallback)
    String? currentCfi = targetCfi ?? _epubController.generateEpubCfi();
    
    if (currentCfi == null) {
      // Try to fallback to what we know
      currentCfi = widget.book.lastReadCfi; 
      debugPrint('Warning: Could not generate CFI. Falling back to initial/saved CFI: $currentCfi');
    }

    // 统一清洗与兜底
    currentCfi ??= widget.book.lastReadCfi;
    currentCfi ??= 'epubcfi(/6/0!/4/2)';
    currentCfi = currentCfi.replaceAll('[null]', '');
    debugPrint('Target CFI prepared: $currentCfi');
    debugPrint('Reloading book at CFI: $currentCfi (isCapture: $isCapture)');
    
    // 2. Create new controller
    final newController = EpubController(
      document: _loadAndHighlightBook(),
      epubCfi: currentCfi,
    );
    
    final oldController = _epubController;
    
    // Store pending jump for onDocumentLoaded ONLY if it's NOT a capture reload
    // If it is a capture reload, we trust the controller to init at the correct position (currentCfi)
    // and we want to avoid the "jump" animation/action.
    if (!isCapture) {
      _pendingJumpCfi = currentCfi.replaceAll('[null]', '');
      _pendingJumpItemId = targetItemId;
    } else {
      _pendingJumpCfi = null;
      _pendingJumpItemId = null;
    }
    
    // If we have an explicit chapter index, prioritize that for the cross-chapter check
    if (targetChapterIndex != null) {
       // We can pre-set the pending cross chapter jump if we know we need to go there.
       // But _tryJumpToCfi handles the check. 
       // We need to ensure _tryJumpToCfi knows about this chapter index preference?
       // OR we can simply set the initial location of the controller? 
       // EpubController doesn't take initial chapter index, only CFI.
       
       // Strategy: When _tryJumpToCfi is called, if we have targetChapterIndex, use it.
       // But _tryJumpToCfi doesn't take targetChapterIndex as arg yet.
       // Let's update _tryJumpToCfi or store it in a member?
       // Actually, we can infer it from targetItemId if we have the map.
       // BUT the user said "record it".
       
       // If we have targetChapterIndex, let's trust it over the CFI's chapter.
       // We can inject it into the map immediately if we have targetItemId.
       if (targetItemId != null) {
          _highlightIdToSpineIndex[targetItemId] = targetChapterIndex;
       }
    }

    // 3. Update state
    setState(() {
      _epubController = newController;
    });

    // 4. Dispose old controller SAFELY after a frame delay
    WidgetsBinding.instance.addPostFrameCallback((_) {
       try {
         oldController.dispose();
       } catch (e) {
         debugPrint('Error disposing old controller: $e');
       }
    });
  }


  

  int? _parseChapterIndexFromCfi(String cfi) {
    try {
      String clean = cfi;
      if (cfi.startsWith('epubcfi(')) {
        clean = cfi.substring(8, cfi.length - 1);
      }
      final parts = clean.split('!');
      if (parts.isEmpty) return null;
      final packagePart = parts[0]; 
      if (packagePart.startsWith('/6/')) {
         final segments = packagePart.split('/');
         if (segments.length >= 3) {
            String indexStr = segments[2];
            if (indexStr.contains('[')) {
              indexStr = indexStr.substring(0, indexStr.indexOf('['));
            }
            final index = int.tryParse(indexStr);
            if (index != null) {
               // Assumption: CFI uses even numbers for items (2, 4, 6...) -> List index (0, 1, 2...)
               // Handle edge case where index is 0 (unlikely in standard but possible in malformed CFIs)
               if (index < 2) return 0;
               return (index ~/ 2) - 1;
            }
         }
      }
    } catch (e) {
      debugPrint('Error parsing CFI: $e');
    }
    return null;
  }

  

  int? _getCurrentChapterIndex() {
    final cfi = _epubController.generateEpubCfi();
    if (cfi != null) {
       return _parseChapterIndexFromCfi(cfi);
    }
    return null;
  }

  void _tryJumpToCfi(String cfi, {int attempts = 0, int? targetItemId}) {
    if (!mounted) return;
    
    // 1. Clean CFI
    String cleanCfi = cfi.replaceAll('[null]', '');
    if (cleanCfi.isEmpty) return;

    // 2. PATCH CFI: If we have a targetItemId, ensure the CFI points to the correct chapter.
    if (attempts == 0 && targetItemId != null) {
       final correctSpineIndex = _highlightIdToSpineIndex[targetItemId];
       final correctCfiPath = _highlightIdToCfiPath[targetItemId];

       if (correctSpineIndex != null) {
           // Priority: Use calculated path if available
          if (correctCfiPath != null) {
               // 指向元素的第一个文本节点起点：/1:0
               final newCfi = 'epubcfi(/6/${(correctSpineIndex + 1) * 2}!$correctCfiPath/1:0[highlight-$targetItemId])';
               if (newCfi != cleanCfi) {
                   debugPrint('Using calculated accurate CFI: $newCfi (was $cleanCfi)');
                   cleanCfi = newCfi;
               }
           } else {
               // Fallback: Patch existing CFI if chapter doesn't match
               final currentCfiChapterIndex = _parseChapterIndexFromCfi(cleanCfi);
               if (currentCfiChapterIndex != correctSpineIndex) {
                   debugPrint('CFI Mismatch detected! CFI points to ch $currentCfiChapterIndex, but item $targetItemId is in ch $correctSpineIndex.');
                   
                   final correctSpinePart = '/6/${(correctSpineIndex + 1) * 2}';
                   final spineMatch = RegExp(r'epubcfi\((/6/\d+)').firstMatch(cleanCfi);
                   if (spineMatch != null) {
                       final oldSpinePart = spineMatch.group(1)!;
                       cleanCfi = cleanCfi.replaceFirst(oldSpinePart, correctSpinePart);
                       
                       // Fix assertion
                       final assertionMatch = RegExp(r'\[([^\]]+)\]\)?$').firstMatch(cleanCfi);
                       if (assertionMatch != null) {
                          final oldAssertion = assertionMatch.group(1)!;
                          if (oldAssertion != 'highlight-$targetItemId') {
                             cleanCfi = cleanCfi.replaceAll(oldAssertion, 'highlight-$targetItemId');
                          }
                       } else {
                          if (cleanCfi.endsWith(')')) {
                             cleanCfi = cleanCfi.substring(0, cleanCfi.length - 1) + '[highlight-$targetItemId])';
                          } else {
                             cleanCfi = cleanCfi + '[highlight-$targetItemId]';
                          }
                       }
                       debugPrint('  -> Patched CFI to: $cleanCfi');
                   }
               }
           }
       }
    }

    // 3. Early Cross-Chapter Check (using the potentially patched CFI)
    if (attempts == 0) {
       final targetChapterIndex = _parseChapterIndexFromCfi(cleanCfi);
       if (targetChapterIndex != null) {
           final currentChapterIndex = _getCurrentChapterIndex();
           
           // If we are in the wrong chapter (or current is unknown), jump chapter first.
           if (currentChapterIndex == null || currentChapterIndex != targetChapterIndex) {
               debugPrint('Cross-chapter jump detected (Current: $currentChapterIndex, Target: $targetChapterIndex). Initiating chapter jump...');
               
               // Store pending CFI for onChapterChanged to handle
               _pendingCrossChapterCfi = cleanCfi;
               
               _epubController.jumpTo(index: targetChapterIndex);
               return;
           }
       }
    }

    debugPrint('### _tryJumpToCfi (Attempt $attempts) Target: $cleanCfi');

    // 4. Attempt Jump
    try {
      _epubController.gotoEpubCfi(cleanCfi);
    } catch (e) {
      debugPrint('  -> gotoEpubCfi failed: $e');
    }

    // 5. Verify and Retry
    Future.delayed(const Duration(milliseconds: 1000), () {
        if (!mounted) return;
        
        final currentCfi = _epubController.generateEpubCfi();
        
        bool seemsValid = currentCfi != null && !currentCfi.contains('[null]');
        
        if (targetItemId != null && seemsValid) {
            final currentIdx = _getCurrentChapterIndex();
            final expectedIdx = _highlightIdToSpineIndex[targetItemId];
            if (currentIdx != null && expectedIdx != null && currentIdx != expectedIdx) {
                debugPrint('Jump verification failed: Wrong chapter (Current: $currentIdx, Expected: $expectedIdx)');
                seemsValid = false;
            }
        }
        
        if (seemsValid) {
            debugPrint('Jump appears successful. Current: $currentCfi');
            return; 
        }

        if (attempts < 5) {
             debugPrint('Jump verification failed or incomplete. Retrying...');
             _tryJumpToCfi(cleanCfi, attempts: attempts + 1, targetItemId: targetItemId);
        } else {
             // 6. Final Fallback
             debugPrint('Jump failed after retries. Trying fallback strategy.');
             
             if (targetItemId != null) {
                 final correctSpineIndex = _highlightIdToSpineIndex[targetItemId];
                 if (correctSpineIndex != null) {
                     final currentIdx = _getCurrentChapterIndex();
                     if (currentIdx != correctSpineIndex) {
                         debugPrint('Fallback: Force jumping to correct spine index $correctSpineIndex');
                         // Set pending CFI for fallback
                         final contentPathMatch = RegExp(r'!([^\[]+)').firstMatch(cleanCfi);
                         final contentPath = contentPathMatch?.group(1) ?? '/4/2';
                         _pendingCrossChapterCfi = 'epubcfi(/6/${(correctSpineIndex + 1) * 2}!$contentPath/1:0[highlight-$targetItemId])';
                         
                         _epubController.jumpTo(index: correctSpineIndex);
                     } else {
                         // In correct chapter, try heuristic CFI immediately
                         final contentPathMatch = RegExp(r'!([^\[]+)').firstMatch(cleanCfi);
                         final contentPath = contentPathMatch?.group(1) ?? '/4/2';
                         final heuristicCfi = 'epubcfi(/6/${(correctSpineIndex + 1) * 2}!$contentPath/1:0[highlight-$targetItemId])';
                         debugPrint('Fallback: Trying heuristic CFI: $heuristicCfi');
                         _epubController.gotoEpubCfi(heuristicCfi);
                     }
                 }
             }
        }
    });
  }

  Future<void> _processCapture(String text) async {
    if (!mounted) return;

    // 1. Initial Feedback
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Translating and saving...'),
        duration: Duration(seconds: 2),
      ),
    );

    // 2. Get CFI and Chapter Index
    String cfi = '';
    int? currentChapterIndex = _currentChapterIndex;
    
    try {
      cfi = _epubController.generateEpubCfi() ?? '';
    } catch (e) {
      debugPrint('Error generating CFI: $e');
    }
    
    try {
      // 3. Translate
      final translation = await ref.read(aiServiceProvider).translate(text);
      
      // 4. Save to DB
      final db = ref.read(databaseProvider);
      final cardId = await db.createCard(CardsCompanion(
         note: drift.Value('Auto Captured'),
      ));

      await db.into(db.capturedItems).insert(CapturedItemsCompanion(
          bookId: drift.Value(widget.book.id),
          cardId: drift.Value(cardId),
         content: drift.Value(text),
         translation: drift.Value(translation),
         locationCfi: drift.Value((cfi.isEmpty ? 'epubcfi(/6/0!/4/2)' : cfi).replaceAll('[null]', '')),
         chapterIndex: drift.Value(currentChapterIndex),
      ));
      
      // 5. Reload & Feedback
      if (mounted) {
         // Pass the original captured CFI to ensure we stay on the same page
         // Use isCapture: true to avoid the jump animation/action
         _reloadBook(targetCfi: cfi.isEmpty ? null : cfi, targetChapterIndex: currentChapterIndex, isCapture: true);
         ScaffoldMessenger.of(context).showSnackBar(
           SnackBar(
             content: Text('Saved! Translation: $translation'),
             duration: const Duration(seconds: 3),
           ),
         );
      }

    } catch (e) {
       debugPrint('Capture process failed: $e');
       if (mounted) {
         showDialog(
           context: context,
           builder: (ctx) => AlertDialog(
             title: const Text('Capture Failed'),
             content: Text('$e'),
             actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
           ),
         );
       }
    }
  }

  

  void _handleLinkTap(String url) async {
    if (url.startsWith('highlight://')) {
      final idStr = url.replaceFirst('highlight://', '');
      final id = int.tryParse(idStr);
      if (id != null) {
        debugPrint('Tapped highlight with ID: $id');
        // Fetch item details
        final db = ref.read(databaseProvider);
        final item = await (db.select(db.capturedItems)..where((t) => t.id.equals(id))).getSingleOrNull();
        
        if (item != null && mounted) {
          showDialog(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('Translation'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(item.content, style: const TextStyle(fontWeight: FontWeight.bold)),
                    const Divider(),
                    Text(item.translation ?? 'No translation available.'),
                  ],
                ),
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
              ],
            ),
          );
        }
      }
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
               String? jumpToCfi;
               int? jumpToId;
               int? jumpToChapterIndex;
               await Navigator.push(
                 context,
                 MaterialPageRoute(
                   builder: (context) => CardsScreen(
                     bookId: widget.book.id,
                     onItemTap: (item) {
                       jumpToCfi = item.locationCfi;
                       jumpToId = item.id;
                       jumpToChapterIndex = item.chapterIndex;
                       Navigator.pop(context);
                     },
                   ),
                 ),
               );
               // Reload to sync highlights (remove deleted ones) and jump if requested
               if (mounted) {
                 _reloadBook(
                   targetCfi: jumpToCfi,
                   targetItemId: jumpToId,
                   targetChapterIndex: jumpToChapterIndex,
                 );
               }
             },
           ),
           IconButton(
             icon: const Icon(Icons.bookmark),
             tooltip: 'Save Bookmark',
             onPressed: () => _saveProgress(showFeedback: true),
           ),
        ],
      ),
      drawer: Drawer(
        child: EpubViewTableOfContents(controller: _epubController),
      ),
      body: SelectionArea(
        onSelectionChanged: (content) {
           _currentSelectedText = content?.plainText;
           // debugPrint('Selection changed: ${_currentSelectedText?.length ?? 0} chars');
        },
        contextMenuBuilder: (selectionContext, editableTextState) {
            return AdaptiveTextSelectionToolbar.buttonItems(
                anchors: editableTextState.contextMenuAnchors,
                buttonItems: [
                    ...editableTextState.contextMenuButtonItems,
                    ContextMenuButtonItem(
                        onPressed: () async {
                              debugPrint('Capture button pressed');
                              try {
                                // 1. Check cached selection first
                                String capturedText = _currentSelectedText ?? '';
                                
                                // 2. Fallback to clipboard if empty (just in case user copied manually before)
                                if (capturedText.isEmpty) {
                                   debugPrint('Selection empty, checking clipboard...');
                                   try {
                                     final data = await Clipboard.getData(Clipboard.kTextPlain);
                                     capturedText = data?.text ?? '';
                                   } catch (e) {
                                     debugPrint('Clipboard read error: $e');
                                   }
                                }

                                // 3. Process Capture (Auto Translate & Save)
                                // Use 'mounted' (State property) instead of context.mounted to be safer
                                // Use 'context' (State property) which is stable
                                if (mounted) {
                                   debugPrint('Processing capture for text: "$capturedText"');
                                   if (capturedText.isEmpty) {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        const SnackBar(content: Text('No text selected. Please select text first.')),
                                      );
                                   } else {
                                      // Close the toolbar/menu if possible (optional)
                                      editableTextState.hideToolbar();
                                      await _processCapture(capturedText);
                                   }
                                } else {
                                   debugPrint('Skipping capture: Widget not mounted.');
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
          onDocumentLoaded: (document) {
              debugPrint('Document loaded. Checking pending jump...');
              if (_pendingJumpCfi != null) {
                  final cfiToJump = _pendingJumpCfi!;
                  final itemIdToJump = _pendingJumpItemId;
                  _pendingJumpCfi = null; // Clear immediately to prevent double triggers
                  _pendingJumpItemId = null;
                  
                  // Add a small delay to ensure the UI (ScrollablePositionedList) is attached
                  Future.delayed(const Duration(milliseconds: 600), () {
                      if (mounted) { // Check mounted before executing
                          debugPrint('Executing pending jump to: $cfiToJump');
                          _tryJumpToCfi(cfiToJump, targetItemId: itemIdToJump);
                      }
                  });
              } else {
                  debugPrint('No pending jump. Initial location check: ${_epubController.generateEpubCfi()}');
              }
          },
          onExternalLinkPressed: (href) {
             debugPrint('Link pressed: $href');
             _handleLinkTap(href);
          },
          onChapterChanged: (value) {
               if (value != null) {
                 debugPrint('Chapter changed to: ${value.chapter?.Title}, position: ${value.position}');
                 _currentChapterIndex = value.position.index;
                 
                 // Handle Pending Cross-Chapter Jump
                 if (_pendingCrossChapterCfi != null) {
                     // We check if we arrived at the target chapter.
                     // Note: value.position.index is 0-based chapter index.
                     final targetIndex = _parseChapterIndexFromCfi(_pendingCrossChapterCfi!);
                     
                     // We accept if we are at the target index
                     if (targetIndex != null && value.position.index == targetIndex) {
                         debugPrint('Arrived at target chapter $targetIndex. Executing CFI jump to $_pendingCrossChapterCfi');
                         final cfi = _pendingCrossChapterCfi!;
                         _pendingCrossChapterCfi = null; // Clear first to prevent double triggering
                         
                         // Small delay to ensure DOM is ready for CFI resolution
                         Future.delayed(const Duration(milliseconds: 1000), () {
                             if (mounted) {
                                debugPrint('Executing final jump to: $cfi');
                                _epubController.gotoEpubCfi(cfi);
                             }
                         });
                     }
                 }
               }
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
         locationCfi: drift.Value((widget.cfi.isEmpty ? 'epubcfi(/0!/0)' : widget.cfi).replaceAll('[null]', '')),
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
