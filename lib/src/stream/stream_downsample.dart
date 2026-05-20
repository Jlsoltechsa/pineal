import 'dart:typed_data';

import 'stream_buffer.dart';

/// Incremental min/max-per-pixel-column envelope of a [StreamBuffer].
///
/// Maintains a `pixelColumns × (min, max)` table plus a render-ready
/// `Float32List` of vertical envelope segments. Each frame:
///
/// 1. Determine which columns have had at least one slot touched since the
///    previous update.
/// 2. Recompute `(min, max)` over those columns' slot ranges only.
/// 3. Update the matching segments in the render buffer.
///
/// Work per frame is bounded by *samples written that frame*, not by
/// buffer capacity — which is what makes 100 KHz feeds sustainable.
class StreamDownsampleCache {
  StreamDownsampleCache();

  // Per-column min/max state.
  Float32List? _columnMinMax;

  /// Render-ready interleaved coords `[x, y_min, x, y_max, ...]` per column,
  /// in *pixel* space. Pass directly to `drawRawPoints(PointMode.lines)`.
  Float32List? renderCoords;

  int _lastCount = 0;
  int _columns = 0;
  int _capacity = 0;
  double _yMin = 0;
  double _yMax = 1;
  double _height = 0;

  int get columns => _columns;

  /// Sweep-mode update — work proportional to new samples since the last
  /// frame, not buffer capacity. Returns the render-ready coord buffer.
  Float32List updateSweep(
    StreamBuffer buffer, {
    required int pixelColumns,
    required double pixelWidth,
    required double pixelHeight,
    required double yMin,
    required double yMax,
  }) {
    final reset = _columnMinMax == null ||
        _columns != pixelColumns ||
        _capacity != buffer.capacity ||
        _yMin != yMin ||
        _yMax != yMax ||
        _height != pixelHeight;

    if (reset) {
      _columns = pixelColumns.clamp(1, 1 << 20);
      _capacity = buffer.capacity;
      _yMin = yMin;
      _yMax = yMax;
      _height = pixelHeight;
      _columnMinMax = Float32List(_columns * 2);
      renderCoords = Float32List(_columns * 4);
      _initX(pixelWidth);
      _fullScan(buffer);
      _lastCount = buffer.count;
      return renderCoords!;
    }

    final newCount = buffer.count;
    if (newCount == _lastCount) return renderCoords!;
    _incrementalUpdate(buffer, _lastCount, newCount);
    _lastCount = newCount;
    return renderCoords!;
  }

  /// Scroll-mode update. Column ownership shifts every frame as the
  /// visible window slides, so the cache does a single bounded pass
  /// over the ring in age order (oldest → newest) instead of trying to
  /// be incremental. Cost is O(capacity) per frame — at 100 K capacity
  /// and 120 FPS that's ~12 M ops/s, well inside a frame budget.
  Float32List updateScroll(
    StreamBuffer buffer, {
    required int pixelColumns,
    required double pixelWidth,
    required double pixelHeight,
    required double yMin,
    required double yMax,
  }) {
    final reset = _columnMinMax == null ||
        _columns != pixelColumns ||
        _capacity != buffer.capacity ||
        _height != pixelHeight;

    if (reset) {
      _columns = pixelColumns.clamp(1, 1 << 20);
      _capacity = buffer.capacity;
      _yMin = yMin;
      _yMax = yMax;
      _height = pixelHeight;
      _columnMinMax = Float32List(_columns * 2);
      renderCoords = Float32List(_columns * 4);
      _initX(pixelWidth);
    }
    _yMin = yMin;
    _yMax = yMax;

    final cols = _columns;
    final cap = buffer.capacity;
    final head = buffer.head;
    final values = buffer.values;
    final state = _columnMinMax!;
    final coords = renderCoords!;
    final ySpan = yMax - yMin;
    if (ySpan <= 0) return coords;

    // Reset column state.
    for (var c = 0; c < cols; c++) {
      state[c * 2] = double.infinity;
      state[c * 2 + 1] = double.negativeInfinity;
    }

    // Before the ring fills, only the first `count` slots have real data;
    // align them to the right edge so the trace flows in from the right
    // (matches the partial-state behaviour of the raw renderer).
    final visibleCount = buffer.count < cap ? buffer.count : cap;
    if (visibleCount == 0) {
      for (var c = 0; c < cols; c++) {
        _setColumnEmpty(c);
      }
      _lastCount = buffer.count;
      return coords;
    }
    final colsUsed = ((visibleCount * cols) ~/ cap).clamp(1, cols);
    final colStart = cols - colsUsed;
    final slotStart = buffer.count < cap ? 0 : head;

    for (var i = 0; i < visibleCount; i++) {
      final slot = (slotStart + i) % cap;
      var c = colStart + (i * colsUsed) ~/ visibleCount;
      if (c >= cols) c = cols - 1;
      final v = values[slot];
      if (!v.isFinite) continue;
      if (v < state[c * 2]) state[c * 2] = v;
      if (v > state[c * 2 + 1]) state[c * 2 + 1] = v;
    }

    // Project to pixel coords. Empty columns get degenerate segments.
    final invSpan = _height / ySpan;
    for (var c = 0; c < cols; c++) {
      final mn = state[c * 2];
      if (mn == double.infinity) {
        _setColumnEmpty(c);
        continue;
      }
      final mx = state[c * 2 + 1];
      coords[c * 4 + 1] = _height - (mn - yMin) * invSpan;
      coords[c * 4 + 3] = _height - (mx - yMin) * invSpan;
    }
    _lastCount = buffer.count;
    return coords;
  }

