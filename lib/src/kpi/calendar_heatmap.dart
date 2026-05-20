import 'package:flutter/material.dart';

/// Week × day heatmap, à la GitHub's contribution graph.
///
/// `daysData` keys must be `'YYYY-MM-DD'`; values are the intensity. The
/// most recent week sits on the right; older weeks scroll off to the
/// left.
class KpiCalendarHeatmap extends StatelessWidget {
  const KpiCalendarHeatmap({
    super.key,
    required this.daysData,
    this.weeks = 16,
    this.color = const Color(0xFFD8584D),
    this.emptyColor = const Color(0xFFE7ECF4),
    this.labelColor = const Color(0xFF5A6A8A),
    this.dayLabels = const ['S', 'M', 'T', 'W', 'T', 'F', 'S'],
    this.emptyLabel,
    this.cellSize = 14,
    this.cellSpacing = 2,
  })  : assert(dayLabels.length == 7, 'dayLabels must have 7 entries');

  final Map<String, num> daysData;
  final int weeks;
  final Color color;
  final Color emptyColor;
  final Color labelColor;

  /// Single-letter labels for the seven rows, starting on Sunday.
  /// Default is English (`S M T W T F S`); pass your own (e.g.
  /// `['D','L','M','X','J','V','S']` for Spanish) to localize.
  final List<String> dayLabels;

  final String? emptyLabel;
  final double cellSize;
  final double cellSpacing;

  @override
  Widget build(BuildContext context) {
    final maxV = daysData.values.fold<num>(0, (a, b) => b > a ? b : a);
    final today = DateTime.now();
    final startBase = today.subtract(Duration(days: weeks * 7));
    final start =
        startBase.subtract(Duration(days: startBase.weekday % 7));
    final rowHeight = cellSize + cellSpacing;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 7 * rowHeight + 6,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final l in dayLabels)
                    SizedBox(
                      height: rowHeight,
                      child: Text(
                        l,
                        style: TextStyle(
                          fontSize: 9,
                          color: labelColor,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(width: 4),
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  reverse: true,
                  child: Row(
                    children: [
                      for (var w = 0; w < weeks; w++)
                        Column(
                          children: [
                            for (var d = 0; d < 7; d++)
                              _cell(start, w, d, maxV.toDouble()),
                          ],
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        if (daysData.isEmpty && emptyLabel != null) ...[
          const SizedBox(height: 8),
          Text(
            emptyLabel!,
            style: TextStyle(fontSize: 11, color: labelColor),
          ),
        ],
      ],
    );
  }

  Widget _cell(DateTime start, int week, int dow, double maxV) {
    final d = start.add(Duration(days: week * 7 + dow));
    String two(int n) => n.toString().padLeft(2, '0');
    final key = '${d.year}-${two(d.month)}-${two(d.day)}';
    final v = (daysData[key] ?? 0).toDouble();
    final t = maxV == 0 ? 0.0 : (v / maxV).clamp(0.0, 1.0);
    final bg = v == 0
        ? emptyColor
        : Color.lerp(emptyColor, color, 0.2 + 0.8 * t)!;
    return Tooltip(
      message: v == 0 ? key : '$key · $v',
      child: Container(
        margin: EdgeInsets.all(cellSpacing / 2),
        width: cellSize,
        height: cellSize,
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}
