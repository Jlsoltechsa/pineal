/// Pineal PDF — headless viewer module (opt-in).
///
/// Tile-cached `RenderBox` + `ui.Image` layer over a swappable
/// [PdfBackend]. No PDF backend is bundled: implement [PdfBackend] over
/// pdfium, mupdf, or an `ffigen` binding so the dependency surface stays
/// minimal. Designed for large drawings — every paint pass culls
/// non-visible pages and only walks the tiles intersecting the viewport.
/// Scroll + zoom mutate a `ChangeNotifier`-backed controller that drives
/// `markNeedsPaint` directly; gestures use raw `Listener` pointer events,
/// so the gesture arena doesn't burn cycles every frame.
library pineal.pdf;

export 'pdf/backend/pdf_backend.dart';
export 'pdf/pineal_pdf_view.dart';
export 'pdf/pdf_controller.dart';
export 'pdf/pdf_element.dart';
export 'pdf/pdf_geometry.dart';
export 'pdf/rasterize_queue.dart';
export 'pdf/render_pineal_pdf.dart';
export 'pdf/tile_cache.dart';
