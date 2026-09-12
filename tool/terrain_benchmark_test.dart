// Run with flutter test tool/terrain_benchmark_test.dart --reporter expanded.
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antiyoy_self/src/game/map_generator.dart';
import 'package:antiyoy_self/src/game/models.dart';
import 'package:antiyoy_self/src/modding/game_mod.dart';
import 'package:antiyoy_self/src/ui/classic_assets.dart';
import 'package:antiyoy_self/src/ui/hex_board.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'dense giant terrain recording and raster benchmark',
    () async {
      final mod = await GameMod.loadDefault();
      final state = MapGenerator(mod).generate(
        const GameConfig(
          mapSize: MapSize.giant,
          playerCount: 15,
          humanCount: 15,
          startingProvinceCount: 3,
          treePercent: 100,
          seed: 20260903,
        ),
      );
      final sprites = await ClassicSprites.load(teamColors: mod.palette);
      final visible = state.hexes.map((t) => t.index).toSet();
      final water = state.waterCells.map((t) => t.index).toSet();
      final size = HexBoard.canvasSize(state);
      for (var iteration = 0; iteration < 4; iteration++) {
        final painter = HexBoardPainter(
          state: state,
          mod: mod,
          fogActive: false,
          sprites: sprites,
          selected: null,
          selectedWater: null,
          selectionOpacity: 1,
          moveTargets: {},
          waterTargets: {},
          defensePreviewTiles: {},
          defensePreviewWaterCells: {},
          defensePreviewOpacity: 0,
          artilleryRangePreview: false,
          artilleryVolleys: [],
          artilleryFireProgress: 0,
          visibleTiles: visible,
          visibleWaterCells: water,
        );
        final watch = Stopwatch()..start();
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder)..scale(1000 / size.longestSide);
        painter.paint(canvas, size);
        final picture = recorder.endRecording();
        final recordMs = watch.elapsedMicroseconds / 1000;
        watch.reset();
        final image = await picture.toImage(1000, 1000);
        // ignore: avoid_print
        print(
          'DALA_TERRAIN iteration=$iteration cells=${state.hexes.length} '
          'recordMs=$recordMs rasterMs=${watch.elapsedMicroseconds / 1000}',
        );
        image.dispose();
        picture.dispose();
      }
      final jobs = <VoidCallback>[];
      Future<void>? current;
      var textures = 0;
      final cache = HexTerrainCache(
        schedule: jobs.add,
        rasterizer: (picture, w, h) {
          final watch = Stopwatch()..start();
          final future = picture.toImage(w, h);
          current = future.then((_) {
            textures++;
            // ignore: avoid_print
            print(
              'DALA_TEXTURE ${w}x$h ms=${watch.elapsedMicroseconds / 1000}',
            );
          });
          return future;
        },
      );
      cache.setViewport(
        Rect.fromCenter(
          center: size.center(Offset.zero),
          width: 500,
          height: 700,
        ),
        2,
      );
      final painter = HexBoardPainter(
        state: state,
        mod: mod,
        fogActive: false,
        sprites: sprites,
        selected: null,
        selectedWater: null,
        selectionOpacity: 1,
        moveTargets: {},
        waterTargets: {},
        defensePreviewTiles: {},
        defensePreviewWaterCells: {},
        defensePreviewOpacity: 0,
        artilleryRangePreview: false,
        artilleryVolleys: [],
        artilleryFireProgress: 0,
        visibleTiles: visible,
        visibleWaterCells: water,
        terrainCache: cache,
        terrainSignature: 1,
      );
      final record = Stopwatch()..start();
      final recorder = ui.PictureRecorder();
      painter.paint(Canvas(recorder), size);
      recorder.endRecording().dispose();
      // ignore: avoid_print
      print('DALA_OVERVIEW recordMs=${record.elapsedMicroseconds / 1000}');
      while (jobs.isNotEmpty) {
        final watch = Stopwatch()..start();
        jobs.removeAt(0)();
        // ignore: avoid_print
        print('DALA_REGION recordMs=${watch.elapsedMicroseconds / 1000}');
        await current;
        await Future<void>.delayed(Duration.zero);
      }
      expect(textures, greaterThan(1));
      cache.dispose();
      sprites.dispose();
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
