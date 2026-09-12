import 'package:antiyoy_self/src/ui/dala_theme.dart';
import 'package:antiyoy_self/src/game/game_controller.dart';
import 'package:antiyoy_self/src/game/map_generator.dart';
import 'package:antiyoy_self/src/game/models.dart';
import 'package:antiyoy_self/src/modding/game_mod.dart';
import 'package:antiyoy_self/src/persistence/save_repository.dart';
import 'package:antiyoy_self/src/ui/game_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'render_test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('portrait board visual smoke', (tester) async {
    final fontLoader = FontLoader('Antiyoy')
      ..addFont(rootBundle.load('assets/classic/font.ttf'));
    await fontLoader.load();
    final semantics = tester.ensureSemantics();
    await tester.binding.setSurfaceSize(const Size(390, 844));
    SharedPreferences.setMockInitialValues({});
    final mod = await GameMod.loadDefault();
    final state = MapGenerator(mod).generate(
      const GameConfig(
        mapSize: MapSize.small,
        playerCount: 3,
        humanCount: 3,
        seed: 824,
      ),
    );
    final controller = GameController(
      mod: mod,
      state: state,
      saves: SaveRepository(),
      autosaveEnabled: false,
    );
    final province = controller.engine.provincesOf(0).first;
    province.money = 60;
    final defenseIndex = province.tiles.firstWhere(
      (index) => index != province.capital,
      orElse: () => province.capital,
    );
    state.hexes[defenseIndex].object = TileObject.tower;
    controller.tapTile(province.capital);
    await tester.pumpWidget(
      MaterialApp(
        theme: DalaTheme.light,
        // Asset decoding time must not change the flag animation phase in a
        // static screenshot; animation behavior has its own tests.
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: GameScreen(controller: controller),
      ),
    );
    await waitForMapSprites(tester);
    controller.longPressTile(defenseIndex);
    await tester.pump(const Duration(milliseconds: 320));
    await tester.pump(const Duration(milliseconds: 200));
    await expectLater(
      find.byType(GameScreen),
      matchesGoldenFile('visual_smoke_board.png'),
    );
    controller.endLongPress();
    await tester.pump(const Duration(milliseconds: 600));

    controller
      ..aiThinking = true
      ..aiPlayer = 1
      ..aiProgress = .4
      ..notifyListeners();
    await tester.pump(const Duration(milliseconds: 160));
    await expectLater(
      find.byType(GameScreen),
      matchesGoldenFile('visual_smoke_ai_progress.png'),
    );
    controller
      ..aiThinking = false
      ..aiPlayer = null
      ..aiProgress = 0
      ..notifyListeners();
    await tester.pump(const Duration(milliseconds: 160));

    await tester.tap(find.bySemanticsLabel('Доход рейтингі'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 360));
    await expectLater(
      find.byType(Overlay).first,
      matchesGoldenFile('visual_smoke_income_chart.png'),
    );
    await tester.tapAt(const Offset(10, 80));
    await tester.pump(const Duration(milliseconds: 250));

    state.hexes[defenseIndex].object = TileObject.port1;
    controller.tapTile(defenseIndex);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await expectLater(
      find.byType(GameScreen),
      matchesGoldenFile('visual_smoke_port_panel.png'),
    );

    state.hexes[defenseIndex]
      ..object = TileObject.artillery1
      ..artilleryAmmo = 0;
    controller.tapTile(defenseIndex);
    controller.tapTile(defenseIndex);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await expectLater(
      find.byType(GameScreen),
      matchesGoldenFile('visual_smoke_artillery_panel.png'),
    );

    controller.tapTile(province.capital);
    controller.setTool(PlayerTool.unit1);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));
    await expectLater(
      find.byType(GameScreen),
      matchesGoldenFile('visual_smoke_tool_preview.png'),
    );
    controller.setTool(PlayerTool.select);
    await tester.pump(const Duration(milliseconds: 220));

    final sourceCell = state.waterCells.firstWhere(
      (cell) =>
          cell.navigable &&
          cell.coastTiles.any(
            (index) => controller.engine.provinceAt(index) != null,
          ),
    );
    final sourceTile = sourceCell.coastTiles.firstWhere(
      (index) => controller.engine.provinceAt(index) != null,
    );
    final sourceProvince = controller.engine.provinceAt(sourceTile)!
      ..money = 100;
    final targetOwner = (sourceProvince.owner + 1) % state.config.playerCount;
    state.hexes[sourceTile]
      ..object = TileObject.artillery3
      ..artilleryAmmo = 7
      ..unit = null;
    sourceCell.boat = GameBoat(
      owner: targetOwner,
      level: 1,
      homeProvinceId: state.provinces
          .firstWhere((province) => province.owner == targetOwner)
          .id,
    );
    state.turn = 2;

    final turnFuture = controller.finishTurn();
    await tester.pump();
    expect(controller.artilleryFireAnimation, isNotEmpty);
    await tester.pump(const Duration(milliseconds: 280));
    await expectLater(
      find.byType(GameScreen),
      matchesGoldenFile('visual_smoke_artillery.png'),
    );
    await tester.pump(const Duration(milliseconds: 1000));
    await _pumpUntilDone(tester, turnFuture);
    semantics.dispose();
    await tester.binding.setSurfaceSize(null);
  });
}

Future<void> _pumpUntilDone(
  WidgetTester tester,
  Future<void> future, {
  int maxFrames = 320,
}) async {
  var completed = false;
  Object? failure;
  StackTrace? failureStack;
  future.then<void>(
    (_) => completed = true,
    onError: (Object error, StackTrace stack) {
      failure = error;
      failureStack = stack;
      completed = true;
    },
  );
  for (var frame = 0; frame < maxFrames && !completed; frame++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
  if (failure != null) Error.throwWithStackTrace(failure!, failureStack!);
  expect(
    completed,
    isTrue,
    reason: 'turn did not finish within $maxFrames frames',
  );
}
