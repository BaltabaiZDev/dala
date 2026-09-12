import '../l10n/game_locale.dart';
import 'dala_theme.dart';
import 'package:flutter/material.dart';

import '../game/models.dart';

/// Consistent atlas seals on the map and in diplomacy.
Color diplomacyStatusColor(DiplomacyStatus status) => switch (status) {
  DiplomacyStatus.peace => DalaTheme.canvas,
  DiplomacyStatus.alliance => DalaTheme.green,
  DiplomacyStatus.coalition => DalaTheme.teal,
  DiplomacyStatus.war => DalaTheme.rose,
};

/// Always paints immediately, even offline or with a cold/failed image cache.
/// Vector seals stay distinct at small sizes, including in monochrome.
class DiplomacyStatusBadge extends StatelessWidget {
  const DiplomacyStatusBadge({
    super.key,
    required this.status,
    required this.size,
  });
  final DiplomacyStatus status;
  final double size;

  @override
  Widget build(BuildContext context) => Semantics(
    image: true,
    label: context.trNullable(switch (status) {
      DiplomacyStatus.peace => 'Бейтарап белгісі',
      DiplomacyStatus.alliance => 'Достық белгісі',
      DiplomacyStatus.coalition => 'Әскери одақ белгісі',
      DiplomacyStatus.war => 'Жау белгісі',
    }),
    child: CustomPaint(
      size: Size.square(size),
      painter: DiplomacyBadgePainter(status),
    ),
  );
}

class DiplomacyBadgePainter extends CustomPainter {
  const DiplomacyBadgePainter(this.status);
  final DiplomacyStatus status;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 64, size.height / 64);
    final edge = Paint()
      ..color = DalaTheme.ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final seal = Path()
      ..moveTo(16, 9)
      ..quadraticBezierTo(33, 3, 49, 11)
      ..quadraticBezierTo(62, 23, 54, 44)
      ..quadraticBezierTo(45, 60, 24, 55)
      ..quadraticBezierTo(4, 52, 7, 30)
      ..quadraticBezierTo(8, 15, 16, 9)
      ..close();
    canvas.drawPath(seal, Paint()..color = diplomacyStatusColor(status));
    canvas.drawPath(seal, edge);
    switch (status) {
      case DiplomacyStatus.peace:
        canvas.drawLine(const Offset(24, 45), const Offset(40, 20), edge);
        canvas.drawPath(
          Path()
            ..moveTo(30, 35)
            ..quadraticBezierTo(17, 33, 23, 23)
            ..quadraticBezierTo(35, 24, 30, 35),
          edge,
        );
        canvas.drawPath(
          Path()
            ..moveTo(33, 31)
            ..quadraticBezierTo(34, 18, 46, 24)
            ..quadraticBezierTo(46, 34, 33, 31),
          edge,
        );
      case DiplomacyStatus.alliance:
        canvas.save();
        canvas.translate(32, 32);
        canvas.rotate(-.5);
        for (final x in [-14.0, -2.0]) {
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromLTWH(x, -8, 17, 16),
              const Radius.circular(7),
            ),
            edge,
          );
        }
        canvas.restore();
      case DiplomacyStatus.coalition:
        canvas.drawPath(
          Path()
            ..moveTo(19, 21)
            ..quadraticBezierTo(32, 25, 45, 21)
            ..lineTo(43, 36)
            ..quadraticBezierTo(40, 43, 32, 47)
            ..quadraticBezierTo(24, 43, 21, 36)
            ..close(),
          edge,
        );
        canvas.drawLine(const Offset(32, 28), const Offset(32, 40), edge);
        canvas.drawLine(const Offset(27, 33), const Offset(37, 33), edge);
      case DiplomacyStatus.war:
        for (final flip in [false, true]) {
          canvas.save();
          if (flip) {
            canvas.translate(64, 0);
            canvas.scale(-1, 1);
          }
          canvas.drawPath(
            Path()
              ..moveTo(21, 21)
              ..lineTo(27, 23)
              ..lineTo(43, 41)
              ..lineTo(40, 44)
              ..lineTo(23, 27)
              ..close(),
            edge,
          );
          canvas.drawLine(const Offset(35, 43), const Offset(43, 35), edge);
          canvas.drawLine(const Offset(41, 42), const Offset(46, 47), edge);
          canvas.restore();
        }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(DiplomacyBadgePainter oldDelegate) =>
      oldDelegate.status != status;
}
