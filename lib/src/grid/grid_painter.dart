import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';

import '../painters/text_cache.dart';
import 'column.dart';
import 'grid_aggregator.dart';
import 'grid_controller.dart';

/// Visual constants. Kept on a single class so themes can be swapped without
/// touching the painter body.
@immutable
class GridStyle {
  const GridStyle({
    this.background = const Color(0xFF101418),
    this.headerBackground = const Color(0xFF181D22),
    this.gridLine = const Color(0xFF2A3038),
    this.headerText = const Color(0xFFD7DEE6),
    this.cellText = const Color(0xFFB8C0CC),
    this.activeCell = const Color(0x551E88E5),
    this.activeBorder = const Color(0xFF1E88E5),
    this.selectionFill = const Color(0x221E88E5),
    this.sortIndicator = const Color(0xFF1E88E5),
    this.resizeGuide = const Color(0xFF1E88E5),
    this.fontSize = 12,
    this.fontFamily,
    this.cellPaddingH = 8,
    this.resizeHitZone = 6,
  });

  final Color background;
  final Color headerBackground;
  final Color gridLine;
  final Color headerText;
  final Color cellText;
  final Color activeCell;
  final Color activeBorder;
  final Color selectionFill;
  final Color sortIndicator;
  final Color resizeGuide;
  final double fontSize;
  final String? fontFamily;
  final double cellPaddingH;

  /// Horizontal pixels around a column's right edge that count as a resize
  /// handle. 6 is the macOS Finder convention; small enough to avoid
  /// stealing sort-on-click events.
  final double resizeHitZone;
}

/// Header hit-test result: which column the pointer is over and whether
/// it landed in that column's right-edge resize handle.
@immutable
class HeaderHit {
  const HeaderHit(this.columnIndex, this.resizeZone);
  final int columnIndex;
  final bool resizeZone;
}

/// Single-pass painter for [PinealGrid]. Body, headers, pinned columns and
/// the active-cell highlight share one [Canvas]; the only overlays drawn on
/// top are the floating editor and the scrollbars (both widgets, not paint).
class GridPainter extends CustomPainter {
  GridPainter({
    required this.controller,
    required this.style,
    required this.textCache,
    this.columnGroups = const [],
    this.groupBandHeight = 0,
    this.frozenRowCount = 0,
    this.showAggregateFooter = false,
    this.footerHeight = 32,
    this.showFooterLabels = false,
    this.sectionOf,
    this.sectionLabel,
  }) : super(repaint: controller);

  final GridController controller;
  final GridStyle style;
  final TextCache textCache;

  /// Header-band grouping spec. Empty by default. When present, the painter
  /// carves the top `groupBandHeight` pixels out of `controller.headerHeight`
  /// for the labeled group row, leaves the rest for column headers.
  final List<GridColumnGroup> columnGroups;

  /// Height in pixels reserved at the top of the header band for the group
  /// row. Caller is responsible for ensuring `controller.headerHeight` was
  /// bumped to accommodate this.
  final double groupBandHeight;

  /// First N rows are pinned below the header and don't scroll. Respects
  /// `controller.rowHeightOf` if set, so variable-height frozen rows work
  /// alongside variable-height body rows.
  final int frozenRowCount;

  /// When `true`, a pinned footer band runs along the bottom showing each
  /// column's `aggregate` value via `controller.aggregateFor`. Empty
  /// aggregates draw an empty cell; the band's height is [footerHeight].
  final bool showAggregateFooter;
  final double footerHeight;

  /// Prefix every footer cell with its aggregate's label ("Sum: 1234").
  /// Per-column overrides via `GridColumn.aggregateLabel` win when set —
  /// `null` means "use the default name", `""` means "suppress".
  final bool showFooterLabels;

  /// Maps a display row to a section ID. When non-null and the resolver
  /// returns a non-null ID for the topmost visible body row, the painter
  /// replaces the column-header band with a sticky section header that
  /// holds the section's label. Rolls back to the column headers once
  /// scrolling lands on a row outside any section.
  final String? Function(int row)? sectionOf;

  /// Display-name resolver for the section ID returned by [sectionOf].
  /// Defaults to using the ID itself when null.
  final String Function(String sectionId)? sectionLabel;

  double get _frozenBandHeight {
    if (frozenRowCount == 0) return 0;
    final n = math.min(frozenRowCount, controller.source.rowCount);
    // rowYAt(n) is sum of heights of rows 0..n-1 — uniform → n*rowHeight,
    // variable → the prefix-sum buffer value. Same formula for both modes.
    return controller.rowYAt(n);
  }
  double get _footerH => showAggregateFooter ? footerHeight : 0.0;

