import 'dart:typed_data';
import 'dart:ui';

import '../pdf_element.dart';
import '../pdf_geometry.dart';

/// Opens a PDF file/stream and returns a [PinealPdfDocument]. Every
/// resource the viewer needs goes through that document — the [PdfBackend]
/// itself is stateless after the open call.
///
/// Swap implementations to switch underlying engines (pdfx, native
/// `ffigen` bindings, a remote rendering service). The Pineal viewer
/// doesn't care which one it talks to.
abstract class PdfBackend {
  /// Open an in-memory byte buffer. The buffer is consumed once — the
  /// backend may or may not retain it; callers shouldn't mutate it
  /// afterwards.
  Future<PinealPdfDocument> openBytes(Uint8List bytes, {String? password});

  /// Open a file from the host filesystem. Mobile callers usually go via
  /// [openBytes] after a `file_picker` round-trip; this is here for
  /// desktop where a path is naturally available.
  Future<PinealPdfDocument> openFile(String path, {String? password});

  /// Open a Flutter asset (`pubspec.yaml` → `flutter.assets`). Equivalent
  /// to loading via `rootBundle.load(assetPath)` and calling
  /// [openBytes].
  Future<PinealPdfDocument> openAsset(String assetPath, {String? password});
}

/// A handle to a parsed PDF document. Pages are addressed by zero-based
/// index. Implementations are responsible for closing native resources
/// when [close] is called.
abstract class PinealPdfDocument {
  /// Total page count. Cheap — the backend should cache this after open.
  int get pageCount;

  /// Native geometry of a single page. Async because some backends parse
  /// page dictionaries lazily.
  Future<PdfPageGeometry> pageGeometry(int pageIndex);

  /// Rasterize part of a page to a `ui.Image`. `srcRect` is in PDF points
  /// (unrotated, top-left origin); `scale` is pixels per PDF point.
  ///
  /// Returned images live on the GPU (`ui.Image` is texture-backed) — the
  /// caller is responsible for `image.dispose()` once the tile leaves the
  /// cache.
  Future<Image> rasterize({
    required int pageIndex,
    required Rect srcRect,
    required double scale,
  });

  /// Text spans inside [rect] (PDF points; null = full page). The returned
  /// list is ordered by reading order when the backend supports it,
  /// otherwise by Y then X.
  Future<List<PdfTextSpan>> extractText({
    required int pageIndex,
    Rect? rect,
  });

  /// Element at the given PDF-point coordinate, or `null` if none. The
  /// default implementation walks [extractText] and any annotation list;
  /// backends with a native hit-test API can override for speed.
  Future<PdfElement?> elementAt({
    required int pageIndex,
    required Offset pdfPoint,
  }) async {
    final spans = await extractText(pageIndex: pageIndex);
    for (final span in spans) {
      if (span.pdfRect.contains(pdfPoint)) return span;
    }
    return null;
  }

  Future<void> close();
}
