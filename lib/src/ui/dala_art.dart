import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'dala_theme.dart';

/// Original vector artwork shared by map sprites, controls and the editor.
/// Asset names are retained only as save/mod-facing compatibility keys.
class DalaArt {
  static void drawBrand(Canvas canvas, double size) {
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size, size),
      Paint()..color = DalaTheme.paper,
    );
    canvas.save();
    canvas.scale(size / 100);
    canvas.drawCircle(
      const Offset(50, 50),
      39,
      Paint()..color = DalaTheme.teal,
    );
    canvas.drawCircle(
      const Offset(50, 50),
      34,
      Paint()
        ..color = DalaTheme.paper
        ..style = PaintingStyle.stroke
        ..strokeWidth = .8,
    );
    canvas.translate(20, 18);
    canvas.scale(.95);
    draw(canvas, 'castle');
    canvas.restore();
  }

  static Future<ui.Image> rasterize(String name) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)..scale(2);
    draw(canvas, name);
    final picture = recorder.endRecording();
    final image = await picture.toImage(128, 128);
    picture.dispose();
    return image;
  }

  static void draw(Canvas c, String name, {Color? tint}) {
    if (name == 'infantry' || name == 'scout') {
      draw(c, name == 'scout' ? 'man1' : 'man0');
      draw(
        c,
        name == 'scout' ? 'man1_team' : 'man0_team',
        tint: tint ?? DalaTheme.gold,
      );
      return;
    }
    name = name.split('/').last.replaceAll('.png', '');
    final mask = name.endsWith('_team');
    final key = name.replaceAll('_team', '');
    const ink = DalaTheme.ink;
    const cream = Color(0xfffaf1d8);
    const wood = Color(0xffa77e58);
    const leaf = Color(0xff467b62);
    final accent = mask ? tint ?? Colors.white : DalaTheme.gold;
    void path(Path p, Color color, {bool outline = true}) {
      c.drawPath(p, Paint()..color = color);
      if (outline && !mask) {
        c.drawPath(
          p,
          Paint()
            ..color = ink
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.2
            ..strokeJoin = StrokeJoin.round,
        );
      }
    }

    void line(Offset a, Offset b, Color color, [double width = 2.4]) =>
        c.drawLine(
          a,
          b,
          Paint()
            ..color = color
            ..strokeWidth = width
            ..strokeCap = StrokeCap.round,
        );
    void oval(Rect r, Color color) => c.drawOval(r, Paint()..color = color);
    void box(Rect r, Color color, [double radius = 4]) {
      final rr = RRect.fromRectAndRadius(r, Radius.circular(radius));
      c.drawRRect(rr, Paint()..color = color);
      if (!mask) {
        c.drawRRect(
          rr,
          Paint()
            ..color = ink
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2,
        );
      }
    }

    if (key == 'radar') {
      box(const Rect.fromLTWH(13, 45, 38, 10), wood);
      line(const Offset(32, 45), const Offset(32, 29), ink, 5);
      path(
        Path()
          ..moveTo(14, 19)
          ..quadraticBezierTo(16, 44, 43, 36)
          ..close(),
        cream,
      );
      line(const Offset(25, 29), const Offset(39, 15), tint ?? accent, 3);
      c.drawArc(
        const Rect.fromLTWH(24, 7, 27, 27),
        -math.pi / 2,
        math.pi / 2,
        false,
        Paint()
          ..color = tint ?? accent
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3,
      );
      return;
    }
    if (key == 'airfield' || key == 'factory' || key == 'building') {
      box(const Rect.fromLTWH(9, 27, 44, 27), cream);
      path(
        Path()
          ..moveTo(7, 27)
          ..lineTo(31, 13)
          ..lineTo(56, 27)
          ..close(),
        tint ?? accent,
      );
      box(const Rect.fromLTWH(17, 34, 17, 20), ink, 2);
      if (key == 'airfield') {
        path(
          Path()
            ..moveTo(37, 36)
            ..lineTo(44, 29)
            ..lineTo(55, 54)
            ..lineTo(37, 54)
            ..close(),
          blueSteel,
        );
        line(const Offset(44, 37), const Offset(47, 48), cream, 2);
      } else if (key == 'factory') {
        box(const Rect.fromLTWH(43, 8, 8, 32), wood, 1);
        oval(const Rect.fromLTWH(42, 2, 12, 5), blueSteel);
      }
      return;
    }
    if (key == 'aircraft') {
      oval(const Rect.fromLTWH(14, 49, 39, 5), const Color(0x4030463b));
      path(
        Path()
          ..moveTo(32, 6)
          ..lineTo(36, 26)
          ..lineTo(57, 39)
          ..lineTo(57, 44)
          ..lineTo(36, 36)
          ..lineTo(35, 48)
          ..lineTo(43, 54)
          ..lineTo(21, 54)
          ..lineTo(29, 48)
          ..lineTo(28, 36)
          ..lineTo(7, 44)
          ..lineTo(7, 39)
          ..lineTo(28, 26)
          ..close(),
        cream,
      );
      line(const Offset(32, 20), const Offset(32, 40), tint ?? accent, 4);
      return;
    }
    if (!mask &&
        (key.startsWith('man') ||
            key == 'castle' ||
            key == 'house' ||
            key.contains('tower') ||
            key == 'pine' ||
            key == 'palm' ||
            key.startsWith('port') ||
            key.startsWith('boat') ||
            key.startsWith('farm'))) {
      oval(const Rect.fromLTWH(12, 49, 40, 7), const Color(0x2630463b));
    }
    if (key.startsWith('man')) {
      final level = (int.tryParse(key.substring(3)) ?? 0) + 1;
      final robe = Path()
        ..moveTo(26, 27)
        ..quadraticBezierTo(32, 24, 38, 27)
        ..lineTo(43, 46)
        ..quadraticBezierTo(32, 52, 21, 46)
        ..close();
      if (mask) {
        path(robe, accent);
        return;
      }
      line(const Offset(27, 46), const Offset(25, 55), ink, 4);
      line(const Offset(37, 46), const Offset(39, 55), ink, 4);
      path(robe, cream);
      line(const Offset(23, 31), const Offset(17, 42), wood, 4);
      line(const Offset(39, 31), const Offset(46, 38), wood, 4);
      oval(const Rect.fromLTWH(24, 12, 16, 17), const Color(0xffe0b68b));
      path(
        Path()
          ..moveTo(22, 18)
          ..quadraticBezierTo(24, 8, 32, 8)
          ..quadraticBezierTo(40, 8, 42, 18)
          ..close(),
        level >= 3 ? blueSteel : ink,
      );
      line(const Offset(24, 37), const Offset(40, 37), wood, 3);
      for (var i = 0; i < level; i++) {
        oval(Rect.fromCircle(center: Offset(28 + i * 3, 32), radius: .9), ink);
      }
      if (level >= 2) {
        path(
          Path()
            ..moveTo(43, 32)
            ..lineTo(54, 35)
            ..lineTo(52, 45)
            ..quadraticBezierTo(47, 51, 42, 44)
            ..close(),
          accent,
        );
        line(const Offset(47, 36), const Offset(47, 43), cream, 1.6);
      }
      if (level >= 3) {
        line(const Offset(15, 21), const Offset(15, 52), wood, 2.6);
        path(
          Path()
            ..moveTo(15, 9)
            ..lineTo(11, 22)
            ..lineTo(19, 22)
            ..close(),
          cream,
        );
      }
      if (level == 4) {
        path(
          Path()
            ..moveTo(31, 9)
            ..quadraticBezierTo(37, 0, 45, 5)
            ..lineTo(36, 13)
            ..close(),
          DalaTheme.rose,
        );
      }
      return;
    }
    if (key == 'castle' || key == 'house') {
      final roof = Path()
        ..moveTo(10, 30)
        ..quadraticBezierTo(14, 21, 30, 13)
        ..quadraticBezierTo(34, 11, 38, 16)
        ..quadraticBezierTo(50, 24, 54, 30)
        ..close();
      if (mask) {
        path(roof, accent);
        return;
      }
      box(const Rect.fromLTWH(13, 29, 38, 23), cream, 7);
      path(roof, DalaTheme.gold);
      box(const Rect.fromLTWH(27, 35, 10, 17), wood, 5);
      line(const Offset(18, 36), const Offset(22, 40), wood, 1.5);
      line(const Offset(22, 36), const Offset(18, 40), wood, 1.5);
      line(const Offset(43, 36), const Offset(47, 40), wood, 1.5);
      if (key == 'castle') {
        line(const Offset(34, 5), const Offset(34, 16), ink);
        path(
          Path()
            ..moveTo(35, 5)
            ..lineTo(45, 8)
            ..lineTo(35, 11)
            ..close(),
          DalaTheme.rose,
        );
      }
      return;
    }
    if (key == 'tower' || key == 'strong_tower' || key == 'sea_fort') {
      if (!mask) {
        box(const Rect.fromLTWH(20, 23, 25, 31), cream, 6);
        box(const Rect.fromLTWH(17, 18, 31, 13), wood, 4);
        for (final x in [18.0, 30.0, 42.0]) {
          box(Rect.fromLTWH(x, 12, 7, 13), cream, 2);
        }
        box(const Rect.fromLTWH(29, 37, 8, 17), ink, 4);
        if (key != 'tower') {
          box(const Rect.fromLTWH(10, 33, 10, 21), wood, 3);
          box(const Rect.fromLTWH(45, 33, 10, 21), wood, 3);
        }
      } else {
        box(const Rect.fromLTWH(21, 27, 23, 6), accent, 2);
      }
      return;
    }
    if (key == 'farm1') {
      if (!mask) {
        path(
          Path()
            ..moveTo(9, 40)
            ..lineTo(34, 26)
            ..lineTo(56, 41)
            ..lineTo(32, 55)
            ..close(),
          wood,
        );
        for (var i = 0; i < 3; i++) {
          line(
            Offset(18 + i * 8, 39 + i * 4),
            Offset(34 + i * 5, 31 + i * 5),
            cream,
            2,
          );
        }
      }
      for (final p in [
        const Offset(21, 31),
        const Offset(34, 24),
        const Offset(43, 34),
      ]) {
        line(p, p.translate(0, -13), mask ? accent : leaf, 3);
        path(
          Path()
            ..moveTo(p.dx, p.dy - 5)
            ..quadraticBezierTo(p.dx - 11, p.dy - 7, p.dx - 6, p.dy - 13)
            ..quadraticBezierTo(p.dx, p.dy - 12, p.dx, p.dy - 5),
          mask ? accent : leaf,
          outline: false,
        );
      }
      return;
    }
    if (key == 'pine' || key == 'palm') {
      line(const Offset(32, 33), const Offset(32, 54), wood, 5);
      if (key == 'pine') {
        for (final y in [39.0, 29.0, 18.0]) {
          path(
            Path()
              ..moveTo(32, y - 16)
              ..quadraticBezierTo(23, y - 5, 17, y + 4)
              ..quadraticBezierTo(32, y + 11, 47, y + 4)
              ..close(),
            leaf,
          );
        }
      } else {
        for (var i = 0; i < 5; i++) {
          final angle = -.1 - math.pi * i / 4;
          final p =
              const Offset(32, 25) +
              Offset(math.cos(angle), math.sin(angle)) * 21;
          path(
            Path()
              ..moveTo(32, 28)
              ..quadraticBezierTo(p.dx, p.dy - 12, p.dx, p.dy + 8)
              ..quadraticBezierTo(p.dx, p.dy, 32, 28),
            leaf,
          );
        }
      }
      return;
    }
    if (key.startsWith('boat') || key.startsWith('port')) {
      final port = key.startsWith('port');
      final large = key.endsWith('2');
      if (!mask) {
        if (port) {
          box(const Rect.fromLTWH(8, 40, 49, 8), wood, 3);
          for (final x in [14.0, 47.0]) {
            line(Offset(x, 42), Offset(x, 56), wood, 4);
          }
        } else {
          path(
            Path()
              ..moveTo(8, 41)
              ..quadraticBezierTo(31, 47, 57, 39)
              ..lineTo(48, 53)
              ..quadraticBezierTo(29, 58, 16, 50)
              ..close(),
            wood,
          );
          line(const Offset(31, 9), const Offset(31, 43), ink, 3);
        }
      }
      path(
        Path()
          ..moveTo(29, 10)
          ..quadraticBezierTo(19, 24, 13, 35)
          ..quadraticBezierTo(22, 39, 29, 36)
          ..close(),
        mask ? accent : cream,
      );
      if (large) {
        path(
          Path()
            ..moveTo(34, 12)
            ..quadraticBezierTo(49, 25, 51, 36)
            ..lineTo(34, 36)
            ..close(),
          mask ? accent : cream,
        );
      }
      return;
    }
    if (key.startsWith('artillery')) {
      if (mask) return;
      if (key != 'artillery_turret') {
        oval(const Rect.fromLTWH(15, 37, 35, 15), wood);
        for (final x in [18.0, 42.0]) {
          oval(Rect.fromLTWH(x, 37, 10, 16), ink);
          oval(Rect.fromLTWH(x + 3, 41, 4, 8), cream);
        }
      }
      if (key != 'artillery_base') {
        c.save();
        c.translate(32, 30);
        c.rotate(-.35);
        box(const Rect.fromLTWH(-15, -8, 35, 12), blueSteel, 4);
        c.restore();
      }
      return;
    }
    if (key == 'grave') {
      box(const Rect.fromLTWH(21, 19, 22, 33), const Color(0xffb7b7a0), 9);
      line(const Offset(28, 30), const Offset(36, 30), cream);
      line(const Offset(32, 26), const Offset(32, 39), cream);
      return;
    }
    if (key == 'sea_mint') {
      for (var i = 0; i < 5; i++) {
        final a = i * math.pi * 2 / 5;
        oval(
          Rect.fromCenter(
            center:
                const Offset(32, 32) + Offset(math.cos(a), math.sin(a)) * 11,
            width: 18,
            height: 23,
          ),
          leaf,
        );
      }
      oval(const Rect.fromLTWH(27, 27, 10, 10), DalaTheme.gold);
      return;
    }
    if (key == 'coin') {
      oval(const Rect.fromLTWH(11, 10, 42, 44), DalaTheme.gold);
      c.drawCircle(
        const Offset(32, 32),
        16,
        Paint()
          ..color = wood
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
      path(
        Path()
          ..moveTo(32, 20)
          ..lineTo(40, 32)
          ..lineTo(32, 44)
          ..lineTo(24, 32)
          ..close(),
        cream,
      );
      return;
    }
    if (key == 'hex_color5' || key == 'selection' || key == 'selection_pixel') {
      path(
        Path()
          ..moveTo(10, 23)
          ..cubicTo(13, 3, 48, 7, 54, 22)
          ..cubicTo(68, 47, 39, 61, 17, 52)
          ..cubicTo(5, 48, 1, 33, 10, 23),
        accent,
      );
      return;
    }
    if (key == 'naval_supply_link') {
      c.drawCircle(
        const Offset(32, 32),
        22,
        Paint()
          ..color = tint ?? cream
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4,
      );
      return;
    }
    final icon = switch (key) {
      'settings_icon' => Icons.tune_rounded,
      'shut_down' => Icons.power_settings_new_rounded,
      'arrow' => Icons.arrow_back_rounded,
      'menu_icon' => Icons.menu_rounded,
      'coin' => Icons.paid_outlined,
      'like_icon' => Icons.handshake_outlined,
      'dislike_icon' => Icons.shield_outlined,
      'black_mark_icon' || 'diplomacy_black_mark' => Icons.block_rounded,
      'mail_icon' => Icons.mail_outline_rounded,
      'info_icon' => Icons.info_outline_rounded,
      'exchange_icon' => Icons.swap_horiz_rounded,
      'exchange_down' => Icons.keyboard_arrow_down_rounded,
      'exclamation_mark' => Icons.priority_high_rounded,
      'undo' => Icons.undo_rounded,
      'end_turn' || 'next' => Icons.skip_next_rounded,
      'random_color_pixel' => Icons.palette_outlined,
      _ => Icons.explore_outlined,
    };
    final text = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(icon.codePoint),
        style: TextStyle(
          fontFamily: icon.fontFamily,
          package: icon.fontPackage,
          color: tint ?? ink,
          fontSize: 46,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    text.paint(c, Offset((64 - text.width) / 2, (64 - text.height) / 2));
  }

  static const blueSteel = Color(0xff7e9aa0);
}

class DalaAsset extends StatelessWidget {
  const DalaAsset(
    this.name, {
    this.width,
    this.height,
    this.fit,
    this.color,
    this.colorBlendMode,
    this.filterQuality,
    super.key,
  });
  final String name;
  final double? width;
  final double? height;
  final BoxFit? fit;
  final Color? color;
  final BlendMode? colorBlendMode;
  final FilterQuality? filterQuality;
  @override
  Widget build(BuildContext context) => CustomPaint(
    size: Size(width ?? 32, height ?? 32),
    painter: _DalaArtPainter(name, color),
  );
}

class _DalaArtPainter extends CustomPainter {
  const _DalaArtPainter(this.name, this.tint);
  final String name;
  final Color? tint;
  @override
  void paint(Canvas canvas, Size size) {
    final scale = math.min(size.width, size.height) / 64;
    canvas.save();
    canvas.translate(
      (size.width - 64 * scale) / 2,
      (size.height - 64 * scale) / 2,
    );
    canvas.scale(scale);
    DalaArt.draw(canvas, name, tint: tint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_DalaArtPainter old) =>
      old.name != name || old.tint != tint;
}
