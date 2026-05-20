import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';

import '../painters/text_cache.dart';
import 'gantt_buffer.dart';

/// Visible time window in epoch microseconds. Mutating either bound notifies
/// listeners — the [RenderGantt] subscribes via `markNeedsPaint`.
class GanttViewport extends ChangeNotifier {
  GanttViewport({required double tMin, required double tMax})
      : _tMin = tMin,
        _tMax = tMax;

  double _tMin;
  double _tMax;

  double get tMin => _tMin;
  double get tMax => _tMax;
  double get span => _tMax - _tMin;

  /// Pan by a fraction of the current span. `+0.1` shifts 10% to the right
  /// (forward in time).
  void pan(double frac) {
    final dx = frac * span;
    _tMin += dx;
    _tMax += dx;
    notifyListeners();
  }

  void zoom(double factor, {double anchorFrac = 0.5}) {
    final anchorT = _tMin + anchorFrac * span;
    _tMin = anchorT + (_tMin - anchorT) * factor;
    _tMax = anchorT + (_tMax - anchorT) * factor;
    notifyListeners();
  }

  void setWindow(double tMin, double tMax) {
    _tMin = tMin;
    _tMax = tMax;
    notifyListeners();
  }
}

/// Resolves visual properties for a task. Implementations should be `O(1)`
/// — this gets called once per visible task per paint.
typedef GanttTaskStyleOf = GanttTaskStyle Function(int taskIndex);

class GanttTaskStyle {
  const GanttTaskStyle({
    required this.fill,
    this.borderColor,
    this.label = '',
  });

  final Color fill;
  final Color? borderColor;
  final String label;
}

/// Virtual-scroll RenderBox for a Gantt chart.
///
/// The time axis is "infinite" in the sense that nothing about the
/// `RenderBox` size depends on the dataset — viewport translation pans the
/// camera through time, the painter only touches tasks whose `[t1, t2]`
/// interval intersects the current window. Lane axis can scroll vertically
/// inside the box just like a `ListView`.
///
/// Hit-testing routes through the [SlotIndex] too: a tap is converted to
/// `(t, lane)` and we fire a single bucket query — no per-bar `GestureDetector`
/// in the widget tree, so a 100K-task dataset still hits at constant cost.
class RenderGantt extends RenderBox {
  RenderGantt({
    required TaskBuffer tasks,
    required SlotIndex slotIndex,
    required GanttViewport viewport,
    required GanttTaskStyleOf styleOf,
    required TextCache textCache,
    double laneHeight = 28,
    double laneScrollY = 0,
    Color background = const Color(0xFFFFFFFF),
    Color gridLine = const Color(0xFFE0E0E0),
    void Function(int taskIndex)? onTap,
  })  : _tasks = tasks,
        _slotIndex = slotIndex,
        _viewport = viewport,
        _styleOf = styleOf,
        _textCache = textCache,
        _laneHeight = laneHeight,
        _laneScrollY = laneScrollY,
        _background = background,
        _gridLine = gridLine,
        _onTap = onTap {
    // Viewport listener is added on attach() so it pairs cleanly with
    // detach() — adding here too would leak a second subscription that
    // detach can't undo.
    _ensureSeenBuffer();
  }

  TaskBuffer _tasks;
  SlotIndex _slotIndex;
  GanttViewport _viewport;
  GanttTaskStyleOf _styleOf;
  final TextCache _textCache;
  double _laneHeight;
  double _laneScrollY;
  Color _background;
  Color _gridLine;
  void Function(int)? _onTap;

  Uint8List _seen = Uint8List(0);
  final List<int> _visible = <int>[];

  // ─── Setters used by the host widget on rebuild ─────────────────────────

  set tasks(TaskBuffer v) {
    if (identical(v, _tasks)) return;
    _tasks = v;
    _ensureSeenBuffer();
    markNeedsPaint();
  }

  set slotIndex(SlotIndex v) {
    if (identical(v, _slotIndex)) return;
    _slotIndex = v;
    markNeedsPaint();
  }

  set viewport(GanttViewport v) {
    if (identical(v, _viewport)) return;
    if (attached) _viewport.removeListener(markNeedsPaint);
    _viewport = v;
    if (attached) _viewport.addListener(markNeedsPaint);
    markNeedsPaint();
  }

  set styleOf(GanttTaskStyleOf v) {
    if (v == _styleOf) return;
    _styleOf = v;
    markNeedsPaint();
  }

  set laneHeight(double v) {
    if (v == _laneHeight) return;
    _laneHeight = v;
    markNeedsPaint();
  }

  set laneScrollY(double v) {
    if (v == _laneScrollY) return;
    _laneScrollY = v;
    markNeedsPaint();
  }

  set background(Color v) {
    if (v == _background) return;
    _background = v;
    markNeedsPaint();
  }

  set gridLine(Color v) {
    if (v == _gridLine) return;
    _gridLine = v;
    markNeedsPaint();
  }

  set onTap(void Function(int)? v) => _onTap = v;

  void _ensureSeenBuffer() {
    if (_seen.length < _tasks.length) {
      _seen = Uint8List(_tasks.length);
    }
  }

