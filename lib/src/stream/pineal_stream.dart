import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'stream_buffer.dart';
import 'stream_downsample.dart';

/// How a [PinealStream] visualises an active [StreamBuffer].
enum StreamMode {
  /// Oscilloscope sweep: the write head advances rightward and overwrites
  /// the previous trace in place. The "cursor gap" makes it obvious where
  /// the next sample will land.
  sweep,

  /// Continuous horizontal scroll: the trace moves left as new samples
  /// arrive at the right edge. Useful when you want chronological
  /// continuity over many cycles.
  scroll,
}

class StreamStyle {
  const StreamStyle({
    this.color = const Color(0xFF66BB6A),
    this.lineWidth = 1.2,
    this.background,
    this.showCursor = true,
    this.cursorColor = const Color(0x88FFCA28),
    this.gridColor = const Color(0x22FFFFFF),
    this.gridRows = 4,
  });

  final Color color;
  final double lineWidth;
  final Color? background;

  /// In sweep mode, draws a thin vertical line at the write head.
  final bool showCursor;
  final Color cursorColor;

  /// Faint horizontal grid lines. `0` disables.
  final Color gridColor;
  final int gridRows;
}

/// Oscilloscope-style widget rendering a live [StreamBuffer].
///
/// Repaints every frame via a [Ticker]; the painter walks the buffer's
/// internal interleaved coord array and emits two `drawRawPoints` calls
/// (one per ring half) — no per-frame allocation, no value→pixel copy.
/// At 120 FPS this means roughly 240 draw calls per second total,
/// regardless of how many samples enter the buffer in between.
class PinealStream extends StatefulWidget {
  const PinealStream({
    super.key,
    required this.buffer,
    required this.yMin,
    required this.yMax,
    this.mode = StreamMode.sweep,
    this.style = const StreamStyle(),
    this.padding = const EdgeInsets.all(8),
    this.downsample,
  });

  final StreamBuffer buffer;
  final double yMin;
  final double yMax;
  final StreamMode mode;
  final StreamStyle style;
  final EdgeInsets padding;

  /// When non-null, enables incremental min/max envelope rendering with
  /// one envelope segment per *N* pixel columns (where `N = 1` by default).
  /// Recommended when the buffer is much denser than the viewport (say,
  /// >4× samples per pixel). Only honoured in [StreamMode.sweep] — scroll
  /// mode uses the raw trace because column ownership shifts every frame.
  final bool? downsample;

  @override
  State<PinealStream> createState() => _PinealStreamState();
}

class _PinealStreamState extends State<PinealStream>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final ValueNotifier<int> _frame = ValueNotifier<int>(0);
  final StreamDownsampleCache _downsampleCache = StreamDownsampleCache();

  /// Single matrix pool reused across frames and across segments — the
  /// painter only overwrites the 4 cells that vary (sx, sy, tx, ty).
  final Float64List _matrixPool = Float64List(16)
    ..[10] = 1
    ..[15] = 1;

  int _lastRevision = -1;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
  }

  void _onTick(Duration _) {
    final r = widget.buffer.revision;
    if (r == _lastRevision) return;
    _lastRevision = r;
    _frame.value++;
  }

  @override
  void dispose() {
    _ticker.dispose();
    _frame.dispose();
    super.dispose();
  }

  bool get _useDownsample {
    if (widget.downsample != null) return widget.downsample!;
    // Auto: enable when the buffer is much denser than a typical viewport.
    return widget.buffer.capacity > 4000;
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: widget.padding,
      child: RepaintBoundary(
        child: CustomPaint(
          painter: _StreamPainter(
            buffer: widget.buffer,
            mode: widget.mode,
            yMin: widget.yMin,
            yMax: widget.yMax,
            style: widget.style,
            matrixPool: _matrixPool,
            repaint: _frame,
            downsampleCache: _useDownsample ? _downsampleCache : null,
          ),
          size: Size.infinite,
        ),
      ),
    );
  }
}

class _StreamPainter extends CustomPainter {
  _StreamPainter({
    required this.buffer,
    required this.mode,
    required this.yMin,
    required this.yMax,
    required this.style,
    required this.matrixPool,
    required Listenable repaint,
    this.downsampleCache,
  }) : super(repaint: repaint);

  final StreamBuffer buffer;
  final StreamMode mode;
  final double yMin;
  final double yMax;
  final StreamStyle style;
  final StreamDownsampleCache? downsampleCache;

  /// Pre-allocated 4×4 matrix held by the State, reused per frame so the
  /// painter doesn't churn a `Float64List(16)` on every draw call.
  final Float64List matrixPool;

  @override
  void paint(Canvas canvas, Size size) {
    final ySpan = yMax - yMin;
    if (ySpan <= 0 || size.width <= 0 || size.height <= 0) return;

    final w = size.width;
    final h = size.height;
    if (style.background != null) {
      canvas.drawRect(Offset.zero & size, Paint()..color = style.background!);
    }
    _drawGrid(canvas, w, h);

    final scaleY = -h / ySpan;
    final ty = h + yMin * (h / ySpan);
    final capacity = buffer.capacity;
    final head = buffer.head;
    final paint = Paint()
      ..color = style.color
      ..strokeWidth = style.lineWidth
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;

    switch (mode) {
      case StreamMode.sweep:
        if (downsampleCache != null) {
          _drawDownsampled(canvas, w, h, paint, scroll: false);
        } else {
          _drawSweep(canvas, w, scaleY, ty, capacity, head, paint);
        }
        if (style.showCursor) {
          _drawCursor(canvas, w, h, head, capacity);
        }
        break;
      case StreamMode.scroll:
        if (downsampleCache != null) {
          _drawDownsampled(canvas, w, h, paint, scroll: true);
        } else {
          _drawScroll(canvas, w, scaleY, ty, capacity, head, paint);
        }
        break;
    }
  }

