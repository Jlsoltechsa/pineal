/// Pineal — umbrella entry point.
///
/// Re-exports every public module. Convenient for prototyping, but if you
/// ship to production prefer the narrower entry points so tree-shaking can
/// prune what you don't use:
///
/// - `package:pineal/core.dart` — shared primitives only.
/// - `package:pineal/cartesian.dart` — time-series / multi-axis charts.
/// - `package:pineal/mesh.dart` — node/edge graphs.
/// - `package:pineal/polar.dart` — pie / donut / radar.
/// - `package:pineal/heatmap.dart` — dense matrix bitmaps.
/// - `package:pineal/treemap.dart` — squarified hierarchical layouts.
/// - `package:pineal/financial.dart` — OHLC candlesticks on top of cartesian.
/// - `package:pineal/flow.dart` — Sankey / alluvial diagrams.
/// - `package:pineal/grid.dart` — virtual DataGrid for tabular data.
/// - `package:pineal/geo.dart` — vector maps via `drawVertices`.
/// - `package:pineal/gantt.dart` — virtualized chronological RenderBox.
/// - `package:pineal/user_table.dart` — pretty paginated table for
///   person/user lists (avatar initials, badges, hover, action).
library pineal;

export 'cartesian.dart';
export 'mesh.dart';
export 'polar.dart';
export 'heatmap.dart';
export 'treemap.dart';
export 'financial.dart';
export 'flow.dart';
export 'stream.dart';
export 'phosphor.dart';
export 'grid.dart';
export 'geo.dart';
export 'gantt.dart';
export 'export.dart';
export 'user_table.dart';