  @override
  void detach() {
    _viewport.removeListener(markNeedsPaint);
    super.detach();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _viewport.addListener(markNeedsPaint);
  }

  @override
  void performLayout() {
    size = constraints.biggest;
  }

  @override
  bool hitTestSelf(Offset position) => true;

  @override
  void handleEvent(PointerEvent event, BoxHitTestEntry entry) {
    if (event is! PointerUpEvent || _onTap == null) return;
    final hit = _hitAt(event.localPosition);
    if (hit >= 0) _onTap!(hit);
  }

  // ─── Painting ─────────────────────────────────────────────────────────────

  @override
  void paint(PaintingContext context, Offset offset) {
    final canvas = context.canvas;
    final rect = offset & size;
    canvas.save();
    canvas.clipRect(rect);
    final bgPaint = Paint()..color = _background;
    canvas.drawRect(rect, bgPaint);

    final span = _viewport.span;
    if (span <= 0) {
      canvas.restore();
      return;
    }

    // 1. Slot-driven cull → only the tasks whose interval intersects the
    //    visible window survive. Allocation-free across frames because
    //    `_visible` and `_seen` are reused.
    _visible.clear();
    _slotIndex.query(
      tMin: _viewport.tMin,
      tMax: _viewport.tMax,
      seen: _seen,
      out: _visible,
    );

    // 2. Time → pixel mapping. Cache the conversion factor so the inner
    //    loop is a multiply + add.
    final pxPerMicro = size.width / span;
    final firstVisibleLane = (_laneScrollY / _laneHeight).floor();
    final lastVisibleLane =
        ((_laneScrollY + size.height) / _laneHeight).ceil();

    // 3. Lane gridlines — a single drawRawPoints(Lines) for the entire
    //    visible band, regardless of how many lanes there are.
    final gridSegs = Float32List((lastVisibleLane - firstVisibleLane + 1) * 4);
    var go = 0;
    final gridPaint = Paint()
      ..color = _gridLine
      ..strokeWidth = 1.0;
    for (var l = firstVisibleLane; l <= lastVisibleLane; l++) {
      final y = offset.dy + l * _laneHeight - _laneScrollY;
      gridSegs[go++] = offset.dx;
      gridSegs[go++] = y;
      gridSegs[go++] = offset.dx + size.width;
      gridSegs[go++] = y;
    }
    canvas.drawRawPoints(ui.PointMode.lines, gridSegs, gridPaint);

    // 4. Bars — one rect per visible task. We bypass Path entirely;
    //    drawRect is cheap and Skia handles batching for us.
    final barPaint = Paint();
    final borderPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;

    for (final taskIdx in _visible) {
      final lane = _tasks.lane(taskIdx);
      if (lane < firstVisibleLane || lane > lastVisibleLane) continue;
      final t1 = _tasks.t1(taskIdx);
      final t2 = _tasks.t2(taskIdx);
      // Clip to viewport at the data level so bars that start before the
      // window or end after it still render their visible chunk.
      final aT = t1 < _viewport.tMin ? _viewport.tMin : t1;
      final bT = t2 > _viewport.tMax ? _viewport.tMax : t2;
      if (bT <= aT) continue;
      final x = offset.dx + (aT - _viewport.tMin) * pxPerMicro;
      final w = (bT - aT) * pxPerMicro;
      final y = offset.dy + lane * _laneHeight - _laneScrollY + 4;
      final h = _laneHeight - 8;
      final bar = Rect.fromLTWH(x, y, w, h);

      final style = _styleOf(taskIdx);
      barPaint.color = style.fill;
      canvas.drawRect(bar, barPaint);
      if (style.borderColor != null) {
        borderPaint.color = style.borderColor!;
        canvas.drawRect(bar, borderPaint);
      }

      // 5. Label — only if there's room and a string. Routed through the
      //    shared TextCache so a 1000-task viewport runs `Paragraph.layout`
      //    once per unique label, not 1000 times per frame.
      if (style.label.isNotEmpty && w > 24) {
        final p = _textCache.paragraph(
          style.label,
          fontSize: 11,
          color: const Color(0xFF222222),
          maxWidth: (w - 6).clamp(1, double.infinity),
        );
        canvas.drawParagraph(p, Offset(x + 4, y + (h - p.height) / 2));
      }
    }

    canvas.restore();
  }

  // ─── Hit-test ─────────────────────────────────────────────────────────────

  int _hitAt(Offset local) {
    if (size.width <= 0 || size.height <= 0) return -1;
    final span = _viewport.span;
    if (span <= 0) return -1;
    final pxPerMicro = size.width / span;
    final t = _viewport.tMin + local.dx / pxPerMicro;
    final lane = ((local.dy + _laneScrollY) / _laneHeight).floor();

    // One-slot query at `t` is enough — we want a tight time window.
    _visible.clear();
    _slotIndex.query(
      tMin: t,
      tMax: t,
      seen: _seen,
      out: _visible,
    );
    // Linear refine inside the bucket.
    for (final taskIdx in _visible) {
      if (_tasks.lane(taskIdx) != lane) continue;
      final t1 = _tasks.t1(taskIdx);
      final t2 = _tasks.t2(taskIdx);
      if (t >= t1 && t <= t2) return taskIdx;
    }
    return -1;
  }
}
