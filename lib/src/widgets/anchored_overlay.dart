import 'package:flutter/widgets.dart';

import '../core/pineal_core.dart';

/// Pins a Flutter widget to a data coordinate.
///
/// Only anchors whose projection falls inside the plot rect are inserted
/// into the widget tree, so a million markers on a stock chart costs nothing
/// when you're zoomed in on a single day.
@immutable
class DataAnchor {
  const DataAnchor({
    required this.x,
    required this.y,
    required this.builder,
    this.yAxisId = 'y',
    this.alignment = Alignment.center,
  });

  final double x;
  final double y;
  final String yAxisId;
  final Alignment alignment;
  final WidgetBuilder builder;
}

/// Renders [anchors] over a chart, reacting to viewport changes.
class AnchoredOverlay extends StatelessWidget {
  const AnchoredOverlay({
    super.key,
    required this.core,
    required this.padding,
    required this.anchors,
  });

  final PinealCore core;
  final EdgeInsets padding;
  final List<DataAnchor> anchors;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: false,
      child: LayoutBuilder(
        builder: (ctx, constraints) {
          return AnimatedBuilder(
            animation: core,
            builder: (ctx, _) {
              final size = constraints.biggest;
              final plot = Rect.fromLTWH(
                padding.left,
                padding.top,
                (size.width - padding.horizontal).clamp(1.0, double.infinity),
                (size.height - padding.vertical).clamp(1.0, double.infinity),
              );

              final children = <Widget>[];
              for (final a in anchors) {
                if (a.x < core.xViewport.xMin || a.x > core.xViewport.xMax) {
                  continue;
                }
                final spec = core.yAxes.firstWhere(
                  (s) => s.id == a.yAxisId,
                  orElse: () => core.yAxes.first,
                );
                final yw = core.yWindow(spec.id);
                if (a.y < yw.min || a.y > yw.max) continue;

                final coords = core.coordsForAxis(spec.id, plot);
                final pos = coords.project(a.x, a.y);
                if (!plot.contains(pos)) continue;

                children.add(
                  _PositionedAnchor(
                    key: ValueKey(a),
                    position: pos,
                    alignment: a.alignment,
                    child: Builder(builder: a.builder),
                  ),
                );
              }

              return Stack(
                clipBehavior: Clip.hardEdge,
                children: children,
              );
            },
          );
        },
      ),
    );
  }
}

class _PositionedAnchor extends StatelessWidget {
  const _PositionedAnchor({
    super.key,
    required this.position,
    required this.alignment,
    required this.child,
  });

  final Offset position;
  final Alignment alignment;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // Use a Stack-relative Positioned with alignment via FractionalTranslation.
    return Positioned(
      left: position.dx,
      top: position.dy,
      child: FractionalTranslation(
        translation: Offset(
          (alignment.x - 1) * 0.5,
          (alignment.y - 1) * 0.5,
        ),
        child: child,
      ),
    );
  }
}