  @override
  void paint(Canvas canvas, Size size) {
    final bg = Paint()..color = style.background;
    canvas.drawRect(Offset.zero & size, bg);

    final headerH = controller.headerHeight;
    final frozenH = _frozenBandHeight;
    final footerH = _footerH;
    final bodyTop = headerH + frozenH;
    final bodyBottom = (size.height - footerH).clamp(bodyTop, size.height);
    final bodyRect = Rect.fromLTWH(0, bodyTop, size.width,
        (bodyBottom - bodyTop).clamp(0, size.height));

    final n = controller.source.rowCount;
    final clampedFrozen = math.min(frozenRowCount, n);
    final firstRow = _firstVisibleBodyRow(clampedFrozen);
    final lastRow = _lastVisibleBodyRow(bodyRect.height, clampedFrozen);

    controller.source.prefetch(firstRow, lastRow);

    final leftPinW = controller.pinnedWidth(ColumnPin.left);
    final rightPinW = controller.pinnedWidth(ColumnPin.right);
    final scrollableLeft = leftPinW;
    final scrollableRight = (size.width - rightPinW).clamp(scrollableLeft, size.width);
    final scrollableBody = Rect.fromLTRB(
        scrollableLeft, bodyTop, scrollableRight, bodyBottom);

    // Body rows (everything below the frozen band).
    final bodyContentOffset =
        clampedFrozen > 0 ? controller.rowYAt(clampedFrozen) : 0.0;
    _paintScrollingBody(canvas, scrollableBody, firstRow, lastRow,
        bodyContentOffset, controller.scrollY);
    _paintPinned(canvas, ColumnPin.left, 0, bodyTop, bodyBottom, firstRow,
        lastRow, bodyContentOffset, controller.scrollY);
    _paintPinned(canvas, ColumnPin.right, scrollableRight, bodyTop,
        bodyBottom, firstRow, lastRow, bodyContentOffset, controller.scrollY);

    // Frozen band — same drawing code, but anchored at headerH with zero
    // scroll. Drawn AFTER the body so it sits on top of any partial body
    // row that might bleed up when scrollY < 0 (defensive).
    if (clampedFrozen > 0) {
      final frozenBodyRect = Rect.fromLTRB(
          scrollableLeft, headerH, scrollableRight, bodyTop);
      _paintScrollingBody(canvas, frozenBodyRect, 0, clampedFrozen - 1, 0, 0);
      _paintPinned(canvas, ColumnPin.left, 0, headerH, bodyTop, 0,
          clampedFrozen - 1, 0, 0);
      _paintPinned(canvas, ColumnPin.right, scrollableRight, headerH,
          bodyTop, 0, clampedFrozen - 1, 0, 0);

      // Divider line below the frozen band — subtle but useful.
      final divider = Paint()
        ..color = style.activeBorder
        ..strokeWidth = 1;
      canvas.drawLine(
          Offset(0, bodyTop), Offset(size.width, bodyTop), divider);
    }

    final activeSection = _activeSectionId(firstRow);
    if (activeSection != null) {
      _paintSectionAsHeader(canvas, size, activeSection);
    } else {
      _paintHeader(canvas, size, scrollableBody);
    }
    if (showAggregateFooter) {
      _paintFooter(canvas, size, bodyBottom, scrollableBody);
    }
    _paintActiveOverlay(canvas, size);
  }

  /// The section ID of the row currently sitting at the top of the body,
  /// or `null` if sections aren't configured / the row falls outside any
  /// section. Used to swap the column-header band for a section sticky.
  String? _activeSectionId(int firstBodyRow) {
    final resolver = sectionOf;
    if (resolver == null) return null;
    if (firstBodyRow < 0 || firstBodyRow >= controller.source.rowCount) {
      return null;
    }
    return resolver(firstBodyRow);
  }

  /// Paints the section sticky in the slot the column-header band would
  /// occupy, so the section label "takes over" the header while the user
  /// is scrolling through that section's rows. Group band and pinned
  /// column slots are left visible so the row-level identity (pinned
  /// idx / name) stays anchored even when the column titles disappear.
  void _paintSectionAsHeader(Canvas canvas, Size size, String sectionId) {
    final headerH = controller.headerHeight;
    final columnBandTop = groupBandHeight;
    final rect = Rect.fromLTWH(0, columnBandTop, size.width,
        headerH - columnBandTop);
    canvas.drawRect(rect, Paint()..color = style.activeBorder);

    final label = sectionLabel?.call(sectionId) ?? sectionId;
    final p = textCache.paragraph(
      label,
      fontSize: style.fontSize,
      color: const Color(0xFFFFFFFF),
      fontFamily: style.fontFamily,
      fontWeight: ui.FontWeight.w700,
      maxWidth: (rect.width - style.cellPaddingH * 2)
          .clamp(0, double.infinity),
      align: TextAlign.center,
    );
    final tx = rect.left + (rect.width - p.maxIntrinsicWidth) / 2;
    final ty = rect.top + (rect.height - p.height) / 2;
    canvas.drawParagraph(p, Offset(tx, ty));

    // Group band on top (still visible) and bottom divider.
    if (columnGroups.isNotEmpty && groupBandHeight > 0) {
      // Paint the group band as before so the per-group context survives
      // the section-takeover. Scrollable column groups still meaningful
      // even when the column titles are hidden under the section sticky.
      final scrollableLeft = controller.pinnedWidth(ColumnPin.left);
      final scrollableRight =
          (size.width - controller.pinnedWidth(ColumnPin.right))
              .clamp(scrollableLeft, size.width);
      _paintGroupBand(canvas, Rect.fromLTRB(
          scrollableLeft, 0, scrollableRight, groupBandHeight));
    }

    final divider = Paint()
      ..color = style.gridLine
      ..strokeWidth = 1;
    canvas.drawLine(
        Offset(0, headerH), Offset(size.width, headerH), divider);
  }

