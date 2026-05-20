import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import 'backend/pdf_backend.dart';
import 'pdf_element.dart';
import 'pdf_geometry.dart';
import 'rasterize_queue.dart';
import 'tile_cache.dart';

/// Observable state shared between [PinealPdfView], its [RenderBox] and
/// the overlay layer. Owns the document handle, the tile cache and the
/// rasterize queue — all the things the viewer's lifetime needs to clean
/// up exactly once.
class PinealPdfController extends ChangeNotifier {
  PinealPdfController({
    required this.backend,
    this.minZoom = 0.25,
    this.maxZoom = 8.0,
    this.pageGutter = 12,
    this.tileSize = 512,
    int tileCacheSize = 64,
    int rasterizeConcurrency = 2,
  })  : _tileCache = TileCache(maxTiles: tileCacheSize),
        _rasterizeConcurrency = rasterizeConcurrency;

  final PdfBackend backend;
  final double minZoom;
  final double maxZoom;
  final double pageGutter;

  /// Edge length of each rasterized tile, in pixels at the active mip
  /// level. 512 is the standard texture-tile size: small enough that
  /// edge tiles aren't wasteful, large enough that a typical viewport
  /// covers 4-12 tiles rather than dozens.
  final double tileSize;

  final TileCache _tileCache;
  final int _rasterizeConcurrency;
  RasterizeQueue? _queue;

  PinealPdfDocument? _document;
  List<PdfPageGeometry> _geometries = const <PdfPageGeometry>[];
  double _scrollY = 0;
  double _scrollX = 0;
  double _zoom = 1.0;
  bool _loading = false;
  Object? _error;
  ui.Size _viewportSize = ui.Size.zero;
  String? _searchQuery;
  List<PdfTextSpan> _searchHits = const <PdfTextSpan>[];
  int? _currentHitIndex;
  int _searchEpoch = 0;

  PinealPdfDocument? get document => _document;
  List<PdfPageGeometry> get pageGeometries => _geometries;
  int get pageCount => _geometries.length;
  double get scrollX => _scrollX;
  double get scrollY => _scrollY;
  double get zoom => _zoom;
  bool get isLoading => _loading;
  Object? get error => _error;
  TileCache get tileCache => _tileCache;
  RasterizeQueue? get rasterizeQueue => _queue;

  String? get searchQuery => _searchQuery;
  List<PdfTextSpan> get searchHits => _searchHits;
  int? get currentHitIndex => _currentHitIndex;
  PdfTextSpan? get currentHit =>
      _currentHitIndex == null ? null : _searchHits[_currentHitIndex!];

  /// Standard zoom levels we quantize to so the tile cache doesn't thrash.
  /// Pinch/scroll updates round to the nearest level inside the
  /// `[minZoom, maxZoom]` window. Mip level = index in this list.
  static const List<double> zoomStops = <double>[
    0.25, 0.5, 0.75, 1.0, 1.5, 2.0, 3.0, 4.0, 6.0, 8.0,
  ];

  int get mipLevel {
    // Pick the stop whose zoom is closest in log space — keeps the user's
    // perceptual jumps roughly even.
    var best = 0;
    var bestDelta = double.infinity;
    for (var i = 0; i < zoomStops.length; i++) {
      final delta = (zoomStops[i] - _zoom).abs();
      if (delta < bestDelta) {
        bestDelta = delta;
        best = i;
      }
    }
    return best;
  }

  Future<void> openBytes(Uint8List bytes, {String? password}) async {
    await _bindNew(() => backend.openBytes(bytes, password: password));
  }

  Future<void> openFile(String path, {String? password}) async {
    await _bindNew(() => backend.openFile(path, password: password));
  }

  Future<void> openAsset(String assetPath, {String? password}) async {
    await _bindNew(() => backend.openAsset(assetPath, password: password));
  }

