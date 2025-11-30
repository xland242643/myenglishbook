import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';
import '../data/database.dart';
import '../providers/database_provider.dart';
import '../services/anki_service.dart';
import 'reader_screen.dart';
import 'cards_screen.dart';

final booksProvider = StreamProvider.autoDispose<List<Book>>((ref) {
  final db = ref.watch(databaseProvider);
  return db.select(db.books).watch();
});

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  Future<void> _importEpub(WidgetRef ref) async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['epub'],
    );

    if (result != null && result.files.single.path != null) {
      File file = File(result.files.single.path!);
      
      // Copy to app directory
      final appDir = await getApplicationDocumentsDirectory();
      final fileName = p.basename(file.path);
      final savedFile = await file.copy(p.join(appDir.path, fileName));
      
      // Add to DB
      final db = ref.read(databaseProvider);
      await db.addBook(BooksCompanion.insert(
        title: fileName.replaceAll('.epub', ''), // Simple title extraction
        filePath: savedFile.path,
      ));
    }
  }
  
  Future<void> _exportAnki(WidgetRef ref) async {
      final db = ref.read(databaseProvider);
      final service = AnkiService(db);
      try {
         final path = await service.exportToApkg(); // Actually CSV for now
         // ignore: deprecated_member_use
         await Share.shareXFiles([XFile(path)], text: 'My Anki Export (CSV)');
      } catch (e) {
         // show error
      }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final booksAsync = ref.watch(booksProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('My English Book'),
        actions: [
          IconButton(
            icon: const Icon(Icons.download),
            tooltip: 'Export to Anki (CSV)',
            onPressed: () => _exportAnki(ref),
          ),
          IconButton(
            icon: const Icon(Icons.style),
            onPressed: () {
                Navigator.push(context, MaterialPageRoute(builder: (context) => const CardsScreen()));
            },
          ),
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: () => _importEpub(ref),
          ),
        ],
      ),
      body: booksAsync.when(
        data: (books) {
          if (books.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text('No books yet.'),
                  const SizedBox(height: 20),
                  ElevatedButton(
                    onPressed: () => _importEpub(ref),
                    child: const Text('Import EPUB'),
                  ),
                ],
              ),
            );
          }
          return ListView.builder(
            itemCount: books.length,
            itemBuilder: (context, index) {
              final book = books[index];
              return ListTile(
                leading: const Icon(Icons.book, size: 40),
                title: Text(book.title),
                subtitle: Text(book.author ?? 'Unknown Author'),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => ReaderScreen(book: book),
                    ),
                  );
                },
                trailing: IconButton(
                    icon: const Icon(Icons.delete, color: Colors.red),
                    onPressed: () {
                        ref.read(databaseProvider).deleteBook(book.id);
                    },
                ),
              );
            },
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, stack) => Center(child: Text('Error: $err')),
      ),
    );
  }
}
