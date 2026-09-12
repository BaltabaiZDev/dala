import 'dart:io';
import 'dart:ui' as ui;
import 'package:antiyoy_self/src/game/game_controller.dart';
import 'package:antiyoy_self/src/game/game_engine.dart';
import 'package:antiyoy_self/src/modding/example_mod.dart';
import 'package:antiyoy_self/src/modding/game_mod.dart';
import 'package:antiyoy_self/src/persistence/editor_repository.dart';
import 'package:antiyoy_self/src/persistence/save_repository.dart';
import 'package:antiyoy_self/src/ui/dala_theme.dart';
import 'package:antiyoy_self/src/ui/dala_viewport.dart';
import 'package:antiyoy_self/src/ui/editor_screen.dart';
import 'package:antiyoy_self/src/ui/game_screen.dart';
import 'package:antiyoy_self/src/ui/hex_board.dart';
import 'package:antiyoy_self/src/ui/map_viewport.dart';
import 'package:antiyoy_self/src/ui/mod_build_menu.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'mod_types_test.dart' as fixture;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late GameMod mod;
  setUpAll(() async {
    mod = createExampleMod(await GameMod.loadDefault());
    await (FontLoader(
      'Dala Sans',
    )..addFont(rootBundle.load('assets/dala/fonts/NotoSans.ttf'))).load();
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Widget shell(Widget home, {double textScale = 1}) => RepaintBoundary(
    key: const ValueKey('mod-capture'),
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: DalaTheme.light,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: DalaViewport(child: child!),
      ),
      home: home,
    ),
  );
  void phone(WidgetTester tester, {double width = 390}) {
    tester.view.physicalSize = Size(width, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<void> capture(WidgetTester tester, String name) async {
    // Rasterization completes on the engine thread, outside fake test time.
    bool spritesReady() {
      final editors = find.byKey(const ValueKey('editor-board'));
      if (editors.evaluate().isNotEmpty) {
        final dynamic painter = tester.widget<CustomPaint>(editors).painter;
        if (painter.sprites == null) return false;
      }
      return tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((w) => w.painter)
          .whereType<HexUnitPainter>()
          .every((p) => p.sprites != null);
    }

    for (var i = 0; i < 100; i++) {
      if (spritesReady()) break;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    expect(
      spritesReady(),
      isTrue,
      reason: 'Capture only the fully rendered game',
    );
    await tester.pump();
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('mod-capture')),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final directory = Directory('build/mod-types-qa')
        ..createSync(recursive: true);
      File(
        '${directory.path}/$name.png',
      ).writeAsBytesSync(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  Offset pointFor(WidgetTester tester, int index) {
    final board = tester.widget<HexBoard>(find.byType(HexBoard));
    final viewport = tester.widget<MapViewport>(find.byType(MapViewport));
    final render = tester.renderObject<RenderBox>(find.byType(MapViewport));
    return render.localToGlobal(
      MatrixUtils.transformPoint(
        viewport.transformationController.value,
        HexBoard.centerOf(board.controller.state.hexes[index]),
      ),
    );
  }

  testWidgets('phone buys real radar through compact mod catalog and map tap', (
    tester,
  ) async {
    phone(tester);
    final engine = fixture.modFixture(mod);
    final controller = GameController(
      mod: mod,
      state: engine.state,
      saves: SaveRepository(),
      autosaveEnabled: false,
      authoritativeSimulation: false,
    );
    await tester.pumpWidget(shell(GameScreen(controller: controller)));
    await tester.pump(const Duration(milliseconds: 500));
    final home = engine.provincesOf(0).first;
    controller.tapTile(home.capital);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.tap(find.byTooltip('Құрылыс'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(
      find.byKey(const ValueKey('mod-type-my_dala_mod.radar')),
      findsOneWidget,
    );
    await capture(tester, 'catalog-390');
    await tester.tap(find.byKey(const ValueKey('mod-type-my_dala_mod.radar')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(controller.selectedModTypeId, fixture.radar);
    final target = controller.targetTiles.first;
    final before = home.money;
    await tester.tapAt(pointFor(tester, target));
    await tester.pump();
    expect(controller.state.hexes[target].buildingTypeId, fixture.radar);
    expect(home.money, before - 30);
    expect(tester.takeException(), isNull);
    await capture(tester, 'radar-390');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('phone selects aircraft above land and flies over water', (
    tester,
  ) async {
    phone(tester, width: 320);
    final engine = fixture.modFixture(mod);
    final from = fixture.placeAircraft(engine);
    final controller = GameController(
      mod: mod,
      state: engine.state,
      saves: SaveRepository(),
      autosaveEnabled: false,
      authoritativeSimulation: false,
    );
    await tester.pumpWidget(
      shell(GameScreen(controller: controller), textScale: 1.2),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tapAt(pointFor(tester, from));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.byType(ModAirPanel), findsOneWidget);
    final rect = tester.getRect(find.byType(MapViewport));
    final sea = engine
        .airMoveTargets(from)
        .where((i) => !engine.state.hexes[i].active)
        .firstWhere((i) => rect.deflate(8).contains(pointFor(tester, i)));
    await tester.tapAt(pointFor(tester, sea));
    await tester.pump();
    expect(controller.selectedAirTile, sea);
    expect(controller.state.hexes[sea].airUnit!.ready, isFalse);
    expect(find.byType(ModAirPanel), findsOneWidget);
    expect(tester.takeException(), isNull);
    await capture(tester, 'aircraft-320');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'editor places and removes new building types without spending treasury',
    (tester) async {
      phone(tester);
      final engine = fixture.modFixture(mod);
      const repository = EditorRepository();
      await tester.pumpWidget(
        shell(
          EditorScreen(
            mod: mod,
            repository: repository,
            initialState: engine.state,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.ensureVisible(find.text('Модтар'));
      await tester.tap(find.text('Модтар'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.tap(
        find.byKey(const ValueKey('mod-type-my_dala_mod.radar')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.tap(find.byTooltip('Сызу режиміне өту'));
      await tester.pump();
      final target = engine
          .modBuildTargets(engine.provincesOf(0).first.id, fixture.radar)
          .first;
      final camera = tester.widget<MapViewport>(find.byType(MapViewport));
      final render = tester.renderObject<RenderBox>(find.byType(MapViewport));
      final point = render.localToGlobal(
        MatrixUtils.transformPoint(
          camera.transformationController.value,
          HexBoard.centerOf(engine.state.hexes[target]),
        ),
      );
      await tester.tapAt(point);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      final saved = await repository.loadDraft(rules: mod.rules);
      expect(saved?.hexes[target].buildingTypeId, fixture.radar);
      expect(saved?.provinces.first.money, engine.state.provinces.first.money);
      await capture(tester, 'editor-390');
      await tester.tapAt(point);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      expect(
        (await repository.loadDraft(
          rules: mod.rules,
        ))?.hexes[target].buildingTypeId,
        isNull,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('large mod catalog stays searchable above a phone keyboard', (
    tester,
  ) async {
    phone(tester, width: 320);
    final json = mod.toJson();
    (json['buildings'] as List).addAll(<Map<String, dynamic>>[
      for (var i = 0; i < 10; i++)
        ModBuilding(
          id: 'my_dala_mod.mine$i',
          name: 'Mine $i',
          price: 25,
        ).toJson(),
    ]);
    final many = GameMod.fromJson(json);
    await tester.pumpWidget(
      shell(
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showModTypeMenu(context, many),
              child: const Text('Open'),
            ),
          ),
        ),
        textScale: 1.3,
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.resetViewInsets);
    await tester.tap(find.byType(TextField));
    await tester.enterText(find.byType(TextField), 'Mine 9');
    await tester.pumpAndSettle();
    final row = find.byKey(const ValueKey('mod-type-my_dala_mod.mine9'));
    expect(row, findsOneWidget);
    expect(tester.getRect(row).bottom, lessThan(544));
    expect(find.byType(TextField), findsOneWidget);
    expect(tester.takeException(), isNull);
    await capture(tester, 'catalog-keyboard-320');
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets(
    'airfield opens only its aircraft and launches from that airfield',
    (tester) async {
      phone(tester, width: 320);
      final engine = fixture.modFixture(mod);
      final home = engine.provincesOf(0).first;
      final first = engine.modBuildTargets(home.id, fixture.airfield).first;
      engine.buildModType(home.id, first, fixture.airfield);
      final second = engine.modBuildTargets(home.id, fixture.airfield).last;
      engine.buildModType(home.id, second, fixture.airfield);
      final controller = GameController(
        mod: mod,
        state: engine.state,
        saves: SaveRepository(),
        autosaveEnabled: false,
        authoritativeSimulation: false,
      );
      await tester.pumpWidget(
        shell(GameScreen(controller: controller), textScale: 1.3),
      );
      controller.tapTile(first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.byType(ModBuildingPanel), findsOneWidget);
      expect(find.text('Модтар'), findsNothing);
      await capture(tester, 'airfield-production-320');
      await tester.tap(find.byTooltip('Әскер'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(
        find.byKey(const ValueKey('mod-type-my_dala_mod.aircraft')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('mod-type-my_dala_mod.radar')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('mod-type-my_dala_mod.scout')),
        findsNothing,
      );
      await capture(tester, 'airfield-catalog-320');
      await tester.tap(
        find.byKey(const ValueKey('mod-type-my_dala_mod.aircraft')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(controller.selectedTile, first);
      expect(controller.targetTiles, isNot(contains(second)));
      final before = home.money;
      await tester.tapAt(pointFor(tester, first));
      await tester.pump();
      expect(controller.state.hexes[first].airUnit?.typeId, fixture.aircraft);
      expect(home.money, before - 40);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'long production names stay compact and full details remain accessible',
    (tester) async {
      phone(tester, width: 320);
      final json = mod.toJson();
      final products = (json['buildings'] as List)[1]['production'] as List;
      products.clear();
      for (var i = 0; i < 32; i++) {
        products.add(
          ModUnitType(
            id: 'my_dala_mod.plane$i',
            name: 'Long aircraft designation with extended equipment number $i',
            price: 40,
            movement: ModMovement.air,
          ).toJson(),
        );
      }
      final many = GameMod.fromJson(json);
      await tester.pumpWidget(
        shell(
          Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showModTypeMenu(
                  context,
                  many,
                  typeIds: many.buildings[fixture.airfield]!.production.map(
                    (u) => u.id,
                  ),
                  title: 'Аэродром',
                ),
                child: const Text('Open'),
              ),
            ),
          ),
          textScale: 1.3,
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      final first = find.byKey(const ValueKey('mod-type-my_dala_mod.plane0'));
      expect(tester.getSize(first).height, lessThan(105));
      expect(find.byType(TextField), findsOneWidget);
      await capture(tester, 'long-production-320');
      await tester.tap(
        find.byKey(const ValueKey('mod-info-my_dala_mod.plane0')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('Өндіріс: Аэродром'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Жабу'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'number 31');
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('mod-type-my_dala_mod.plane31')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
