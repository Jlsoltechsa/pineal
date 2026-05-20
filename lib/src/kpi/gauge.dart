import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Semicircular gauge — three-band arc with a needle.
///
/// `value` is normalized to the `[0, 100]` domain. `palette` carries the
/// arc colors for the three segments (low → mid → high); supply any
/// length and the arc divides evenly between them.
class KpiGauge extends StatelessWidget {
  const KpiGauge({
    super.key,
    required this.value,
    this.label,
    this.palette = const [
      Color(0xFFD8584D),
      Color(0xFFE89A2D),
      Color(0xFF2BA876),
    ],
    this.needleColor = const Color(0xFF12182A),
    this.valueColor = const Color(0xFF12182A),
    this.labelColor = const Color(0xFF5A6A8A),
    this.size = 180,
  });

  /// 0..100.
  final double value;
  final String? label;
  final List<Color> palette;
  final Color needleColor;
  final Color valueColor;
  final Color labelColor;
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size * 0.6,
      child: CustomPaint(
        painter: _GaugePainter(
          value: value.clamp(0.0, 100.0),
          palette: palette,
          needleColor: needleColor,
        ),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.only(top: 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '${value.toStringAsFixed(1)}%',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w900,
                    color: valueColor,
                  ),
                ),
                if (label != null)
                  Text(
                    label!,
                    style: TextStyle(
                      fontSize: 10,
                      letterSpacing: 1.0,
                      color: labelColor,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _GaugePainter extends CustomPainter {
  _GaugePainter({
    required this.value,
    required this.palette,
    required this.needleColor,
  });

  final double value;
  final List<Color> palette;
  final Color needleColor;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(8, 8, size.width - 16, size.width - 16);
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 14;
    const start = math.pi;
    const sweep = math.pi;
    final third = sweep / palette.length;
    for (var i = 0; i < palette.length; i++) {
      stroke.color = palette[i];
      canvas.drawArc(rect, start + i * third, third * 0.95, false, stroke);
    }
    final t = value / 100.0;
    final angle = start + sweep * t;
    final cx = size.width / 2;
    final cy = size.width / 2;
    final r = (size.width - 16) / 2 - 6;
    final x = cx + r * math.cos(angle);
    final y = cy + r * math.sin(angle);
    final needle = Paint()
      ..color = needleColor
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 3;
    canvas.drawLine(Offset(cx, cy), Offset(x, y), needle);
    canvas.drawCircle(Offset(cx, cy), 5, Paint()..color = needleColor);
  }

  @override
  bool shouldRepaint(covariant _GaugePainter old) =>
      old.value != value || old.palette != palette;
}
