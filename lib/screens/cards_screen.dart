import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart' hide Card;
import 'package:flutter/material.dart' as material show Card;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/database.dart';
import '../providers/database_provider.dart';
import 'reader_screen.dart';

class CardWithDetails {
  final CapturedItem item;
  final Book book;
  final Card? card;
  CardWithDetails({required this.item, required this.book, this.card});
}

final cardsProvider = StreamProvider.autoDispose.family<List<CapturedItem>, int?>((ref, bookId) {
  final db = ref.watch(databaseProvider);
  
  // SIMPLIFIED QUERY: No joins, just raw items
  // We will filter in Dart to be safe
  return db.select(db.capturedItems).watch().map((items) {
    if (bookId != null) {
      return items.where((i) => i.bookId == bookId).toList();
    }
    return items;
  });
});

class CardsScreen extends ConsumerWidget {
  final int? bookId;
  final void Function(CapturedItem)? onItemTap;

  const CardsScreen({super.key, this.bookId, this.onItemTap});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    debugPrint('CardsScreen building. bookId: $bookId');
    final cardsAsync = ref.watch(cardsProvider(bookId));

    return Scaffold(
      appBar: AppBar(
        title: Text(bookId == null ? 'My Cards' : 'Book Cards'),
      ),
      body: cardsAsync.when(
        data: (items) {
           debugPrint('CardsScreen loaded items: ${items.length}');
           for (var item in items) {
             debugPrint(' - Item: ${item.id}, BookId: ${item.bookId}, Content: ${item.content}');
           }
           if (items.isEmpty) {
             return Center(
               child: Column(
                 mainAxisAlignment: MainAxisAlignment.center,
                 children: [
                   const Text('No captured sentences yet.', style: TextStyle(fontSize: 18)),
                   if (bookId != null)
                     Padding(
                       padding: const EdgeInsets.only(top: 16),
                       child: Text('Filtering for Book ID: $bookId', style: const TextStyle(color: Colors.grey)),
                     ),
                 ],
               ),
             );
           }
           return ListView.builder(
             itemCount: items.length,
             itemBuilder: (context, index) {
               final item = items[index];
               return Stack(
                  children: [
                    InkWell(
                      onTap: () => onItemTap?.call(item),
                      child: material.Card(
                        margin: const EdgeInsets.all(8),
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(item.content, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                              if (item.translation != null && item.translation!.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: Text(item.translation!, style: const TextStyle(color: Colors.grey)),
                                ),
                              const SizedBox(height: 8),
                              Text('Book ID: ${item.bookId} | Item ID: ${item.id}', style: const TextStyle(fontSize: 12, color: Colors.grey)),
                              if (onItemTap != null)
                                const Padding(
                                  padding: EdgeInsets.only(top: 8.0),
                                  child: Row(
                                    children: [
                                      Icon(Icons.touch_app, size: 16, color: Colors.blue),
                                      SizedBox(width: 4),
                                      Text('Tap to jump', style: TextStyle(color: Colors.blue, fontSize: 12)),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                     top: 8,
                     right: 8,
                     child: IconButton(
                       icon: const Icon(Icons.delete, color: Colors.red),
                       onPressed: () {
                         showDialog(
                           context: context,
                           builder: (ctx) => AlertDialog(
                             title: const Text('Delete Item'),
                             content: const Text('Are you sure you want to delete this captured sentence?'),
                             actions: [
                               TextButton(
                                 onPressed: () => Navigator.pop(ctx),
                                 child: const Text('Cancel'),
                               ),
                               TextButton(
                                 onPressed: () async {
                                   Navigator.pop(ctx);
                                   await ref.read(databaseProvider).deleteCapturedItem(item.id);
                                   ScaffoldMessenger.of(context).showSnackBar(
                                     const SnackBar(content: Text('Item deleted')),
                                   );
                                 },
                                 child: const Text('Delete', style: TextStyle(color: Colors.red)),
                               ),
                             ],
                           ),
                         );
                       },
                     ),
                   ),
                 ],
               );
        },
      );
    },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, st) => Center(child: Text('Error: $err')),
      ),
    );
  }
}