  void _paintFooter(Canvas canvas, Size size, double top, Rect scrollableBody) {
    final rect = Rect.fromLTWH(0, top, size.width, footerHeight);
    canvas.drawRect(rect, Paint()..color = style.headerBackground);

    final divider = Paint()
      ..color = style.gridLine
      ..strokeWidth = 1;
    canvas.drawLine(
        Offset(0, top), Offset(size.width, top), divider);

    // Scrolling footer cells — clipped to the same band as the body.
    canvas.save();
    canvas.clipRect(Rect.fromLTRB(
        scrollableBody.left, top, scrollableBody.right, top + footerHeight));
    var x = scrollableBody.left - controller.scrollX;
    for (var c = 0; c < controller.columns.length; c++) {
      final col = controller.columns[c];
      if (col.pin != ColumnPin.none) continue;
      final w = controller.widthOf(c);
      _drawAggregate(canvas, col, x, top, w);
      x += w;
    }
    canvas.restore();

    // Pinned columns (left + right), unclipped.
    var lx = 0.0;
    for (var c = 0; c < controller.columns.length; c++) {
      final col = controller.columns[c];
      if (col.pin != ColumnPin.left) continue;
      final w = controller.widthOf(c);
      _drawAggregate(canvas, col, lx, top, w);
      lx += w;
    }
    var rx = scrollableBody.right;
    for (var c = 0; c < controller.columns.length; c++) {
      final col = controller.columns[c];
      if (col.pin != ColumnPin.right) continue;
      final w = controller.widthOf(c);
      _drawAggregate(canvas, col, rx, top, w);
      rx += w;
    }
  }

  void _drawAggregate(Canvas canvas, GridColumn col, double x, double y,
      double w) {
    final value = controller.aggregateFor(col);
    if (value == null) return;
    // Format numeric aggregates with the column's own formatter when the
    // result type matches — keeps "$12.50" formatting consistent between
    // body and footer. Otherwise fall back to plain text.
    final formatted = (value is num) ? col.format(value) : value.toString();
    final label = _aggregateLabel(col);
    final text = label.isEmpty ? formatted : '$label: $formatted';
    final p = textCache.paragraph(
      text,
      fontSize: style.fontSize,
      color: style.headerText,
      fontFamily: style.fontFamily,
      fontWeight: ui.FontWeight.w600,
      maxWidth: (w - style.cellPaddingH * 2).clamp(0, double.infinity),
      align: col.align,
    );
    final tx = _textOffsetX(x, w, col.align);
    final ty = y + (footerHeight - p.height) / 2;
    canvas.drawParagraph(p, Offset(tx, ty));
  }

  /// Resolves the label string to prepend in the footer cell:
  ///   - column override wins when non-null (`""` suppresses)
  ///   - otherwise the global flag toggles the auto-derived name
  String _aggregateLabel(GridColumn col) {
    final override = col.aggregateLabel;
    if (override != null) return override;
    if (!showFooterLabels) return '';
    return GridAggregator.label(col.aggregate);
  }

  /// First body row that's even partially visible. The body's content-Y
  /// origin sits at `rowYAt(frozen)`; `scrollY` then offsets within the
  /// body. The same formula handles both uniform and variable modes.
  int _firstVisibleBodyRow(int frozen) {
    final offset = frozen > 0 ? controller.rowYAt(frozen) : 0.0;
    final row = controller.rowAtY(offset + controller.scrollY);
    return math.max(frozen, row);
  }

  int _lastVisibleBodyRow(double bodyH, int frozen) {
    final n = controller.source.rowCount;
    if (n == 0) return -1;
    final offset = frozen > 0 ? controller.rowYAt(frozen) : 0.0;
    final row = controller.rowAtY(offset + controller.scrollY + bodyH);
    return math.min(n - 1, row);
  }

