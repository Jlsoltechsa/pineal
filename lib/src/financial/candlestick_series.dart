import 'dart:typed_data';
import 'dart:ui';

import '../data/data_buffer.dart';
import '../core/coordinate_system.dart';
import '../series/series.dart';
import 'ohlc_buffer.dart';
import 'ohlc_downsample.dart';

/// Renders a stream of OHLC bars as candlesticks inside [PinealChart].
///
/// Plugs into the cartesian engine — the chart's pan / zoom / inertia /
/// tooltip layers all work unchanged. When the visible range exceeds
/// [maxCandlesPerPixel] candles per pixel, the series aggregates them via
/// [OhlcDownsample] so volatility (the wicks) stays preserved even at
/// extreme zoom-out.
class CandlestickSeries extends Series {
  CandlestickSeries({
    required super.id,
    required this.ohlc,
    super.yAxisId,
    this.bullColor = const Color(0xFF26A69A),
    this.bearColor = const Color(0xFFEF5350),
    this.wickWidth = 1.0,
    this.bodyWidthFactor = 0.7,
    this.maxCandlesPerPixel = 0.5,
  }) : super(data: _indexBufferFor(ohlc));

  final OhlcBuffer ohlc;
  final Color bullColor;
  final Color bearColor;
  final double wickWidth;
  final double bodyWidthFactor;

  /// Above this density (candles per logical pixel) the series aggregates
  /// before drawing. Default 0.5 keeps each rendered candle at least 2px
  /// wide on screen.
  final double maxCandlesPerPixel;

  static DataBuffer _indexBufferFor(OhlcBuffer ohlc) {
    final flat = Float32List(ohlc.length * 2);
    for (var i = 0; i < ohlc.length; i++) {
      flat[i * 2] = ohlc.t(i);
      flat[i * 2 + 1] = ohlc.close(i);
    }
    return DataBuffer.fromInterleaved(flat);
  }

  @override
  void paint(Canvas canvas, CoordinateSystem coords, RenderMode mode) {
    if (ohlc.length == 0) return;

    final startIdx = ohlc.lowerBound(coords.x.domainMin);
    final endIdx = ohlc.lowerBound(coords.x.domainMax);
    final hi = (endIdx + 1).clamp(0, ohlc.length);
    final lo = startIdx.clamp(0, ohlc.length);
    final visible = hi - lo;
    if (visible <= 0) return;

    final targetCount =
        (coords.plot.width * maxCandlesPerPixel).floor().clamp(2, 1 << 20);
    final source = visible > targetCount
        ? OhlcDownsample.aggregate(ohlc, lo, hi, target: targetCount)
        : _slice(ohlc, lo, hi);

    final spacing = source.length > 1
        ? (source.t(1) - source.t(0)).abs()
        : 1.0;
    final pxPerUnit =
        coords.plot.width / (coords.x.domainMax - coords.x.domainMin);
    final bodyWidthPx =
        (spacing * pxPerUnit * bodyWidthFactor).clamp(1.0, 64.0);

    // Batched render: one Float32List per group (bull/bear) for wicks
    // (line segments) and one triangle list per group for bodies. Result:
    // 4 draw calls regardless of candle count.
    var bullCount = 0;
    for (var i = 0; i < source.length; i++) {
      if (source.close(i) >= source.open(i)) bullCount++;
    }
    final bearCount = source.length - bullCount;

    final bullWicks = Float32List(bullCount * 4);
    final bearWicks = Float32List(bearCount * 4);
    final bullBodies = Float32List(bullCount * 12);
    final bearBodies = Float32List(bearCount * 12);
    var bwW = 0, bwB = 0, bbW = 0, bbB = 0;

    for (var i = 0; i < source.length; i++) {
      final t = source.t(i);
      final o = source.open(i);
      final h = source.high(i);
      final l = source.low(i);
      final c = source.close(i);
      final bull = c >= o;

      final centerX = coords.project(t, o).dx;
      final hiPx = coords.project(t, h).dy;
      final loPx = coords.project(t, l).dy;
      final openPx = coords.project(t, o).dy;
      final closePx = coords.project(t, c).dy;
      final left = centerX - bodyWidthPx * 0.5;
      final right = centerX + bodyWidthPx * 0.5;
      final top = openPx < closePx ? openPx : closePx;
      var bottom = openPx < closePx ? closePx : openPx;
      if (bottom - top < 1) bottom = top + 1;

      if (bull) {
        bullWicks[bwW++] = centerX;
        bullWicks[bwW++] = hiPx;
        bullWicks[bwW++] = centerX;
        bullWicks[bwW++] = loPx;
        // Two triangles for the body rect.
        bullBodies[bwB++] = left;  bullBodies[bwB++] = top;
        bullBodies[bwB++] = right; bullBodies[bwB++] = top;
        bullBodies[bwB++] = left;  bullBodies[bwB++] = bottom;
        bullBodies[bwB++] = right; bullBodies[bwB++] = top;
        bullBodies[bwB++] = right; bullBodies[bwB++] = bottom;
        bullBodies[bwB++] = left;  bullBodies[bwB++] = bottom;
      } else {
        bearWicks[bbW++] = centerX;
        bearWicks[bbW++] = hiPx;
        bearWicks[bbW++] = centerX;
        bearWicks[bbW++] = loPx;
        bearBodies[bbB++] = left;  bearBodies[bbB++] = top;
        bearBodies[bbB++] = right; bearBodies[bbB++] = top;
        bearBodies[bbB++] = left;  bearBodies[bbB++] = bottom;
        bearBodies[bbB++] = right; bearBodies[bbB++] = top;
        bearBodies[bbB++] = right; bearBodies[bbB++] = bottom;
        bearBodies[bbB++] = left;  bearBodies[bbB++] = bottom;
      }
    }

    final aa = mode == RenderMode.uiRich;

    void drawGroup(Color color, Float32List wicks, Float32List bodies) {
      if (bodies.isNotEmpty) {
        final v = Vertices.raw(VertexMode.triangles, bodies);
        canvas.drawVertices(
            v, BlendMode.srcOver, Paint()..color = color..isAntiAlias = aa);
        v.dispose();
      }
      if (wicks.isNotEmpty) {
        canvas.drawRawPoints(
            PointMode.lines,
            wicks,
            Paint()
              ..color = color
              ..strokeWidth = wickWidth
              ..isAntiAlias = aa);
      }
    }

    drawGroup(bullColor, bullWicks, bullBodies);
    drawGroup(bearColor, bearWicks, bearBodies);
  }

  static OhlcBuffer _slice(OhlcBuffer src, int start, int end) {
    final n = end - start;
    final slice = Float32List(n * 6);
    slice.setRange(0, n * 6, src.raw, start * 6);
    return OhlcBuffer.fromInterleaved(slice);
  }
}
