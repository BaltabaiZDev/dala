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

  setUpAll(() async {
    final fontLoader = FontLoader('Antiyoy')
      ..addFont(rootBundle.load('assets/classic/font.ttf'));
    await fontLoader.load();
  });

  testWidgets('classic diplomacy inbox visual', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    SharedPreferences.setMockInitialValues({});
    final mod = await GameMod.loadDefault();
    final state = MapGenerator(mod).generate(
      const GameConfig(
        mapSize: MapSize.small,
        playerCount: 3,
        humanCount: 1,
        seed: 1910,
        diplomacy: true,
      ),
    );
    final controller = GameController(
      mod: mod,
      state: state,
      saves: SaveRepository(),
      autosaveEnabled: false,
    );
    controller.engine.sendDiplomacyMessage(
      from: 1,
      to: 0,
      text: 'Шекараны бірге қорғайық.',
    );
    controller.engine.proposeExchange(
      from: 2,
      to: 0,
      fromOffer: const DiplomacyOffer(
        type: DiplomacyExchangeType.friendship,
        duration: 12,
      ),
      toOffer: const DiplomacyOffer(
        type: DiplomacyExchangeType.subsidies,
        amount: 2,
        duration: 12,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: DalaTheme.light,
        home: GameScreen(controller: controller),
      ),
    );
    await waitForMapSprites(tester);
    await tester.tap(find.byIcon(Icons.mail_outline));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await expectLater(
      find.byType(Overlay).first,
      matchesGoldenFile('diplomacy_inbox.png'),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.binding.setSurfaceSize(null);
  });
}
