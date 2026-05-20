import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';

import 'pdf_controller.dart';
import 'pdf_geometry.dart';
import 'tile_cache.dart';

/// `RenderBox`-level state of the PDF viewer. Hosted by the
/// [LeafRenderObjectWidget] in `pineal_pdf_view.dart`. Paint is
/// single-pass: walk every page in the doc, draw the ones that intersect
/// the viewport, queue rasterizations for tiles not yet in cache.
///
/// This class is deliberately silent about gestures — pointer events are
/// captured by the outer `Listener` in `PinealPdfView` and mutate the
/// controller, which fires `notifyListeners`, which calls
/// `markNeedsPaint` here. That separation keeps the RenderBox's
/// responsibilities to "given a controller state, paint the page" and
/// nothing else.
class RenderPinealPdf extends RenderBox {
  RenderPinealPdf({required PinealPdfController controller})
      : _controller = controller {
    _controller.addListener(_onControllerChange);
  }

  PinealPdfController _controller;
  PinealPdfController get controller => _controller;
  set controller(PinealPdfController value) {
    if (identical(_controller, value)) return;
    _controller.removeListener(_onControllerChange);
    _controller = value;
    _controller.addListener(_onControllerChange);
    _pendingTiles.clear();
    markNeedsLayout();
  }

  final Set<TileKey> _pendingTiles = <TileKey>{};

  void _onControllerChange() {
    markNeedsPaint();
  }

