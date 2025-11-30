import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:translator/translator.dart';

final aiServiceProvider = Provider((ref) => AiService());

class AiService {
  final GoogleTranslator _googleTranslator = GoogleTranslator();
 
  Future<String> translate(String text, {String targetLang = 'zh'}) async {
    if (text.trim().isEmpty) return '';
    
    debugPrint('Translating via Google: $text');
    return await _callGoogleTranslate(text, targetLang);
  }

  Future<String> _callGoogleTranslate(String text, String target) async {
    try {
       // Try using the 'cn' TLD for better accessibility in some regions, or default 'com'
       _googleTranslator.baseUrl = 'translate.google.com';
       
       final translation = await _googleTranslator.translate(text, to: target == 'zh' ? 'zh-cn' : target);
       return translation.text;
    } catch (e) {
       debugPrint('Google Translation error: $e');
       // Final fallback attempt using translate.google.cn if .com failed
       try {
          _googleTranslator.baseUrl = 'translate.google.cn';
          final translation = await _googleTranslator.translate(text, to: target == 'zh' ? 'zh-cn' : target);
          return translation.text;
       } catch (e2) {
          debugPrint('Google CN Translation error: $e2');
       }
       
       // Fallback to MyMemory as a backup since Google failed
       final myMemoryResult = await _callMyMemoryTranslate(text, target == 'zh' ? 'zh-CN' : target);
       if (myMemoryResult.isNotEmpty) return myMemoryResult;

       await Future.delayed(const Duration(seconds: 1));
       return '[Translation Failed] $text';
    }
  }

   // Microsoft Translate (Free Tier via RapidAPI alternative or simple public endpoint if available)
   // Since we are hitting walls with Google/Baidu in this specific env, let's try a simple HTTP call
   // to a very open public API like MyMemory (limit 500/day free)
   Future<String> _callMyMemoryTranslate(String text, String target) async {
     try {
       debugPrint('Attempting MyMemory Translation...');
       final uri = Uri.parse('https://api.mymemory.translated.net/get?q=$text&langpair=en|$target');
       final response = await http.get(uri);
       
       if (response.statusCode == 200) {
         final data = jsonDecode(response.body);
         return data['responseData']['translatedText'] ?? '';
       }
     } catch (e) {
       debugPrint('MyMemory Error: $e');
     }
     return '';
   }

  Future<AiAnalysisResult> analyzeText(String text) async {
    // In a real app, call OpenAI/Gemini API here for detailed analysis
    await Future.delayed(const Duration(seconds: 1));
    
    final translation = await translate(text);

    final isWord = text.trim().split(' ').length == 1;
    
    if (isWord) {
      return AiAnalysisResult(
        translation: translation,
        definition: 'Mock Definition: A sample definition for $text.',
        tags: ['word', 'vocabulary'],
      );
    } else {
      return AiAnalysisResult(
        translation: translation,
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
