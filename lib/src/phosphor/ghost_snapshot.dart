import 'dart:typed_data';

import '../stream/stream_buffer.dart';

/// Immutable copy of a [StreamBuffer]'s sample values at a moment in time.
///
/// Useful for "ghosting" — keeping a baseline trace visible while the live
/// buffer keeps flowing, so the user can spot drift. The snapshot owns its
/// own `Float32List`, so the source buffer can keep being written without
/// disturbing the copy.
class GhostSnapshot {
  GhostSnapshot._(this.values, this.coords, this.capacity, this.head);

  /// Captures the current state of [buffer]. Allocates two [Float32List]s
  /// of `capacity` and `capacity * 2` floats respectively — call sparingly
  /// (e.g. on user request, not every frame).
  factory GhostSnapshot.of(StreamBuffer buffer) {
    return GhostSnapshot._(
      Float32List.fromList(buffer.values),
      Float32List.fromList(buffer.coords),
      buffer.capacity,
      buffer.head,
    );
  }

  /// Sample values at the moment of capture.
  final Float32List values;

  /// Interleaved `[x_norm, y]` pairs ready for `drawRawPoints` — exactly
  /// the same layout the live painter consumes.
  final Float32List coords;

  /// Buffer capacity at the moment of capture. The snapshot uses the same
  /// X normalisation, so the live trace and the ghost line up.
  final int capacity;

  /// Head pointer at the moment of capture, useful when an overlay wants
  /// to draw the snapshot with its own sweep-style split.
  final int head;
}