  void _paintScrollingBody(Canvas canvas, Rect clip, int firstRow, int lastRow,
      double contentOffset, double scrollOffset) {
    if (firstRow > lastRow) return;
    canvas.save();
    canvas.clipRect(clip);

    final originX = clip.left - controller.scrollX;
    final rowStart = firstRow;
    final visibleRows = lastRow - firstRow + 1;

    // Pre-resolve per-row top-Y and height into local lists so we walk each
    // (column × row) pair without recomputing the prefix-sum lookup.
    final rowTops = List<double>.filled(visibleRows, 0);
    final rowHeights = List<double>.filled(visibleRows, 0);
    final firstRowY = controller.rowYAt(rowStart);
    for (var i = 0; i < visibleRows; i++) {
      final row = rowStart + i;
      rowTops[i] = clip.top +
          (controller.rowYAt(row) - contentOffset) -
          scrollOffset;
      rowHeights[i] = controller.rowHeightAt(row);
    }

    // Zebra striping.
    final zebra = Paint()..color = const Color(0x0AFFFFFF);
    for (var i = 0; i < visibleRows; i++) {
      if ((rowStart + i).isOdd) {
        canvas.drawRect(
          Rect.fromLTWH(clip.left, rowTops[i], clip.width, rowHeights[i]),
          zebra,
        );
      }
    }

    final gridPaint = Paint()
      ..color = style.gridLine
      ..strokeWidth = 1;

    // Walk every non-pinned column once, drawing its visible cells.
    var x = originX;
    for (var c = 0; c < controller.columns.length; c++) {
      final col = controller.columns[c];
      if (col.pin != ColumnPin.none) continue;
      final w = controller.widthOf(c);
      final right = x + w;
      if (right < clip.left) {
        x = right;
        continue;
      }
      if (x > clip.right) break;

      for (var i = 0; i < visibleRows; i++) {
        final row = rowStart + i;
        if (row >= controller.source.rowCount) break;
        _drawCell(canvas, col, row, x, rowTops[i], w, rowHeights[i]);
      }

      // Right edge of the column.
      canvas.drawLine(
        Offset(right, clip.top),
        Offset(right, clip.bottom),
        gridPaint,
      );

      x = right;
    }

    // Horizontal grid lines, one per row top + one closing line.
    for (var i = 0; i < visibleRows; i++) {
      canvas.drawLine(Offset(clip.left, rowTops[i]),
          Offset(clip.right, rowTops[i]), gridPaint);
    }
    if (visibleRows > 0) {
      final last = rowTops[visibleRows - 1] + rowHeights[visibleRows - 1];
      canvas.drawLine(
          Offset(clip.left, last), Offset(clip.right, last), gridPaint);
    } else {
      // Empty grid still wants a baseline so the header stays visually
      // anchored even when there are no rows yet.
      canvas.drawLine(Offset(clip.left, clip.top + firstRowY),
          Offset(clip.right, clip.top + firstRowY), gridPaint);
    }

    canvas.restore();
  }

  void _paintPinned(Canvas canvas, ColumnPin pin, double anchorX,
      double topY, double bottomY, int firstRow, int lastRow,
      double contentOffset, double scrollOffset) {
    final width = controller.pinnedWidth(pin);
    if (width == 0) return;
    if (firstRow > lastRow) return;
    final rect = Rect.fromLTWH(anchorX, topY, width, bottomY - topY);

    canvas.save();
    canvas.clipRect(rect);
    final fill = Paint()..color = style.headerBackground.withValues(alpha: 0.65);
    canvas.drawRect(rect, fill);

    final visibleRows = lastRow - firstRow + 1;
    final rowTops = List<double>.filled(visibleRows, 0);
    final rowHeights = List<double>.filled(visibleRows, 0);
    for (var i = 0; i < visibleRows; i++) {
      final row = firstRow + i;
      rowTops[i] = topY +
          (controller.rowYAt(row) - contentOffset) -
          scrollOffset;
      rowHeights[i] = controller.rowHeightAt(row);
    }

    final gridPaint = Paint()
      ..color = style.gridLine
      ..strokeWidth = 1;

    var x = anchorX;
    for (var c = 0; c < controller.columns.length; c++) {
      final col = controller.columns[c];
      if (col.pin != pin) continue;
      final w = controller.widthOf(c);
      for (var i = 0; i < visibleRows; i++) {
        final row = firstRow + i;
        if (row >= controller.source.rowCount) break;
        _drawCell(canvas, col, row, x, rowTops[i], w, rowHeights[i]);
      }
      canvas.drawLine(
        Offset(x + w, topY),
        Offset(x + w, bottomY),
        gridPaint,
      );
      x += w;
    }

    // Horizontal grid lines.
    for (var i = 0; i < visibleRows; i++) {
      canvas.drawLine(Offset(rect.left, rowTops[i]),
          Offset(rect.right, rowTops[i]), gridPaint);
    }
    if (visibleRows > 0) {
      final last = rowTops[visibleRows - 1] + rowHeights[visibleRows - 1];
      canvas.drawLine(
          Offset(rect.left, last), Offset(rect.right, last), gridPaint);
    }
    canvas.restore();
  }

