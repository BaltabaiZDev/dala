import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:antiyoy_self/src/game/map_generator.dart';
import 'package:antiyoy_self/src/game/models.dart';
import 'package:antiyoy_self/src/modding/content_library.dart';
import 'package:antiyoy_self/src/modding/content_package.dart';
import 'package:antiyoy_self/src/modding/game_mod.dart';
import 'package:antiyoy_self/src/ui/content_screen.dart';
import 'package:antiyoy_self/src/ui/dala_theme.dart';
import 'package:antiyoy_self/src/ui/map_setup_dialog.dart';
import 'content_package_test.dart' show MemoryContentStorage;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late GameMod base;
  late GameState state;
  setUpAll(() async {
    base = await GameMod.loadDefault();
    state = MapGenerator(base).generate(
      const GameConfig(
        mapSize: MapSize.small,
        playerCount: 4,
        humanCount: 1,
        seed: 78,
        diplomacy: true,
        fogOfWar: true,
        campaignLevel: 1,
      ),
    );
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> finishDeletion(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('confirm-content-delete')));
    // Route completion uses frames, while content decoding uses an isolate.
    for (var i = 0; i < 100; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
      if (find.byType(LinearProgressIndicator).evaluate().isEmpty &&
          find.byType(AlertDialog).evaluate().isEmpty) {
        break;
      }
    }
    await tester.pumpAndSettle();
  }

  test(
    'all valid seat counts preserve authored map and rules; campaign is detached',
    () {
      final map = DalaMap.fromState('Four realms', state, base);
      final original = jsonEncode(map.stateJson);
      expect(map.maxHumanCount, 4);
      expect(map.createState(base, multiplayer: true).config.humanCount, 2);
      for (var people = 1; people <= 4; people++) {
        for (final lan in [false, true]) {
          if (lan && people == 1) continue;
          final match = map.createState(
            base,
            multiplayer: lan,
            humanCount: people,
          );
          expect(match.config.humanCount, people);
          expect(match.config.playerCount, 4);
          expect(match.config.campaignLevel, isNull);
          final expected = state.toJson()..remove('modSnapshot');
          (expected['config'] as Map)
            ..['humanCount'] = people
            ..remove('campaignLevel');
          final actual = match.toJson()..remove('modSnapshot');
          expect(actual, expected);
          expect(jsonEncode(map.stateJson), original);
        }
      }
      for (final count in [0, 5, -1]) {
        expect(
          () => map.createState(base, humanCount: count),
          throwsFormatException,
        );
      }
      expect(
        () => map.createState(base, multiplayer: true, humanCount: 1),
        throwsFormatException,
      );
    },
  );

  test('uninhabited factions cannot silently occupy LAN human seats', () {
    final copy = state.toJson();
    // Metadata models a map with a gap in its authored faction slots.
    final provinces = copy['provinces'] as List;
    provinces.removeWhere((p) => (p as Map)['owner'] == 1);
    final map = DalaMap(name: 'Gap', stateJson: copy);
    expect(map.maxHumanCount, 1);
    expect(
      () => map.createState(base, multiplayer: true),
      throwsFormatException,
    );
  });

  testWidgets(
    'custom map setup exposes seats while authored dimensions stay read-only',
    (tester) async {
      final map = DalaMap.fromState('Four realms', state, base);
      int? result;
      await tester.pumpWidget(
        MaterialApp(
          theme: DalaTheme.light,
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  result = await showMapSetup(context, map, lan: true);
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(
        find.text('Өлшемі: ${map.width} × ${map.height} · Тараптар: 4'),
        findsOneWidget,
      );
      expect(find.byType(DropdownButtonFormField<int>), findsOneWidget);
      expect(find.byType(Slider), findsNothing);
      expect(find.text('Адамдар: 2 · Боттар: 2'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('map-human-count')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Адамдар: 3 · Боттар: 1').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('map-setup-start')));
      await tester.pumpAndSettle();
      expect(result, 3);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'map delete requires confirmation and cancel preserves the file',
    (tester) async {
      final storage = MemoryContentStorage();
      final library = ContentLibrary(base, storage: storage);
      addTearDown(library.dispose);
      await tester.runAsync(
        () => library.importFile(
          'map.dalamap',
          DalaMap.fromState('Keep me', state, base).encode(),
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: DalaTheme.light,
          home: ContentScreen(library: library),
        ),
      );
      await tester.tap(find.text('Карталар'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Өшіру'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(storage.files, hasLength(1));
      await tester.tap(find.text('Бас тарту'));
      await tester.pumpAndSettle();
      expect(library.maps, hasLength(1));
      await tester.tap(find.byTooltip('Өшіру'));
      await tester.pumpAndSettle();
      await finishDeletion(tester);
      expect(storage.files, isEmpty);
      expect(library.maps, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'mod delete explains bundled map loss and preserves standalone maps',
    (tester) async {
      final mod = GameMod.fromJson(
        base.toJson()
          ..['id'] = 'bundle'
          ..['name'] = 'Bundle',
      );
      final modState = MapGenerator(
        mod,
      ).generate(const GameConfig(playerCount: 2, mapSize: MapSize.small));
      final storage = MemoryContentStorage();
      final library = ContentLibrary(base, storage: storage);
      addTearDown(library.dispose);
      await tester.runAsync(() async {
        await library.importFile(
          'bundle.dalamod',
          ContentPackage(
            mod: mod,
            maps: [DalaMap.fromState('Bundled', modState, mod)],
          ).encode(),
        );
        await library.importFile(
          'standalone.dalamap',
          DalaMap.fromState('Standalone', modState, mod).encode(),
        );
        await library.activate(mod.fingerprint);
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: DalaTheme.light,
          home: ContentScreen(library: library),
        ),
      );
      await tester.tap(find.byTooltip('Өшіру'));
      await tester.pumpAndSettle();
      expect(
        find.text('Модпен бірге оның ішіндегі 1 карта да өшіріледі.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Бас тарту'));
      await tester.pumpAndSettle();
      expect(library.activeMod.fingerprint, mod.fingerprint);
      await tester.tap(find.byTooltip('Өшіру'));
      await tester.pumpAndSettle();
      await finishDeletion(tester);
      expect(library.mods, isEmpty);
      expect(library.maps.single.map.name, 'Standalone');
      expect(library.modForMap(library.maps.single), isNull);
      expect(library.activeMod.fingerprint, base.fingerprint);
      expect(tester.takeException(), isNull);
    },
  );
}
