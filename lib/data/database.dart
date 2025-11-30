import 'dart:io';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

part 'database.g.dart';

class Books extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get title => text()();
  TextColumn get author => text().nullable()();
  TextColumn get filePath => text()();
  TextColumn get coverPath => text().nullable()();
  TextColumn get lastReadCfi => text().nullable()(); // Store EPUB CFI or location
  IntColumn get totalChapters => integer().nullable()();
  DateTimeColumn get lastReadAt => dateTime().nullable()();
}

class Cards extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get note => text().nullable()(); // User's manual note/meaning
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

class CapturedItems extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get cardId => integer().nullable().references(Cards, #id)();
  IntColumn get bookId => integer().references(Books, #id)();
  TextColumn get content => text()(); // The collected sentence/phrase
  TextColumn get translation => text().nullable()();
  TextColumn get locationCfi => text()(); // Location in book to jump back
  TextColumn get chapterName => text().nullable()();
  DateTimeColumn get capturedAt => dateTime().withDefault(currentDateAndTime)();
}

class Tags extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text().unique()();
}

class CardTags extends Table {
  IntColumn get cardId => integer().references(Cards, #id)();
  IntColumn get tagId => integer().references(Tags, #id)();
  
  @override
  Set<Column> get primaryKey => {cardId, tagId};
}

class Words extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get word => text().unique()();
  TextColumn get definition => text().nullable()();
}

class WordOccurrences extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get wordId => integer().references(Words, #id)();
  IntColumn get bookId => integer().references(Books, #id)();
  TextColumn get sentenceContext => text()();
  TextColumn get locationCfi => text()();
}

@DriftDatabase(tables: [Books, Cards, CapturedItems, Tags, CardTags, Words, WordOccurrences])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openConnection());

  @override
  int get schemaVersion => 1;
  
  // Helpers
  Future<int> addBook(BooksCompanion entry) => into(books).insert(entry);
  Future<List<Book>> getAllBooks() => select(books).get();
  
  Future<int> createCard(CardsCompanion entry) => into(cards).insert(entry);
  Future<int> addCapturedItem(CapturedItemsCompanion entry) => into(capturedItems).insert(entry);
  Future<void> deleteCapturedItem(int id) => (delete(capturedItems)..where((t) => t.id.equals(id))).go();
  
  Future<void> deleteBook(int id) => (delete(books)..where((t) => t.id.equals(id))).go();
}

LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    final dbFolder = await getApplicationDocumentsDirectory();
    final file = File(p.join(dbFolder.path, 'db.sqlite'));
    return NativeDatabase.createInBackground(file);
  });
}