  @override
  bool get sizedByParent => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    // Take the largest finite size the parent allows — same trade-off the
    // grid module made. If we're given an infinite axis we squash it to
    // the smallest reasonable size; the host widget should be inside a
    // bounded parent.
    return constraints.biggest.isFinite
        ? constraints.biggest
        : constraints.smallest;
  }

  @override
  void performLayout() {
    super.performLayout();
    _controller.setViewportSize(size);
  }

  @override
  bool hitTestSelf(Offset position) => true;

  @override
  void paint(PaintingContext context, Offset offset) {
    final canvas = context.canvas;
    canvas.save();
    canvas.clipRect(offset & size);
    canvas.translate(offset.dx, offset.dy);
    _paintBackground(canvas);
    _paintPages(canvas);
    _paintSearchHighlights(canvas);
    canvas.restore();
  }

  void _paintSearchHighlights(ui.Canvas canvas) {
    final hits = controller.searchHits;
    if (hits.isEmpty) return;
    final layouts = visiblePageLayouts();
    if (layouts.isEmpty) return;
    final layoutByPage = <int, PdfPageLayout>{
      for (final l in layouts) l.geometry.pageIndex: l,
    };
    final current = controller.currentHit;
    final base = ui.Paint()..color = const ui.Color(0x55FFE94B);
    final active = ui.Paint()..color = const ui.Color(0x661E88E5);
    final activeBorder = ui.Paint()
      ..color = const ui.Color(0xFF1E88E5)
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = 1.5;
    for (final hit in hits) {
      final layout = layoutByPage[hit.pageIndex];
      if (layout == null) continue;
      final tl = layout.pdfToScreen(hit.pdfRect.topLeft);
      final br = layout.pdfToScreen(hit.pdfRect.bottomRight);
      final rect = ui.Rect.fromPoints(tl, br);
      if (identical(hit, current)) {
        canvas.drawRect(rect, active);
        canvas.drawRect(rect.deflate(0.75), activeBorder);
      } else {
        canvas.drawRect(rect, base);
      }
    }
  }

  void _paintBackground(ui.Canvas canvas) {
    final paint = ui.Paint()..color = const ui.Color(0xFF14181C);
    canvas.drawRect(ui.Offset.zero & size, paint);
  }

  void _paintPages(ui.Canvas canvas) {
    final geometries = controller.pageGeometries;
    if (geometries.isEmpty) return;

    final viewportH = size.height;
    final viewportW = size.width;
    final scrollX = controller.scrollX;
    final scrollY = controller.scrollY;
    final zoom = controller.zoom;
    final gutter = controller.pageGutter;
    final tileSize = controller.tileSize;
    final mip = controller.mipLevel;
    final mipScale = PinealPdfController.zoomStops[mip];

    final pagePaint = ui.Paint()..color = const ui.Color(0xFFFFFFFF);
    final shimmer = ui.Paint()..color = const ui.Color(0xFF1B2128);
    final tilePaint = ui.Paint()..filterQuality = ui.FilterQuality.medium;

    var contentY = 0.0;
    for (final geom in geometries) {
      final pageW = geom.renderedSize.width * zoom;
      final pageH = geom.renderedSize.height * zoom;

      final screenTop = contentY - scrollY;
      final screenBottom = screenTop + pageH;
      if (screenBottom >= 0 && screenTop <= viewportH) {
        final screenLeft = (viewportW - pageW) / 2 - scrollX;
        final pageRect =
            ui.Rect.fromLTWH(screenLeft, screenTop, pageW, pageH);
        canvas.drawRect(pageRect, pagePaint);

        // Tile grid at the current mip level. Page in mip-pixel space
        // is `pageWidth * mipScale` × `pageHeight * mipScale`; each tile
        // is `tileSize × tileSize` pixels in that space (smaller at the
        // right/bottom edges).
        final fullPxW = geom.renderedSize.width * mipScale;
        final fullPxH = geom.renderedSize.height * mipScale;
        final tileCols = (fullPxW / tileSize).ceil();
        final tileRows = (fullPxH / tileSize).ceil();
        // Display-space ratio: mip tile → screen tile.
        final dispRatio = zoom / mipScale;

        for (var row = 0; row < tileRows; row++) {
          for (var col = 0; col < tileCols; col++) {
            final tilePxX = col * tileSize;
            final tilePxY = row * tileSize;
            final tilePxW = math.min(tileSize, fullPxW - tilePxX);
            final tilePxH = math.min(tileSize, fullPxH - tilePxY);

            final tileScreenLeft =
                pageRect.left + tilePxX * dispRatio;
            final tileScreenTop = pageRect.top + tilePxY * dispRatio;
            final tileScreenW = tilePxW * dispRatio;
            final tileScreenH = tilePxH * dispRatio;
            final tileScreenRect = ui.Rect.fromLTWH(
                tileScreenLeft, tileScreenTop, tileScreenW, tileScreenH);

            // Tile-level culling — skip tiles outside the viewport so
            // we don't even ask the cache for them.
            if (tileScreenRect.bottom < 0 ||
                tileScreenRect.top > viewportH ||
                tileScreenRect.right < 0 ||
                tileScreenRect.left > viewportW) {
              continue;
            }

            final key = TileKey(
              pageIndex: geom.pageIndex,
              mipLevel: mip,
              row: row,
              col: col,
            );
            final image = controller.tileCache.lookup(key);
            if (image != null) {
              final src = ui.Rect.fromLTWH(
                  0, 0, image.width.toDouble(), image.height.toDouble());
              canvas.drawImageRect(image, src, tileScreenRect, tilePaint);
            } else {
              canvas.drawRect(tileScreenRect.deflate(2), shimmer);
              _requestTile(geom, mip, mipScale, row, col, tileSize,
                  tilePxW, tilePxH);
            }
          }
        }
      }

      contentY += pageH + gutter;
    }
  }

  void _requestTile(
    PdfPageGeometry geom,
    int mip,
    double mipScale,
    int row,
    int col,
    double tileSize,
    double tilePxW,
    double tilePxH,
  ) {
    final queue = controller.rasterizeQueue;
    if (queue == null) return;
    final key = TileKey(
      pageIndex: geom.pageIndex,
      mipLevel: mip,
      row: row,
      col: col,
    );
    if (_pendingTiles.contains(key)) return;
    _pendingTiles.add(key);
    // Tile bounds in PDF-point space: pixel coords / mipScale.
    final pdfLeft = col * tileSize / mipScale;
    final pdfTop = row * tileSize / mipScale;
    final pdfRight = pdfLeft + tilePxW / mipScale;
    final pdfBottom = pdfTop + tilePxH / mipScale;
    final srcRect =
        ui.Rect.fromLTRB(pdfLeft, pdfTop, pdfRight, pdfBottom);
    queue
        .enqueue(
      tag: key,
      pageIndex: geom.pageIndex,
      srcRect: srcRect,
      scale: mipScale,
    )
        .then((image) {
      _pendingTiles.remove(key);
      if (image == null) return;
      controller.tileCache.put(key, image);
      markNeedsPaint();
    }).catchError((Object err) {
      _pendingTiles.remove(key);
    });
  }

  /// Reverse mapping for hit-testing and overlay anchoring. Returns the
  /// layout snapshot of every page that currently intersects the
  /// viewport, with screen-space rectangles already including scroll +
  /// zoom + centering.
  List<PdfPageLayout> visiblePageLayouts() {
    final out = <PdfPageLayout>[];
    final geometries = controller.pageGeometries;
    if (geometries.isEmpty) return out;
    final viewportH = size.height;
    final viewportW = size.width;
    final scrollX = controller.scrollX;
    final scrollY = controller.scrollY;
    final zoom = controller.zoom;
    final gutter = controller.pageGutter;
    var contentY = 0.0;
    for (final geom in geometries) {
      final pageW = geom.renderedSize.width * zoom;
      final pageH = geom.renderedSize.height * zoom;
      final screenTop = contentY - scrollY;
      final screenBottom = screenTop + pageH;
      if (screenBottom >= 0 && screenTop <= viewportH) {
        final screenLeft = (viewportW - pageW) / 2 - scrollX;
        out.add(PdfPageLayout(
          geometry: geom,
          screenRect:
              ui.Rect.fromLTWH(screenLeft, screenTop, pageW, pageH),
          zoom: zoom,
        ));
      }
      contentY += pageH + gutter;
    }
    return out;
  }

  /// Walks the visible page layouts and returns `(page, pdfPoint)` for the
  /// first one whose `screenRect` contains [localPosition]. Used by the
  /// outer Listener to translate a tap into a PDF-space hit-test.
  ({PdfPageLayout layout, ui.Offset pdfPoint})?
      pageAtLocal(ui.Offset localPosition) {
    for (final layout in visiblePageLayouts()) {
      if (layout.screenRect.contains(localPosition)) {
        final pdfPoint = layout.screenToPdf(localPosition);
        return (layout: layout, pdfPoint: pdfPoint);
      }
    }
    return null;
  }

  @override
  void detach() {
    _controller.removeListener(_onControllerChange);
    super.detach();
  }
}
