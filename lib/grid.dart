/// Pineal grid — single-pass DataGrid for million-row datasets.
///
/// Built on the same `Float32List` + `RepaintBoundary` + `TextCache`
/// machinery as the chart modules: cells are not widgets, they're a function
/// of `(row, column) -> Canvas`. Hit-testing is arithmetic over the column
/// widths and the uniform row height, so a one-million-row dataset costs no
/// more than a one-thousand-row one — the painter only touches the visible
/// window.
///
/// Editing uses a single floating `TextField` overlay positioned by the
/// painter, which keeps the focus model identical to a standard Flutter
/// form: copy/paste, IME, autocomplete and validation all work without
/// per-cell widgets.
library;

export 'core.dart';

export 'src/grid/column.dart';
export 'src/grid/data_source.dart'
    show
        GridDataSource,
        InMemoryGridDataSource,
        CellWrite,
        GridFilter,
        TextFilter,
        ValueSetFilter,
        NumericRangeFilter,
        DateRangeFilter;
export 'src/grid/grid_aggregator.dart';
export 'src/grid/grid_controller.dart';
export 'src/grid/grid_export.dart';
export 'src/grid/grid_painter.dart' show GridStyle, HeaderHit;
export 'src/grid/paged_data_source.dart';
// GridSelection lives in grid_controller.dart already exported above.
export 'src/grid/pineal_grid.dart';
