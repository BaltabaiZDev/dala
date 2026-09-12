import 'package:antiyoy_self/src/ui/dala_theme.dart';
import 'dart:ui' as ui;

import 'package:antiyoy_self/src/game/game_controller.dart';
import 'package:antiyoy_self/src/game/game_engine.dart';
import 'package:antiyoy_self/src/game/map_generator.dart';
import 'package:antiyoy_self/src/game/models.dart';
import 'package:antiyoy_self/src/modding/game_mod.dart';
import 'package:antiyoy_self/src/persistence/save_repository.dart';
import 'package:antiyoy_self/src/ui/game_screen.dart';
import 'package:antiyoy_self/src/ui/hex_board.dart';
import 'package:antiyoy_self/src/ui/map_viewport.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'render_test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late GameMod mod;

  setUpAll(() async {
    final fontLoader = FontLoader('Antiyoy')
      ..addFont(rootBundle.load('assets/classic/font.ttf'));
    await fontLoader.load();
    mod = await GameMod.loadDefault();
  });

  test('hidden land and water use the same opaque fog paint', () async {
    final state = MapGenerator(mod).generate(
      const GameConfig(
        mapSize: MapSize.small,
        playerCount: 2,
        humanCount: 1,
        fogOfWar: true,
        seed: 824,
      ),
    );
    final size = HexBoard.canvasSize(state);
    final recorder = ui.PictureRecorder();
    final painter = HexBoardPainter(
      state: state,
      mod: mod,
      fogActive: true,
      sprites: null,
      selected: null,
      selectedWater: null,
      selectionOpacity: 0,
      moveTargets: const <int>{},
      waterTargets: const <int>{},
      defensePreviewTiles: const <int>{},
      defensePreviewWaterCells: const <int>{},
      defensePreviewOpacity: 0,
      artilleryRangePreview: false,
      artilleryVolleys: const <List<ArtilleryStrike>>[],
      artilleryFireProgress: 0,
      visibleTiles: const <int>{},
      visibleWaterCells: const <int>{},
    );
    painter.paint(Canvas(recorder), size);
    final image = await recorder.endRecording().toImage(
      size.width.ceil(),
      size.height.ceil(),
    );
    final rgba = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    final width = image.width;
    Color pixelAt(Offset point) {
      final x = point.dx.round().clamp(0, image.width - 1);
      final y = point.dy.round().clamp(0, image.height - 1);
      final offset = (y * width + x) * 4;
      return Color.fromARGB(
        rgba.getUint8(offset + 3),
        rgba.getUint8(offset),
        rgba.getUint8(offset + 1),
        rgba.getUint8(offset + 2),
      );
    }

    final hiddenLand = state.hexes.firstWhere((tile) => tile.active);
    final landColor = pixelAt(HexBoard.centerOf(hiddenLand));
    final terrainColors = <Color>{
      for (final tile in state.hexes.where((tile) => tile.inWorld))
        pixelAt(HexBoard.centerOf(tile)),
    };
    image.dispose();

    expect((landColor.a * 255).round(), 255);
    expect(terrainColors, <Color>{landColor});
  });

  test('fog masks terrain type only when both edge cells are hidden', () {
    expect(
      HexBoardPainter.masksUnknownTerrainBoundary(
        fogActive: true,
        firstVisible: false,
        secondVisible: false,
      ),
      isTrue,
    );
    expect(
      HexBoardPainter.masksUnknownTerrainBoundary(
        fogActive: true,
        firstVisible: true,
        secondVisible: false,
      ),
      isFalse,
    );
    expect(
      HexBoardPainter.masksUnknownTerrainBoundary(
        fogActive: false,
        firstVisible: false,
        secondVisible: false,
      ),
      isFalse,
    );
  });

  testWidgets('fog hides distant ownership borders visual smoke', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.binding.setSurfaceSize(const Size(390, 844));
    SharedPreferences.setMockInitialValues({});
    final state = MapGenerator(mod).generate(
      const GameConfig(
        mapSize: MapSize.small,
        playerCount: 6,
        humanCount: 1,
        fogOfWar: true,
        seed: 824,
      ),
    );
    // If alert filtering regresses, every hidden capital would now leak its
    // location through a bouncing exclamation mark in this golden.
    for (final province in state.provinces) {
      province.money = 20;
    }
    final controller = GameController(
      mod: mod,
      state: state,
      saves: SaveRepository(),
      autosaveEnabled: false,
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: DalaTheme.light,
        home: GameScreen(controller: controller),
      ),
    );
    for (var frame = 0; frame < 40; frame++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
    await waitForMapSprites(tester);
    await expectLater(
      find.byType(GameScreen),
      matchesGoldenFile('visual_smoke_fog_boundaries.png'),
    );

    controller.tapTile(
      controller.engine.provincesOf(controller.state.turn).first.capital,
    );
    expect(controller.selectedOwnProvince, isNotNull);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    final coin = find.bySemanticsLabel('Доход рейтингі');
    expect(coin, findsOneWidget);
    await tester.tap(coin);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await expectLater(
      find.byType(Overlay).first,
      matchesGoldenFile('visual_smoke_fog_income_chart.png'),
    );

    await tester.binding.setSurfaceSize(null);
    semantics.dispose();
  });

  testWidgets('fog boat reveals a usable landing coast', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    SharedPreferences.setMockInitialValues({});
    final state = MapGenerator(mod).generate(
      const GameConfig(
        mapSize: MapSize.small,
        playerCount: 2,
        humanCount: 2,
        fogOfWar: true,
        seed: 824,
      ),
    );
    final controller = GameController(
      mod: mod,
      state: state,
      saves: SaveRepository(),
      autosaveEnabled: false,
    );
    final hiddenBeforeBoat = controller.visibleTileIndices;
    final cell = state.waterCells.firstWhere(
      (candidate) =>
          candidate.navigable &&
          candidate.coastTiles.any(
            (tile) =>
                state.hexes[tile].owner < 0 && !hiddenBeforeBoat.contains(tile),
          ),
    );
    final landing = cell.coastTiles.firstWhere(
      (tile) => state.hexes[tile].owner < 0 && !hiddenBeforeBoat.contains(tile),
    );
    cell.boat = GameBoat(
      owner: state.turn,
      level: 1,
      homeProvinceId: controller.engine.provincesOf(state.turn).first.id,
      cargo: [GameUnit(strength: 1, ready: true)],
    );
    controller.tapWaterCell(cell.index);
    controller.selectBoatCargo(0);
    expect(controller.visibleTileIndices, contains(landing));
    expect(controller.targetTiles, contains(landing));

    await tester.pumpWidget(
      MaterialApp(
        theme: DalaTheme.light,
        home: GameScreen(controller: controller),
      ),
    );
    for (var frame = 0; frame < 40; frame++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
    final view = tester.widget<MapViewport>(find.byType(MapViewport));
    final transform = view.transformationController.value;
    final boatPosition =
        HexBoard.centerOfWater(state, cell) * transform.entry(0, 0) +
        Offset(transform.entry(0, 3), transform.entry(1, 3));
    expect(
      (Offset.zero & tester.getSize(find.byType(MapViewport))).contains(
        boatPosition,
      ),
      isTrue,
    );
    await expectLater(
      find.byType(GameScreen),
      matchesGoldenFile('visual_smoke_fog_boat_landing.png'),
    );

    await tester.binding.setSurfaceSize(null);
  });
}
