# My English Book

A Flutter application for reading EPUBs and learning English.

## Features

- **EPUB Reader**: Import and read `.epub` files.
- **Sentence Capture**: Select text and "Capture" it to your flashcards.
- **Context Preservation**: Jump back to the exact location in the book from your card.
- **Review**: View collected sentences with notes and tags.
- **Progress Tracking**: Automatically saves your reading progress.

## How to Run

1.  Ensure Flutter is installed.
2.  Run `flutter pub get`.
3.  Run `dart run build_runner build` (Already done).
4.  Run `flutter run`.

## Architecture

- **State Management**: Riverpod
- **Database**: Drift (SQLite)
- **EPUB Rendering**: epub_view
