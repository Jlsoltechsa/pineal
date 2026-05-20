import 'package:flutter/material.dart';

/// A funnel chart — horizontal bars decreasing in length, typical of
/// conversion / drop-off visualizations.
///
/// `stages` is a `List<Map>` with keys `label`, `value`, and optional
/// `color`. The widest bar is whichever stage has the largest value
/// (usually the first).
class KpiFunnel extends StatelessWidget {
  const KpiFunnel({
    super.key,
    required this.stages,
    this.defaultColor = const Color(0xFF1E88E5),
    this.trackColor = const Color(0xFFE7ECF4),
    this.labelWidth = 130,
    this.rowHeight = 28,
  });

  /// `[{label, value, color?}, ...]`.
  final List<Map<String, dynamic>> stages;
  final Color defaultColor;
  final Color trackColor;
  final double labelWidth;
  final double rowHeight;

  @override
  Widget build(BuildContext context) {
    if (stages.isEmpty) return const SizedBox.shrink();
    final maxV = stages
        .map((s) => ((s['value'] ?? 0) as num).toDouble())
        .reduce((a, b) => a > b ? a : b);
    return Column(
      children: [
        for (final s in stages) _row(s, maxV == 0 ? 1 : maxV),
      ],
    );
  }

  Widget _row(Map<String, dynamic> s, double maxV) {
    final v = ((s['value'] ?? 0) as num).toDouble();
    final pct = v / maxV;
    final color = (s['color'] as Color?) ?? defaultColor;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: labelWidth,
            child: Text(
              s['label']?.toString() ?? '',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
            ),
          ),
          Expanded(
            child: LayoutBuilder(builder: (ctx, c) {
              return Stack(
                children: [
                  Container(
                    height: rowHeight,
                    width: c.maxWidth,
                    decoration: BoxDecoration(
                      color: trackColor,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                  Container(
                    height: rowHeight,
                    width: c.maxWidth * pct,
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.85),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                  Positioned.fill(
                    child: Center(
                      child: Text(
                        v.toStringAsFixed(0),
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w900,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ],
              );
            }),
          ),
        ],
      ),
    );
  }
}
