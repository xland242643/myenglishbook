import 'dart:io';
// import 'package:archive/archive_io.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:drift/drift.dart';
// import 'package:sqlite3/sqlite3.dart' as sqlite;
import '../data/database.dart';

class AnkiService {
  final AppDatabase db;

  AnkiService(this.db);

  Future<String> exportToApkg() async {
    final tempDir = await getTemporaryDirectory();
    final exportDir = Directory(p.join(tempDir.path, 'anki_export_${DateTime.now().millisecondsSinceEpoch}'));
    await exportDir.create();

    // 1. Create Anki SQLite Database (collection.anki2)
    // final ankiDbPath = p.join(exportDir.path, 'collection.anki2');
    // final ankiDb = sqlite.sqlite3.open(ankiDbPath);
    
    // _initAnkiSchema(ankiDb);
    
    // 2. Fetch Data
    // final cards = await db.select(db.cards).get();
    // final capturedItems = await db.select(db.capturedItems).get();
    
    // 3. Insert Data
    // final deckId = 1; // Default deck
    // final modelId = 1234567890; // Random model ID
    
    // ankiDb.dispose();
    return _exportCsv(exportDir);
  }
  
  Future<String> _exportCsv(Directory dir) async {
      final file = File(p.join(dir.path, 'anki_import.csv'));
      final sink = file.openWrite();
      
      // Header (Optional for Anki, but good for readability)
      // sink.writeln('# Front,Back,Tags'); 
      
      final cards = await db.select(db.cards).get();
      
      for (final card in cards) {
         final items = await (db.select(db.capturedItems)..where((t) => t.cardId.equals(card.id))).get();
         final tags = await (db.select(db.cardTags).join([
            innerJoin(db.tags, db.tags.id.equalsExp(db.cardTags.tagId))
         ])..where(db.cardTags.cardId.equals(card.id))).map((row) => row.readTable(db.tags).name).get();
         
         final front = items.map((i) => i.content).join('<br><br>');
         final back = '${card.note ?? ''}<br>${items.map((i) => i.translation ?? '').join('<br>')}';
         final tagString = tags.join(' ');
         
         // CSV escaping
         final fSafe = _csvEscape(front);
         final bSafe = _csvEscape(back);
         
         sink.writeln('$fSafe,$bSafe,$tagString');
      }
      
      await sink.close();
      return file.path;
  }
  
  String _csvEscape(String input) {
    if (input.contains(',') || input.contains('"') || input.contains('\n')) {
      return '"${input.replaceAll('"', '""')}"';
    }
    return input;
  }
}
