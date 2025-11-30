import 'package:flutter_riverpod/flutter_riverpod.dart';

final aiServiceProvider = Provider((ref) => AiService());

class AiService {
  Future<AiAnalysisResult> analyzeText(String text) async {
    // Mock implementation
    // In a real app, call OpenAI/Gemini API here
    await Future.delayed(const Duration(seconds: 1));
    
    final isWord = text.trim().split(' ').length == 1;
    
    if (isWord) {
      return AiAnalysisResult(
        translation: 'Mock Translation of word: $text',
        definition: 'Mock Definition: A sample definition for $text.',
        tags: ['word', 'vocabulary'],
      );
    } else {
      return AiAnalysisResult(
        translation: 'Mock Translation of sentence.',
        definition: 'Grammar analysis: Subject + Verb + Object...',
        tags: ['sentence', 'grammar'],
      );
    }
  }
}

class AiAnalysisResult {
  final String translation;
  final String definition;
  final List<String> tags;

  AiAnalysisResult({
    required this.translation,
    required this.definition,
    required this.tags,
  });
}
