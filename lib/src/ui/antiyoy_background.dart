import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'dala_theme.dart';

/// Atlas contour lines; the legacy class name is retained for callers.
class AntiyoyAnimatedParticles extends StatelessWidget {
  const AntiyoyAnimatedParticles({
    this.color = DalaTheme.deepWater,
    this.opacity = .16,
    super.key,
  });
  final Color color;
  final double opacity;
  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: CustomPaint(
      painter: _AtlasContours(color.withValues(alpha: opacity)),
    ),
  );
}

class _AtlasContours extends CustomPainter {
  const _AtlasContours(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (final anchor in [
      Offset(size.width * .03, size.height * .18),
      Offset(size.width * .98, size.height * .86),
    ]) {
      for (var ring = 0; ring < 7; ring++) {
        final path = Path();
        for (var i = 0; i <= 120; i++) {
          final angle = i / 120 * math.pi * 2;
          final radius =
              (62 + ring * 23) *
              (1 +
                  .09 * math.sin(angle * 3 + ring * .16) +
                  .06 * math.cos(angle * 5));
          final point =
              anchor +
              Offset(math.cos(angle) * radius, math.sin(angle) * radius * 1.22);
          if (i == 0) {
            path.moveTo(point.dx, point.dy);
          } else {
            path.lineTo(point.dx, point.dy);
          }
        }
        canvas.drawPath(path..close(), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_AtlasContours oldDelegate) => oldDelegate.color != color;
}