  void _initX(double pixelWidth) {
    final coords = renderCoords!;
    final step = _columns > 1 ? pixelWidth / (_columns - 1) : 0.0;
    for (var c = 0; c < _columns; c++) {
      final x = c * step;
      coords[c * 4] = x;
      coords[c * 4 + 2] = x;
    }
  }

  void _fullScan(StreamBuffer buffer) {
    final state = _columnMinMax!;
    for (var c = 0; c < _columns; c++) {
      state[c * 2] = double.infinity;
      state[c * 2 + 1] = double.negativeInfinity;
    }
    for (var c = 0; c < _columns; c++) {
      _recomputeColumn(buffer, c);
    }
  }

  void _incrementalUpdate(StreamBuffer buffer, int from, int to) {
    final capacity = buffer.capacity;
    final diff = to - from;
    if (diff >= capacity) {
      _fullScan(buffer);
      return;
    }
    // Which columns own a slot that was written in the [from, to) range?
    final firstSlot = from % capacity;
    final lastSlot = (to - 1) % capacity;
    final firstCol = _columnOf(firstSlot);
    final lastCol = _columnOf(lastSlot);
    if (firstSlot <= lastSlot) {
      for (var c = firstCol; c <= lastCol; c++) {
        _recomputeColumn(buffer, c);
      }
    } else {
      // Wrap-around: cover both halves.
      for (var c = firstCol; c < _columns; c++) {
        _recomputeColumn(buffer, c);
      }
      for (var c = 0; c <= lastCol; c++) {
        _recomputeColumn(buffer, c);
      }
    }
  }

  int _columnOf(int slot) {
    if (_columns <= 1) return 0;
    final c = (slot * _columns) ~/ _capacity;
    return c >= _columns ? _columns - 1 : c;
  }

  void _recomputeColumn(StreamBuffer buffer, int column) {
    final state = _columnMinMax!;
    final coords = renderCoords!;
    final slotStart = (column * _capacity) ~/ _columns;
    final slotEnd = column == _columns - 1
        ? _capacity
        : ((column + 1) * _capacity) ~/ _columns;

    // Before the ring fills, only slots [0, head) hold real data — clip
    // the scan range so we don't fold the initial zeros into the envelope.
    final isFull = buffer.count >= _capacity;
    final effEnd = isFull ? slotEnd : (slotEnd <= buffer.head ? slotEnd : buffer.head);
    final effStart = isFull ? slotStart : (slotStart >= buffer.head ? buffer.head : slotStart);
    if (effEnd <= effStart) {
      _setColumnEmpty(column);
      return;
    }

    var mn = double.infinity;
    var mx = double.negativeInfinity;
    for (var s = effStart; s < effEnd; s++) {
      final v = buffer.values[s];
      if (!v.isFinite) continue;
      if (v < mn) mn = v;
      if (v > mx) mx = v;
    }
    if (mn == double.infinity) {
      _setColumnEmpty(column);
      return;
    }
    state[column * 2] = mn;
    state[column * 2 + 1] = mx;
    final ySpan = _yMax - _yMin;
    if (ySpan <= 0) return;
    final yMinPx = _height - (mn - _yMin) / ySpan * _height;
    final yMaxPx = _height - (mx - _yMin) / ySpan * _height;
    coords[column * 4 + 1] = yMinPx;
    coords[column * 4 + 3] = yMaxPx;
  }

  /// Collapses a column's envelope to a degenerate zero-length segment so
  /// `drawRawPoints(lines)` doesn't paint anything for it.
  void _setColumnEmpty(int column) {
    final state = _columnMinMax!;
    final coords = renderCoords!;
    state[column * 2] = 0;
    state[column * 2 + 1] = 0;
    // Coincident top + bottom Y → invisible.
    coords[column * 4 + 1] = -10;
    coords[column * 4 + 3] = -10;
  }
}
