import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/database.dart';

final databaseProvider = Provider<AppDatabase>((ref) {
  return AppDatabase();
});

final capturedItemsProvider = StreamProvider.family<List<CapturedItem>, int>((ref, bookId) {
  final db = ref.watch(databaseProvider);
  return (db.select(db.capturedItems)..where((t) => t.bookId.equals(bookId))).watch();
});
