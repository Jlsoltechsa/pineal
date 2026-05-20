import 'dart:collection';
import 'dart:ui';

/// LRU cache of laid-out [Paragraph]s keyed by `(text, style hash)`.
///
/// Axis labels repeat across frames; without a cache, `TextPainter.layout`
/// becomes the dominant cost on dense axes. We keep the cache bounded so it
/// adapts when zooming changes the visible tick set.
class TextCache {
  TextCache({this.maxEntries = 256});

  final int maxEntries;
  final LinkedHashMap<int, _Entry> _entries = LinkedHashMap<int, _Entry>();

  /// Returns a laid-out [Paragraph] for [text] with the given style. Reused
  /// across frames if still in the cache.
  Paragraph paragraph(
    String text, {
    required double fontSize,
    required Color color,
    String? fontFamily,
    FontWeight fontWeight = FontWeight.w400,
    double maxWidth = double.infinity,
    TextAlign align = TextAlign.left,
  }) {
    final key = Object.hash(text, fontSize, color.toARGB32(), fontFamily,
        fontWeight, align, maxWidth);

    final cached = _entries.remove(key);
    if (cached != null) {
      _entries[key] = cached;
      return cached.paragraph;
    }

    final builder = ParagraphBuilder(ParagraphStyle(
      textAlign: align,
      fontSize: fontSize,
      fontFamily: fontFamily,
      fontWeight: fontWeight,
    ))
      ..pushStyle(TextStyle(
        color: color,
        fontSize: fontSize,
        fontFamily: fontFamily,
        fontWeight: fontWeight,
      ))
      ..addText(text);
    final p = builder.build()..layout(ParagraphConstraints(width: maxWidth));

    _entries[key] = _Entry(p);
    if (_entries.length > maxEntries) {
      final firstKey = _entries.keys.first;
      _entries.remove(firstKey);
    }
    return p;
  }

  void clear() => _entries.clear();
  int get size => _entries.length;
}

class _Entry {
  _Entry(this.paragraph);
  final Paragraph paragraph;
}