  void _paintHeader(Canvas canvas, Size size, Rect scrollableRect) {
    final headerRect = Rect.fromLTWH(0, 0, size.width, controller.headerHeight);
    final paint = Paint()..color = style.headerBackground;
    canvas.drawRect(headerRect, paint);

    final columnBandTop = groupBandHeight;
    final columnBandHeight = controller.headerHeight - groupBandHeight;

    // Group band over the scrolling area, if any. We draw it before the
    // column headers so the column row's divider line lands on top.
    if (columnGroups.isNotEmpty && groupBandHeight > 0) {
      _paintGroupBand(canvas, scrollableRect);
    }

    // Scrolling column headers — sit below the group band.
    canvas.save();
    canvas.clipRect(Rect.fromLTRB(
        scrollableRect.left,
        columnBandTop,
        scrollableRect.right,
        controller.headerHeight));
    var x = scrollableRect.left - controller.scrollX;
    for (var c = 0; c < controller.columns.length; c++) {
      final col = controller.columns[c];
      if (col.pin != ColumnPin.none) continue;
      final w = controller.widthOf(c);
      _drawHeader(canvas, col, x, columnBandTop, w, columnBandHeight);
      x += w;
    }
    canvas.restore();

    // Pinned headers occupy the full header band (group band ignored).
    var leftX = 0.0;
    for (var c = 0; c < controller.columns.length; c++) {
      final col = controller.columns[c];
      if (col.pin != ColumnPin.left) continue;
      final w = controller.widthOf(c);
      _drawHeader(canvas, col, leftX, 0, w, controller.headerHeight);
      leftX += w;
    }
    var rightX = scrollableRect.right;
    for (var c = 0; c < controller.columns.length; c++) {
      final col = controller.columns[c];
      if (col.pin != ColumnPin.right) continue;
      final w = controller.widthOf(c);
      _drawHeader(canvas, col, rightX, 0, w, controller.headerHeight);
      rightX += w;
    }

    final divider = Paint()
      ..color = style.gridLine
      ..strokeWidth = 1;
    // Divider between column row and body.
    canvas.drawLine(
      Offset(0, controller.headerHeight),
      Offset(size.width, controller.headerHeight),
      divider,
    );
    // Divider between group band and column row (only when groups exist).
    if (columnGroups.isNotEmpty && groupBandHeight > 0) {
      canvas.drawLine(
        Offset(scrollableRect.left, columnBandTop),
        Offset(scrollableRect.right, columnBandTop),
        divider,
      );
    }
  }

  /// Walks the scrolling columns left-to-right, accumulating each group's
  /// contiguous run, and emits one labeled box per run. Non-contiguous
  /// groups (after a reorder) produce multiple boxes — same trade-off
  /// Excel makes.
  void _paintGroupBand(Canvas canvas, Rect scrollableRect) {
    canvas.save();
    canvas.clipRect(Rect.fromLTRB(scrollableRect.left, 0,
        scrollableRect.right, groupBandHeight));

    // Map column id → group for O(1) lookup.
    final groupOf = <String, GridColumnGroup>{};
    for (final g in columnGroups) {
      for (final id in g.columnIds) {
        groupOf[id] = g;
      }
    }

    final divider = Paint()
      ..color = style.gridLine
      ..strokeWidth = 1;

    GridColumnGroup? runGroup;
    double runStart = 0;
    var x = scrollableRect.left - controller.scrollX;
    for (var c = 0; c < controller.columns.length; c++) {
      final col = controller.columns[c];
      if (col.pin != ColumnPin.none) continue;
      final w = controller.widthOf(c);
      final g = groupOf[col.id];
      if (g != runGroup) {
        if (runGroup != null) {
          _emitGroupRun(canvas, runGroup, runStart, x, divider);
        }
        runGroup = g;
        runStart = x;
      }
      x += w;
    }
    if (runGroup != null) {
      _emitGroupRun(canvas, runGroup, runStart, x, divider);
    }
    canvas.restore();
  }

  void _emitGroupRun(Canvas canvas, GridColumnGroup group, double startX,
      double endX, Paint divider) {
    final fill = Paint()
      ..color = group.color ?? style.headerBackground;
    final rect = Rect.fromLTWH(startX, 0, endX - startX, groupBandHeight);
    canvas.drawRect(rect, fill);
    canvas.drawLine(Offset(endX, 0), Offset(endX, groupBandHeight), divider);

    final p = textCache.paragraph(
      group.label,
      fontSize: style.fontSize - 1,
      color: style.headerText,
      fontFamily: style.fontFamily,
      fontWeight: ui.FontWeight.w700,
      maxWidth:
          (rect.width - style.cellPaddingH * 2).clamp(0, double.infinity),
      align: TextAlign.center,
    );
    final tx = startX + (rect.width - p.maxIntrinsicWidth) / 2;
    final ty = (groupBandHeight - p.height) / 2;
    canvas.drawParagraph(p, Offset(tx, ty));
  }

  void _paintActiveOverlay(Canvas canvas, Size size) {
    final sel = controller.selection;
    if (sel == null) return;

    // Draw the range fill over every cell in the selection, then the
    // focus-cell highlight + border on top. Single-cell selections skip
    // the range pass entirely.
    if (!sel.isSingle) {
      _paintSelectionRange(canvas, size, sel);
    }

    final rect = cellRect(sel.focus, size);
    if (rect == null) return;

    final fill = Paint()..color = style.activeCell;
    canvas.drawRect(rect, fill);

    final border = Paint()
      ..color = style.activeBorder
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawRect(rect.deflate(0.75), border);
  }

