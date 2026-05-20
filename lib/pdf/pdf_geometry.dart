import 'dart:ui';

import 'package:flutter/foundation.dart';

/// Static description of a single PDF page in its native coordinate system.
///
/// PDF lives in "points" (1/72 of an inch). The origin is the bottom-left
/// of the page by spec, but every renderer we'll talk to (pdfium, mupdf)
/// normalizes to top-left during rasterization, so callers never see the
/// flip. `pdfSize` is the unrotated logical extent — apply [rotation]
/// degrees clockwise to get the rendered orientation.
@immutable
class PdfPageGeometry {
  const PdfPageGeometry({
    required this.pageIndex,
    required this.pdfSize,
    this.rotation = 0,
  });

  final int pageIndex;
  final Size pdfSize;

  /// Rotation in degrees, multiples of 90. The viewer composes this on top
  /// of the user-controlled zoom.
  final int rotation;

  /// Rotated extent. A landscape page with rotation 90 becomes portrait
  /// here, which is what the viewer should layout against.
  Size get renderedSize {
    if (rotation % 180 == 0) return pdfSize;
    return Size(pdfSize.height, pdfSize.width);
  }

  @override
  bool operator ==(Object other) =>
      other is PdfPageGeometry &&
      other.pageIndex == pageIndex &&
      other.pdfSize == pdfSize &&
      other.rotation == rotation;

  @override
  int get hashCode => Object.hash(pageIndex, pdfSize, rotation);
}

/// Per-page layout snapshot computed by the renderer. The overlay layer
/// reads this to pin annotations to PDF-point coordinates while scroll
/// and zoom mutate the screen-space mapping.
@immutable
class PdfPageLayout {
  const PdfPageLayout({
    required this.geometry,
    required this.screenRect,
    required this.zoom,
  });

  final PdfPageGeometry geometry;

  /// Page rect in viewport (widget-local) coordinates. Already includes
  /// scroll offset, gutters, centering, and zoom.
  final Rect screenRect;

  /// Pixels per PDF point. Equivalent to `screenRect.width /
  /// geometry.renderedSize.width` modulo rounding; exposed so overlay
  /// callers can avoid the divide.
  final double zoom;

  /// Maps a point in PDF-point coordinates (unrotated, top-left origin) to
  /// a screen-space [Offset]. Inverse is [screenToPdf].
  Offset pdfToScreen(Offset pdfPoint) {
    return Offset(
      screenRect.left + pdfPoint.dx * zoom,
      screenRect.top + pdfPoint.dy * zoom,
    );
  }

  /// Inverse of [pdfToScreen]. Returns the PDF-point coordinates that
  /// correspond to [screenPoint] (which must be in viewport-local space).
  Offset screenToPdf(Offset screenPoint) {
    return Offset(
      (screenPoint.dx - screenRect.left) / zoom,
      (screenPoint.dy - screenRect.top) / zoom,
    );
  }
}
