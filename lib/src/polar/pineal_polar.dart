import 'package:flutter/widgets.dart';

import 'pie_series.dart';
import 'polar_coordinates.dart';
import 'radar_series.dart';

/// Declarative entry point for polar visualizations.
///
/// Pass any combination of [PieSeries] and [RadarSeries]; the widget figures
/// out how to lay them out inside the same circular plot.
class PinealPolar extends StatelessWidget {
  const PinealPolar({
    super.key,
    this.pies = const <PieSeries>[],
    this.radars = const <RadarSeries>[],
    this.radarAxisLabels,
    this.radarRings = 4,
    this.padding = const EdgeInsets.all(24),
    this.onSliceTap,
  });

  final List<PieSeries> pies;
  final List<RadarSeries> radars;
  final List<String>? radarAxisLabels;
  final int radarRings;
  final EdgeInsets padding;

  /// Reports `(pieIndex, sliceIndex)` when a pie slice is tapped.
  final void Function(int pieIndex, int sliceIndex)? onSliceTap;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (ctx, constraints) {
      final size = constraints.biggest;
      final plot = Rect.fromLTRB(
        padding.left,
        padding.top,
        size.width - padding.right,
        size.height - padding.vertical,
      );
      final coords = PolarCoordinates(bounds: plot);
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: onSliceTap == null
            ? null
            : (d) {
                for (var i = 0; i < pies.length; i++) {
                  final hit = pies[i].hitTest(d.localPosition, coords);
                  if (hit >= 0) {
                    onSliceTap!(i, hit);
                    return;
                  }
                }
              },
        child: RepaintBoundary(
          child: CustomPaint(
            painter: _PolarPainter(
              pies: pies,
              radars: radars,
              radarLabels: radarAxisLabels,
              radarRings: radarRings,
              padding: padding,
            ),
            size: Size.infinite,
          ),
        ),
      );
    });
  }
}

class _PolarPainter extends CustomPainter {
  _PolarPainter({
    required this.pies,
    required this.radars,
    required this.radarLabels,
    required this.radarRings,
    required this.padding,
  });

  final List<PieSeries> pies;
  final List<RadarSeries> radars;
  final List<String>? radarLabels;
  final int radarRings;
  final EdgeInsets padding;

  @override
  void paint(Canvas canvas, Size size) {
    final plot = Rect.fromLTRB(
      padding.left,
      padding.top,
      size.width - padding.right,
      size.height - padding.bottom,
    );
    final coords = PolarCoordinates(bounds: plot);

    if (radars.isNotEmpty) {
      RadarSeries.paintGrid(
        canvas,
        coords,
        axisCount: radars.first.values.length,
        rings: radarRings,
        labels: radarLabels,
      );
      for (final r in radars) {
        r.paint(canvas, coords);
      }
    }
    for (final p in pies) {
      p.paint(canvas, coords);
    }
  }

  @override
  bool shouldRepaint(covariant _PolarPainter old) {
    return old.pies != pies ||
        old.radars != radars ||
        old.radarLabels != radarLabels ||
        old.padding != padding;
  }
}
