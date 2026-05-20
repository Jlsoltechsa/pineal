import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../stream/stream_buffer.dart';

/// Visual configuration for an analog phosphor trail.
class PhosphorStyle {
  const PhosphorStyle({
    this.color = const Color(0xFF66BB6A),
    this.lineWidth = 1.4,
    this.trailFraction = 0.85,
    this.headBoost = 1.0,
    this.background,
  });

  /// Base trace color. The alpha channel is overwritten per-vertex by the
  /// fade function.
  final Color color;

  /// Trace thickness in pixels.
  final double lineWidth;

  /// Fraction of the buffer that participates in the fade. The tail
  /// `(1 - trailFraction)` is fully transparent. `1.0` fades evenly from
  /// the freshest sample to the oldest.
  final double trailFraction;

  /// Multiplier applied to the freshest sample's alpha. `> 1.0` gives a
  /// glow at the write head typical of phosphor CRTs.
  final double headBoost;

  /// Optional solid backdrop drawn before the trace.
  final Color? background;
}

/// Oscilloscope-style streaming widget with a true per-vertex phosphor
/// decay trail.
///
/// Each sample in the [StreamBuffer] expands into two vertices (top and
/// bottom of a thin stroke). The resulting triangle strip is fed straight
/// to `canvas.drawVertices` with a per-vertex color array — alpha falls
/// linearly with age, so the fade is continuous (no banding) and the
/// whole trail renders in just two draw calls per frame regardless of
/// buffer size.
class PhosphorStream extends StatefulWidget {
  const PhosphorStream({
    super.key,
    required this.buffer,
    required this.yMin,
    required this.yMax,
    this.style = const PhosphorStyle(),
    this.padding = const EdgeInsets.all(8),
  });

  final StreamBuffer buffer;
  final double yMin;
  final double yMax;
  final PhosphorStyle style;
  final EdgeInsets padding;

  @override
  State<PhosphorStream> createState() => _PhosphorStreamState();
}

class _PhosphorStreamState extends State<PhosphorStream>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final ValueNotifier<int> _frame = ValueNotifier<int>(0);
  int _lastRevision = -1;

  /// Pixel-space `[x, y, x, y, …]` — two vertices per sample (top/bottom
  /// of stroke). Allocated once per capacity, reused across frames.
  late Float32List _positions;

  /// Per-vertex ARGB ints. Two per sample, matching [_positions].
  late Int32List _colors;
  int _capacity = 0;

  @override
  void initState() {
    super.initState();
    _ensureBuffers(widget.buffer.capacity);
    _ticker = createTicker(_onTick)..start();
  }

  @override
  void didUpdateWidget(covariant PhosphorStream old) {
    super.didUpdateWidget(old);
    _ensureBuffers(widget.buffer.capacity);
  }

  void _ensureBuffers(int capacity) {
    if (capacity == _capacity) return;
    _capacity = capacity;
    _positions = Float32List(capacity * 4);
    _colors = Int32List(capacity * 2);
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

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: widget.padding,
      child: RepaintBoundary(
        child: CustomPaint(
          painter: _PhosphorPainter(
            buffer: widget.buffer,
            yMin: widget.yMin,
            yMax: widget.yMax,
            style: widget.style,
            positions: _positions,
            colors: _colors,
            repaint: _frame,
          ),
          size: Size.infinite,
        ),
      ),
    );
  }
}

class _PhosphorPainter extends CustomPainter {
  _PhosphorPainter({
    required this.buffer,
    required this.yMin,
    required this.yMax,
    required this.style,
    required this.positions,
    required this.colors,
    required Listenable repaint,
  }) : super(repaint: repaint);

  final StreamBuffer buffer;
  final double yMin;
  final double yMax;
  final PhosphorStyle style;
  final Float32List positions;
  final Int32List colors;

  static final _paint = Paint();

  @override
  void paint(Canvas canvas, Size size) {
    final ySpan = yMax - yMin;
    if (ySpan <= 0 || size.width <= 0 || size.height <= 0) return;

    if (style.background != null) {
      canvas.drawRect(Offset.zero & size, Paint()..color = style.background!);
    }

    final w = size.width;
    final h = size.height;
    final invSpan = h / ySpan;
    final capacity = buffer.capacity;
    final head = buffer.head;
    final halfW = style.lineWidth * 0.5;
    final rgb = style.color.toARGB32() & 0x00FFFFFF;
    final trailSamples =
        (capacity * style.trailFraction).ceil().clamp(2, capacity);
    final values = buffer.values;
    final invCapMinus1 = capacity > 1 ? 1.0 / (capacity - 1) : 0.0;
    final headSlot = head == 0 ? capacity - 1 : head - 1;

    for (var s = 0; s < capacity; s++) {
      final px = s * invCapMinus1 * w;
      final py = h - (values[s] - yMin) * invSpan;
      final base = s * 4;
      positions[base] = px;
      positions[base + 1] = py - halfW;
      positions[base + 2] = px;
      positions[base + 3] = py + halfW;

      // Age relative to the write head, wrapped into [0, capacity).
      var age = headSlot - s;
      if (age < 0) age += capacity;
      var fade = 1.0 - age / trailSamples;
      if (fade < 0) fade = 0;
      if (s == headSlot) {
        fade *= style.headBoost;
        if (fade > 1) fade = 1;
      }
      final alpha = (fade * 255).round() & 0xFF;
      final argb = (alpha << 24) | rgb;
      colors[s * 2] = argb;
      colors[s * 2 + 1] = argb;
    }

    // Two segments split at the head — the wraparound triangle that
    // would connect the freshest sample to the oldest is left out, like a
    // real CRT sweep. Before the buffer has filled, the [head, capacity)
    // half holds the unwritten initial zeros; rendering it would draw a
    // thick green bar across the screen, so we skip it until the ring is
    // full.
    final isFull = buffer.count >= capacity;
    if (isFull) {
      _drawSegment(canvas, head * 4, capacity * 4, head * 2, capacity * 2);
    }
    _drawSegment(canvas, 0, head * 4, 0, head * 2);
  }

  void _drawSegment(Canvas canvas, int pStart, int pEnd, int cStart, int cEnd) {
    if (pEnd - pStart < 8) return; // need at least 2 samples (4 vertices)
    final pos = Float32List.sublistView(positions, pStart, pEnd);
    final col = Int32List.sublistView(colors, cStart, cEnd);
    final v = Vertices.raw(VertexMode.triangleStrip, pos, colors: col);
    canvas.drawVertices(v, BlendMode.srcOver, _paint);
    v.dispose();
  }

  @override
  bool shouldRepaint(covariant _PhosphorPainter old) =>
      old.buffer != buffer ||
      old.yMin != yMin ||
      old.yMax != yMax ||
      old.style != style ||
      old.positions != positions ||
      old.colors != colors;
}
