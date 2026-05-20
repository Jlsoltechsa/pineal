/// Pineal cartesian — time series, multi-axis charts, area/bar/line plots.
///
/// Importing this entry point pulls in [core.dart] automatically. If you
/// only build cartesian charts, prefer this over `package:pineal/pineal.dart`
/// — AOT release builds will tree-shake every symbol from the mesh family.
library pineal.cartesian;

export 'core.dart';

export 'src/data/summary.dart';

export 'src/core/coordinate_system.dart';
export 'src/core/viewport.dart';
export 'src/core/pineal_core.dart';

export 'src/series/series.dart';
export 'src/series/line_series.dart';
export 'src/series/bar_series.dart';
export 'src/series/stacked_bar_series.dart';
export 'src/series/horizontal_bar_series.dart';
export 'src/series/scatter_series.dart';
export 'src/series/area_series.dart';
export 'src/series/animated_line_series.dart';

export 'src/painters/axis.dart';

export 'src/interaction/interaction_layer.dart';
export 'src/interaction/gesture_handler.dart';

export 'src/render/chart_painter.dart';

export 'src/widgets/pineal_chart.dart';
export 'src/widgets/anchored_overlay.dart';