  Future<void> _bindNew(
      Future<PinealPdfDocument> Function() opener) async {
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      final doc = await opener();
      final geometries = <PdfPageGeometry>[];
      for (var i = 0; i < doc.pageCount; i++) {
        geometries.add(await doc.pageGeometry(i));
      }
      final old = _document;
      _document = doc;
      _geometries = geometries;
      _queue?.shutdown();
      _queue = RasterizeQueue(
          document: doc, maxConcurrent: _rasterizeConcurrency);
      _tileCache.clear();
      _scrollX = 0;
      _scrollY = 0;
      _loading = false;
      notifyListeners();
      await old?.close();
    } catch (err) {
      _error = err;
      _loading = false;
      notifyListeners();
      rethrow;
    }
  }

  /// Total size of the laid-out content (pages stacked vertically with
  /// gutters). Used by [setScroll] to clamp and by overlay callers to
  /// position elements past the visible viewport.
  ui.Size contentSize() {
    var maxW = 0.0;
    var totalH = 0.0;
    for (final geom in _geometries) {
      final size = geom.renderedSize;
      final w = size.width * _zoom;
      final h = size.height * _zoom;
      if (w > maxW) maxW = w;
      totalH += h + pageGutter;
    }
    if (totalH > 0) totalH -= pageGutter;
    return ui.Size(maxW, totalH);
  }

  /// Called by the RenderBox after layout. The controller uses it to
  /// clamp scroll values so the user can't drift past the last page.
  /// Idempotent — only notifies when the size genuinely changed.
  void setViewportSize(ui.Size size) {
    if (size == _viewportSize) return;
    _viewportSize = size;
    setScroll(x: _scrollX, y: _scrollY);
  }

  void setScroll({double? x, double? y}) {
    final content = contentSize();
    final maxX = math.max(0.0, content.width - _viewportSize.width);
    final maxY = math.max(0.0, content.height - _viewportSize.height);
    final nx = (x ?? _scrollX).clamp(0.0, maxX);
    final ny = (y ?? _scrollY).clamp(0.0, maxY);
    if (nx == _scrollX && ny == _scrollY) return;
    _scrollX = nx;
    _scrollY = ny;
    notifyListeners();
  }

  /// Sets the zoom and reanchors scroll around [focalPoint] (viewport
  /// coordinates) so the point under the user's cursor stays put. When
  /// `focalPoint` is null, scroll stays where it was.
  ///
  /// Cancels any in-flight [animateZoomTo] so user-driven gestures take
  /// precedence over a running animation.
  void setZoom(double zoom, {({double sx, double sy})? anchor}) {
    _cancelZoomAnimation();
    _setZoomInternal(zoom, anchor: anchor);
  }

  /// Animated zoom — interpolates from the current zoom to [target] over
  /// [duration] with an ease-out curve. Used by zoom buttons, keyboard
  /// shortcuts and "fit to width" — pinch and Ctrl+scroll bypass this
  /// and call [setZoom] directly so they track user input frame-by-frame.
  void animateZoomTo(
    double target, {
    ({double sx, double sy})? anchor,
    Duration duration = const Duration(milliseconds: 200),
  }) {
    _cancelZoomAnimation();
    final start = _zoom;
    final clamped = target.clamp(minZoom, maxZoom);
    if (start == clamped) return;
    final totalMs = duration.inMilliseconds;
    final sw = Stopwatch()..start();
    _zoomAnimTimer = Timer.periodic(const Duration(milliseconds: 16),
        (timer) {
      final t = (sw.elapsedMilliseconds / totalMs).clamp(0.0, 1.0);
      // easeOut: 1 - (1 - t)^3 — fast start, gentle land.
      final eased = 1 - math.pow(1 - t, 3).toDouble();
      _setZoomInternal(start + (clamped - start) * eased, anchor: anchor);
      if (t >= 1.0) {
        timer.cancel();
        _zoomAnimTimer = null;
      }
    });
  }

  void _cancelZoomAnimation() {
    _zoomAnimTimer?.cancel();
    _zoomAnimTimer = null;
  }

  Timer? _zoomAnimTimer;

  void _setZoomInternal(double zoom,
      {({double sx, double sy})? anchor}) {
    final next = zoom.clamp(minZoom, maxZoom);
    if (next == _zoom) return;
    final oldMip = mipLevel;
    if (anchor != null) {
      final ratio = next / _zoom;
      _scrollX = (anchor.sx + _scrollX) * ratio - anchor.sx;
      _scrollY = (anchor.sy + _scrollY) * ratio - anchor.sy;
      if (_scrollX < 0) _scrollX = 0;
      if (_scrollY < 0) _scrollY = 0;
    }
    _zoom = next;
    // Crossing a mip boundary makes already-queued tiles for the old mip
    // worthless — they'd land in cache and immediately get evicted as
    // the new mip's tiles arrive. Cancel them so we don't burn FFI time
    // on tiles nobody will draw.
    if (mipLevel != oldMip) {
      _queue?.cancel((tag) => tag is TileKey && tag.mipLevel != mipLevel);
    }
    notifyListeners();
  }

  /// Stride for keyboard pan / page navigation.
  void scrollBy({double dx = 0, double dy = 0}) {
    setScroll(x: _scrollX + dx, y: _scrollY + dy);
  }

  Future<void> close() async {
    _queue?.shutdown();
    _queue = null;
    _tileCache.clear();
    final doc = _document;
    _document = null;
    _geometries = const <PdfPageGeometry>[];
    notifyListeners();
    await doc?.close();
  }

  @override
  void dispose() {
    _cancelZoomAnimation();
    _queue?.shutdown();
    _tileCache.clear();
    _document?.close();
    super.dispose();
  }

  /// Full-document text search. Walks every page, asks the backend for
  /// text spans, returns the ones whose text contains [query]
  /// (case-insensitive). Subsequent calls cancel the previous search so
  /// fast typing in a search bar doesn't pile up stale futures.
  ///
  /// Hits highlight at fragment granularity — pdfium gives us per-run
  /// bounds, not per-character, so a match in the middle of a long run
  /// highlights the whole run. Sufficient for "find next" navigation;
  /// glyph-precise highlights would need per-character rects we don't
  /// currently expose.
  Future<void> search(String query) async {
    final doc = _document;
    final epoch = ++_searchEpoch;
    final q = query.trim().toLowerCase();
    if (q.isEmpty || doc == null) {
      _searchQuery = query.isEmpty ? null : query;
      _searchHits = const <PdfTextSpan>[];
      _currentHitIndex = null;
      notifyListeners();
      return;
    }
    _searchQuery = query;
    _searchHits = const <PdfTextSpan>[];
    _currentHitIndex = null;
    notifyListeners();
    final hits = <PdfTextSpan>[];
    for (var i = 0; i < doc.pageCount; i++) {
      if (epoch != _searchEpoch) return; // superseded
      final spans = await doc.extractText(pageIndex: i);
      for (final span in spans) {
        if (span.text.toLowerCase().contains(q)) hits.add(span);
      }
    }
    if (epoch != _searchEpoch) return;
    _searchHits = hits;
    _currentHitIndex = hits.isEmpty ? null : 0;
    notifyListeners();
    if (hits.isNotEmpty) _scrollToHit(hits[0]);
  }

  void clearSearch() {
    if (_searchQuery == null && _searchHits.isEmpty) return;
    _searchEpoch++;
    _searchQuery = null;
    _searchHits = const <PdfTextSpan>[];
    _currentHitIndex = null;
    notifyListeners();
  }

  void nextHit() {
    if (_searchHits.isEmpty) return;
    final cur = _currentHitIndex ?? -1;
    _currentHitIndex = (cur + 1) % _searchHits.length;
    notifyListeners();
    _scrollToHit(_searchHits[_currentHitIndex!]);
  }

  void previousHit() {
    if (_searchHits.isEmpty) return;
    final cur = _currentHitIndex ?? 0;
    _currentHitIndex =
        (cur - 1 + _searchHits.length) % _searchHits.length;
    notifyListeners();
    _scrollToHit(_searchHits[_currentHitIndex!]);
  }

  /// Scroll the viewport so [hit] sits centered (or as close to centered
  /// as the content allows). The page's content-Y position is computed
  /// from the cumulative height of preceding pages at the current zoom.
  void _scrollToHit(PdfTextSpan hit) {
    if (_geometries.isEmpty) return;
    var y = 0.0;
    for (var i = 0; i < hit.pageIndex && i < _geometries.length; i++) {
      y += _geometries[i].renderedSize.height * _zoom + pageGutter;
    }
    final hitCenterY = y + hit.pdfRect.center.dy * _zoom;
    final targetY = hitCenterY - _viewportSize.height / 2;
    setScroll(y: targetY);
  }

  /// Best-effort hit-test that walks the document's text/annotation list
  /// for the page under [pageIndex] and returns the first element
  /// containing [pdfPoint]. v0.1 returns null for the reference backend
  /// because pdfx doesn't expose text yet; the API stays so an upgraded
  /// backend lights up element taps without any view-side changes.
  Future<PdfElement?> hitTestPdf({
    required int pageIndex,
    required ui.Offset pdfPoint,
  }) async {
    final doc = _document;
    if (doc == null) return null;
    return doc.elementAt(pageIndex: pageIndex, pdfPoint: pdfPoint);
  }
}
