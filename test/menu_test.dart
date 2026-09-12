import 'package:antiyoy_self/src/ui/dala_theme.dart';
import 'package:antiyoy_self/src/modding/game_mod.dart';
import 'package:antiyoy_self/src/persistence/save_repository.dart';
import 'package:antiyoy_self/src/persistence/settings_repository.dart';
import 'package:antiyoy_self/src/ui/home_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'content_package_test.dart' show MemoryContentStorage;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late GameMod mod;

  setUpAll(() async {
    final fontLoader = FontLoader('Antiyoy')
      ..addFont(rootBundle.load('assets/classic/font.ttf'));
    await fontLoader.load();
    mod = await GameMod.loadDefault();
  });

  testWidgets('classic menu exposes every working flow on a phone', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: DalaTheme.light,
        home: HomeScreen(gameMod: mod, saves: SaveRepository(), contentStorage: MemoryContentStorage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Шайқас'), findsOneWidget);
    expect(find.text('LAN ойыны'), findsOneWidget);
    expect(find.text('Редактор'), findsOneWidget);
    expect(find.text('Ойыншы деңгейлері'), findsOneWidget);
    expect(find.text('Кампания'), findsOneWidget);
    expect(find.text('Жүктеу'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Шайқас'));
    await tester.pumpAndSettle();
    expect(find.text('Қиындық'), findsOneWidget);
    expect(find.text('Карта өлшемі'), findsOneWidget);
    expect(find.text('Ойыншылар'), findsOneWidget);
    expect(find.text('Бастау'), findsOneWidget);
    expect(find.bySemanticsLabel('Артқа'), findsOneWidget);
    expect(tester.getRect(find.text('Бастау')).top, greaterThanOrEqualTo(0));
    expect(
      tester.getRect(find.bySemanticsLabel('Артқа')).top,
      greaterThanOrEqualTo(0),
    );
    expect(find.byType(Slider), findsNWidgets(4));
    expect(find.textContaining('Seed'), findsNothing);
    expect(find.text('Кездейсоқ карта'), findsNothing);
    expect(find.text('Slay ережесі'), findsNothing);
    expect(find.text('Соғыс тұманы'), findsNothing);
    expect(find.text('Дипломатия'), findsNothing);
    expect(find.text('Қосымша'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.drag(find.byType(Slider).at(2), const Offset(-500, 0));
    await tester.pump();
    expect(find.text('боттар шайқасы'), findsOneWidget);

    await tester.drag(find.byType(Slider).at(3), const Offset(500, 0));
    await tester.pump();
    expect(find.text('9 түс'), findsOneWidget);

    await tester.drag(find.byType(Slider).at(1), const Offset(500, 0));
    await tester.pump();
    await tester.drag(find.byType(Slider).at(3), const Offset(500, 0));
    await tester.pump();
    expect(find.text('15 түс'), findsOneWidget);
    await tester.drag(find.byType(Slider).at(2), const Offset(500, 0));
    await tester.pump();
    expect(find.text('мультиплеер 15x'), findsOneWidget);

    await tester.drag(find.byType(Slider).at(1), const Offset(-500, 0));
    await tester.pump();
    expect(find.text('5 түс'), findsOneWidget);
    expect(find.text('мультиплеер 5x'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Қосымша'));
    await tester.pumpAndSettle();
    expect(find.text('Slay ережесі'), findsOneWidget);
    expect(find.text('Соғыс тұманы'), findsOneWidget);
    expect(find.text('Дипломатия'), findsOneWidget);
    expect(find.text('Провинциялар'), findsOneWidget);
    expect(find.text('Ағаштар'), findsOneWidget);
    expect(find.byKey(const ValueKey('player-color-selector')), findsOneWidget);
    expect(find.text('Әдепкі'), findsOneWidget);
    expect(find.byType(Slider), findsNWidgets(2));
    final provinceSlider = tester.widget<Slider>(find.byType(Slider).first);
    expect(provinceSlider.min, 0);
    expect(provinceSlider.max, 3);
    expect(provinceSlider.divisions, 3);
    expect(provinceSlider.value, 0);
    expect(find.text('Қиындық'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('editor is a separate persistent functional flow', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: DalaTheme.light,
        home: HomeScreen(gameMod: mod, saves: SaveRepository(), contentStorage: MemoryContentStorage()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Редактор'));
    await tester.pumpAndSettle();

    expect(find.text('Редактор'), findsOneWidget);
    expect(find.text('Жер'), findsOneWidget);
    expect(find.text('Түс'), findsOneWidget);
    expect(find.text('Нысан'), findsOneWidget);
    expect(find.text('Әскер'), findsOneWidget);
    expect(find.text('Теңіз'), findsOneWidget);
    expect(find.byTooltip('Картаны ойнату'), findsOneWidget);
    expect(find.byTooltip('Карта баптаулары'), findsOneWidget);
    expect(find.byKey(const ValueKey('editor-board')), findsOneWidget);
    await expectLater(
      find.byType(Overlay).first,
      matchesGoldenFile('goldens/editor_no_frame_phone.png'),
    );

    await tester.tap(find.text('Теңіз'));
    await tester.pump();
    expect(find.byTooltip('Су жалбызы'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byTooltip('Карта әрекеттері'));
    await tester.pumpAndSettle();
    expect(find.text('Жобаны сақтау'), findsOneWidget);
    expect(find.text('Жобаны жүктеу'), findsOneWidget);
    expect(find.text('Картаны экспорттау'), findsOneWidget);
    expect(find.text('Картаны импорттау'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('editor back requires an explicit save-and-exit choice', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: DalaTheme.light,
        home: HomeScreen(gameMod: mod, saves: SaveRepository(), contentStorage: MemoryContentStorage()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Редактор'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.tap(find.byTooltip('Артқа'));
    await tester.pumpAndSettle();
    expect(find.text('Редактордан шығу?'), findsOneWidget);
    await tester.tap(find.text('Редакторға қайту'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('editor-board')), findsOneWidget);

    await tester.tap(find.byTooltip('Артқа'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Сақтау және шығу'));
    await tester.pumpAndSettle();
    expect(find.text('Шайқас'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('player color opens the Classic bottom palette', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: DalaTheme.light,
        home: HomeScreen(gameMod: mod, saves: SaveRepository(), contentStorage: MemoryContentStorage()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Шайқас'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Қосымша'));
    await tester.pumpAndSettle();
    final advancedContext = tester.element(
      find.byKey(const ValueKey('player-color-selector')),
    );
    await tester.runAsync(() async {
      for (final asset in [
        'assets/classic/random_color_pixel.png',
        'assets/classic/arrow.png',
        'assets/classic/gray_circle.png',
      ]) {
        await precacheImage(AssetImage(asset), advancedContext);
      }
    });
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('player-color-selector')));
    await tester.pumpAndSettle();

    final palette = find.byKey(const ValueKey('player-color-palette'));
    expect(palette, findsOneWidget);
    for (var index = 0; index < 15; index++) {
      expect(find.byKey(ValueKey('player-color-$index')), findsOneWidget);
    }
    expect(find.byKey(const ValueKey('player-color-random')), findsOneWidget);
    final paletteRect = tester.getRect(palette);
    expect(paletteRect.bottom, closeTo(800, 1));
    expect(paletteRect.height, closeTo(180, 1));
    await expectLater(
      find.byType(Overlay).first,
      matchesGoldenFile('goldens/classic_color_picker_phone.png'),
    );

    await tester.tap(find.byKey(const ValueKey('player-color-8')));
    await tester.pumpAndSettle();
    expect(palette, findsNothing);
    expect((await const SettingsRepository().load()).playerColorChoice, 8);

    await tester.tap(find.byKey(const ValueKey('player-color-selector')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('player-color-random')));
    await tester.pumpAndSettle();
    expect((await const SettingsRepository().load()).playerColorChoice, -1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('province selector shows default then one two three', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: DalaTheme.light,
        home: HomeScreen(gameMod: mod, saves: SaveRepository(), contentStorage: MemoryContentStorage()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Шайқас'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Қосымша'));
    await tester.pumpAndSettle();

    expect(find.text('Әдепкі'), findsOneWidget);
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/province_default_phone.png'),
    );

    await tester.drag(find.byType(Slider).first, const Offset(500, 0));
    await tester.pump();
    expect(find.text('3'), findsOneWidget);
    final slider = tester.widget<Slider>(find.byType(Slider).first);
    expect(slider.value, 3);
  });

  testWidgets('classic home matches the phone visual baseline', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: DalaTheme.light,
        home: HomeScreen(gameMod: mod, saves: SaveRepository(), contentStorage: MemoryContentStorage()),
      ),
    );
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/classic_home_phone.png'),
    );
  });

  testWidgets('settings expose only controls that affect gameplay', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: DalaTheme.light,
        home: HomeScreen(gameMod: mod, saves: SaveRepository(), contentStorage: MemoryContentStorage()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.bySemanticsLabel('Баптаулар'));
    await tester.pumpAndSettle();

    expect(find.text('Автосақтау'), findsOneWidget);
    expect(find.text('Сезімталдық'), findsOneWidget);
    expect(find.text('Жылдам құрылыс'), findsNothing);
    expect(find.text('Жылдам қозғалыс'), findsNothing);
  });

  testWidgets('campaign and player levels are not swapped', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: DalaTheme.light,
        home: HomeScreen(gameMod: mod, saves: SaveRepository(), contentStorage: MemoryContentStorage()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Ойыншы деңгейлері'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Swiss Cheese Royale'), findsOneWidget);
    expect(find.text('1'), findsNothing);
    await tester.tap(find.bySemanticsLabel('Артқа'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Кампания'));
    await tester.pumpAndSettle();
    expect(find.text('1'), findsOneWidget);
    expect(find.text('Кездейсоқ деңгей'), findsNothing);
  });

  testWidgets('long pressing a preset copies it into the real editor', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: DalaTheme.light,
        home: HomeScreen(gameMod: mod, saves: SaveRepository(), contentStorage: MemoryContentStorage()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Кампания'));
    await tester.pumpAndSettle();
    await tester.longPress(find.text('1'));
    // Map generation uses a worker isolate. Alternate real-time waits with
    // widget pumps so its completion can re-enter the fake-async UI zone while
    // the intentionally repeating Classic loader is on screen.
    for (
      var attempt = 0;
      attempt < 500 && find.text('Жер').evaluate().isEmpty;
      attempt++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    await tester.pumpAndSettle();

    expect(find.text('Редактор'), findsOneWidget);
    expect(find.text('Жер'), findsOneWidget);
    expect(find.byTooltip('Картаны ойнату'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('classic battle setup matches the phone visual baseline', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: DalaTheme.light,
        home: HomeScreen(gameMod: mod, saves: SaveRepository(), contentStorage: MemoryContentStorage()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Шайқас'));
    await tester.pumpAndSettle();
    final battleContext = tester.element(find.byType(Scaffold));
    await tester.runAsync(() async {
      for (final asset in [
        'assets/classic/arrow.png',
        'assets/classic/gray_circle.png',
      ]) {
        await precacheImage(AssetImage(asset), battleContext);
      }
    });
    await tester.pump();

    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/classic_battle_phone.png'),
    );
  });

  testWidgets('classic battle more page matches the phone visual baseline', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: DalaTheme.light,
        home: HomeScreen(gameMod: mod, saves: SaveRepository(), contentStorage: MemoryContentStorage()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Шайқас'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Қосымша'));
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/classic_battle_more_phone.png'),
    );
  });

  testWidgets('classic level grid matches the phone visual baseline', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: DalaTheme.light,
        home: HomeScreen(gameMod: mod, saves: SaveRepository(), contentStorage: MemoryContentStorage()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Кампания'));
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/classic_levels_phone.png'),
    );
  });

  testWidgets('player level list matches the phone visual baseline', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: DalaTheme.light,
        home: HomeScreen(gameMod: mod, saves: SaveRepository(), contentStorage: MemoryContentStorage()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ойыншы деңгейлері'));
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/classic_player_levels_phone.png'),
    );
  });
}
