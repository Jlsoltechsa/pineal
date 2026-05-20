import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Simple box plot — min, Q1, median, Q3, max, with an optional
/// user-marker dot to highlight a single observation against the
/// distribution.
class KpiBoxplot extends StatelessWidget {
  const KpiBoxplot({
    super.key,
    required this.values,
    this.mark,
    this.boxColor = const Color(0xFF1E88E5),
    this.markerColor = const Color(0xFFEAAA2F),
    this.axisColor = const Color(0xFFD9DEE9),
    this.labelColor = const Color(0xFF5A6A8A),
    this.emptyMessage = 'No data',
    this.height = 60,
  });

  final List<num> values;

  /// Optional observation to highlight (typically the user's own
  /// value). When non-null, a colored dot is drawn at that x-position.
  final num? mark;

  final Color boxColor;
  final Color markerColor;
  final Color axisColor;
  final Color labelColor;
  final String emptyMessage;
  final double height;

  @override
  Widget build(BuildContext context) {
    if (values.isEmpty) {
      return Text(
        emptyMessage,
        style: TextStyle(color: labelColor, fontSize: 12),
      );
    }
    final sorted = [...values]..sort();
    double q(double p) {
      final idx = ((sorted.length - 1) * p).round();
      return sorted[idx].toDouble();
    }

    final lo = sorted.first.toDouble();
    final hi = sorted.last.toDouble();
    final q1 = q(0.25), q2 = q(0.5), q3 = q(0.75);
    final span = (hi - lo) == 0 ? 1.0 : (hi - lo);
    return SizedBox(
      height: height,
      child: LayoutBuilder(builder: (_, c) {
        double x(double v) => c.maxWidth * (v - lo) / span;
        return Stack(
          children: [
            Positioned(
              left: 0,
              right: 0,
              top: 28,
              height: 2,
              child: Container(color: axisColor),
            ),
            Positioned(
              left: x(q1),
              top: 14,
              width: math.max(2.0, x(q3) - x(q1)),
              height: 30,
              child: Container(
                decoration: BoxDecoration(
                  color: boxColor.withValues(alpha: 0.30),
                  border: Border.all(color: boxColor),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
            Positioned(
              left: x(q2) - 1,
              top: 14,
              width: 2,
              height: 30,
              child: Container(color: boxColor),
            ),
            if (mark != null)
              Positioned(
                left: x(mark!.toDouble()) - 5,
                top: 14,
                width: 10,
                height: 30,
                child: Container(
                  decoration: BoxDecoration(
                    color: markerColor,
                    border: Border.all(color: Colors.white, width: 2),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            Positioned(
              left: 0,
              bottom: 0,
              child: Text(
                lo.toStringAsFixed(0),
                style: TextStyle(fontSize: 10, color: labelColor),
              ),
            ),
            Positioned(
              right: 0,
              bottom: 0,
              child: Text(
                hi.toStringAsFixed(0),
                style: TextStyle(fontSize: 10, color: labelColor),
              ),
            ),
          ],
        );
      }),
    );
  }
}
