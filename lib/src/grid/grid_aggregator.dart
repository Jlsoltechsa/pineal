import 'column.dart';
import 'data_source.dart';

/// Single-pass aggregate computers. Each `compute` call walks
/// `source.rowCount` rows once and returns `null` if the function isn't
/// applicable (e.g. `sum` on a column without numeric values). Results are
/// expected to be cached by the caller — see `GridController.aggregateFor`.
class GridAggregator {
  GridAggregator._();

  static Object? compute(
      GridAggregate fn, GridDataSource source, String columnId) {
    if (fn == GridAggregate.none) return null;
    final n = source.rowCount;
    switch (fn) {
      case GridAggregate.count:
        var c = 0;
        for (var r = 0; r < n; r++) {
          if (source.valueAt(r, columnId) != null) c++;
        }
        return c;
      case GridAggregate.sum:
        var s = 0.0;
        var any = false;
        for (var r = 0; r < n; r++) {
          final v = source.valueAt(r, columnId);
          if (v is num) {
            s += v;
            any = true;
          }
        }
        return any ? s : null;
      case GridAggregate.avg:
        var s = 0.0;
        var c = 0;
        for (var r = 0; r < n; r++) {
          final v = source.valueAt(r, columnId);
          if (v is num) {
            s += v;
            c++;
          }
        }
        return c == 0 ? null : s / c;
      case GridAggregate.min:
        num? out;
        for (var r = 0; r < n; r++) {
          final v = source.valueAt(r, columnId);
          if (v is num && (out == null || v < out)) out = v;
        }
        return out;
      case GridAggregate.max:
        num? out;
        for (var r = 0; r < n; r++) {
          final v = source.valueAt(r, columnId);
          if (v is num && (out == null || v > out)) out = v;
        }
        return out;
      case GridAggregate.none:
        return null;
    }
  }

  /// Short label shown in the footer label-row when the host wants to print
  /// "Sum: 1234" style entries — not used by the default painter, exposed
  /// so consumers building their own footer don't have to re-derive it.
  static String label(GridAggregate fn) {
    switch (fn) {
      case GridAggregate.count:
        return 'Count';
      case GridAggregate.sum:
        return 'Sum';
      case GridAggregate.avg:
        return 'Avg';
      case GridAggregate.min:
        return 'Min';
      case GridAggregate.max:
        return 'Max';
      case GridAggregate.none:
        return '';
    }
  }
}
