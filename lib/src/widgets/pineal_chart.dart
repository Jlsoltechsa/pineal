import 'package:flutter/widgets.dart';

import '../core/coordinate_system.dart';
import '../core/pineal_core.dart';
import '../core/viewport.dart';
import '../interaction/gesture_handler.dart';
import '../interaction/interaction_layer.dart';
import '../painters/axis.dart';
import '../painters/text_cache.dart';
import '../render/chart_painter.dart';
import '../series/series.dart';
import 'anchored_overlay.dart';

/// Declarative entry point. Behaves like any other Flutter widget; under the
/// hood it owns a [PinealCore], a [ChartViewport], a [PictureCache] and two
/// repaint boundaries (chart body + interaction overlay).
class PinealChart extends StatefulWidget {
  const PinealChart({
    super.key,
    required this.series,
    required this.yAxes,
    this.xRange,
    this.padding = const EdgeInsets.fromLTRB(48, 12, 16, 28),
    this.axisStyle = const AxisStyle(),
    this.interactionStyle = const InteractionStyle(),
    this.xFormatter = defaultFormatter,
    this.yFormatter = defaultFormatter,
    this.allowZoom = true,
    this.allowYPan = false,
    this.showInteraction = true,
    this.anchors = const <DataAnchor>[],
  });

  final List<Series> series;
  final List<YAxisSpec> yAxes;

  /// Optional initial X window. Defaults to the union of every series'
  /// `xMin..xMax`.
  final ({double min, double max})? xRange;

  final EdgeInsets padding;
  final AxisStyle axisStyle;
  final InteractionStyle interactionStyle;
  final String Function(double, Scale) xFormatter;
  final String Function(double, Scale) yFormatter;
  final bool allowZoom;
  final bool allowYPan;
  final bool showInteraction;

  /// Optional list of widgets pinned to data coordinates. Only those whose
  /// projection lands inside the plot rect are inserted into the tree.
  final List<DataAnchor> anchors;

  @override
  State<PinealChart> createState() => _PinealChartState();
}

class _PinealChartState extends State<PinealChart> {
  late PinealCore _core;
  late ChartViewport _viewport;
  late Listenable _repaintTrigger;
  final TextCache _textCache = TextCache();
  final PictureCache _pictureCache = PictureCache();

  @override
  void initState() {
    super.initState();
    _build();
    _viewport.addListener(_onViewportChange);
    _attachSeriesListeners();
  }

  void _onViewportChange() {
    if (_viewport.lastChange != ChartViewportChange.pan) {
      _pictureCache.invalidate();
    }
  }

  void _onSeriesTick() {
    // Animated series mutate their internal vertex set every frame, so the
    // raster cache must be discarded each tick — pan-blits don't apply.
    _pictureCache.invalidate();
  }

  void _attachSeriesListeners() {
    final triggers = <Listenable>[_core];
    for (final s in widget.series) {
      final t = s.repaintTrigger;
      if (t != null) {
        triggers.add(t);
        t.addListener(_onSeriesTick);
      }
    }
    _repaintTrigger = Listenable.merge(triggers);
  }

  void _detachSeriesListeners(List<Series> series) {
    for (final s in series) {
      s.repaintTrigger?.removeListener(_onSeriesTick);
    }
  }

  void _build() {
    final xRange = widget.xRange ?? _unionX(widget.series);
    _viewport = ChartViewport(
      xMin: xRange.min,
      xMax: xRange.max,
      yMin: widget.yAxes.first.min,
      yMax: widget.yAxes.first.max,
    );
    _core = PinealCore(
      xViewport: _viewport,
      yAxes: widget.yAxes,
      series: widget.series,
    );
  }

  ({double min, double max}) _unionX(List<Series> series) {
    if (series.isEmpty) return (min: 0.0, max: 1.0);
    var lo = series.first.data.xMin;
    var hi = series.first.data.xMax;
    for (final s in series.skip(1)) {
      if (s.data.xMin < lo) lo = s.data.xMin;
      if (s.data.xMax > hi) hi = s.data.xMax;
    }
    if (lo == hi) hi = lo + 1;
    return (min: lo, max: hi);
  }

  @override
  void didUpdateWidget(covariant PinealChart old) {
    super.didUpdateWidget(old);
    final seriesChanged = !identical(old.series, widget.series) ||
        old.series.length != widget.series.length;
    final axesChanged = !identical(old.yAxes, widget.yAxes);
    if (seriesChanged || axesChanged) {
      _detachSeriesListeners(old.series);
      _viewport.removeListener(_onViewportChange);
      _core.dispose();
      _pictureCache.invalidate();
      _textCache.clear();
      _build();
      _viewport.addListener(_onViewportChange);
      _attachSeriesListeners();
    }
  }

  @override
  void dispose() {
    _detachSeriesListeners(widget.series);
    _viewport.removeListener(_onViewportChange);
    _viewport.dispose();
    _core.dispose();
    _pictureCache.invalidate();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final chartLayer = RepaintBoundary(
      child: CustomPaint(
        painter: ChartPainter(
          core: _core,
          padding: widget.padding,
          axisStyle: widget.axisStyle,
          xFormatter: widget.xFormatter,
          yFormatter: widget.yFormatter,
          textCache: _textCache,
          pictureCache: _pictureCache,
          repaintListenable: _repaintTrigger,
        ),
        size: Size.infinite,
      ),
    );

    final stack = Stack(
      fit: StackFit.expand,
      children: [
        chartLayer,
        if (widget.anchors.isNotEmpty)
          AnchoredOverlay(
            core: _core,
            padding: widget.padding,
            anchors: widget.anchors,
          ),
        if (widget.showInteraction)
          InteractionLayer(
            core: _core,
            padding: widget.padding,
            style: widget.interactionStyle,
            xFormatter: widget.xFormatter,
            yFormatter: widget.yFormatter,
          ),
      ],
    );

    return GestureHandler(
      viewport: _viewport,
      allowZoom: widget.allowZoom,
      allowYPan: widget.allowYPan,
      child: stack,
    );
  }
}
