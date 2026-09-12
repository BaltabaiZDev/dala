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

  testWidgets('classic diplomacy panel visual', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    SharedPreferences.setMockInitialValues({});
    final mod = await GameMod.loadDefault();
    final state = MapGenerator(mod).generate(
      const GameConfig(
        mapSize: MapSize.small,
        playerCount: 5,
        humanCount: 5,
        seed: 1906,
        diplomacy: true,
      ),
    );
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
    final screenContext = tester.element(find.byType(GameScreen));
    await tester.runAsync(() async {
      for (final asset in const [
        'assets/classic/diplomacy/like_icon.png',
        'assets/classic/diplomacy/dislike_icon.png',
        'assets/classic/diplomacy/black_mark_icon.png',
        'assets/classic/diplomacy/info_icon.png',
        'assets/classic/diplomacy/mail_icon.png',
        'assets/classic/diplomacy/exchange_icon.png',
        'assets/classic/diplomacy/exchange_down.png',
        'assets/classic/back_icon.png',
      ]) {
        await precacheImage(AssetImage(asset), screenContext);
      }
    });
    await waitForMapSprites(tester);
    expect(find.byIcon(Icons.mail_outline), findsNothing);
    await tester.tap(find.byIcon(Icons.flag_outlined));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await expectLater(
      find.byType(Overlay).first,
      matchesGoldenFile('diplomacy_main.png'),
    );
    await tester.tap(find.text(state.playerName(1)).first);
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byTooltip('Достық ұсыну'), findsOneWidget);
    expect(find.byTooltip('Соғыс жариялау'), findsOneWidget);
    expect(find.byTooltip('Қара белгі қою'), findsOneWidget);
    expect(find.byTooltip('Қатынастары'), findsOneWidget);
    expect(find.byTooltip('Хат жіберу'), findsOneWidget);
    expect(find.byTooltip('Айырбас'), findsOneWidget);
    await expectLater(
      find.byType(Overlay).first,
      matchesGoldenFile('diplomacy_selected.png'),
    );
    final exchangeIcon = find.byTooltip('Айырбас');
    await tester.tap(exchangeIcon);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 900));
    await tester.pump();
    expect(find.text('Ұсыну'), findsOneWidget);
    expect(find.text('Ештеңе'), findsNWidgets(2));
    await expectLater(
      find.byKey(const ValueKey('diplomacy-exchange-page')),
      matchesGoldenFile('diplomacy_exchange.png'),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.binding.setSurfaceSize(null);
  });
}
