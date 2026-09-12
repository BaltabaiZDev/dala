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

  testWidgets('Slay rules phone matches the compact Antiyoy layout', (
    tester,
  ) async {
    final fontLoader = FontLoader('Antiyoy')
      ..addFont(rootBundle.load('assets/classic/font.ttf'));
    await fontLoader.load();
    await tester.binding.setSurfaceSize(const Size(390, 844));
    SharedPreferences.setMockInitialValues({});
    final mod = await GameMod.loadDefault();
    final state = MapGenerator(mod).generate(
      const GameConfig(
        mapSize: MapSize.small,
        playerCount: 5,
        humanCount: 5,
        seed: 20260829,
        treePercent: 0,
        slayRules: true,
      ),
    );
    final controller = GameController(
      mod: mod,
      state: state,
      saves: SaveRepository(),
      autosaveEnabled: false,
    );
    controller.tapTile(controller.engine.provincesOf(0).first.capital);

    await tester.pumpWidget(
      MaterialApp(
        theme: DalaTheme.light,
        home: GameScreen(controller: controller),
      ),
    );
    // The classic atlas contains several dozen PNGs. Give their async codecs
    // time to finish so the golden verifies the real towns and units too.
    for (var frame = 0; frame < 40; frame++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
    await waitForMapSprites(tester);

    await expectLater(
      find.byType(GameScreen),
      matchesGoldenFile('slay_rules_phone.png'),
    );
    await tester.binding.setSurfaceSize(null);
  });
}
