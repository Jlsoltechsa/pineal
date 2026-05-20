import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../painters/text_cache.dart';
import 'auto_fit.dart';
import 'column.dart';
import 'data_source.dart';
import 'filter_popup.dart';
import 'floating_editor.dart';
import 'grid_controller.dart';
import 'grid_painter.dart';

/// Top-level grid widget. One [RepaintBoundary] for the painter, plus an
/// overlay layer for the floating editor. Gestures are translated to
/// `(row, column)` purely by arithmetic in [GridPainter.cellAt] — there are
/// no per-cell child widgets, so 1M rows cost the same as 1k.
class PinealGrid extends StatefulWidget {
  const PinealGrid({
    super.key,
    required this.columns,
    required this.source,
    this.rowHeight = 28,
    this.headerHeight = 32,
    this.rowHeightOf,
    this.autoSizeRows = false,
    this.columnGroups = const [],
    this.groupHeaderHeight = 24,
    this.frozenRowCount = 0,
    this.showAggregateFooter = false,
    this.footerHeight = 32,
    this.aggregateFooterShowLabels = false,
    this.sectionOf,
    this.sectionLabel,
    this.style = const GridStyle(),
    this.onCellTap,
    this.onCellDoubleTap,
  });

  final List<GridColumn> columns;
  final GridDataSource source;
  final double rowHeight;
  final double headerHeight;

  /// Optional per-row height resolver — see [GridController.rowHeightOf].
  /// When `null`, every row is [rowHeight] tall (the fast uniform path).
  /// If both [rowHeightOf] and [autoSizeRows] are supplied, [rowHeightOf]
  /// wins.
  final double Function(int row)? rowHeightOf;

  /// When `true`, the grid measures the wrapped paragraph height of every
  /// [GridColumn.wrap] column at its current width and sets the row height
  /// to the largest of those (clamped at or above [rowHeight]). Results
  /// are cached per row and re-invalidated when column widths change.
  final bool autoSizeRows;

  /// Optional header-band groupings. When non-empty, the painter carves
  /// [groupHeaderHeight] off the top of the header band for a labeled
  /// row above the column headers. Pinned columns ignore groups (they
  /// keep the full-height single-row look).
  final List<GridColumnGroup> columnGroups;

  /// Height of the group band when [columnGroups] is non-empty.
  final double groupHeaderHeight;

  /// First N rows are pinned just below the header and don't scroll.
  /// Respects `rowHeightOf` / [autoSizeRows] so a variable-height row can
  /// be frozen and still get its measured height in the frozen band.
  final int frozenRowCount;

  /// Pin a footer band that runs `GridColumn.aggregate` over the displayed
  /// rows. Aggregates are cached on the controller and invalidated on any
  /// source change (filter, sort, edit) so the footer always agrees with
  /// the view.
  final bool showAggregateFooter;
  final double footerHeight;

  /// Prefix each footer cell with its aggregate's label ("Sum: 1234").
  /// `GridColumn.aggregateLabel` overrides this per-column (set to `""` to
  /// suppress the prefix even when this flag is on).
  final bool aggregateFooterShowLabels;

  /// Partitions rows into named sections. When the topmost visible body
  /// row belongs to a section, the column-header band is replaced by a
  /// section sticky carrying [sectionLabel]'s result (defaulting to the
  /// ID itself). As the user scrolls past the section's rows, the column
  /// header returns. Behaves like iOS UITableView's pinned section
  /// header, but it overrides the column titles instead of stacking
  /// below them.
  ///
  /// Pinned columns and group bands remain visible during the takeover —
  /// only the scrolling column-title row is replaced.
  final String? Function(int row)? sectionOf;
  final String Function(String sectionId)? sectionLabel;
  final GridStyle style;
  final void Function(GridCell cell)? onCellTap;
  final void Function(GridCell cell)? onCellDoubleTap;

  @override
  State<PinealGrid> createState() => _PinealGridState();
}

