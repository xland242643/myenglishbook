import 'package:html/parser.dart' as html_parser;
import 'package:html/dom.dart' as dom;

class CfiUtils {
  /// Parses the HTML content and calculates the CFI path (the part after '!')
  /// for the elements with the given IDs.
  /// Returns a map of ID -> CFI Path.
  static Map<String, String> calculateCfiPaths(String htmlContent, List<String> elementIds) {
    final document = html_parser.parse(htmlContent);
    final result = <String, String>{};
    
    for (final id in elementIds) {
      final element = document.getElementById(id);
      if (element != null) {
        final path = _generatePath(element);
        if (path != null) {
          result[id] = path;
        }
      }
    }
    return result;
  }

  static String? _generatePath(dom.Element element) {
    // We walk up the tree until we hit the root (usually html)
    // The standard CFI usually starts with the spine item, then '!', then the path inside the file.
    // The path inside the file typically starts with the root element.
    // However, 'package:html' parse() returns a Document, which has a 'documentElement' (html).
    // If we walk up, we eventually reach 'html'.
    
    // CFI structure:
    // /step/step...
    // steps for elements are (index + 1) * 2.
    
    var current = element;
    var path = '';
    
    while (current.parent != null) {
      final parent = current.parent!;
      
      // Find index among element siblings
      // Note: package:html 'children' only contains Elements, which matches CFI element steps logic.
      final index = parent.children.indexOf(current);
      
      if (index == -1) {
        // Should not happen for elements
        return null;
      }
      
      final step = (index + 1) * 2;
      path = '/$step$path';
      
      current = parent;
      
      // If current is now the 'html' element, we might need to stop or include it?
      // Usually CFI includes the 'html' element step?
      // epubcfi(/spine!/4/...) -> /4 usually refers to 'body' if 'head' is /2.
      // So the path usually starts AFTER the root? 
      // No, /spine!/4 means child 2 of the spine item (which is the document root?? No).
      // The spine item points to the FILE. The file content starts with <html>.
      // So /spine!/2 would be <html>?? No, usually <html> is implicit or it's the root.
      // Let's check standard examples.
      // epubcfi(/6/4!/4/10)
      // /6/4 -> Spine item.
      // ! -> indirection.
      // /4/10 -> Inside the XHTML file.
      // If file is <html><head>...</head><body>...</body></html>
      // Root is <html>.
      // 1st child of root (head) -> /2
      // 2nd child of root (body) -> /4
      // So /4 refers to <body>.
      // So the path starts from the ROOT element's children.
      // It does NOT include the root element itself in the step?
      // "The path step /4/10 ... The first step (/4) selects the second child element of the root element..."
      // So yes, we stop when parent is the Document? Or when current is Root?
      
      if (current.localName == 'html') {
         // We have reached the html tag. 
         // The epub.js implementation usually expects the path to start from the root element's children.
         // e.g. /4/2/10... where /4 is the body.
         // So if we are at body, parent is html.
         // index of body in html is usually 1 (head is 0) -> step 4.
         // So we DO include the step for body.
         // We stop when the PARENT is html? 
         // Yes, because the root element (html) is the starting context for the path steps.
         // Wait, if we stop when parent is html, we include the step to reach 'current' from 'html'.
         // That is correct.
         
         // BUT, does the path include the step FOR html? 
         // No. The path starts relative to the root.
         // So we break here.
         break;
      }
      
      // Safety check for root (if localName check fails or structure is weird)
      if (current.parent == null) break;
    }
    
    return path;
  }
}
