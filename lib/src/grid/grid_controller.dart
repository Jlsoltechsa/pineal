import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'column.dart';
import 'data_source.dart';
import 'grid_aggregator.dart';

/// Best-effort `String -> typed value` coercion that mirrors [sample]'s
/// runtime type, so editing or pasting `"42"` into an `int` column stays
/// an int and doesn't poison the column with strings. Empty input maps
/// to `null` (the spreadsheet "clear cell" convention).
Object? coerceValue(String raw, Object? sample) {
  if (raw.isEmpty) return null;
  if (sample is int) return int.tryParse(raw) ?? raw;
  if (sample is double) return double.tryParse(raw) ?? raw;
  if (sample is bool) {
    final lo = raw.toLowerCase();
    if (lo == 'true' || lo == '1') return true;
    if (lo == 'false' || lo == '0') return false;
  }
  return raw;
}

/// Identifies a single (row, column) intersection.
@immutable
class GridCell {
  const GridCell(this.row, this.columnId);
  final int row;
  final String columnId;

  @override
  bool operator ==(Object other) =>
      other is GridCell && other.row == row && other.columnId == columnId;

  @override
  int get hashCode => Object.hash(row, columnId);
}

enum SortDirection { ascending, descending }

@immutable
class SortSpec {
  const SortSpec(this.columnId, this.direction);
  final String columnId;
  final SortDirection direction;
}

/// A rectangular block of cells. `focus` is the cell the user is "on" — what
/// arrow keys move and what the active-cell border paints around. `anchor`
/// stays put while the focus walks during a shift-extend gesture.
///
/// A single-cell selection has `anchor == focus`.
@immutable
class GridSelection {
  const GridSelection({required this.anchor, required this.focus});

  final GridCell anchor;
  final GridCell focus;

  bool get isSingle => anchor == focus;

  int get firstRow =>
      anchor.row < focus.row ? anchor.row : focus.row;
  int get lastRow =>
      anchor.row > focus.row ? anchor.row : focus.row;

  bool contains(int row, int columnIndex, int anchorIdx, int focusIdx) {
    final lo = anchorIdx < focusIdx ? anchorIdx : focusIdx;
    final hi = anchorIdx > focusIdx ? anchorIdx : focusIdx;
    return row >= firstRow &&
        row <= lastRow &&
        columnIndex >= lo &&
        columnIndex <= hi;
  }

  @override
  bool operator ==(Object other) =>
      other is GridSelection && other.anchor == anchor && other.focus == focus;

  @override
  int get hashCode => Object.hash(anchor, focus);
}

/// Mutable, observable backing store for one [PinealGrid].
///
/// Holds column widths in a [Float32List] so the painter can run the visible
/// window arithmetic with cache-friendly access. Row layout has two modes:
/// uniform (default — every row is [rowHeight] tall, O(1) row-at-offset
/// arithmetic) and variable (when [rowHeightOf] is supplied — backed by a
/// lazy [Float64List] of prefix sums so row-at-offset stays O(log n) via
/// binary search).
class GridController extends ChangeNotifier {
  GridController({
    required List<GridColumn> columns,
    required this.source,
    this.rowHeight = 28,
    this.headerHeight = 32,
    this.rowHeightOf,
  })  : _initialColumns = columns,
        _widths = Float32List(columns.length) {
    _seedWidths();
    source.addListener(_onSourceChange);
  }

  // Columns are stored as a mutable internal list so [reorderColumn] can
  // shuffle them without forcing the host widget to rebuild. Defensive copy
  // in the constructor protects the caller's list from being mutated.
  late final List<GridColumn> _columns = List.of(_initialColumns);

  /// Live column order. Reads are zero-cost; do not mutate this list
  /// directly — call [reorderColumn] (or any column-mutating API as it
  /// lands) so the parallel `_widths` buffer stays in sync.
  List<GridColumn> get columns => _columns;

  final List<GridColumn> _initialColumns;
  final GridDataSource source;
  final double rowHeight;
  final double headerHeight;

  /// Per-row height resolver. When `null`, the grid uses uniform
  /// [rowHeight] and the painter takes a faster integer-arithmetic path.
  /// When non-null, the grid builds a prefix-sum buffer on demand and
  /// caches it until [invalidateRowHeights] is called or the row count
  /// changes.
  ///
  /// Must be a pure function of the row index — values returned for the
  /// same row across paint cycles are expected to be stable. If the
  /// underlying data changes such that heights change, call
  /// [invalidateRowHeights] explicitly.
  final double Function(int row)? rowHeightOf;