  void _paintSelectionRange(Canvas canvas, Size size, GridSelection sel) {
    final anchorIdx = _columnIndex(sel.anchor.columnId);
    final focusIdx = _columnIndex(sel.focus.columnId);
    if (anchorIdx < 0 || focusIdx < 0) return;
    final firstCol = anchorIdx < focusIdx ? anchorIdx : focusIdx;
    final lastCol = anchorIdx > focusIdx ? anchorIdx : focusIdx;

    final fill = Paint()..color = style.selectionFill;
    // Clip away from the focus cell — we'll paint the strong fill on top
    // inside `_paintActiveOverlay`, but the lighter selection fill should
    // still cover the rest of the range without double-painting.
    for (var r = sel.firstRow; r <= sel.lastRow; r++) {
      for (var c = firstCol; c <= lastCol; c++) {
        final col = controller.columns[c];
        final cellGc = GridCell(r, col.id);
        if (cellGc == sel.focus) continue;
        final rect = cellRect(cellGc, size);
        if (rect == null) continue;
        canvas.drawRect(rect, fill);
      }
    }
  }

  void _drawCell(Canvas canvas, GridColumn col, int row, double x, double y,
      double w, double rowH) {
    final value = controller.source.valueAt(row, col.id);
    if (value == null) {
      final placeholder = Paint()..color = const Color(0x14FFFFFF);
      canvas.drawRect(
        Rect.fromLTWH(x + style.cellPaddingH, y + rowH / 2 - 4,
            w - style.cellPaddingH * 2, 8),
        placeholder,
      );
      return;
    }
    final builder = col.cellBuilder;
    if (builder != null) {
      builder(GridCellContext(
        canvas: canvas,
        rect: Rect.fromLTWH(x, y, w, rowH),
        value: value,
        row: row,
        column: col,
        textCache: textCache,
        fontSize: style.fontSize,
        fontFamily: style.fontFamily,
        cellTextColor: style.cellText,
        cellPaddingH: style.cellPaddingH,
      ));
      return;
    }
    final text = col.format(value);
    if (text.isEmpty) return;
    final p = textCache.paragraph(
      text,
      fontSize: style.fontSize,
      color: style.cellText,
      fontFamily: style.fontFamily,
      maxWidth: (w - style.cellPaddingH * 2).clamp(0, double.infinity),
      align: col.align,
    );
    final tx = _textOffsetX(x, w, col.align);
    // Wrap columns top-align with a small padding; non-wrap columns vertical
    // centre as before. Top-aligning prevents wrapped text from drifting up
    // out of the cell when the paragraph is taller than the row.
    final ty = col.wrap ? y + 4 : y + (rowH - p.height) / 2;
    canvas.drawParagraph(p, Offset(tx, ty));
  }

  void _drawHeader(Canvas canvas, GridColumn col, double x, double y,
      double w, double bandH) {
    final chain = controller.sort;
    final sortIdx = chain.indexWhere((s) => s.columnId == col.id);
    final isSorted = sortIdx >= 0;
    final isFiltered = controller.hasFilter(col.id);

    // Right-edge layout: [filter icon (12)] [sort arrow + position (8..14)].
    final sortW = isSorted ? (chain.length > 1 ? 22.0 : 14.0) : 0.0;
    final filterW = isFiltered ? 16.0 : 0.0;
    final reserved = sortW + filterW;

    final p = textCache.paragraph(
      col.header,
      fontSize: style.fontSize,
      color: style.headerText,
      fontFamily: style.fontFamily,
      fontWeight: ui.FontWeight.w600,
      maxWidth: (w - style.cellPaddingH * 2 - reserved).clamp(0, double.infinity),
      align: col.align,
    );
    final tx = _textOffsetX(x, w, col.align);
    final ty = y + (bandH - p.height) / 2;
    canvas.drawParagraph(p, Offset(tx, ty));

    var rightX = x + w - style.cellPaddingH;

    if (isSorted) {
      final spec = chain[sortIdx];
      final arrowCenter = Offset(rightX - 4, y + bandH / 2);
      _drawSortArrow(canvas, arrowCenter, spec.direction);
      if (chain.length > 1) {
        _drawSortPosition(canvas, arrowCenter, sortIdx + 1);
      }
      rightX -= sortW;
    }

    if (isFiltered) {
      _drawFunnel(canvas, Offset(rightX - 10, y + bandH / 2));
    }
  }

  /// Minimal funnel glyph — five points forming the silhouette, no fill.
  /// Drawn whenever the column has an active filter installed.
  void _drawFunnel(Canvas canvas, Offset center) {
    final paint = Paint()
      ..color = style.sortIndicator
      ..style = PaintingStyle.fill;
    final path = Path()
      ..moveTo(center.dx - 5, center.dy - 4)
      ..lineTo(center.dx + 5, center.dy - 4)
      ..lineTo(center.dx + 1.5, center.dy)
      ..lineTo(center.dx + 1.5, center.dy + 4)
      ..lineTo(center.dx - 1.5, center.dy + 4)
      ..lineTo(center.dx - 1.5, center.dy)
      ..close();
    canvas.drawPath(path, paint);
  }

