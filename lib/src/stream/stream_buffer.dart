import 'dart:typed_data';

/// Circular ring buffer of single-channel samples, backed by a pre-allocated
/// `Float32List`.
///
/// The buffer stores two parallel views:
/// 1. [values] — `Float32List(capacity)`: just the raw values, useful for
///    analyzers / FFT pipelines that want a flat column.
/// 2. [coords] — `Float32List(capacity * 2)`: `[x_norm, y]` pairs ready to
///    feed straight into `drawRawPoints(PointMode.polygon, …)`. The X
///    coordinates are pre-computed at construction (`x = i / (capacity-1)`),
///    so during a push only the Y slot is touched.
///
/// Insertion is O(1) per sample and O(n) per batch via
/// `Float32List.setRange` (memcpy on the platform's typed-data fast path).
/// No allocations after construction.
class StreamBuffer {
  StreamBuffer({
    required this.capacity,
    double initialValue = 0,
  })  : assert(capacity >= 2, 'capacity must be at least 2'),
        values = Float32List(capacity),
        coords = Float32List(capacity * 2) {
    final inv = 1.0 / (capacity - 1);
    for (var i = 0; i < capacity; i++) {
      coords[i * 2] = i * inv;
      coords[i * 2 + 1] = initialValue;
      values[i] = initialValue;
    }
  }

  final int capacity;

  /// Raw samples. Slot `i` holds the value last written to that position.
  final Float32List values;

  /// Interleaved `[x_norm, y]` pairs. X stays fixed across the buffer's
  /// lifetime; Y is overwritten on every push.
  final Float32List coords;

  int _head = 0;
  int _count = 0;

  /// Next write position (mod capacity).
  int get head => _head;

  /// Total samples written since construction (monotonic — wraps would need
  /// 2⁶³ years at 100 KHz so we don't worry about it).
  int get count => _count;

  /// `true` once at least [capacity] samples have been written.
  bool get isFull => _count >= capacity;

  /// Bumped on every push so painters know whether to repaint.
  int get revision => _count;

  /// Pushes a single sample. O(1), zero allocations.
  void push(double value) {
    values[_head] = value;
    coords[_head * 2 + 1] = value;
    final next = _head + 1;
    _head = next == capacity ? 0 : next;
    _count++;
  }

  /// Pushes a batch via two `setRange` memcpys (one for the tail, one for
  /// the wrap-around head). For an N-sample batch this is `O(N)` total —
  /// dominated by the underlying typed-data copy intrinsic.
  void pushAll(Float32List batch) {
    final n = batch.length;
    if (n == 0) return;
    if (n >= capacity) {
      // Discard everything older than the last `capacity` samples.
      final start = n - capacity;
      values.setRange(0, capacity, batch, start);
      for (var i = 0; i < capacity; i++) {
        coords[i * 2 + 1] = batch[start + i];
      }
      _head = 0;
      _count += n;
      return;
    }

    final firstChunk = _head + n <= capacity ? n : capacity - _head;
    values.setRange(_head, _head + firstChunk, batch);
    for (var i = 0; i < firstChunk; i++) {
      coords[(_head + i) * 2 + 1] = batch[i];
    }
    if (firstChunk < n) {
      final second = n - firstChunk;
      values.setRange(0, second, batch, firstChunk);
      for (var i = 0; i < second; i++) {
        coords[i * 2 + 1] = batch[firstChunk + i];
      }
      _head = second;
    } else {
      _head = (_head + n) % capacity;
    }
    _count += n;
  }

  /// Resets the buffer to its empty state. Capacity and X coords are
  /// preserved; Y values reset to zero.
  void clear() {
    for (var i = 0; i < capacity; i++) {
      values[i] = 0;
      coords[i * 2 + 1] = 0;
    }
    _head = 0;
    _count = 0;
  }

  /// Sample at slot `s` (raw access; for absolute-index lookup use
  /// [sampleAt]).
  double valueAt(int slot) => values[slot];

  /// Sample at absolute index `n` (must satisfy `count - capacity ≤ n < count`).
  /// Returns `double.nan` if the index has been overwritten or hasn't
  /// been reached yet.
  double sampleAt(int n) {
    if (n < _count - capacity || n >= _count || n < 0) return double.nan;
    return values[n % capacity];
  }
}
