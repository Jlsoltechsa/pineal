/// Pineal KPI — single-number-summary cards.
///
/// These widgets sit alongside the chart modules but answer a different
/// question: instead of showing a distribution or a trend, each one
/// reduces the data to a single insight — *did we hit the goal?*, *how
/// far through the funnel?*, *where does this score fall in the
/// distribution?*
///
/// They use `CustomPainter` + Flutter widgets rather than the
/// raw-buffer pipeline of `cartesian.dart` etc., because the data
/// volumes here are tiny (a handful of stages, one observation, a
/// quarter of dates) and the layout concerns dominate.
library;

export 'src/kpi/bullet.dart';
export 'src/kpi/calendar_heatmap.dart';
export 'src/kpi/boxplot.dart';
export 'src/kpi/funnel.dart';
export 'src/kpi/gauge.dart';