  void _drawSortPosition(Canvas canvas, Offset arrowCenter, int position) {
    final p = textCache.paragraph(
      '$position',
      fontSize: style.fontSize - 3,
      color: style.sortIndicator,
      fontFamily: style.fontFamily,
      fontWeight: ui.FontWeight.w700,
    );
    // Sit the number just to the left of the arrow so it reads "2 ↑".
    final tx = arrowCenter.dx - 6 - p.maxIntrinsicWidth;
    final ty = arrowCenter.dy - p.height / 2;
    canvas.drawParagraph(p, Offset(tx, ty));
  }

  void _drawSortArrow(Canvas canvas, Offset center, SortDirection dir) {
    final paint = Paint()..color = style.sortIndicator;
    final path = Path();
    const half = 4.0;
    if (dir == SortDirection.ascending) {
      path
        ..moveTo(center.dx - half, center.dy + 2)
        ..lineTo(center.dx + half, center.dy + 2)
        ..lineTo(center.dx, center.dy - 3)
        ..close();
    } else {
      path
        ..moveTo(center.dx - half, center.dy - 2)
        ..lineTo(center.dx + half, center.dy - 2)
        ..lineTo(center.dx, center.dy + 3)
        ..close();
    }
    canvas.drawPath(path, paint);
  }

  double _textOffsetX(double cellX, double cellW, TextAlign align) {
    switch (align) {
      case TextAlign.right:
      case TextAlign.end:
        return cellX + style.cellPaddingH;
      case TextAlign.center:
        return cellX + style.cellPaddingH;
      case TextAlign.left:
      case TextAlign.start:
      case TextAlign.justify:
        return cellX + style.cellPaddingH;
    }
  }

  /// Resolves the on-screen rectangle of a cell, or `null` if it's clipped
  /// completely. Used by the active-cell overlay and the floating editor.
  Rect? cellRect(GridCell cell, Size size) {
    final colIndex = _columnIndex(cell.columnId);
    if (colIndex < 0) return null;
    final col = controller.columns[colIndex];
    final w = controller.widthOf(colIndex);
    final rowH = controller.rowHeightAt(cell.row);
    final n = math.min(frozenRowCount, controller.source.rowCount);
    final double y;
    if (cell.row < n) {
      // Frozen rows sit at fixed positions, no scrollY applied. rowYAt
      // handles uniform and variable heights with the same formula.
      y = controller.headerHeight + controller.rowYAt(cell.row);
    } else {
      final bodyTop = controller.headerHeight + _frozenBandHeight;
      final contentOffset = n > 0 ? controller.rowYAt(n) : 0.0;
      y = bodyTop +
          (controller.rowYAt(cell.row) - contentOffset) -
          controller.scrollY;
      if (y + rowH < bodyTop) return null;
    }
    if (y > size.height) return null;

    double x;
    switch (col.pin) {
      case ColumnPin.left:
        x = 0;
        for (var i = 0; i < colIndex; i++) {
          if (controller.columns[i].pin == ColumnPin.left) {
            x += controller.widthOf(i);
          }
        }
      case ColumnPin.right:
        final rightPinW = controller.pinnedWidth(ColumnPin.right);
        x = size.width - rightPinW;
        for (var i = 0; i < colIndex; i++) {
          if (controller.columns[i].pin == ColumnPin.right) {
            x += controller.widthOf(i);
          }
        }
      case ColumnPin.none:
        final leftPinW = controller.pinnedWidth(ColumnPin.left);
        x = leftPinW - controller.scrollX;
        for (var i = 0; i < colIndex; i++) {
          if (controller.columns[i].pin == ColumnPin.none) {
            x += controller.widthOf(i);
          }
        }
    }
    return Rect.fromLTWH(x, y, w, rowH);
  }

  /// Where a reorder drop at [position] would insert the column. Returns
  /// the index inside the same pin group as [draggedIndex] — we don't
  /// allow moving a left-pinned column into the scrolling area or vice
  /// versa, because that breaks the painter's pinning assumptions. `null`
  /// if no valid drop target was found (pointer outside the header).
  int? headerInsertionIndexAt(
      Offset position, Size size, int draggedIndex) {
    if (position.dy >= controller.headerHeight) return null;
    final draggedCol = controller.columns[draggedIndex];
    final draggedPin = draggedCol.pin;
    final draggedGroup = _groupIdOf(draggedCol.id);

    double startX;
    if (draggedPin == ColumnPin.left) {
      startX = 0;
    } else if (draggedPin == ColumnPin.right) {
      startX = size.width - controller.pinnedWidth(ColumnPin.right);
    } else {
      startX = controller.pinnedWidth(ColumnPin.left) - controller.scrollX;
    }

    // First pass: walk to populate the running x position and accept-flags.
    // Group-aware reorder: only same-group siblings (including "no group ↔ no
    // group") are valid drop targets. Columns in a different group are
    // skipped without advancing the registered drop index, so dragging an
    // ungrouped column past a grouped run can't split the group.
    var x = startX;
    var lastIdx = -1;
    for (var i = 0; i < controller.columns.length; i++) {
      final col = controller.columns[i];
      if (col.pin != draggedPin) continue;
      final w = controller.widthOf(i);
      final mid = x + w / 2;
      final sameGroup = _groupIdOf(col.id) == draggedGroup;
      if (sameGroup) {
        if (position.dx < mid) return i;
        lastIdx = i;
      }
      x += w;
    }
    return lastIdx >= 0 ? lastIdx : null;
  }