  /// Envelope path. The cache picks between the incremental sweep path
  /// and the bounded scroll pass internally.
  void _drawDownsampled(Canvas canvas, double w, double h, Paint paint,
      {required bool scroll}) {
    final cols = w.clamp(2.0, 8192.0).floor();
    final coords = scroll
        ? downsampleCache!.updateScroll(
            buffer,
            pixelColumns: cols,
            pixelWidth: w,
            pixelHeight: h,
            yMin: yMin,
            yMax: yMax,
          )
        : downsampleCache!.updateSweep(
            buffer,
            pixelColumns: cols,
            pixelWidth: w,
            pixelHeight: h,
            yMin: yMin,
            yMax: yMax,
          );
    canvas.drawRawPoints(PointMode.lines, coords, paint);
  }

  void _drawGrid(Canvas canvas, double w, double h) {
    if (style.gridRows < 1) return;
    final paint = Paint()
      ..color = style.gridColor
      ..strokeWidth = 0.5;
    for (var i = 1; i < style.gridRows; i++) {
      final y = i / style.gridRows * h;
      canvas.drawLine(Offset(0, y), Offset(w, y), paint);
    }
  }

  /// Sweep: scale matrix maps the buffer's stored coords to pixels
  /// directly. Two segments separated at `head` give the natural cursor
  /// gap of a CRT-style oscilloscope.
  void _drawSweep(Canvas canvas, double w, double scaleY, double ty,
      int capacity, int head, Paint paint) {
    canvas.save();
    canvas.transform(_matrix(w, scaleY, 0, ty));
    final isFull = buffer.count >= capacity;
    if (head >= 2) {
      final view = Float32List.sublistView(buffer.coords, 0, head * 2);
      canvas.drawRawPoints(PointMode.polygon, view, paint);
    }
    // Until the ring fills, slots [head, capacity) hold the initial zeros
    // — skip them so we don't draw a flat baseline across the screen.
    if (isFull && capacity - head >= 2) {
      final view =
          Float32List.sublistView(buffer.coords, head * 2, capacity * 2);
      canvas.drawRawPoints(PointMode.polygon, view, paint);
    }
    canvas.restore();
  }

  /// Scroll: translate the two halves of the ring so they stitch
  /// together as a single continuous left→right trace, with the newest
  /// sample at the right edge.
  void _drawScroll(Canvas canvas, double w, double scaleY, double ty,
      int capacity, int head, Paint paint) {
    final denom = (capacity - 1).toDouble();
    final isFull = buffer.count >= capacity;

    if (isFull) {
      final headFrac = head / denom;
      final secondFrac = (capacity - head) / denom;

      // Segment A: slots [head, capacity-1] → left half of screen.
      canvas.save();
      canvas.transform(_matrix(w, scaleY, -headFrac * w, ty));
      if (capacity - head >= 2) {
        final view =
            Float32List.sublistView(buffer.coords, head * 2, capacity * 2);
        canvas.drawRawPoints(PointMode.polygon, view, paint);
      }
      canvas.restore();

      // Segment B: slots [0, head-1] → right half of screen.
      canvas.save();
      canvas.transform(_matrix(w, scaleY, secondFrac * w, ty));
      if (head >= 2) {
        final view = Float32List.sublistView(buffer.coords, 0, head * 2);
        canvas.drawRawPoints(PointMode.polygon, view, paint);
      }
      canvas.restore();
      return;
    }

    // Pre-fill state: only slots [0, head) are real data. Scale them so
    // the partial trace lands at the right edge as it grows.
    if (head < 2) return;
    final partialFrac = head / denom;
    canvas.save();
    canvas.transform(_matrix(w, scaleY, (1 - partialFrac) * w, ty));
    final view = Float32List.sublistView(buffer.coords, 0, head * 2);
    canvas.drawRawPoints(PointMode.polygon, view, paint);
    canvas.restore();
  }

  void _drawCursor(Canvas canvas, double w, double h, int head, int capacity) {
    final x = head / (capacity - 1) * w;
    canvas.drawLine(
      Offset(x, 0),
      Offset(x, h),
      Paint()
        ..color = style.cursorColor
        ..strokeWidth = 1.0,
    );
  }

  /// Writes a column-major 4×4 affine into the shared [matrixPool] and
  /// returns the same list. No allocation.
  Float64List _matrix(double sx, double sy, double tx, double ty) {
    final m = matrixPool;
    // Zero only the cells that change; the constant cells are pre-set
    // once by the State during construction.
    m[0] = sx;
    m[5] = sy;
    m[12] = tx;
    m[13] = ty;
    return m;
  }

  @override
  bool shouldRepaint(covariant _StreamPainter old) =>
      old.buffer != buffer ||
      old.mode != mode ||
      old.yMin != yMin ||
      old.yMax != yMax ||
      old.style != style;
}
