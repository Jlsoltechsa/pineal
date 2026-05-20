import 'package:flutter/foundation.dart';

import 'grid_controller.dart';

/// Read/write contract between [GridController] and whatever holds the rows.
///
/// Implementations are free to back the data with an in-memory list, a paged
/// network feed, a SQLite cursor, etc. The grid never copies the dataset;
/// every cell paint resolves through [valueAt], so a million-row backing
/// store costs no more than its index does.
///
/// Returning `null` from [valueAt] means *not loaded yet* — the painter
/// renders a shimmer placeholder and the source is expected to notify
/// listeners once the page arrives.
abstract class GridDataSource extends ChangeNotifier {
  int get rowCount;

  /// Synchronous lookup. Return `null` to signal pending I/O.
  Object? valueAt(int row, String columnId);

  /// Write-back hook for the floating editor. Override when the source is
  /// mutable; the default is a no-op.
  void setValueAt(int row, String columnId, Object? value) {}

  /// Hint for the source to prefetch the rows the painter is about to draw.
  /// The default implementation does nothing — paged sources should override.
  void prefetch(int firstRow, int lastRow) {}

  /// Re-orders the rows in place. An empty [chain] restores the original
  /// (unsorted) order. Multi-element chains express stable nested sorts:
  /// `[a asc, b desc]` means "primary by a ascending; ties broken by b
  /// descending". The default implementation is a no-op — override when
  /// the backing store can sort itself (in-memory, SQL `ORDER BY`, etc.).
  void sort(List<SortSpec> chain) {}

  /// Hides rows that fail any of the per-column predicates. An empty map
  /// shows everything. Filters compose with [sort]: implementations should
  /// be able to filter AND sort simultaneously without re-loading data.
  void applyFilters(Map<String, GridFilter> filters) {}

  /// Distinct values that appear in [columnId], used to populate categorical
  /// filter checklists. Implementations should ignore any active filter on
  /// that same column (so values the user just unchecked are still listed),
  /// and should cap the result at [limit] to avoid building huge lists for
  /// high-cardinality columns. The default is an empty list — paged
  /// sources that can't enumerate cheaply should leave it as-is.
  List<Object?> uniqueValues(String columnId, {int limit = 1000}) =>
      const <Object?>[];

  /// Apply many cell writes at once. The default falls back to one
  /// [setValueAt] per write, which is correct but spams listeners — paged
  /// or in-memory sources should override to emit a single consolidated
  /// notification at the end (see [InMemoryGridDataSource]).
  void writeBatch(List<CellWrite> writes) {
    for (final w in writes) {
      setValueAt(w.row, w.columnId, w.value);
    }
  }
}

/// One element of a [GridDataSource.writeBatch] payload.
@immutable
class CellWrite {
  const CellWrite(this.row, this.columnId, this.value);
  final int row;
  final String columnId;
  final Object? value;
}

/// Per-column row predicate. Implementations should be cheap — [accepts] is
/// called once per row per repaint of the filter pipeline.
abstract class GridFilter {
  const GridFilter();

  /// `true` keeps the row visible, `false` hides it.
  bool accepts(Object? value);
}

/// Case-insensitive "contains" match against the value's `toString()`.
class TextFilter extends GridFilter {
  TextFilter(this.query) : _needle = query.toLowerCase();
  final String query;
  final String _needle;

  @override
  bool accepts(Object? value) {
    if (_needle.isEmpty) return true;
    if (value == null) return false;
    return value.toString().toLowerCase().contains(_needle);
  }
}

/// Whitelist of allowed raw values. Useful for categorical columns (status,
/// region, owner) where the user picks from a checklist.
class ValueSetFilter extends GridFilter {
  ValueSetFilter(Set<Object?> allowed) : _allowed = Set.of(allowed);
  final Set<Object?> _allowed;

  Set<Object?> get allowed => Set.unmodifiable(_allowed);

  @override
  bool accepts(Object? value) => _allowed.contains(value);
}

/// Inclusive numeric range. `null` on either end means open. Non-numeric
/// values (including null) fail the predicate, which matches the spreadsheet
/// convention "numeric filter implies a numeric cell".
class NumericRangeFilter extends GridFilter {
  const NumericRangeFilter({this.min, this.max});
  final num? min;
  final num? max;

  @override
  bool accepts(Object? value) {
    if (value is! num) return false;
    if (min != null && value < min!) return false;
    if (max != null && value > max!) return false;
    return true;
  }
}

