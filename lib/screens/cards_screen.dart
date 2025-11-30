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

final cardsProvider = StreamProvider.autoDispose<List<CardWithDetails>>((ref) {
  final db = ref.watch(databaseProvider);
  return db.select(db.capturedItems).join([
    innerJoin(db.books, db.books.id.equalsExp(db.capturedItems.bookId)),
    leftOuterJoin(db.cards, db.cards.id.equalsExp(db.capturedItems.cardId)),
  ]).map((row) {
     return CardWithDetails(
       item: row.readTable(db.capturedItems),
       book: row.readTable(db.books),
       card: row.readTableOrNull(db.cards),
     );
  }).watch();
});

class CardsScreen extends ConsumerWidget {
  const CardsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cardsAsync = ref.watch(cardsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('My Cards')),
      body: cardsAsync.when(
        data: (items) {
           if (items.isEmpty) {
             return const Center(child: Text('No captured sentences yet.'));
           }
           return ListView.builder(
             itemCount: items.length,
             itemBuilder: (context, index) {
               final item = items[index];
               return material.Card(
                 margin: const EdgeInsets.all(8),
                 child: Padding(
                   padding: const EdgeInsets.all(16),
                   child: Column(
                     crossAxisAlignment: CrossAxisAlignment.start,
                     children: [
                       Text(item.item.content, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                       if (item.card?.note != null)
                         Padding(
                           padding: const EdgeInsets.only(top: 8),
                           child: Text(item.card!.note!, style: const TextStyle(fontStyle: FontStyle.italic)),
                         ),
                       const SizedBox(height: 8),
                       Row(
                         mainAxisAlignment: MainAxisAlignment.spaceBetween,
                         children: [
                            Expanded(child: Text(item.book.title, overflow: TextOverflow.ellipsis)),
                            TextButton.icon(
                              icon: const Icon(Icons.arrow_forward),
                              label: const Text('Context'),
                              onPressed: () {
                                 // Open Reader at location
                                 // We create a temporary book object with the target CFI
                                 // Note: The reader will start at this CFI.
                                 Navigator.push(
                                   context,
                                   MaterialPageRoute(
                                     builder: (context) => ReaderScreen(
                                       book: item.book.copyWith(
                                         lastReadCfi: Value(item.item.locationCfi)
                                       ),
                                     ),
                                   ),
                                 );
                              },
                            )
                         ],
                       )
                     ],
                   ),
                 ),
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
