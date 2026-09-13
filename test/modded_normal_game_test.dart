import 'package:antiyoy_self/src/game/models.dart';
import 'package:antiyoy_self/src/modding/content_package.dart';
import 'package:antiyoy_self/src/modding/example_mod.dart';
import 'package:antiyoy_self/src/modding/game_mod.dart';
import 'package:antiyoy_self/src/modding/mod_stack.dart';
import 'package:antiyoy_self/src/persistence/save_repository.dart';
import 'package:antiyoy_self/src/persistence/settings_repository.dart';
import 'package:antiyoy_self/src/ui/dala_theme.dart';
import 'package:antiyoy_self/src/ui/dala_viewport.dart';
import 'package:antiyoy_self/src/ui/game_screen.dart';
import 'package:antiyoy_self/src/ui/home_screen.dart';
import 'package:antiyoy_self/src/ui/mod_build_menu.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'content_package_test.dart' show MemoryContentStorage;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late GameMod base, technology, industry;
  setUpAll(() async {
    base = await GameMod.loadDefault();
    final json = createExampleMod(base).toJson();
    (json['rules'] as Map)['initialMoney'] = 200;
    technology = GameMod.fromJson(json);
    industry = GameMod.fromJson(
      base.toJson()..addAll({
        'id': 'industry',
        'name': 'Industry',
        'buildings': [
          const ModBuilding(
            id: 'industry.mine',
            name: 'Mine',
            price: 40,
            income: 5,
          ).toJson(),
        ],
      }),
    );
  });

  Future<void> until(WidgetTester tester, Finder finder) async {
    for (
      var attempt = 0;
      attempt < 500 && finder.evaluate().isEmpty;
      attempt++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(finder, findsOneWidget);
    await tester.pump(const Duration(milliseconds: 400));
  }

  for (final stacked in [false, true]) {
    testWidgets(
      'ordinary battle retains ${stacked ? 'stacked' : 'single'} mod types after player recoloring and resume',
      (tester) async {
        final selected = [technology, if (stacked) industry];
        final expected = ModStack.compose(base, selected).mod;
        final offset = stacked ? base.palette.length - 1 : 1;
        SharedPreferences.setMockInitialValues({
          'dala.content.activeMods': selected
              .map((m) => m.fingerprint)
              .toList(),
        });
        await const SettingsRepository().save(
          AppSettings(
            mapSize: MapSize.small,
            playerCount: 2,
            humanCount: 2,
            startingProvinceCount: 1,
            treePercent: 0,
            playerColorChoice: offset,
            autosave: false,
          ),
        );
        final storage = MemoryContentStorage();
        for (final mod in selected) {
          storage.files['mods/${mod.id}.dalamod'] = ContentPackage(
            mod: mod,
          ).encode();
        }
        final saves = SaveRepository();
        Widget app() => MaterialApp(
          theme: DalaTheme.light,
          builder: (context, child) => DalaViewport(child: child!),
          home: HomeScreen(
            gameMod: base,
            saves: saves,
            contentStorage: storage,
          ),
        );
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(app());
        await until(tester, find.text('Қосулы модтар: ${selected.length}'));
        await tester.tap(find.text('Шайқас'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Бастау'));
        await until(tester, find.byType(GameScreen));
        final controller = tester
            .widget<GameScreen>(find.byType(GameScreen))
            .controller;
        expect(controller.state.config.playerColorOffset, offset);
        expect(controller.mod.palette.first, expected.palette[offset]);
        expect(
          controller.mod.buildings.keys,
          expected.buildings.keys,
          reason:
              'Choosing a player color must not remove active mod buildings',
        );
        expect(controller.mod.units.keys, expected.units.keys);
        expect(
          controller.mod.components.map((m) => m.hash),
          expected.components.map((m) => m.hash),
        );
        expect(
          GameMod.fromJson(controller.state.modSnapshot!).fingerprint,
          expected.fingerprint,
        );

        final province = controller.engine
            .provincesOf(controller.state.turn)
            .first;
        controller.tapTile(province.capital);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        expect(find.byType(ModCatalogButton), findsOneWidget);
        await tester.tap(find.byTooltip('Құрылыс'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        expect(find.text('Радар'), findsOneWidget);
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('mod-type-my_dala_mod.airfield')),
            matching: find.text('Аэродром'),
          ),
          findsOneWidget,
        );
        expect(find.text('Ұшақ'), findsNothing);
        await tester.tap(
          find.byKey(const ValueKey('mod-type-my_dala_mod.radar')),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        final site = controller.targetTiles.first;
        final money = province.money;
        expect(controller.tapModTile(site), isTrue);
        expect(
          controller.state.hexes[site].buildingTypeId,
          'my_dala_mod.radar',
        );
        expect(
          province.money,
          money - technology.buildings['my_dala_mod.radar']!.price,
        );
        final turnOrder = List<int>.of(controller.state.turnOrder);
        await tester.runAsync(() => saves.save(controller.state));
        await tester.pumpWidget(const SizedBox.shrink());

        // Existing matches retain their saved mod, even after it is disabled or
        // removed. Its palette must be rotated once, not again on every resume.
        storage.files.clear();
        final prefs = await SharedPreferences.getInstance();
        await prefs.setStringList('dala.content.activeMods', []);
        await tester.pumpWidget(app());
        await until(tester, find.text('Жалғастыру'));
        await tester.tap(find.text('Жалғастыру'));
        await until(tester, find.byType(GameScreen));
        final resumed = tester
            .widget<GameScreen>(find.byType(GameScreen))
            .controller;
        expect(resumed.state.turnOrder, turnOrder);
        expect(resumed.mod.buildings.keys, expected.buildings.keys);
        expect(resumed.mod.units.keys, expected.units.keys);
        expect(resumed.mod.palette.first, expected.palette[offset]);
        expect(resumed.state.hexes[site].buildingTypeId, 'my_dala_mod.radar');
        expect(
          GameMod.fromJson(resumed.state.modSnapshot!).fingerprint,
          expected.fingerprint,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
