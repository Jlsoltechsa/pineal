import 'dart:ui';

import 'package:flutter/foundation.dart';

/// Anything the user can poke inside a PDF page. Subclasses cover the
/// common cases the viewer surfaces; the abstract type is `sealed` so
/// switches over it are exhaustive at compile time.
sealed class PdfElement {
  const PdfElement({required this.pageIndex, required this.pdfRect});

  final int pageIndex;

  /// Bounding box in PDF-point coordinates (unrotated, top-left origin).
  /// The viewer's layout maps this through [PdfPageLayout.pdfToScreen] for
  /// rendering / overlay positioning.
  final Rect pdfRect;
}

/// A run of text on the page. `pdfRect` is the union of the glyph boxes;
/// individual character boxes aren't exposed here (yet) — drag-selection
/// will need them and we'll add it in v0.2.
@immutable
class PdfTextSpan extends PdfElement {
  const PdfTextSpan({
    required super.pageIndex,
    required super.pdfRect,
    required this.text,
  });

  final String text;

  @override
  bool operator ==(Object other) =>
      other is PdfTextSpan &&
      other.pageIndex == pageIndex &&
      other.pdfRect == pdfRect &&
      other.text == text;

  @override
  int get hashCode => Object.hash(pageIndex, pdfRect, text);
}

/// A clickable region annotated by the PDF author. `target` is either a
/// `uri:…` URL or a `page:N` intra-document reference.
@immutable
class PdfLinkAnnotation extends PdfElement {
  const PdfLinkAnnotation({
    required super.pageIndex,
    required super.pdfRect,
    required this.target,
  });

  final String target;

  @override
  bool operator ==(Object other) =>
      other is PdfLinkAnnotation &&
      other.pageIndex == pageIndex &&
      other.pdfRect == pdfRect &&
      other.target == target;

  @override
  int get hashCode => Object.hash(pageIndex, pdfRect, target);
}

/// Selection state. Multiple spans because a drag can cross line breaks
/// (one span per visible line).
@immutable
class PdfTextSelection {
  const PdfTextSelection({
    required this.pageIndex,
    required this.spans,
  });

  final int pageIndex;
  final List<PdfTextSpan> spans;

  bool get isEmpty => spans.isEmpty;
  String get text => spans.map((s) => s.text).join(' ');
}
