import 'dart:ui' as ui;

import 'package:antiyoy_self/src/game/map_generator.dart';
import 'package:antiyoy_self/src/game/models.dart';
import 'package:antiyoy_self/src/modding/game_mod.dart';
import 'package:antiyoy_self/src/ui/classic_assets.dart';
import 'package:antiyoy_self/src/ui/hex_board.dart';
import 'package:antiyoy_self/src/ui/map_raster_cache.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'large-map spatial culling and crisp object layer preserve visible pixels',
    () async {
      final mod = await GameMod.loadDefault();
      final state = MapGenerator(mod).generate(
        const GameConfig(
          mapSize: MapSize.giant,
          playerCount: 15,
          humanCount: 15,
          treePercent: 100,
          seed: 20260903,
        ),
      );
      final cache = HexTerrainCache(schedule: (_) {});
      final sprites = await ClassicSprites.load(teamColors: mod.palette);
      addTearDown(cache.dispose);
      addTearDown(sprites.dispose);
      final visible = state.hexes.map((t) => t.index).toSet();
      HexBoardPainter painter(bool cached) => HexBoardPainter(
        state: state,
        mod: mod,
        sprites: sprites,
        fogActive: false,
        terrainCache: cached ? cache : null,
        terrainSignature: cached ? 1 : null,
        selected: null,
        selectedWater: null,
        selectionOpacity: 0,
        moveTargets: const {},
        waterTargets: const {},
        defensePreviewTiles: const {},
        defensePreviewWaterCells: const {},
        defensePreviewOpacity: 0,
        artilleryRangePreview: false,
        artilleryVolleys: const [],
        artilleryFireProgress: 0,
        visibleTiles: visible,
        visibleWaterCells: state.waterCells.map((c) => c.index).toSet(),
      );
      final source = painter(true);
      for (final tile in state.hexes.where((t) => t.index % 113 == 0)) {
        final view = Rect.fromCenter(
          center: HexBoard.centerOf(tile),
          width: 280,
          height: 360,
        );
        final indexed = source.tilesWithin(view).map((t) => t.index).toSet();
        final expected = state.hexes
            .where((t) => view.contains(HexBoard.centerOf(t)))
            .map((t) => t.index);
        expect(indexed, containsAll(expected));
        expect(indexed.length, lessThan(100));
      }
      for (final type in [TileObject.town, TileObject.pine, TileObject.palm]) {
        final tile = state.hexes.firstWhere(
          (t) => t.active && t.object == type,
        );
        final center = HexBoard.centerOf(tile);
        final view = Rect.fromCenter(center: center, width: 120, height: 120);
        cache.setViewport(view, 2);
        Future<List<int>> pixels(bool cached) async {
          final recorder = ui.PictureRecorder();
          // The central 20x24 world pixels isolate the sprite from coast overlap.
          final canvas = Canvas(recorder)
            ..scale(2)
            ..translate(-center.dx + 10, -center.dy + 14);
          final board = cached ? source : painter(false);
          board.paint(canvas, HexBoard.canvasSize(state));
          if (cached) {
            HexStaticObjectPainter(
              source: board,
              viewBounds: view,
              signature: 1,
              overview: false,
            ).paint(canvas, HexBoard.canvasSize(state));
          }
          final picture = recorder.endRecording();
          final image = await picture.toImage(40, 48);
          final result = (await image.toByteData())!.buffer
              .asUint8List()
              .toList();
          image.dispose();
          picture.dispose();
          return result;
        }

        expect(
          await pixels(true),
          await pixels(false),
          reason: '$type must retain its direct sprite pixels',
        );
        cache.trimMemory();
        expect(
          await pixels(true),
          await pixels(false),
          reason: '$type must remain sharp under memory pressure',
        );
      }
    },
  );

  test(
    'large-map action mask fallback preserves visible land and sea pixels',
    () async {
      final mod = await GameMod.loadDefault();
      final state = MapGenerator(mod).generate(
        const GameConfig(
          mapSize: MapSize.large,
          playerCount: 5,
          humanCount: 5,
          seed: 823,
        ),
      );
      expect(state.hexes.length, greaterThanOrEqualTo(1200));
      final cache = MapRasterCache(schedule: (_) {});
      addTearDown(cache.dispose);
      final coast = state.hexes.firstWhere(
        (t) => t.active && t.neighbors.any((n) => !state.hexes[n].active),
      );
      final view = Rect.fromCenter(
        center: HexBoard.centerOf(coast),
        width: 256,
        height: 256,
      );
      cache.setViewport(view, 1);
      Future<List<int>> pixels(bool cached) async {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder)..translate(-view.left, -view.top);
        HexActionMaskPainter(
          cache: cached ? cache : null,
          signature: 1,
          state: state,
          targets: {coast.index},
          waterTargets: const {},
          selected: coast.index,
          selectedWater: null,
        ).paint(canvas, HexBoard.canvasSize(state));
        final picture = recorder.endRecording();
        final image = await picture.toImage(256, 256);
        final bytes = (await image.toByteData())!.buffer.asUint8List().toList();
        image.dispose();
        picture.dispose();
        return bytes;
      }

      final reference = await pixels(false);
      expect(reference.any((value) => value != 0), isTrue);
      expect(await pixels(true), reference);
    },
  );

  test('pre-tinted team masks preserve direct color-filter pixels', () async {
    const color = Color(0xff5baa77);
    final sprites = await ClassicSprites.load(teamColors: [color]);
    final mask = sprites['castle_team'];
    final tinted = sprites.tintedSprite(mask, color);
    expect(tinted, isNotNull);
    expect(tinted!.$2.width, mask.width);
    Future<List<int>> pixels(bool prepared) async {
      final recorder = ui.PictureRecorder();
      final rect = Rect.fromLTWH(
        0,
        0,
        mask.width.toDouble(),
        mask.height.toDouble(),
      );
      Canvas(recorder).drawImageRect(
        prepared ? tinted.$1 : mask,
        prepared ? tinted.$2 : rect,
        rect,
        Paint()
          ..colorFilter = prepared
              ? null
              : const ColorFilter.mode(color, BlendMode.srcIn),
      );
      final picture = recorder.endRecording();
      final image = await picture.toImage(mask.width, mask.height);
      final result = (await image.toByteData())!.buffer.asUint8List().toList();
      image.dispose();
      picture.dispose();
      return result;
    }

    expect(await pixels(true), await pixels(false));
    sprites.dispose();
  });

  test(
    'terrain display list reuses unchanged frames and invalidates safely',
    () {
      final cache = HexTerrainCache();
      var records = 0;
      void record(Canvas canvas) {
        records++;
        canvas.drawCircle(Offset.zero, 10, Paint());
      }

      for (final signature in [1, 1, 1, 2, 2]) {
        final recorder = ui.PictureRecorder();
        cache.draw(Canvas(recorder), signature, record);
        recorder.endRecording().dispose();
      }
      expect(records, 2);
      expect(cache.builds, 2);
      cache.dispose();
    },
  );

  test(
    'split cached and animated piece passes preserve pixels and cull offscreen',
    () async {
      final mod = await GameMod.loadDefault();
      final state = MapGenerator(mod).generate(
        const GameConfig(
          mapSize: MapSize.small,
          playerCount: 3,
          humanCount: 3,
          diplomacy: true,
          seed: 82,
        ),
      );
      for (final province in state.provinces) {
        final tile = state
            .hexes[province.tiles.firstWhere((i) => i != province.capital)];
        tile
          ..object = TileObject.none
          ..unit = GameUnit(strength: 1, owner: province.owner);
      }
      final visible = state.hexes.map((tile) => tile.index).toSet();
      final water = state.waterCells.map((cell) => cell.index).toSet();
      final frame = HexPieceFrame(state, visible, water);
      expect(frame.units.length, lessThan(state.hexes.length));
      expect(
        frame.movingUnits.every((tile) => tile.unit!.owner == state.turn),
        isTrue,
      );
      final sprites = await ClassicSprites.load();
      final size = HexBoard.canvasSize(state);
      HexUnitPainter painter(HexPiecePass pass, {Rect? view}) => HexUnitPainter(
        state: state,
        mod: mod,
        sprites: sprites,
        jumpProgress: .4,
        alertOwner: 0,
        selectedProvinceId: null,
        visibleTiles: visible,
        visibleWaterCells: water,
        frame: frame,
        pass: pass,
        viewBounds: view,
      );
      Future<List<int>> pixels(List<HexUnitPainter> painters) async {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        for (final painter in painters) {
          painter.paint(canvas, size);
        }
        final picture = recorder.endRecording();
        final image = await picture.toImage(
          size.width.ceil(),
          size.height.ceil(),
        );
        final data = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!.buffer.asUint8List().toList();
        image.dispose();
        picture.dispose();
        return data;
      }

      final ordinary = await pixels([painter(HexPiecePass.all)]);
      final split = await pixels([
        painter(HexPiecePass.still),
        painter(HexPiecePass.animated),
      ]);
      expect(split, ordinary);
      final hidden = await pixels([
        painter(HexPiecePass.all, view: const Rect.fromLTWH(-200, -200, 1, 1)),
      ]);
      expect(hidden.every((value) => value == 0), isTrue);
      sprites.dispose();
    },
  );
}
