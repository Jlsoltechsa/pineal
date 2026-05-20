import 'dart:ui';

import '../painters/text_cache.dart';

/// Where a column sticks when the user scrolls horizontally.
enum ColumnPin { none, left, right }

/// Aggregate function shown in the column's footer cell. `none` skips the
/// footer for that column. Aggregates run over the currently-displayed
/// rows (filter + sort applied), so the footer always agrees with the
/// view. Results are cached on the controller and invalidated on source
/// change.
enum GridAggregate { none, count, sum, avg, min, max }

/// How the grid decides a column's width when no fixed [GridColumn.width] is set.
///
/// - [viewport]: measure only the rows currently on screen + headers. Cheap,
///   produces "good enough" widths in <1ms. Columns may jitter as new long
///   strings scroll in.
/// - [sampled]: reservoir-sample 2–5k rows across the dataset to anchor the
///   width. Runs on the next frame so the first paint stays snappy.
/// - [exhaustive]: scan every row. Expensive; meant for offline use like PDF
///   export, not interactive scrolling.
enum AutoFitMode { viewport, sampled, exhaustive }

/// Declarative spec for one column. Immutable — mutate via [GridController].
class GridColumn {
  const GridColumn({
    required this.id,
    required this.header,
    this.width,
    this.minWidth = 32,
    this.maxWidth = 600,
    this.pin = ColumnPin.none,
    this.align = TextAlign.left,
    this.editable = false,
    this.sortable = true,
    this.formatter,
    this.autoFit = AutoFitMode.viewport,
    this.wrap = false,
    this.aggregate = GridAggregate.none,
    this.aggregateLabel,
    this.cellBuilder,
  });

  final String id;
  final String header;

  /// Explicit width in logical pixels. `null` means auto-fit.
  final double? width;
  final double minWidth;
  final double maxWidth;

  final ColumnPin pin;
  final TextAlign align;
  final bool editable;
  final bool sortable;

  /// Optional value-to-string formatter. Falls back to `value?.toString() ?? ''`.
  final String Function(Object? value)? formatter;

  /// Strategy used when [width] is null.
  final AutoFitMode autoFit;

  /// When `true`, the painter lays out cell text with the column's width
  /// as the wrap constraint and top-aligns the result instead of vertically
  /// centering. Useful for `notes`-style columns that hold paragraphs.
  /// Pair with `PinealGrid(autoSizeRows: true)` for the row height to
  /// follow the wrapped content automatically.
  final bool wrap;

  /// Footer aggregate computed over the displayed rows for this column.
  /// `none` (default) leaves the footer cell empty. Sum/avg/min/max
  /// silently ignore non-numeric values so a categorical column with an
  /// accidental `count` still produces a useful number.
  final GridAggregate aggregate;

  /// Optional label rendered before the aggregate value when the grid's
  /// `aggregateFooterShowLabels` flag is on (or unconditionally when
  /// non-null). `null` → use the default from [GridAggregator.label]
  /// ("Sum", "Avg", …). Set the empty string to suppress the label even
  /// when the global flag is on (e.g. an unlabeled total row).
  final String? aggregateLabel;

  /// Optional custom painter for the cell body. When non-null, the grid
  /// stops drawing the default `format(value)` text and hands the cell off
  /// to this callback. The receiver gets the canvas already clipped to the
  /// cell rect, the resolved value, the row index, the column spec, plus
  /// the same `GridStyle` and `TextCache` the default painter uses — so
  /// badges / sparklines / micro-bars can share the layout cache without
  /// allocating their own paragraph builders.
  ///
  /// Hit-testing isn't routed through here; for clickable cells, listen
  /// at the [PinealGrid] level via `onCellTap`. A button-cell pattern
  /// is: render a visual button here, hook `onCellTap`, dispatch by
  /// column id.
  final GridCellBuilder? cellBuilder;

  String format(Object? value) {
    if (formatter != null) return formatter!(value);
    if (value == null) return '';
    if (value is double) {
      return value == value.truncateToDouble()
          ? value.toStringAsFixed(0)
          : value.toStringAsFixed(2);
    }
    return value.toString();
  }
}

/// Signature for [GridColumn.cellBuilder] — callers draw whatever they
/// want inside `ctx.rect`. The canvas is already clipped to the cell's
/// visible area by the grid painter; the caller is responsible for
/// vertical padding and alignment within that rect.
typedef GridCellBuilder = void Function(GridCellContext ctx);

/// Context handed to [GridCellBuilder] callbacks. Exposes the bits a
/// custom renderer typically needs without leaking painter internals.
class GridCellContext {
  GridCellContext({
    required this.canvas,
    required this.rect,
    required this.value,
    required this.row,
    required this.column,
    required this.textCache,
    required this.fontSize,
    required this.fontFamily,
    required this.cellTextColor,
    required this.cellPaddingH,
  });

  final Canvas canvas;
  final Rect rect;
  final Object? value;
  final int row;
  final GridColumn column;
  final TextCache textCache;

  /// Mirrors `GridStyle.fontSize` so badge labels stay in lockstep with
  /// the default cell text.
  final double fontSize;
  final String? fontFamily;
  final Color cellTextColor;
  final double cellPaddingH;
}

/// Header-band grouping. Each group spans the columns named in [columnIds],
/// rendered as a labeled bar above the column headers. Pinned columns are
/// excluded from group rendering — they keep the full-height single-row
/// header look, since groups can't sensibly span the pinned/scrolling
/// boundary.
///
/// If a group's columns aren't contiguous in display order, the painter
/// draws one labeled span per contiguous run. Reorder a column out of its
/// group and you'll see the gap.
class GridColumnGroup {
  const GridColumnGroup({
    required this.id,
    required this.label,
    required this.columnIds,
    this.color,
  });

  final String id;
  final String label;
  final List<String> columnIds;

  /// Optional accent fill. When `null`, the group uses [GridStyle.headerBackground].
  final Color? color;
}