  final Float32List _widths;
  // Prefix-sum buffer for variable row heights. `_rowYOffsets[i]` is the
  // y-offset of the top of row `i` in content coordinates. `_rowYOffsets`
  // has length `rowCount + 1` so the final entry doubles as the content
  // height. Null until first read in variable-height mode.
  Float64List? _rowYOffsets;
  int? _offsetsForRowCount;
  double _scrollX = 0;
  double _scrollY = 0;
  GridSelection? _selection;
  GridCell? _editingCell;
  List<SortSpec> _sort = const [];
  Map<String, GridFilter> _filters = const {};
  int? _resizingColumn;

  /// Cap on the undo/redo history. Each entry is a full snapshot of the
  /// cells touched, so the memory cost grows with selection size — 100
  /// operations × 10k-cell pastes is already ~1M live entries. Lower the
  /// cap or scope this to "interactive edits only" if that becomes a hot
  /// path.
  static const int maxHistory = 200;
  final List<_GridOp> _undoStack = [];
  final List<_GridOp> _redoStack = [];

  double get scrollX => _scrollX;
  double get scrollY => _scrollY;
  GridSelection? get selection => _selection;
  GridCell? get activeCell => _selection?.focus;
  GridCell? get editingCell => _editingCell;
  List<SortSpec> get sort => _sort;
  Map<String, GridFilter> get filters => _filters;
  bool hasFilter(String columnId) => _filters.containsKey(columnId);
  int? get resizingColumn => _resizingColumn;
  bool get canUndo => _undoStack.isNotEmpty;
  bool get canRedo => _redoStack.isNotEmpty;

  /// Total content width (sum of every column).
  double get contentWidth {
    var sum = 0.0;
    for (var i = 0; i < _widths.length; i++) {
      sum += _widths[i];
    }
    return sum;
  }

  double get contentHeight {
    if (rowHeightOf == null) return source.rowCount * rowHeight;
    _ensureRowYOffsets();
    return _rowYOffsets!.last;
  }

  /// Height of a single row. `O(1)` regardless of mode.
  double rowHeightAt(int row) =>
      rowHeightOf?.call(row) ?? rowHeight;

  /// Top of [row] in content coordinates (i.e. before subtracting `scrollY`).
  /// `O(1)` in uniform mode; `O(1)` in variable mode after a one-time
  /// prefix-sum build.
  double rowYAt(int row) {
    if (rowHeightOf == null) return row * rowHeight;
    _ensureRowYOffsets();
    final n = _rowYOffsets!.length - 1;
    return _rowYOffsets![row.clamp(0, n)];
  }