/// Inclusive `DateTime` range. Same semantics as [NumericRangeFilter]:
/// either bound `null` is open, non-`DateTime` values fail.
class DateRangeFilter extends GridFilter {
  const DateRangeFilter({this.min, this.max});
  final DateTime? min;
  final DateTime? max;

  @override
  bool accepts(Object? value) {
    if (value is! DateTime) return false;
    if (min != null && value.isBefore(min!)) return false;
    if (max != null && value.isAfter(max!)) return false;
    return true;
  }
}

/// Eager, mutable in-memory source. Use for small/medium datasets and tests.
///
/// Filtering and sorting are layered on top of a stable canonical row list:
/// `_rows` is the as-loaded order and never re-shuffled, while
/// `_displayOrder` is a list of indices into `_rows` reflecting the current
/// filter + sort. That way the two can compose without losing the original
/// data, and switching filters off cheaply restores order.
class InMemoryGridDataSource extends GridDataSource {
  InMemoryGridDataSource(List<Map<String, Object?>> rows)
      : _rows = List.of(rows),
        _displayOrder = List.generate(rows.length, (i) => i);

  final List<Map<String, Object?>> _rows;
  List<int> _displayOrder;
  List<SortSpec> _sortChain = const [];
  Map<String, GridFilter> _filters = const {};

  @override
  int get rowCount => _displayOrder.length;

  /// Number of underlying rows before filtering. Useful for "showing N of M"
  /// status badges.
  int get totalRowCount => _rows.length;

  @override
  Object? valueAt(int row, String columnId) {
    if (row < 0 || row >= _displayOrder.length) return null;
    return _rows[_displayOrder[row]][columnId];
  }

  @override
  void setValueAt(int row, String columnId, Object? value) {
    if (row < 0 || row >= _displayOrder.length) return;
    _rows[_displayOrder[row]][columnId] = value;
    notifyListeners();
  }

  /// Replaces the dataset wholesale — used by sort/filter pipelines.
  void replaceRows(List<Map<String, Object?>> rows) {
    _rows
      ..clear()
      ..addAll(rows);
    _filters = const {};
    _sortChain = const [];
    _displayOrder = List.generate(rows.length, (i) => i);
    notifyListeners();
  }

  @override
  void writeBatch(List<CellWrite> writes) {
    var any = false;
    for (final w in writes) {
      if (w.row < 0 || w.row >= _displayOrder.length) continue;
      _rows[_displayOrder[w.row]][w.columnId] = w.value;
      any = true;
    }
    if (any) notifyListeners();
  }

  @override
  void sort(List<SortSpec> chain) {
    _sortChain = chain;
    _rebuildDisplayOrder();
    notifyListeners();
  }

  @override
  void applyFilters(Map<String, GridFilter> filters) {
    _filters = filters;
    _rebuildDisplayOrder();
    notifyListeners();
  }

  @override
  List<Object?> uniqueValues(String columnId, {int limit = 1000}) {
    final seen = <Object?>{};
    for (var i = 0; i < _rows.length && seen.length < limit; i++) {
      seen.add(_rows[i][columnId]);
    }
    return seen.toList();
  }

  void _rebuildDisplayOrder() {
    final out = <int>[];
    if (_filters.isEmpty) {
      for (var i = 0; i < _rows.length; i++) {
        out.add(i);
      }
    } else {
      outer:
      for (var i = 0; i < _rows.length; i++) {
        for (final entry in _filters.entries) {
          if (!entry.value.accepts(_rows[i][entry.key])) continue outer;
        }
        out.add(i);
      }
    }
    if (_sortChain.isNotEmpty) {
      out.sort((a, b) {
        for (final spec in _sortChain) {
          final c =
              _compare(_rows[a][spec.columnId], _rows[b][spec.columnId]);
          if (c != 0) {
            return spec.direction == SortDirection.ascending ? c : -c;
          }
        }
        return 0;
      });
    }
    _displayOrder = out;
  }

  static int _compare(Object? a, Object? b) {
    if (a == null && b == null) return 0;
    if (a == null) return -1;
    if (b == null) return 1;
    if (a is num && b is num) return a.compareTo(b);
    if (a is DateTime && b is DateTime) return a.compareTo(b);
    if (a is bool && b is bool) return (a ? 1 : 0).compareTo(b ? 1 : 0);
    return a.toString().compareTo(b.toString());
  }
}
