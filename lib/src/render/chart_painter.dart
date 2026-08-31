import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';

import '../core/coordinate_system.dart';
import '../core/pineal_core.dart';
import '../painters/axis.dart';
import '../painters/text_cache.dart';
import '../series/series.dart';

/// Threshold (visible points across all series) above which the chart switches
/// from the decorated UI-rich path to the lean high-density path.
const int kHighDensityThreshold = 4000;

/// Paints the chart body: gridded axes plus every series.
///
/// The painter holds a single [TextCache] and a [_PictureCache] so that pure
/// pan operations replay a pre-recorded [ui.Picture] instead of re-projecting
/// every sample. Zoom invalidates the cache.
class ChartPainter extends CustomPainter {
  ChartPainter({
    required this.core,
    required this.padding,
    required this.axisStyle,
    required this.xFormatter,
    required this.yFormatter,
    required this.textCache,
    required this.pictureCache,
    Listenable? repaintListenable,
  }) : super(repaint: repaintListenable ?? core);

  final PinealCore core;
  final EdgeInsets padding;
  final AxisStyle axisStyle;
  final String Function(double, Scale) xFormatter;
  final String Function(double, Scale) yFormatter;
  final TextCache textCache;
  final PictureCache pictureCache;

  @override
  void paint(Canvas canvas, Size size) {
    final plot = Rect.fromLTWH(
      padding.left,
      padding.top,
      (size.width - padding.horizontal).clamp(1.0, double.infinity),
      (size.height - padding.vertical).clamp(1.0, double.infinity),
    );

    final xPainter = AxisPainter(textCache: textCache, formatter: xFormatter);
    final yPainter = AxisPainter(textCache: textCache, formatter: yFormatter);

    // Axes use the first y-axis spec for their coordinate frame.
    final firstAxis = core.yAxes.first;
    final firstSeriesCoords = CoordinateSystem(
      x: LinearScale(core.xViewport.xMin, core.xViewport.xMax),
      y: LinearScale(
          core.yWindow(firstAxis.id).min, core.yWindow(firstAxis.id).max),
      plot: plot,
    );

    yPainter.paint(
        canvas, firstSeriesCoords, AxisPosition.left, axisStyle);
    xPainter.paint(
        canvas, firstSeriesCoords, AxisPosition.bottom, axisStyle);

    // Extra right-side y axes.
    for (var i = 1; i < core.yAxes.length; i++) {
      final spec = core.yAxes[i];
      final coords = CoordinateSystem(
        x: LinearScale(core.xViewport.xMin, core.xViewport.xMax),
        y: LinearScale(core.yWindow(spec.id).min, core.yWindow(spec.id).max),
        plot: plot,
      );
      yPainter.paint(canvas, coords, AxisPosition.right, axisStyle);
    }

    // Series — re-use the cached Picture if the viewport only translated.
    final cached = pictureCache.tryReplay(canvas, plot, core);
    if (!cached) {
      final recorder = ui.PictureRecorder();
      final pictureCanvas = Canvas(recorder, plot);
      final visibleTotal = _visiblePointCount(core);
      final mode = visibleTotal > kHighDensityThreshold
          ? RenderMode.highDensity
          : RenderMode.uiRich;

      pictureCanvas.save();
      pictureCanvas.clipRect(plot);
      for (final s in core.series) {
        final coords = core.coordsFor(s, plot);
        s.paint(pictureCanvas, coords, mode);
      }
      pictureCanvas.restore();
      final picture = recorder.endRecording();
      canvas.drawPicture(picture);
      pictureCache.store(picture, plot, core);
    }
  }

  /// Rough size of what is on screen, used only to pick the render mode.
  ///
  /// This used to call `rangeIndices` on every series, which binary-searches
  /// and asserts `xSorted`. That made a legitimately unsorted buffer — a
  /// horizontal bar chart, where x is the *value* and the category is y —
  /// throw on every paint in debug, from a heuristic that does not even need
  /// an exact answer. An unsorted buffer is now counted the honest way: the
  /// whole thing, since none of it can be culled.
  int _visiblePointCount(PinealCore core) {
    var total = 0;
    for (final s in core.series) {
      if (!s.data.xSorted) {
        total += s.data.length;
        continue;
      }
      final r = s.index.rangeIndices(core.xViewport.xMin, core.xViewport.xMax);
      total += r.end - r.start;
    }
    return total;
  }

  @override
  bool shouldRepaint(covariant ChartPainter old) {
    return old.core != core ||
        old.padding != padding ||
        old.axisStyle != axisStyle;
  }
}

/// Caches a recorded [ui.Picture] of the series layer so that pure pans can
/// replay it (optionally translated). Invalidated on zoom or resize.
class PictureCache {
  ui.Picture? _picture;
  double _xMin = 0, _xMax = 0;
  double _yMin = 0, _yMax = 0;
  Rect _plot = Rect.zero;
  int _seriesHash = 0;

  bool tryReplay(Canvas canvas, Rect plot, PinealCore core) {
    if (_picture == null) return false;
    if (_plot != plot) return false;
    if (_seriesHash != _hashSeries(core)) return false;

    final spanX = (core.xViewport.xMax - core.xViewport.xMin);
    final spanOld = _xMax - _xMin;
    if ((spanX - spanOld).abs() > spanOld * 1e-6) return false;

    final firstAxis = core.yAxes.first;
    final yw = core.yWindow(firstAxis.id);
    final ySpanOld = _yMax - _yMin;
    final ySpan = yw.max - yw.min;
    if ((ySpan - ySpanOld).abs() > ySpanOld * 1e-6) return false;

    // Pan-only: translate the cached picture by the pixel delta. We clip
    // on the *outer* canvas to the plot rect before translating — otherwise
    // the picture's own clip translates along with it and content spills
    // past the plot edge into the rest of the widget.
    final dxFrac = (core.xViewport.xMin - _xMin) / spanOld;
    final dyFrac = (yw.min - _yMin) / ySpanOld;
    final dx = -dxFrac * plot.width;
    final dy = dyFrac * plot.height;
    canvas.save();
    canvas.clipRect(plot);
    canvas.translate(dx, dy);
    canvas.drawPicture(_picture!);
    canvas.restore();
    return true;
  }

  void store(ui.Picture picture, Rect plot, PinealCore core) {
    _picture?.dispose();
    _picture = picture;
    _plot = plot;
    _xMin = core.xViewport.xMin;
    _xMax = core.xViewport.xMax;
    final yw = core.yWindow(core.yAxes.first.id);
    _yMin = yw.min;
    _yMax = yw.max;
    _seriesHash = _hashSeries(core);
  }

  void invalidate() {
    _picture?.dispose();
    _picture = null;
  }

  int _hashSeries(PinealCore core) {
    var h = core.series.length;
    for (final s in core.series) {
      h = Object.hash(
        h,
        s.id,
        s.data.length,
        s.data.revision,
        identityHashCode(s.data.raw),
      );
    }
    return h;
  }
}