  /// Group ID owning [columnId], or `null` if the column isn't grouped.
  /// Cached lookup would shave a few microseconds but reorder is a rare
  /// gesture so we live with the linear scan.
  String? _groupIdOf(String columnId) {
    for (final g in columnGroups) {
      if (g.columnIds.contains(columnId)) return g.id;
    }
    return null;
  }

  /// Resolves a pointer above the header to its column + resize-zone flag.
  /// Returns `null` if the pointer is outside the column-header band — that
  /// includes the group-band area on top, since groups aren't sortable or
  /// resizable.
  HeaderHit? headerHitAt(Offset position, Size size) {
    if (position.dy < groupBandHeight) return null;
    if (position.dy >= controller.headerHeight) return null;
    final zone = style.resizeHitZone;

    final leftPinW = controller.pinnedWidth(ColumnPin.left);
    final rightPinW = controller.pinnedWidth(ColumnPin.right);

    if (position.dx < leftPinW) {
      var x = 0.0;
      for (var i = 0; i < controller.columns.length; i++) {
        if (controller.columns[i].pin != ColumnPin.left) continue;
        final w = controller.widthOf(i);
        if (position.dx < x + w) {
          return HeaderHit(i, (x + w - position.dx) <= zone);
        }
        x += w;
      }
      return null;
    }

    if (position.dx > size.width - rightPinW) {
      var x = size.width - rightPinW;
      for (var i = 0; i < controller.columns.length; i++) {
        if (controller.columns[i].pin != ColumnPin.right) continue;
        final w = controller.widthOf(i);
        if (position.dx < x + w) {
          return HeaderHit(i, (x + w - position.dx) <= zone);
        }
        x += w;
      }
      return null;
    }

    var x = leftPinW - controller.scrollX;
    for (var i = 0; i < controller.columns.length; i++) {
      if (controller.columns[i].pin != ColumnPin.none) continue;
      final w = controller.widthOf(i);
      if (position.dx < x + w) {
        return HeaderHit(i, (x + w - position.dx) <= zone);
      }
      x += w;
    }
    return null;
  }

  /// Inverse of [cellRect]: resolves a pointer position to a (row, column).
  GridCell? cellAt(Offset position, Size size) {
    if (position.dy < controller.headerHeight) return null;
    final n = math.min(frozenRowCount, controller.source.rowCount);
    final frozenH = _frozenBandHeight;
    final bodyTop = controller.headerHeight + frozenH;

    int row;
    if (position.dy < bodyTop && n > 0) {
      // Frozen band — `rowAtY` does the right thing in both uniform and
      // variable modes (binary search vs integer divide).
      row = controller.rowAtY(position.dy - controller.headerHeight);
      if (row < 0 || row >= n) return null;
    } else {
      final contentOffset = n > 0 ? controller.rowYAt(n) : 0.0;
      final contentY = (position.dy - bodyTop) + controller.scrollY + contentOffset;
      row = controller.rowAtY(contentY);
      if (row < n || row >= controller.source.rowCount) return null;
    }

    final leftPinW = controller.pinnedWidth(ColumnPin.left);
    final rightPinW = controller.pinnedWidth(ColumnPin.right);

    if (position.dx < leftPinW) {
      var x = 0.0;
      for (var i = 0; i < controller.columns.length; i++) {
        final col = controller.columns[i];
        if (col.pin != ColumnPin.left) continue;
        final w = controller.widthOf(i);
        if (position.dx < x + w) return GridCell(row, col.id);
        x += w;
      }
      return null;
    }

    if (position.dx > size.width - rightPinW) {
      var x = size.width - rightPinW;
      for (var i = 0; i < controller.columns.length; i++) {
        final col = controller.columns[i];
        if (col.pin != ColumnPin.right) continue;
        final w = controller.widthOf(i);
        if (position.dx < x + w) return GridCell(row, col.id);
        x += w;
      }
      return null;
    }

    var x = leftPinW - controller.scrollX;
    for (var i = 0; i < controller.columns.length; i++) {
      final col = controller.columns[i];
      if (col.pin != ColumnPin.none) continue;
      final w = controller.widthOf(i);
      if (position.dx < x + w) return GridCell(row, col.id);
      x += w;
    }
    return null;
  }

  int _columnIndex(String id) {
    for (var i = 0; i < controller.columns.length; i++) {
      if (controller.columns[i].id == id) return i;
    }
    return -1;
  }

  @override
  bool shouldRepaint(covariant GridPainter old) =>
      old.controller != controller ||
      old.style != style ||
      old.textCache != textCache;
}
