import 'dart:typed_data';

/// Cache-friendly storage for Gantt tasks.
///
/// Layout in memory is `[t1_0, t2_0, lane_0, kind_0, t1_1, t2_1, …]`. Times
/// are stored as `double` epoch-microseconds so we can carry millisecond
/// precision past the year 2200 without losing bits to the float mantissa.
/// Lane and kind packed as `double` for stride uniformity (still exact for
/// any int up to 2^53).
///
/// "Kind" is an opaque category index — the painter resolves it through a
/// caller-supplied palette. Same trick the chart series uses for stack idx.
class TaskBuffer {
  TaskBuffer._(this._data, this.length);

  factory TaskBuffer.empty(int count) =>
      TaskBuffer._(Float64List(count * _stride), count);

  factory TaskBuffer.fromTasks({
    required List<double> t1Micros,
    required List<double> t2Micros,
    required List<int> lanes,
    List<int>? kinds,
  }) {
    assert(t1Micros.length == t2Micros.length);
    assert(t1Micros.length == lanes.length);
    final n = t1Micros.length;
    final data = Float64List(n * _stride);
    for (var i = 0; i < n; i++) {
      final off = i * _stride;
      data[off] = t1Micros[i];
      data[off + 1] = t2Micros[i];
      data[off + 2] = lanes[i].toDouble();
      data[off + 3] = (kinds?[i] ?? 0).toDouble();
    }
    return TaskBuffer._(data, n);
  }

  static const int _stride = 4;

  final Float64List _data;
  final int length;

  Float64List get raw => _data;
  int revision = 0;

  double t1(int i) => _data[i * _stride];
  double t2(int i) => _data[i * _stride + 1];
  int lane(int i) => _data[i * _stride + 2].toInt();
  int kind(int i) => _data[i * _stride + 3].toInt();

  void setTask(int i, double t1, double t2, int lane, [int kind = 0]) {
    final o = i * _stride;
    _data[o] = t1;
    _data[o + 1] = t2;
    _data[o + 2] = lane.toDouble();
    _data[o + 3] = kind.toDouble();
  }

  /// Time / lane bounds across every task. Used to seed the viewport and
  /// the slot index.
  ({double tMin, double tMax, int laneMin, int laneMax}) bounds() {
    if (length == 0) {
      return (tMin: 0, tMax: 1, laneMin: 0, laneMax: 0);
    }
    var tMin = double.infinity, tMax = -double.infinity;
    var laneMin = 1 << 30, laneMax = -(1 << 30);
    for (var i = 0; i < length; i++) {
      final a = t1(i), b = t2(i);
      if (a < tMin) tMin = a;
      if (b > tMax) tMax = b;
      final l = lane(i);
      if (l < laneMin) laneMin = l;
      if (l > laneMax) laneMax = l;
    }
    return (tMin: tMin, tMax: tMax, laneMin: laneMin, laneMax: laneMax);
  }
}

/// Time-axis bucketing for `O(1 + k)` viewport queries against [TaskBuffer].
///
/// We slice the time domain into uniform "slots" of [slotMicros] and write
/// each task's index into every slot it touches. Querying the viewport
/// `[tMin, tMax]` then reduces to walking a contiguous slice of the slot
/// table — independent of total task count. With slot count tuned to roughly
/// `dataset_span / typical_task_duration`, the average bucket population
/// stays small (≤ a few dozen) even on a million-task dataset.
///
/// A task can belong to many slots; we de-duplicate at query time via a
/// caller-supplied "seen" bitset so the result list contains every task at
/// most once. That avoids storing every task in every slot it spans.
class SlotIndex {
  SlotIndex._(
    this._slotMicros,
    this._domainStart,
    this._slots,
    this._slotStart,
  );

  final double _slotMicros;
  final double _domainStart;

  /// Flattened concatenation of every slot's task indices.
  final Int32List _slots;

  /// `_slotStart[s]` is the first index in `_slots` belonging to slot `s`.
  /// `_slotStart[count]` is the total length (terminator).
  final Int32List _slotStart;

  int get slotCount => _slotStart.length - 1;

  factory SlotIndex.build(TaskBuffer tasks,
      {required double slotMicros, double? domainStart, double? domainEnd}) {
    final b = tasks.bounds();
    final start = domainStart ?? b.tMin;
    final end = domainEnd ?? b.tMax;
    final slotCount =
        ((end - start) / slotMicros).ceil().clamp(1, 1 << 28);

    // Two-pass bucket: count per slot, then fill.
    final counts = Int32List(slotCount);
    for (var i = 0; i < tasks.length; i++) {
      final s0 = _slotOf(tasks.t1(i), start, slotMicros, slotCount);
      final s1 = _slotOf(tasks.t2(i), start, slotMicros, slotCount);
      for (var s = s0; s <= s1; s++) {
        counts[s]++;
      }
    }
    final slotStart = Int32List(slotCount + 1);
    var acc = 0;
    for (var s = 0; s < slotCount; s++) {
      slotStart[s] = acc;
      acc += counts[s];
    }
    slotStart[slotCount] = acc;

    final slots = Int32List(acc);
    final cursor = Int32List(slotCount); // per-slot write head
    for (var i = 0; i < tasks.length; i++) {
      final s0 = _slotOf(tasks.t1(i), start, slotMicros, slotCount);
      final s1 = _slotOf(tasks.t2(i), start, slotMicros, slotCount);
      for (var s = s0; s <= s1; s++) {
        slots[slotStart[s] + cursor[s]] = i;
        cursor[s]++;
      }
    }
    return SlotIndex._(slotMicros, start, slots, slotStart);
  }

  static int _slotOf(double t, double start, double slotMicros, int slotCount) {
    final s = ((t - start) / slotMicros).floor();
    if (s < 0) return 0;
    if (s >= slotCount) return slotCount - 1;
    return s;
  }

  /// Appends every task whose `[t1, t2]` intersects `[tMin, tMax]` to [out].
  /// Caller supplies a [seen] bitset (sized to `tasks.length`) which we mark
  /// to dedup tasks that span multiple slots.
  void query({
    required double tMin,
    required double tMax,
    required Uint8List seen,
    required List<int> out,
  }) {
    if (slotCount == 0) return;
    final s0 = _slotOf(tMin, _domainStart, _slotMicros, slotCount);
    final s1 = _slotOf(tMax, _domainStart, _slotMicros, slotCount);
    // Reset the seen bits we touched on the previous query — caller can do
    // this themselves, but we centralize it so the contract is simpler.
    for (var i = 0; i < seen.length; i++) {
      seen[i] = 0;
    }
    for (var s = s0; s <= s1; s++) {
      final from = _slotStart[s];
      final to = _slotStart[s + 1];
      for (var k = from; k < to; k++) {
        final taskIdx = _slots[k];
        if (seen[taskIdx] == 0) {
          seen[taskIdx] = 1;
          out.add(taskIdx);
        }
      }
    }
  }
}
