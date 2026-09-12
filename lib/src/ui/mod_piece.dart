import 'dart:convert';
import 'package:flutter/material.dart';
import '../modding/game_mod.dart';
import 'classic_assets.dart';
import 'dala_art.dart';

void paintModPiece(
  Canvas canvas,
  Offset center,
  double size,
  String id,
  String icon,
  Color tint,
  ClassicSprites? sprites,
) {
  final image = sprites?.images[id];
  if (image == null) {
    canvas.save();
    canvas.translate(center.dx - size / 2, center.dy - size / 2);
    canvas.scale(size / 64);
    DalaArt.draw(canvas, icon, tint: tint);
    canvas.restore();
    return;
  }
  final bounds = Rect.fromCenter(center: center, width: size, height: size);
  canvas.drawImageRect(
    image,
    Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
    bounds,
    Paint(),
  );
  final mask = sprites?.images['${id}_team'];
  if (mask != null) {
    final tinted = sprites!.tintedSprite(mask, tint);
    if (tinted != null) {
      canvas.drawImageRect(tinted.$1, tinted.$2, bounds, Paint());
    } else {
      canvas.drawImageRect(
        mask,
        Rect.fromLTWH(0, 0, mask.width.toDouble(), mask.height.toDouble()),
        bounds,
        Paint()..colorFilter = ColorFilter.mode(tint, BlendMode.srcIn),
      );
    }
  }
  canvas.drawOval(
    Rect.fromCenter(
      center: center + Offset(0, size * .39),
      width: size * .5,
      height: 3,
    ),
    Paint()..color = tint,
  );
}

class ModPieceIcon extends StatelessWidget {
  const ModPieceIcon({
    required this.mod,
    required this.id,
    this.size = 40,
    super.key,
  });
  final GameMod mod;
  final String id;
  final double size;
  @override
  Widget build(BuildContext context) {
    final encoded = mod.sprites[id];
    if (encoded != null) {
      return Image.memory(
        base64Decode(encoded),
        width: size,
        height: size,
        cacheWidth: 128,
      );
    }
    final icon = mod.buildings[id]?.icon ?? mod.units[id]?.icon ?? 'building';
    return CustomPaint(size: Size.square(size), painter: _ModIconPainter(icon));
  }
}

class _ModIconPainter extends CustomPainter {
  const _ModIconPainter(this.icon);
  final String icon;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 64, size.height / 64);
    DalaArt.draw(canvas, icon);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ModIconPainter oldDelegate) => icon != oldDelegate.icon;
}