class _PinealGridState extends State<PinealGrid>
    with SingleTickerProviderStateMixin {
  late GridController _controller;
  final TextCache _textCache = TextCache(maxEntries: 1024);
  final FocusNode _focus = FocusNode(debugLabel: 'PinealGrid');
  late AutoFitMeasurer _measurer;
  late AnimationController _widthAnim;
  Size _lastSize = Size.zero;
  bool _sampledScheduled = false;

  // Width-animation buffers. Allocated once we know the column count, then
  // reused across animations to avoid per-frame allocations on the
  // animation hot path.
  Float32List? _animFrom;
  Float32List? _animTo;

  // autoSizeRows cache: row → measured tallest-wrapped-column height.
  // Cleared whenever any column width changes (resize drag, autofit
  // commit) or the data source notifies a row-count delta.
  final Map<int, double> _autoSizeCache = {};
  Float32List? _widthsSnapshot;
  int? _autoSizeRowCount;

  // Gesture classification. `_drag` is resolved on pan start (and on tap
  // up for the header-pressed case) and dictates what `_handlePanUpdate`
  // does until `_handlePanEnd` resets it.
  _DragMode _drag = _DragMode.none;
  int _resizeColumnIndex = -1;
  int _reorderFromIndex = -1;
  int? _reorderDropIndex;
  Offset _reorderPointer = Offset.zero;

  // Header-press tracking — split from sort triggering so a press followed
  // by a drag escalates into a reorder instead of pre-firing a sort.
  int? _headerPressedIndex;

  // Filter popup state. Only one popup at a time, anchored to the click point.
  ({String columnId, Offset position})? _filterPopup;

  @override
  void initState() {
    super.initState();
    _controller = GridController(
      columns: widget.columns,
      source: widget.source,
      rowHeight: widget.rowHeight,
      headerHeight: _totalHeaderHeight,
      rowHeightOf: _resolveRowHeightOf(),
    );
    _measurer = AutoFitMeasurer(
      textCache: _textCache,
      fontSize: widget.style.fontSize,
      fontFamily: widget.style.fontFamily,
      cellPaddingH: widget.style.cellPaddingH,
    );
    _widthAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 120),
    )..addListener(_onWidthTick);
    if (widget.autoSizeRows) {
      _controller.addListener(_onControllerChangeForAutoSize);
    }
    _scheduleSampledAutoFit();
  }

  @override
  void didUpdateWidget(covariant PinealGrid old) {
    super.didUpdateWidget(old);
    final columnsChanged = old.columns != widget.columns ||
        old.columns.length != _controller.columns.length;
    final sourceChanged = old.source != widget.source;
    if (columnsChanged || sourceChanged) {
      if (old.autoSizeRows) {
        _controller.removeListener(_onControllerChangeForAutoSize);
      }
      _controller.dispose();
      _autoSizeCache.clear();
      _widthsSnapshot = null;
      _autoSizeRowCount = null;
      _controller = GridController(
        columns: widget.columns,
        source: widget.source,
        rowHeight: widget.rowHeight,
        headerHeight: widget.headerHeight,
        rowHeightOf: _resolveRowHeightOf(),
      );
      if (widget.autoSizeRows) {
        _controller.addListener(_onControllerChangeForAutoSize);
      }
      _sampledScheduled = false;
      _scheduleSampledAutoFit();
    } else if (old.autoSizeRows != widget.autoSizeRows) {
      if (old.autoSizeRows) {
        _controller.removeListener(_onControllerChangeForAutoSize);
      }
      if (widget.autoSizeRows) {
        _controller.addListener(_onControllerChangeForAutoSize);
      }
    }
  }

  @override
  void dispose() {
    if (widget.autoSizeRows) {
      _controller.removeListener(_onControllerChangeForAutoSize);
    }
    _widthAnim.dispose();
    _focus.dispose();
    _controller.dispose();
    super.dispose();
  }

  /// Total header band — column-header row plus optional group band.
  double get _totalHeaderHeight =>
      widget.headerHeight +
      (widget.columnGroups.isNotEmpty ? widget.groupHeaderHeight : 0);

  /// Returns the controller's `rowHeightOf` callback. If the caller passed
  /// one explicitly, it wins; otherwise [autoSizeRows] mode is wired to
  /// our internal measurer.
  double Function(int)? _resolveRowHeightOf() {
    if (widget.rowHeightOf != null) return widget.rowHeightOf;
    if (widget.autoSizeRows) return _measureRowHeight;
    return null;
  }

  /// Measures the tallest wrapped-paragraph height across the row's wrap
  /// columns, falling back to [widget.rowHeight] when nothing wraps.
  /// Cached per row; cache is cleared by `_onControllerChangeForAutoSize`
  /// whenever a column width or the row count moves.
  double _measureRowHeight(int row) {
    final cached = _autoSizeCache[row];
    if (cached != null) return cached;
    var maxH = widget.rowHeight;
    for (var i = 0; i < _controller.columns.length; i++) {
      final col = _controller.columns[i];
      if (!col.wrap) continue;
      final value = widget.source.valueAt(row, col.id);
      if (value == null) continue;
      final text = col.format(value);
      if (text.isEmpty) continue;
      final w = _controller.widthOf(i);
      final p = _textCache.paragraph(
        text,
        fontSize: widget.style.fontSize,
        color: widget.style.cellText,
        fontFamily: widget.style.fontFamily,
        maxWidth:
            (w - widget.style.cellPaddingH * 2).clamp(0, double.infinity),
        align: col.align,
      );
      // 4px top padding (matches the painter) + 6px bottom breathing room.
      final h = p.height + 10;
      if (h > maxH) maxH = h;
    }
    _autoSizeCache[row] = maxH;
    return maxH;
  }

  /// Filtered listener that wipes the auto-size cache when something that
  /// would change wrapped row heights happens — column widths or row
  /// count. Scroll/selection/edit notifications fall through.
  void _onControllerChangeForAutoSize() {
    final n = _controller.columns.length;
    final ws = _widthsSnapshot;
    var widthsChanged = false;
    if (ws == null || ws.length != n) {
      _widthsSnapshot = Float32List(n);
      widthsChanged = true;
    }
    for (var i = 0; i < n; i++) {
      final w = _controller.widthOf(i);
      if (_widthsSnapshot![i] != w) {
        _widthsSnapshot![i] = w;
        widthsChanged = true;
      }
    }
    final rowCount = _controller.source.rowCount;
    final rowCountChanged = _autoSizeRowCount != rowCount;
    if (widthsChanged || rowCountChanged) {
      _autoSizeRowCount = rowCount;
      _autoSizeCache.clear();
      _controller.invalidateRowHeights();
    }
  }

  /// Animate from the current column widths to [target] with a short
  /// easeOut, so the user's eye treats the autofit refit as a transition
  /// rather than a jump cut. Manual drags bypass this — see [_handlePanUpdate].
  void _animateWidthsTo(Float32List target) {
    final n = _controller.columns.length;
    final from = Float32List(n);
    var anyDelta = false;
    for (var i = 0; i < n; i++) {
      from[i] = _controller.widthOf(i);
      if ((from[i] - target[i]).abs() > 0.5) anyDelta = true;
    }
    if (!anyDelta) return;
    _animFrom = from;
    _animTo = target;
    _widthAnim
      ..stop()
      ..value = 0
      ..forward();
  }

  void _onWidthTick() {
    final from = _animFrom;
    final to = _animTo;
    if (from == null || to == null) return;
    final t = Curves.easeOut.transform(_widthAnim.value);
    final out = Float32List(from.length);
    for (var i = 0; i < out.length; i++) {
      out[i] = from[i] + (to[i] - from[i]) * t;
    }
    _controller.setWidths(out);
  }

  void _scheduleSampledAutoFit() {
    if (_sampledScheduled) return;
    _sampledScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _runSampledAutoFit();
    });
  }

  Future<void> _runSampledAutoFit() async {
    final next = Float32List(_controller.columns.length);
    for (var i = 0; i < _controller.columns.length; i++) {
      if (!mounted) return;
      final col = _controller.columns[i];
      if (col.width != null) {
        next[i] = col.width!;
        continue;
      }
      if (col.autoFit == AutoFitMode.exhaustive) {
        next[i] =
            _measurer.measureExhaustive(column: col, source: widget.source);
      } else if (col.autoFit == AutoFitMode.sampled) {
        next[i] = await _measurer.measureSampledAsync(
            column: col, source: widget.source);
      } else {
        next[i] = _controller.widthOf(i);
      }
    }
    if (!mounted) return;
    _animateWidthsTo(next);
  }

  void _refreshViewportAutoFit(Size size) {
    final bodyH = size.height - widget.headerHeight;
    final first = _controller.firstVisibleRow();
    final last = _controller.lastVisibleRow(bodyH);
    final next = Float32List(_controller.columns.length);
    var changed = false;
    for (var i = 0; i < _controller.columns.length; i++) {
      final col = _controller.columns[i];
      if (col.width != null) {
        next[i] = col.width!;
      } else if (col.autoFit == AutoFitMode.viewport) {
        next[i] = _measurer.measureViewport(
          column: col,
          source: widget.source,
          firstRow: first,
          lastRow: last,
        );
      } else {
        next[i] = _controller.widthOf(i);
      }
      if (next[i] != _controller.widthOf(i)) changed = true;
    }
    if (changed) _controller.setWidths(next);
  }

  // ─── Gesture handlers ─────────────────────────────────────────────────────

  void _handlePanStart(DragStartDetails d, GridPainter painter, Size size) {
    final hh = painter.headerHitAt(d.localPosition, size);
    if (hh != null && hh.resizeZone) {
      _drag = _DragMode.resize;
      _resizeColumnIndex = hh.columnIndex;
      _controller.beginResize(hh.columnIndex);
    } else if (_headerPressedIndex != null) {
      // Header was pressed and now we're dragging — escalate to reorder.
      _drag = _DragMode.reorder;
      _reorderFromIndex = _headerPressedIndex!;
      _reorderPointer = d.localPosition;
      _reorderDropIndex = _reorderFromIndex;
      _headerPressedIndex = null;
      setState(() {});
    } else {
      _drag = _DragMode.scroll;
    }
  }

  void _handlePanUpdate(DragUpdateDetails d) {
    switch (_drag) {
      case _DragMode.resize:
        _controller.setWidth(
          _resizeColumnIndex,
          _controller.widthOf(_resizeColumnIndex) + d.delta.dx,
        );
      case _DragMode.reorder:
        _reorderPointer = d.localPosition;
        // Resolve the live drop target. The painter knows column geometry.
        // We can't read `_painter` here (it's recreated each build) — so we
        // lazily snapshot it via a callback in setState.
        setState(() {});
      case _DragMode.scroll:
        _controller.setScroll(
          x: _controller.scrollX - d.delta.dx,
          y: _controller.scrollY - d.delta.dy,
        );
      case _DragMode.none:
        break;
    }
  }

  void _handlePanEnd(DragEndDetails d) {
    switch (_drag) {
      case _DragMode.resize:
        _resizeColumnIndex = -1;
        _controller.endResize();
      case _DragMode.reorder:
        final drop = _reorderDropIndex;
        if (drop != null && drop != _reorderFromIndex) {
          _controller.reorderColumn(_reorderFromIndex, drop);
        }
        _reorderFromIndex = -1;
        _reorderDropIndex = null;
        setState(() {});
      case _DragMode.scroll:
      case _DragMode.none:
        break;
    }
    _drag = _DragMode.none;
  }

  void _handleTapDown(TapDownDetails d, GridPainter painter, Size size) {
    _focus.requestFocus();
    final hh = painter.headerHitAt(d.localPosition, size);
    if (hh != null) {
      // Defer header sort to onTapUp so a drag-from-header escalates into
      // reorder without first emitting a sort.
      if (!hh.resizeZone) _headerPressedIndex = hh.columnIndex;
      return;
    }
    final cell = painter.cellAt(d.localPosition, size);
    if (cell == null) return;
    if (HardwareKeyboard.instance.isShiftPressed) {
      _controller.extendSelectionTo(cell);
    } else {
      _controller.selectCell(cell);
    }
    widget.onCellTap?.call(cell);
  }

  void _handleTapUp(TapUpDetails d) {
    final pressed = _headerPressedIndex;
    _headerPressedIndex = null;
    if (pressed == null) return;
    final col = _controller.columns[pressed];
    if (col.sortable) {
      final additive = HardwareKeyboard.instance.isShiftPressed;
      _controller.toggleSort(col.id, additive: additive);
    }
  }

  void _handleTapCancel() {
    _headerPressedIndex = null;
  }

  void _handleDoubleTapDown(TapDownDetails d, GridPainter painter, Size size) {
    final cell = painter.cellAt(d.localPosition, size);
    if (cell == null) return;
    _controller.beginEdit(cell);
    widget.onCellDoubleTap?.call(cell);
  }

  void _handleSecondaryTapDown(
      TapDownDetails d, GridPainter painter, Size size) {
    final hh = painter.headerHitAt(d.localPosition, size);
    if (hh == null) return;
    final col = _controller.columns[hh.columnIndex];
    setState(() {
      _filterPopup = (columnId: col.id, position: d.localPosition);
    });
  }

  void _closeFilterPopup() {
    if (_filterPopup == null) return;
    setState(() => _filterPopup = null);
    _focus.requestFocus();
  }

  void _handlePointerSignal(PointerSignalEvent event, Size size) {
    if (event is PointerScrollEvent) {
      _controller.setScroll(
        x: _controller.scrollX + event.scrollDelta.dx,
        y: _controller.scrollY + event.scrollDelta.dy,
      );
    }
  }

  // ─── Keyboard ─────────────────────────────────────────────────────────────

  KeyEventResult _handleKey(FocusNode node, KeyEvent event, Size size) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (_controller.editingCell != null) return KeyEventResult.ignored;

    final k = event.logicalKey;
    final ctl = HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed;
    final extend = HardwareKeyboard.instance.isShiftPressed;

    // Ctrl/Cmd+C copies the current selection as TSV.
    if (ctl && k == LogicalKeyboardKey.keyC) {
      _copySelectionToClipboard();
      return KeyEventResult.handled;
    }

    // Ctrl/Cmd+V pastes TSV starting at the focus cell.
    if (ctl && k == LogicalKeyboardKey.keyV) {
      _pasteFromClipboard();
      return KeyEventResult.handled;
    }

    // Undo / redo. Ctrl+Shift+Z and Ctrl+Y both map to redo to match the
    // two main desktop conventions (macOS uses Shift+Z, Windows uses Y).
    if (ctl && k == LogicalKeyboardKey.keyZ) {
      if (HardwareKeyboard.instance.isShiftPressed) {
        _controller.redo();
      } else {
        _controller.undo();
      }
      _scrollFocusIntoView(size);
      return KeyEventResult.handled;
    }
    if (ctl && k == LogicalKeyboardKey.keyY) {
      _controller.redo();
      _scrollFocusIntoView(size);
      return KeyEventResult.handled;
    }

    if (k == LogicalKeyboardKey.delete ||
        k == LogicalKeyboardKey.backspace) {
      _controller.deleteSelection();
      return KeyEventResult.handled;
    }

    if (k == LogicalKeyboardKey.arrowUp) {
      _moveAndScroll(0, -1, size, extend: extend);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowDown) {
      _moveAndScroll(0, 1, size, extend: extend);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowLeft) {
      _moveAndScroll(-1, 0, size, extend: extend);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowRight ||
        k == LogicalKeyboardKey.tab) {
      _moveAndScroll(1, 0, size, extend: extend);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.pageDown) {
      _pageMove(1, size, extend: extend);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.pageUp) {
      _pageMove(-1, size, extend: extend);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.home && ctl) {
      _controller.selectCell(GridCell(0, _controller.columns.first.id));
      _controller.scrollCellIntoView(
          _controller.activeCell!, size.height, size.width);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.end && ctl) {
      final last = widget.source.rowCount - 1;
      if (last >= 0) {
        _controller.selectCell(GridCell(last, _controller.columns.last.id));
        _controller.scrollCellIntoView(
            _controller.activeCell!, size.height, size.width);
      }
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.enter ||
        k == LogicalKeyboardKey.numpadEnter ||
        k == LogicalKeyboardKey.f2) {
      final cell = _controller.activeCell;
      if (cell != null) _controller.beginEdit(cell);
      return KeyEventResult.handled;
    }

    // Excel convention: a printable character starts editing and seeds the
    // input with that character. `event.character` is empty for modifier-only
    // events, so we don't need to filter those out separately.
    final ch = event.character;
    if (ch != null && ch.isNotEmpty && !ctl) {
      final code = ch.codeUnitAt(0);
      if (code >= 32) {
        final cell = _controller.activeCell;
        if (cell != null) _controller.beginEdit(cell, seedText: ch);
        return KeyEventResult.handled;
      }
    }

    return KeyEventResult.ignored;
  }

  /// Page-up / page-down with variable-row-height awareness. We translate
  /// "jump by one viewport" into a target Y position and ask the controller
  /// which row covers that Y — same semantics for uniform and variable rows.
  void _pageMove(int direction, Size size, {bool extend = false}) {
    final cell = _controller.activeCell;
    if (cell == null) {
      if (widget.source.rowCount > 0) {
        _controller.selectCell(GridCell(0, _controller.columns.first.id));
      }
      return;
    }
    final bodyH = size.height - widget.headerHeight;
    final currentY = _controller.rowYAt(cell.row);
    final targetY = currentY + direction * bodyH;
    final targetRow = _controller.rowAtY(targetY);
    _moveAndScroll(0, targetRow - cell.row, size, extend: extend);
  }

  void _moveAndScroll(int dx, int dy, Size size, {bool extend = false}) {
    final next = _controller.moveActive(dx, dy, extend: extend);
    if (next == null && _controller.source.rowCount > 0) {
      _controller.selectCell(GridCell(0, _controller.columns.first.id));
    }
    final cell = _controller.activeCell;
    if (cell != null) {
      _controller.scrollCellIntoView(cell, size.height, size.width);
    }
  }

  void _copySelectionToClipboard() {
    final sel = _controller.selection;
    if (sel == null) return;
    final tsv = _serializeSelection(sel);
    Clipboard.setData(ClipboardData(text: tsv));
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty) return;
    _controller.pasteText(text);
  }

  void _scrollFocusIntoView(Size size) {
    final cell = _controller.activeCell;
    if (cell == null) return;
    _controller.scrollCellIntoView(cell, size.height, size.width);
  }

  /// TSV is what every spreadsheet expects when pasting: tabs between cells,
  /// newlines between rows. Embedded tabs/newlines in cell text would
  /// corrupt the structure, so we strip them — same trade Excel itself
  /// makes when copying.
  String _serializeSelection(GridSelection sel) {
    final anchorIdx = _controller.columnIndexOf(sel.anchor.columnId);
    final focusIdx = _controller.columnIndexOf(sel.focus.columnId);
    final firstCol = anchorIdx < focusIdx ? anchorIdx : focusIdx;
    final lastCol = anchorIdx > focusIdx ? anchorIdx : focusIdx;
    final lines = <String>[];
    for (var r = sel.firstRow; r <= sel.lastRow; r++) {
      final cells = <String>[];
      for (var c = firstCol; c <= lastCol; c++) {
        final col = _controller.columns[c];
        final v = widget.source.valueAt(r, col.id);
        var s = col.format(v);
        if (s.contains('\t') || s.contains('\n')) {
          s = s.replaceAll('\t', ' ').replaceAll('\n', ' ');
        }
        cells.add(s);
      }
      lines.add(cells.join('\t'));
    }
    return lines.join('\n');
  }

  // ─── Reorder overlay ──────────────────────────────────────────────────────

  /// Ghost-of-the-dragged-header that follows the pointer, plus a thin
  /// vertical drop indicator at the resolved insertion point.
  List<Widget> _reorderOverlay(Size size) {
    final widgets = <Widget>[];

    final col = _controller.columns[_reorderFromIndex];
    final ghostW = _controller.widthOf(_reorderFromIndex);
    widgets.add(Positioned(
      left: (_reorderPointer.dx - ghostW / 2)
          .clamp(0.0, (size.width - ghostW).clamp(0.0, double.infinity)),
      top: 0,
      width: ghostW,
      height: widget.headerHeight,
      child: IgnorePointer(
        child: Material(
          color: widget.style.headerBackground.withValues(alpha: 0.92),
          elevation: 6,
          child: Center(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: widget.style.cellPaddingH),
              child: Text(
                col.header,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: widget.style.headerText,
                  fontSize: widget.style.fontSize,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ),
      ),
    ));

    // Drop indicator — vertical line at the left edge of the resolved drop
    // index, accounting for pin group.
    final drop = _reorderDropIndex;
    if (drop != null && drop != _reorderFromIndex) {
      final indicatorX = _dropIndicatorX(drop, size);
      if (indicatorX != null) {
        widgets.add(Positioned(
          left: indicatorX - 1,
          top: 0,
          width: 2,
          height: size.height,
          child: IgnorePointer(
            child: ColoredBox(color: widget.style.activeBorder),
          ),
        ));
      }
    }
    return widgets;
  }

  double? _dropIndicatorX(int dropIdx, Size size) {
    final draggedPin = _controller.columns[_reorderFromIndex].pin;
    final dropPin = _controller.columns[dropIdx].pin;
    if (draggedPin != dropPin) return null;

    double x;
    if (draggedPin == ColumnPin.left) {
      x = 0;
    } else if (draggedPin == ColumnPin.right) {
      x = size.width - _controller.pinnedWidth(ColumnPin.right);
    } else {
      x = _controller.pinnedWidth(ColumnPin.left) - _controller.scrollX;
    }
    for (var i = 0; i < dropIdx; i++) {
      if (_controller.columns[i].pin == draggedPin) {
        x += _controller.widthOf(i);
      }
    }
    return x;
  }

  // ─── Mouse cursor ─────────────────────────────────────────────────────────

  MouseCursor _cursorFor(Offset pos, GridPainter painter, Size size) {
    final hh = painter.headerHitAt(pos, size);
    if (hh != null && hh.resizeZone) return SystemMouseCursors.resizeColumn;
    return SystemMouseCursors.basic;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        if (size != _lastSize) {
          _lastSize = size;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            _refreshViewportAutoFit(size);
          });
        }

        final painter = GridPainter(
          controller: _controller,
          style: widget.style,
          textCache: _textCache,
          columnGroups: widget.columnGroups,
          groupBandHeight:
              widget.columnGroups.isNotEmpty ? widget.groupHeaderHeight : 0,
          frozenRowCount: widget.frozenRowCount,
          showAggregateFooter: widget.showAggregateFooter,
          footerHeight: widget.footerHeight,
          showFooterLabels: widget.aggregateFooterShowLabels,
          sectionOf: widget.sectionOf,
          sectionLabel: widget.sectionLabel,
        );

        // Resolve the live drop target while a reorder drag is in flight.
        // Doing it in build keeps the visual indicator and the eventual
        // commit in lockstep, both reading the same painter geometry.
        if (_drag == _DragMode.reorder && _reorderFromIndex >= 0) {
          _reorderDropIndex = painter.headerInsertionIndexAt(
              _reorderPointer, size, _reorderFromIndex);
        }

        return Focus(
          focusNode: _focus,
          onKeyEvent: (n, e) => _handleKey(n, e, size),
          child: Listener(
            onPointerSignal: (e) => _handlePointerSignal(e, size),
            onPointerHover: (e) {
              // Force a hit-test for cursor changes — MouseRegion below picks
              // up the change via its onHover, but cursor isn't reactive
              // without a wrapper. The MouseRegion below covers it.
            },
            child: MouseRegion(
              cursor: SystemMouseCursors.basic,
              onHover: (_) {},
              child: _HoverCursor(
                resolve: (pos) => _cursorFor(pos, painter, size),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (d) => _handleTapDown(d, painter, size),
                  onTapUp: _handleTapUp,
                  onTapCancel: _handleTapCancel,
                  onSecondaryTapDown: (d) =>
                      _handleSecondaryTapDown(d, painter, size),
                  onDoubleTapDown: (d) =>
                      _handleDoubleTapDown(d, painter, size),
                  onDoubleTap: () {},
                  onPanStart: (d) => _handlePanStart(d, painter, size),
                  onPanUpdate: _handlePanUpdate,
                  onPanEnd: _handlePanEnd,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      RepaintBoundary(
                        child: CustomPaint(
                          painter: painter,
                          size: Size.infinite,
                        ),
                      ),
                      FloatingEditor(
                        controller: _controller,
                        painter: painter,
                        size: size,
                        onCommit: (dx, dy) {
                          if (dx == 0 && dy == 0) return;
                          _moveAndScroll(dx, dy, size);
                          _focus.requestFocus();
                        },
                      ),
                      if (_filterPopup != null)
                        FilterPopup(
                          column: _controller.columns
                              .firstWhere((c) => c.id == _filterPopup!.columnId),
                          controller: _controller,
                          position: _filterPopup!.position,
                          viewportSize: size,
                          onClose: _closeFilterPopup,
                        ),
                      if (_drag == _DragMode.reorder &&
                          _reorderFromIndex >= 0)
                        ..._reorderOverlay(size),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

enum _DragMode { none, scroll, resize, reorder }

/// Tiny wrapper that resolves the cursor by sampling the pointer position
/// against a `resolve(pos)` callback. Avoids splitting the gesture tree
/// into multiple `MouseRegion`s per zone.
class _HoverCursor extends StatefulWidget {
  const _HoverCursor({required this.resolve, required this.child});

  final MouseCursor Function(Offset position) resolve;
  final Widget child;

  @override
  State<_HoverCursor> createState() => _HoverCursorState();
}

class _HoverCursorState extends State<_HoverCursor> {
  MouseCursor _cursor = SystemMouseCursors.basic;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: _cursor,
      onHover: (e) {
        final c = widget.resolve(e.localPosition);
        if (c != _cursor) setState(() => _cursor = c);
      },
      onExit: (_) {
        if (_cursor != SystemMouseCursors.basic) {
          setState(() => _cursor = SystemMouseCursors.basic);
        }
      },
      child: widget.child,
    );
  }
}
