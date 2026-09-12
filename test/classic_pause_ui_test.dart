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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late GameMod mod;

  setUpAll(() async {
    final fontLoader = FontLoader('Antiyoy')
      ..addFont(rootBundle.load('assets/classic/font.ttf'));
    await fontLoader.load();
    mod = await GameMod.loadDefault();
  });

  testWidgets('Classic pause rows and manual save work from the three dots', (
    tester,
  ) async {
    _configurePhone(tester);
    final saves = _CountingSaveRepository();
    GameScreenExit? exit;
    await tester.pumpWidget(
      _PauseHarness(mod: mod, saves: saves, onExit: (value) => exit = value),
    );
    await tester.tap(find.text('Ойынды ашу'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    final gameContext = tester.element(find.byType(GameScreen));
    await tester.runAsync(() async {
      await precacheImage(
        const AssetImage('assets/classic/gray_circle.png'),
        gameContext,
      );
    });
    await tester.pump();

    await tester.tap(find.bySemanticsLabel('Мәзір'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));
    final labels = ['Жалғастыру', 'Қайта бастау', 'Сақтау', 'Басты мәзір'];
    for (final label in labels) {
      expect(find.text(label), findsOneWidget);
    }
    await expectLater(
      find.byType(Overlay).first,
      matchesGoldenFile('goldens/classic_pause_phone.png'),
    );
    final tops = [
      for (final label in labels) tester.getTopLeft(find.text(label)).dy,
    ];
    expect(tops, orderedEquals([...tops]..sort()));

    await tester.tap(find.text('Жалғастыру'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));
    expect(find.text('Қайта бастау'), findsNothing);

    await tester.tap(find.bySemanticsLabel('Мәзір'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));
    await tester.tap(find.text('Сақтау'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));
    expect(saves.saveCount, 1);
    final notice = find.byKey(const ValueKey('top-snack-bar'));
    expect(notice, findsOneWidget);
    expect(tester.getTopLeft(notice).dy, lessThan(800 / 3));
    await tester.pump(const Duration(milliseconds: 1500));

    await tester.tap(find.bySemanticsLabel('Мәзір'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));
    await tester.tap(find.text('Басты мәзір'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Ойынды ашу'), findsOneWidget);
    expect(exit, GameScreenExit.mainMenu);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Back opens pause and a second Back activates main menu', (
    tester,
  ) async {
    _configurePhone(tester);
    final saves = _CountingSaveRepository();
    GameScreenExit? exit;
    await tester.pumpWidget(
      _PauseHarness(mod: mod, saves: saves, onExit: (value) => exit = value),
    );
    await tester.tap(find.text('Ойынды ашу'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));
    expect(find.text('Қайта бастау'), findsOneWidget);
    expect(find.byType(GameScreen), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Ойынды ашу'), findsOneWidget);
    expect(exit, GameScreenExit.mainMenu);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Restart leaves the game with an explicit restart result', (
    tester,
  ) async {
    _configurePhone(tester);
    final saves = _CountingSaveRepository();
    GameScreenExit? exit;
    await tester.pumpWidget(
      _PauseHarness(mod: mod, saves: saves, onExit: (value) => exit = value),
    );
    await tester.tap(find.text('Ойынды ашу'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.tap(find.bySemanticsLabel('Мәзір'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));
    await tester.tap(find.text('Қайта бастау'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Ойынды ашу'), findsOneWidget);
    expect(exit, GameScreenExit.restart);
    expect(tester.takeException(), isNull);
  });
}

void _configurePhone(WidgetTester tester) {
  tester.view.physicalSize = const Size(360, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

class _PauseHarness extends StatelessWidget {
  const _PauseHarness({
    required this.mod,
    required this.saves,
    required this.onExit,
  });

  final GameMod mod;
  final _CountingSaveRepository saves;
  final ValueChanged<GameScreenExit?> onExit;

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: DalaTheme.light,
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: TextButton(
            onPressed: () async {
              final state = MapGenerator(mod).generate(
                const GameConfig(
                  mapSize: MapSize.small,
                  playerCount: 2,
                  humanCount: 2,
                  seed: 8302026,
                ),
              );
              final result = await Navigator.of(context).push<GameScreenExit>(
                MaterialPageRoute<GameScreenExit>(
                  builder: (_) => GameScreen(
                    controller: GameController(
                      mod: mod,
                      state: state,
                      saves: saves,
                      autosaveEnabled: false,
                    ),
                  ),
                ),
              );
              onExit(result);
            },
            child: const Text('Ойынды ашу'),
          ),
        ),
      ),
    ),
  );
}

class _CountingSaveRepository extends SaveRepository {
  int saveCount = 0;

  @override
  Future<void> save(GameState state) async {
    saveCount++;
  }
}
