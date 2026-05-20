import 'package:flutter/material.dart';

/// Bullet chart — a horizontal bar with a target marker overlay.
///
/// Useful for "actual vs goal" comparisons where readers need to see at
/// a glance whether [value] has reached [target] (both `0..100`).
class KpiBullet extends StatelessWidget {
  const KpiBullet({
    super.key,
    required this.value,
    required this.target,
    this.label,
    this.color = const Color(0xFF1E88E5),
    this.trackColor = const Color(0xFFE7ECF4),
    this.markerColor = const Color(0xFF12182A),
    this.labelColor = const Color(0xFF5A6A8A),
    this.barHeight = 18,
  });

  /// 0..100.
  final double value;

  /// 0..100.
  final double target;

  final String? label;
  final Color color;
  final Color trackColor;
  final Color markerColor;
  final Color labelColor;
  final double barHeight;

  @override
  Widget build(BuildContext context) {
    final t = (target / 100.0).clamp(0.0, 1.0);
    final v = (value / 100.0).clamp(0.0, 1.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (label != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              label!,
              style: TextStyle(
                fontSize: 11,
                color: labelColor,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        LayoutBuilder(builder: (_, c) {
          return Stack(
            alignment: Alignment.centerLeft,
            children: [
              Container(
                height: barHeight,
                width: c.maxWidth,
                decoration: BoxDecoration(
                  color: trackColor,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
              Container(
                height: barHeight,
                width: c.maxWidth * v,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
              Positioned(
                left: c.maxWidth * t - 1,
                top: -4,
                bottom: -4,
                child: Container(width: 3, color: markerColor),
              ),
            ],
          );
        }),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            '${value.toStringAsFixed(1)}% · target ${target.toStringAsFixed(0)}%',
            style: TextStyle(fontSize: 10, color: labelColor),
          ),
        ),
      ],
    );
  }
}
