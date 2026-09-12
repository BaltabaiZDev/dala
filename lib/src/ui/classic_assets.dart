import 'dala_art.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/services.dart';

class ClassicSprites {
  ClassicSprites._(this.images, this._tintAtlas, this._tintedRegions);

  final Map<String, ui.Image> images;
  final ui.Image? _tintAtlas;
  final Map<(ui.Image, int), ui.Rect> _tintedRegions;

  (ui.Image, ui.Rect)? tintedSprite(ui.Image image, ui.Color tint) {
    final rect = _tintedRegions[(image, tint.toARGB32())];
    return rect == null || _tintAtlas == null ? null : (_tintAtlas, rect);
  }

  ui.Image operator [](String name) => images[name]!;

  static Future<ClassicSprites> load({
    List<ui.Color> teamColors = const [],
    Map<String, String> overrides = const {},
  }) async {
    const names = <String>[
      'selection',
      'selection_pixel',
      'man0',
      'man1',
      'man2',
      'man3',
      'castle',
      'house',
      'farm1',
      'tower',
      'strong_tower',
      'pine',
      'palm',
      'grave',
      'port1',
      'port2',
      'boat1',
      'boat2',
      'sea_mint',
      'sea_fort',
      'artillery',
      'artillery_base',
      'artillery_turret',
      'man0_team',
      'man1_team',
      'man2_team',
      'man3_team',
      'castle_team',
      'farm1_team',
      'tower_team',
      'strong_tower_team',
      'port1_team',
      'port2_team',
      'boat1_team',
      'boat2_team',
      'naval_supply_link',
      'exclamation_mark',
      'diplomacy_black_mark',
    ];
    final result = <String, ui.Image>{};
    for (final name in {...names, ...overrides.keys}) {
      final encoded = overrides[name];
      if (encoded == null) {
        result[name] = await DalaArt.rasterize(name);
      } else {
        final codec = await ui.instantiateImageCodec(
          base64Decode(encoded),
          targetWidth: 128,
          targetHeight: 128,
        );
        try {
          result[name] = (await codec.getNextFrame()).image;
        } finally {
          codec.dispose();
        }
      }
    }
    // A color filter on every sprite can require an offscreen pass on mobile
    // GL. Pre-tint tiny team masks once, never a map-sized target during pan.
    final regions = <(ui.Image, int), ui.Rect>{};
    ui.Image? atlas;
    final colors = teamColors.toSet().toList();
    if (colors.isNotEmpty) {
      final masks = result.entries
          .where(
            (entry) =>
                (names.contains(entry.key) && entry.key.endsWith('_team')) ||
                entry.key == 'naval_supply_link' ||
                entry.key == 'sea_fort',
          )
          .map((e) => e.value)
          .toList();
      final cellWidth = masks.map((image) => image.width + 2).reduce(math.max);
      final width = cellWidth * colors.length;
      final height = masks.fold<int>(0, (sum, image) => sum + image.height + 2);
      final pixels = Uint8List(width * height * 4);
      var top = 1;
      for (final mask in masks) {
        final data = (await mask.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!.buffer.asUint8List();
        for (var col = 0; col < colors.length; col++) {
          final argb = colors[col].toARGB32();
          final left = col * cellWidth + 1;
          regions[(mask, argb)] = ui.Rect.fromLTWH(
            left.toDouble(),
            top.toDouble(),
            mask.width.toDouble(),
            mask.height.toDouble(),
          );
          for (var y = 0; y < mask.height; y++) {
            for (var x = 0; x < mask.width; x++) {
              final alpha =
                  (data[(y * mask.width + x) * 4 + 3] * ((argb >> 24) & 255) +
                      127) ~/
                  255;
              final out = ((top + y) * width + left + x) * 4;
              pixels[out] = (((argb >> 16) & 255) * alpha + 127) ~/ 255;
              pixels[out + 1] = (((argb >> 8) & 255) * alpha + 127) ~/ 255;
              pixels[out + 2] = ((argb & 255) * alpha + 127) ~/ 255;
              pixels[out + 3] = alpha;
            }
          }
        }
        top += mask.height + 2;
      }
      final ready = Completer<ui.Image>();
      ui.decodeImageFromPixels(
        pixels,
        width,
        height,
        ui.PixelFormat.rgba8888,
        ready.complete,
      );
      atlas = await ready.future;
    }
    return ClassicSprites._(result, atlas, regions);
  }

  void dispose() {
    _tintAtlas?.dispose();
    for (final image in images.values) {
      image.dispose();
    }
  }
}