  /// Inverse of [rowYAt] — which row covers content-space y `y`?
  /// `O(1)` in uniform mode; `O(log n)` in variable mode via binary search.
  int rowAtY(double y) {
    if (rowHeightOf == null) return (y / rowHeight).floor();
    _ensureRowYOffsets();
    final offsets = _rowYOffsets!;
    if (y < 0) return 0;
    if (y >= offsets.last) return offsets.length - 2;
    // Binary search for the largest i where offsets[i] <= y.
    var lo = 0;
    var hi = offsets.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (offsets[mid] <= y) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  /// Force the prefix-sum buffer to rebuild on next read. Call this when
  /// the heights returned by [rowHeightOf] would now differ for some rows
  /// (e.g. content edits that affect height). Cheap if no buffer was built.
  void invalidateRowHeights() {
    _rowYOffsets = null;
    _offsetsForRowCount = null;
    notifyListeners();
  }

  void _ensureRowYOffsets() {
    if (rowHeightOf == null) return;
    final n = source.rowCount;
    if (_rowYOffsets != null && _offsetsForRowCount == n) return;
    final offsets = Float64List(n + 1);
    var y = 0.0;
    for (var i = 0; i < n; i++) {
      offsets[i] = y;
      y += rowHeightOf!(i);
    }
    offsets[n] = y;
    _rowYOffsets = offsets;
    _offsetsForRowCount = n;
  }

  double widthOf(int columnIndex) => _widths[columnIndex];

  /// Width of every column whose `pin` matches [pin], in column order.
  double pinnedWidth(ColumnPin pin) {
    var sum = 0.0;
    for (var i = 0; i < columns.length; i++) {
      if (columns[i].pin == pin) sum += _widths[i];
    }
    return sum;
  }

  void setWidth(int columnIndex, double width) {
    final clamped = width.clamp(columns[columnIndex].minWidth,
        columns[columnIndex].maxWidth);
    if (_widths[columnIndex] == clamped) return;
    _widths[columnIndex] = clamped;
    notifyListeners();
  }

  /// Bulk update — used by the auto-fit pipeline so listeners only fire once.
  void setWidths(Float32List widths) {
    assert(widths.length == _widths.length);
    var changed = false;
    for (var i = 0; i < widths.length; i++) {
      if (_widths[i] != widths[i]) {
        _widths[i] = widths[i];
        changed = true;
      }
    }
    if (changed) notifyListeners();
  }

  void setScroll({double? x, double? y}) {
    final nx = (x ?? _scrollX).clamp(0.0, double.infinity);
    final ny = (y ?? _scrollY).clamp(0.0, double.infinity);
    if (nx == _scrollX && ny == _scrollY) return;
    _scrollX = nx;
    _scrollY = ny;
    notifyListeners();
  }

  /// Replaces the selection with a single-cell range at [cell] (anchor and
  /// focus collapsed). Pass `null` to clear.
  void selectCell(GridCell? cell) {
    final next = cell == null
        ? null
        : GridSelection(anchor: cell, focus: cell);
    if (next == _selection) return;
    _selection = next;
    notifyListeners();
  }

  /// Moves the focus end of the selection to [cell] while leaving the anchor
  /// untouched — the shift-click / shift-arrow behavior. If there is no
  /// current selection, behaves like [selectCell].
  void extendSelectionTo(GridCell cell) {
    final cur = _selection;
    if (cur == null) {
      selectCell(cell);
      return;
    }
    final next = GridSelection(anchor: cur.anchor, focus: cell);
    if (next == _selection) return;
    _selection = next;
    notifyListeners();
  }

  String? _editorSeed;
  String? get editorSeed => _editorSeed;

  /// Opens the floating editor over [cell]. If [seedText] is provided, the
  /// editor shows that string instead of the current value — used by the
  /// "type a printable key to overwrite" Excel convention.
  void beginEdit(GridCell cell, {String? seedText}) {
    final col = _columnById(cell.columnId);
    if (col == null || !col.editable) return;
    _editingCell = cell;
    _selection = GridSelection(anchor: cell, focus: cell);
    _editorSeed = seedText;
    notifyListeners();
  }

  void commitEdit(Object? value) {
    final c = _editingCell;
    if (c == null) return;
    _applyWrites([CellWrite(c.row, c.columnId, value)]);
    _editingCell = null;
    _editorSeed = null;
    notifyListeners();
  }

  void cancelEdit() {
    if (_editingCell == null) return;
    _editingCell = null;
    _editorSeed = null;
    notifyListeners();
  }

  void setSort(List<SortSpec> chain) {
    _sort = List.unmodifiable(chain);
    source.sort(_sort);
    // Display indices change meaning when the row order shifts; cells
    // captured by the undo stack would now point at different source rows,
    // and per-row heights also re-key against the new display order.
    clearHistory();
    _rowYOffsets = null;
    _offsetsForRowCount = null;
    notifyListeners();
  }

  /// Set or clear the filter on a single column. Pass `null` to remove the
  /// column's filter; pass a [GridFilter] instance to install one.
  void setFilter(String columnId, GridFilter? filter) {
    final next = Map<String, GridFilter>.of(_filters);
    if (filter == null) {
      if (!next.containsKey(columnId)) return;
      next.remove(columnId);
    } else {
      next[columnId] = filter;
    }
    _filters = Map.unmodifiable(next);
    source.applyFilters(_filters);
    // Same as sort: filtered display indices are a different mapping.
    clearHistory();
    _rowYOffsets = null;
    _offsetsForRowCount = null;
    notifyListeners();
  }

  /// Removes every active filter at once.
  void clearFilters() {
    if (_filters.isEmpty) return;
    _filters = const {};
    source.applyFilters(_filters);
    clearHistory();
    _rowYOffsets = null;
    _offsetsForRowCount = null;
    notifyListeners();
  }

  /// Header-click semantics:
  ///   - Plain click (`additive == false`): if the chain is already exactly
  ///     `[(col, asc)]` flips to desc; if it's `[(col, desc)]` clears the
  ///     chain; otherwise replaces the whole chain with `[(col, asc)]`.
  ///   - Shift+click (`additive == true`): if the column is already in the
  ///     chain, asc → desc → removed; otherwise appends as ascending.
  void toggleSort(String columnId, {bool additive = false}) {
    final cur = _sort;
    if (additive) {
      final i = cur.indexWhere((s) => s.columnId == columnId);
      if (i < 0) {
        setSort([...cur, SortSpec(columnId, SortDirection.ascending)]);
        return;
      }
      final spec = cur[i];
      if (spec.direction == SortDirection.ascending) {
        final next = [...cur];
        next[i] = SortSpec(columnId, SortDirection.descending);
        setSort(next);
      } else {
        final next = [...cur]..removeAt(i);
        setSort(next);
      }
      return;
    }
    if (cur.length == 1 && cur.first.columnId == columnId) {
      if (cur.first.direction == SortDirection.ascending) {
        setSort([SortSpec(columnId, SortDirection.descending)]);
      } else {
        setSort(const []);
      }
    } else {
      setSort([SortSpec(columnId, SortDirection.ascending)]);
    }
  }

  /// Live-drag entry/exit. Width updates happen through [setWidth].
  void beginResize(int columnIndex) {
    _resizingColumn = columnIndex;
    notifyListeners();
  }

  void endResize() {
    if (_resizingColumn == null) return;
    _resizingColumn = null;
    notifyListeners();
  }

  /// Moves the focus cell by (dx, dy) in display coordinates, clamping at
  /// the dataset edges. With `extend: true`, leaves the anchor untouched
  /// (shift-arrow). Returns the new focus, or `null` if there was nothing
  /// to move from.
  GridCell? moveActive(int dx, int dy, {bool extend = false}) {
    final a = activeCell;
    if (a == null) return null;
    final colIndex = _columnIndexById(a.columnId);
    if (colIndex < 0) return a;
    final nextCol = (colIndex + dx).clamp(0, columns.length - 1);
    final nextRow = (a.row + dy).clamp(0, source.rowCount - 1);
    final next = GridCell(nextRow, columns[nextCol].id);
    if (extend) {
      extendSelectionTo(next);
    } else {
      selectCell(next);
    }
    return next;
  }

  /// Look up a column's declaration index by id. Returns `-1` if not found.
  int columnIndexOf(String id) => _columnIndexById(id);

  /// Ensures the cell at [cell] is fully visible inside a viewport of [size].
  /// For pinned columns, only the row offset is adjusted.
  void scrollCellIntoView(GridCell cell, double viewportHeight,
      double viewportWidth) {
    final colIndex = _columnIndexById(cell.columnId);
    if (colIndex < 0) return;

    // Vertical.
    final cellTop = rowYAt(cell.row);
    final cellBottom = cellTop + rowHeightAt(cell.row);
    final bodyTop = _scrollY;
    final bodyBottom = _scrollY + (viewportHeight - headerHeight);
    var y = _scrollY;
    if (cellTop < bodyTop) {
      y = cellTop;
    } else if (cellBottom > bodyBottom) {
      y = cellBottom - (viewportHeight - headerHeight);
    }

    // Horizontal — only scrollable columns participate.
    var x = _scrollX;
    final col = columns[colIndex];
    if (col.pin == ColumnPin.none) {
      var left = 0.0;
      for (var i = 0; i < colIndex; i++) {
        if (columns[i].pin == ColumnPin.none) left += _widths[i];
      }
      final right = left + _widths[colIndex];
      final leftPinW = pinnedWidth(ColumnPin.left);
      final rightPinW = pinnedWidth(ColumnPin.right);
      final visibleW = viewportWidth - leftPinW - rightPinW;
      if (left < _scrollX) {
        x = left;
      } else if (right > _scrollX + visibleW) {
        x = right - visibleW;
      }
    }
    setScroll(x: x, y: y);
  }

  int _columnIndexById(String id) {
    for (var i = 0; i < columns.length; i++) {
      if (columns[i].id == id) return i;
    }
    return -1;
  }

  /// First row whose top is at or past `scrollY`.
  int firstVisibleRow() => rowAtY(_scrollY);

  /// Last row whose top is before `scrollY + viewportHeight`.
  int lastVisibleRow(double viewportHeight) {
    final n = source.rowCount;
    if (n == 0) return -1;
    final last = rowAtY(_scrollY + viewportHeight);
    return math.min(n - 1, last);
  }

  /// Index of the first non-pinned column whose right edge is past `scrollX`.
  int firstVisibleScrollingColumn() {
    var x = 0.0;
    for (var i = 0; i < columns.length; i++) {
      if (columns[i].pin != ColumnPin.none) continue;
      x += _widths[i];
      if (x > _scrollX) return i;
    }
    return columns.length;
  }

  /// X-offset (in content space) of `columnIndex`. Useful for hit-testing.
  double columnLeft(int columnIndex) {
    var x = 0.0;
    for (var i = 0; i < columnIndex; i++) {
      if (columns[i].pin != ColumnPin.none) continue;
      x += _widths[i];
    }
    return x;
  }

  GridColumn? _columnById(String id) {
    for (final c in columns) {
      if (c.id == id) return c;
    }
    return null;
  }

  ({int first, int last}) _selectionColumnSpan(GridSelection sel) {
    final a = _columnIndexById(sel.anchor.columnId);
    final f = _columnIndexById(sel.focus.columnId);
    return (first: math.min(a, f), last: math.max(a, f));
  }

  /// Clears every editable cell in the current selection. Non-editable
  /// columns are skipped silently — the same trade-off the floating editor
  /// makes when a column is read-only.
  void deleteSelection() {
    final sel = _selection;
    if (sel == null) return;
    final span = _selectionColumnSpan(sel);
    final writes = <CellWrite>[];
    for (var r = sel.firstRow; r <= sel.lastRow; r++) {
      for (var c = span.first; c <= span.last; c++) {
        final col = columns[c];
        if (!col.editable) continue;
        writes.add(CellWrite(r, col.id, null));
      }
    }
    if (writes.isNotEmpty) _applyWrites(writes);
  }

  /// Applies a TSV-formatted clipboard payload starting at the focus cell.
  ///
  /// Two paste modes, mirroring Excel/Numbers:
  ///   - 1×1 clipboard into a multi-cell selection → fill the whole
  ///     selection with that value.
  ///   - Otherwise → block paste anchored at the focus cell, extending
  ///     down-right by the clipboard's dimensions. Non-editable target
  ///     columns are skipped silently; out-of-range rows/columns are
  ///     truncated.
  ///
  /// Type coercion follows [coerceValue]: each target cell's current value
  /// dictates how the incoming text is parsed.
  void pasteText(String text) {
    final sel = _selection;
    if (sel == null || text.isEmpty) return;

    var normalized = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    // Excel/Numbers append a trailing newline; drop it so we don't get a
    // spurious empty row.
    if (normalized.endsWith('\n')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    final grid =
        normalized.split('\n').map((line) => line.split('\t')).toList();
    if (grid.isEmpty || grid.first.isEmpty) return;

    final rows = grid.length;
    final cols = grid.fold<int>(0, (m, row) => math.max(m, row.length));

    final writes = <CellWrite>[];

    // Fill-mode: single source cell, multi-cell destination.
    if (rows == 1 && cols == 1 && !sel.isSingle) {
      final raw = grid[0][0];
      final span = _selectionColumnSpan(sel);
      for (var r = sel.firstRow; r <= sel.lastRow; r++) {
        for (var c = span.first; c <= span.last; c++) {
          final col = columns[c];
          if (!col.editable) continue;
          final sample = source.valueAt(r, col.id);
          writes.add(CellWrite(r, col.id, coerceValue(raw, sample)));
        }
      }
      if (writes.isNotEmpty) _applyWrites(writes);
      return;
    }

    // Block-mode: anchor at the focus, extend by clipboard size.
    final anchorRow = sel.focus.row;
    final anchorCol = _columnIndexById(sel.focus.columnId);
    if (anchorCol < 0) return;

    for (var dr = 0; dr < rows; dr++) {
      final r = anchorRow + dr;
      if (r >= source.rowCount) break;
      final row = grid[dr];
      for (var dc = 0; dc < row.length; dc++) {
        final c = anchorCol + dc;
        if (c >= columns.length) break;
        final col = columns[c];
        if (!col.editable) continue;
        final sample = source.valueAt(r, col.id);
        writes.add(CellWrite(r, col.id, coerceValue(row[dc], sample)));
      }
    }
    if (writes.isNotEmpty) _applyWrites(writes);
  }

  /// Applies a list of cell writes and records the inverse on the undo
  /// stack. Snapshotting the `before` state happens here, BEFORE the write
  /// lands, so the source's pre-mutation values are captured cleanly.
  void _applyWrites(List<CellWrite> writes) {
    if (writes.isEmpty) return;
    final before = <CellWrite>[];
    for (final w in writes) {
      before.add(CellWrite(w.row, w.columnId, source.valueAt(w.row, w.columnId)));
    }
    source.writeBatch(writes);
    _undoStack.add(_GridOp(before: before, after: writes));
    if (_undoStack.length > maxHistory) {
      _undoStack.removeAt(0);
    }
    _redoStack.clear();
  }

  /// Reverts the most recent mutation. No-op when the stack is empty.
  /// Restores the focus to the first cell of the operation if a selection
  /// is present.
  void undo() {
    if (_undoStack.isEmpty) return;
    final op = _undoStack.removeLast();
    source.writeBatch(op.before);
    _redoStack.add(op);
    _focusFirstOf(op);
    notifyListeners();
  }

  /// Re-applies the most recently undone mutation.
  void redo() {
    if (_redoStack.isEmpty) return;
    final op = _redoStack.removeLast();
    source.writeBatch(op.after);
    _undoStack.add(op);
    _focusFirstOf(op);
    notifyListeners();
  }

  void clearHistory() {
    _undoStack.clear();
    _redoStack.clear();
    notifyListeners();
  }

  void _focusFirstOf(_GridOp op) {
    final first = op.before.first;
    _selection = GridSelection(
      anchor: GridCell(first.row, first.columnId),
      focus: GridCell(first.row, first.columnId),
    );
  }

  void _seedWidths() {
    for (var i = 0; i < _columns.length; i++) {
      _widths[i] = _columns[i].width ?? _columns[i].minWidth;
    }
  }

  /// Move the column at [from] to position [to]. Both indices reference the
  /// pre-move column list. The parallel `_widths` buffer is reshuffled in
  /// the same step so widths stay glued to their column. No-op if `from ==
  /// to` or either index is out of range.
  ///
  /// Reordering changes display-column indices but column IDs are stable,
  /// so existing `_sort` (keyed by id), `_filters` (keyed by id) and
  /// `_selection` (keyed by id) remain valid without translation.
  void reorderColumn(int from, int to) {
    if (from < 0 || from >= _columns.length) return;
    if (to < 0 || to >= _columns.length) return;
    if (from == to) return;
    final col = _columns.removeAt(from);
    _columns.insert(to, col);
    final w = _widths[from];
    if (from < to) {
      for (var i = from; i < to; i++) {
        _widths[i] = _widths[i + 1];
      }
    } else {
      for (var i = from; i > to; i--) {
        _widths[i] = _widths[i - 1];
      }
    }
    _widths[to] = w;
    notifyListeners();
  }

  /// Lazy aggregate cache. Invalidated on every source notification so it
  /// stays in lockstep with filter/sort and per-cell edits.
  final Map<String, Object?> _aggregateCache = {};

  /// Aggregate value for [col], cached. Returns `null` for
  /// `GridAggregate.none` or when the source has no applicable rows.
  Object? aggregateFor(GridColumn col) {
    if (col.aggregate == GridAggregate.none) return null;
    if (_aggregateCache.containsKey(col.id)) return _aggregateCache[col.id];
    final result = GridAggregator.compute(col.aggregate, source, col.id);
    _aggregateCache[col.id] = result;
    return result;
  }

  void _onSourceChange() {
    _aggregateCache.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    source.removeListener(_onSourceChange);
    super.dispose();
  }
}

/// One reversible mutation: `before` and `after` are the same cells viewed
/// pre- and post-write. Stored in the controller's history stacks.
@immutable
class _GridOp {
  const _GridOp({required this.before, required this.after});
  final List<CellWrite> before;
  final List<CellWrite> after;
}
