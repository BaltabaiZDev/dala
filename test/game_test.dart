import 'dart:convert';
import 'dart:math' as math;

import 'package:antiyoy_self/src/game/game_engine.dart';
import 'package:antiyoy_self/src/game/game_ai.dart';
import 'package:antiyoy_self/src/game/game_controller.dart';
import 'package:antiyoy_self/src/game/map_generator.dart';
import 'package:antiyoy_self/src/game/models.dart';
import 'package:antiyoy_self/src/modding/game_mod.dart';
import 'package:antiyoy_self/src/persistence/save_repository.dart';
import 'package:antiyoy_self/src/persistence/settings_repository.dart';
import 'package:antiyoy_self/src/ui/diplomacy_sheet.dart';
import 'package:antiyoy_self/src/ui/game_screen.dart';
import 'package:antiyoy_self/src/ui/classic_assets.dart';
import 'package:antiyoy_self/src/ui/hex_board.dart';
import 'package:antiyoy_self/src/ui/map_viewport.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late GameMod mod;

  setUpAll(() async {
    mod = await GameMod.loadDefault();
  });

  test('all classic gameplay sprites decode', () async {
    final sprites = await ClassicSprites.load();
    expect(sprites.images, contains('port1'));
    expect(sprites.images, contains('boat2'));
    expect(sprites.images, contains('sea_mint'));
    expect(sprites.images, contains('naval_supply_link'));
    expect(sprites.images, contains('sea_fort'));
    expect(sprites.images, contains('artillery'));
    expect(sprites.images, contains('artillery_base'));
    expect(sprites.images, contains('artillery_turret'));
    expect(sprites.images, contains('exclamation_mark'));
    expect(sprites.images, contains('diplomacy_black_mark'));
    sprites.dispose();
  });

  test('classic mod exposes fifteen distinct player colors', () {
    expect(mod.palette, hasLength(15));
    expect(mod.palette.map((color) => color.toARGB32()).toSet(), hasLength(15));
  });

  test('all six AI difficulty tiers survive config serialization', () {
    expect(AiDifficulty.values, hasLength(6));
    for (final difficulty in AiDifficulty.values) {
      final restored = GameConfig.fromJson(
        GameConfig(difficulty: difficulty).toJson(),
      );
      expect(restored.difficulty, difficulty);
    }
  });

  test('map-size setup capacities follow Classic and extend to fifteen', () {
    expect(MapSize.small.maxPlayers, 5);
    expect(MapSize.medium.maxPlayers, 9);
    expect(MapSize.large.maxPlayers, 10);
    expect(MapSize.huge.maxPlayers, 10);
    expect(MapSize.giant.maxPlayers, 15);

    final clamped = AppSettings.fromJson(const {
      'mapSize': 'small',
      'playerCount': 15,
      'humanCount': 15,
    });
    expect(clamped.playerCount, 5);
    expect(clamped.humanCount, 5);
    final giant = AppSettings.fromJson(const {
      'mapSize': 'giant',
      'playerCount': 15,
      'humanCount': 15,
    });
    expect(giant.playerCount, 15);
    expect(giant.humanCount, 15);
  });

  test(
    'menu and game setup preferences persist in SharedPreferences',
    () async {
      SharedPreferences.setMockInitialValues({});
      const repository = SettingsRepository();
      const expected = AppSettings(
        mapSize: MapSize.giant,
        playerCount: 15,
        humanCount: 15,
        difficulty: AiDifficulty.master,
        treePercent: 35,
        startingProvinceCount: 3,
        playerColorChoice: 8,
        sensitivity: 9,
        sound: true,
        autosave: false,
        leftHanded: true,
      );

      await repository.save(expected);
      final restored = await repository.load();

      expect(restored.mapSize, MapSize.giant);
      expect(restored.playerCount, 15);
      expect(restored.humanCount, 15);
      expect(restored.difficulty, AiDifficulty.master);
      expect(restored.treePercent, 35);
      expect(restored.startingProvinceCount, 3);
      expect(restored.playerColorChoice, 8);
      expect(restored.sensitivity, 9);
      expect(restored.sound, isTrue);
      expect(restored.autosave, isFalse);
      expect(restored.leftHanded, isTrue);
    },
  );

  test('province setup defaults to random and migrates the old maximum', () {
    expect(const AppSettings().startingProvinceCount, 0);
    expect(AppSettings.fromJson(const {}).startingProvinceCount, 0);
    expect(const GameConfig().startingProvinceCount, 0);
    final legacyConfig = const GameConfig().toJson()
      ..remove('startingProvinceCount');
    expect(GameConfig.fromJson(legacyConfig).startingProvinceCount, 0);
    expect(
      AppSettings.fromJson(const {
        'startingProvinceCount': 4,
      }).startingProvinceCount,
      3,
    );
  });

  test('settings import rejects malformed values before writing', () async {
    SharedPreferences.setMockInitialValues({});
    const repository = SettingsRepository();
    const original = AppSettings(playerCount: 6, treePercent: 20);
    await repository.save(original);

    final accepted = await repository.importRaw(
      jsonEncode({
        'version': 1,
        'settings': {...original.toJson(), 'treePercent': 900},
        'unlockedLevels': 7,
      }),
    );

    expect(accepted, isFalse);
    final restored = await repository.load();
    expect(restored.playerCount, 6);
    expect(restored.treePercent, 20);
  });

  test('autosave runs once at the completed turn boundary', () async {
    final saves = _CountingSaveRepository();
    final state = _linearState([0, 0, 1, 1], humanCount: 1);
    state.provinces.first.money = 100;
    final controller = GameController(mod: mod, state: state, saves: saves);

    controller.tapTile(0);
    controller.setTool(PlayerTool.farm);
    controller.tapTile(1);
    expect(saves.saveCount, 0, reason: 'actions must not trigger disk writes');

    await controller.finishTurn();
    expect(saves.saveCount, 1, reason: 'one save per completed human turn');
    controller.dispose();
  });

  test('disabled autosave never writes at a turn boundary', () async {
    final saves = _CountingSaveRepository();
    final controller = GameController(
      mod: mod,
      state: _linearState([0, 0, 1, 1], humanCount: 1),
      saves: saves,
      autosaveEnabled: false,
    );

    await controller.finishTurn();
    expect(saves.saveCount, 0);
    controller.dispose();
  });

  testWidgets('AI turn publishes a visible player and progress state', (
    tester,
  ) async {
    final controller = GameController(
      mod: mod,
      state: _linearState([0, 0, 1, 1], humanCount: 1),
      saves: _CountingSaveRepository(),
    );
    await tester.pumpWidget(
      MaterialApp(home: GameScreen(controller: controller)),
    );
    var publishedThinking = false;
    int? publishedPlayer;
    controller.addListener(() {
      if (controller.aiThinking) {
        publishedThinking = true;
        publishedPlayer = controller.aiPlayer;
      }
    });
    final turnFuture = controller.finishTurn();
    await tester.pump();
    await tester.pump(Duration.zero);

    expect(publishedThinking, isTrue);
    expect(publishedPlayer, 1);

    await tester.pump(const Duration(milliseconds: 500));
    await _pumpUntilDone(tester, turnFuture);
    expect(controller.aiThinking, isFalse);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  test('small maps distribute all fifteen players fairly', () {
    for (final seed in [15, 1515, 91515]) {
      final state = MapGenerator(mod).generate(
        GameConfig(
          mapSize: MapSize.small,
          playerCount: 15,
          humanCount: 1,
          seed: seed,
          startingProvinceCount: 1,
        ),
      );
      expect(state.provinces, hasLength(15));
      expect(state.provinces.map((province) => province.owner).toSet(), {
        for (var player = 0; player < 15; player++) player,
      });
      expect(
        state.provinces.every(
          (province) =>
              province.tiles.length >= 2 && province.tiles.length <= 5,
        ),
        isTrue,
      );
    }
  });

  test('procedural seeds produce varied coastlines at a fixed land budget', () {
    final coastlines = <String>{};
    for (var seed = 100; seed < 112; seed++) {
      final state = MapGenerator(
        mod,
      ).generate(GameConfig(mapSize: MapSize.small, seed: seed));
      expect(state.hexes.where((tile) => tile.active), hasLength(206));
      final coast = state.hexes
          .where(
            (tile) =>
                tile.active &&
                tile.neighbors.any((neighbor) => !state.hexes[neighbor].active),
          )
          .map((tile) => '${tile.q}:${tile.r}')
          .join('|');
      coastlines.add(coast);
    }
    expect(coastlines.length, greaterThanOrEqualTo(10));
  });

  test(
    'seeded generation is deterministic and gives every player a province',
    () {
      const config = GameConfig(
        mapSize: MapSize.small,
        playerCount: 4,
        humanCount: 1,
        seed: 4242,
      );
      final a = MapGenerator(mod).generate(config);
      final b = MapGenerator(mod).generate(config);

      expect(a.hexes.where((tile) => tile.active).length, 206);
      expect(a.provinces.map((province) => province.owner).toSet(), {
        0,
        1,
        2,
        3,
      });
      final waterTiles = a.waterCells.expand((cell) => cell.tiles).toList();
      expect(waterTiles.toSet().length, waterTiles.length);
      expect(
        waterTiles.toSet(),
        a.hexes
            .where((tile) => tile.inWorld && !tile.active)
            .map((tile) => tile.index)
            .toSet(),
      );
      expect(a.hexes.every((tile) => tile.inWorld), isTrue);
      expect(waterTiles.length, greaterThan(206));
      expect(
        a.waterCells.every(
          (cell) => cell.tiles.length >= 3 && cell.tiles.length <= 5,
        ),
        isTrue,
        reason:
            'invalid sea cells: ${a.waterCells.where((cell) => cell.tiles.length < 3 || cell.tiles.length > 5).map((cell) => '${cell.tiles}:${cell.tiles.expand((tile) => a.hexes[tile].neighbors).toSet().where((tile) => !a.hexes[tile].active).toList()}').toList()}',
      );
      expect(
        a.waterCells.where((cell) => cell.tiles.length == 3).every((cell) {
          var joinedEdges = 0;
          for (final tile in cell.tiles) {
            joinedEdges += a.hexes[tile].neighbors
                .where(cell.tiles.contains)
                .length;
          }
          return joinedEdges ~/ 2 >= 2;
        }),
        isTrue,
      );
      expect(
        a.waterCells.every(
          (cell) => cell.neighbors.every(
            (neighbor) => a.waterCells[neighbor].neighbors.contains(cell.index),
          ),
        ),
        isTrue,
      );
      expect(
        a.hexes
            .map((tile) => '${tile.active}:${tile.owner}:${tile.object.name}')
            .toList(),
        b.hexes
            .map((tile) => '${tile.active}:${tile.owner}:${tile.object.name}')
            .toList(),
      );
    },
  );

  test('all map sizes cover the sea with connected three-cell regions', () {
    for (final size in MapSize.values) {
      for (final seed in [3, 29, 811]) {
        final state = MapGenerator(
          mod,
        ).generate(GameConfig(mapSize: size, seed: seed));
        final inactive = state.hexes
            .where((tile) => tile.inWorld && !tile.active)
            .map((tile) => tile.index)
            .toSet();
        final covered = state.waterCells.expand((cell) => cell.tiles).toSet();
        expect(covered, inactive, reason: '$size / $seed sea coverage');
        expect(
          state.waterCells.every(
            (cell) => cell.tiles.length >= 3 && cell.tiles.length <= 5,
          ),
          isTrue,
          reason:
              '$size / $seed remainder merge: ${state.waterCells.map((cell) => cell.tiles.length).where((count) => count < 3 || count > 5).toList()}',
        );
        expect(
          state.waterCells.every(
            (cell) => cell.tiles.every(
              (tile) =>
                  cell.tiles.length == 1 ||
                  state.hexes[tile].neighbors.any(cell.tiles.contains),
            ),
          ),
          isTrue,
          reason: '$size / $seed connectivity',
        );
      }
    }
  });

  test('unit purchase spends province money and creates a ready unit', () {
    final state = MapGenerator(mod).generate(const GameConfig(seed: 7));
    final engine = GameEngine(mod: mod, state: state);
    final province = engine.provincesOf(0).first;
    province.money = 50;
    final target = province.tiles.firstWhere(
      (index) => state.hexes[index].object != TileObject.town,
    );

    expect(engine.buyUnit(province.id, target, 2), isTrue);
    expect(province.money, 30);
    expect(state.hexes[target].unit?.strength, 2);
    expect(state.hexes[target].unit?.ready, isTrue);
  });

  test('buying a unit onto an owned tree spends its movement', () {
    final state = _linearState([0, 0, 0, 1, 1]);
    final engine = GameEngine(mod: mod, state: state);
    final province = engine.provincesOf(0).single..money = 20;
    state.hexes[1].object = TileObject.pine;

    expect(engine.buyUnit(province.id, 1, 1), isTrue);
    expect(province.money, 13);
    expect(state.hexes[1].object, TileObject.none);
    expect(state.hexes[1].unit?.ready, isFalse);
  });

  test('tree generation follows coastal palm and inland pine habitats', () {
    final state = MapGenerator(mod).generate(
      const GameConfig(mapSize: MapSize.small, seed: 912, treePercent: 100),
    );
    var palms = 0;
    var pines = 0;
    for (final tile in state.hexes.where((tile) => tile.hasTree)) {
      final coastal = state.waterCells.any(
        (cell) => cell.navigable && cell.coastTiles.contains(tile.index),
      );
      if (tile.object == TileObject.palm) {
        palms++;
        expect(coastal, isTrue);
      } else {
        pines++;
        expect(coastal, isFalse);
      }
    }
    expect(palms, greaterThan(0));
    expect(pines, greaterThan(0));
  });

  test('generated enclosed lakes are large enough to navigate', () {
    var enclosedLakes = 0;
    for (var seed = 1; seed <= 40; seed++) {
      final state = MapGenerator(
        mod,
      ).generate(GameConfig(mapSize: MapSize.small, seed: seed));
      final unseen = state.waterCells.map((cell) => cell.index).toSet();
      while (unseen.isNotEmpty) {
        final queue = <int>[unseen.first];
        final component = <int>{queue.first};
        unseen.remove(queue.first);
        for (var cursor = 0; cursor < queue.length; cursor++) {
          for (final neighbor in state.waterCells[queue[cursor]].neighbors) {
            if (component.add(neighbor)) {
              unseen.remove(neighbor);
              queue.add(neighbor);
            }
          }
        }
        final rawTiles = component
            .expand((cell) => state.waterCells[cell].tiles)
            .toSet();
        final enclosed = rawTiles.every((index) {
          final tile = state.hexes[index];
          return tile.neighbors.length == 6 &&
              tile.neighbors.every((neighbor) => state.hexes[neighbor].inWorld);
        });
        if (!enclosed) continue;
        enclosedLakes++;
        expect(component.length, greaterThanOrEqualTo(3));
        expect(
          component.every((cell) => state.waterCells[cell].navigable),
          isTrue,
        );
      }
    }
    expect(enclosedLakes, greaterThan(0));
  });

  test('ports use a large sea but reject an adjacent small lake', () {
    final hexes = [
      for (var index = 0; index < 7; index++)
        HexTile(
          index: index,
          q: index,
          r: 0,
          active: index < 3,
          owner: index < 3 ? 0 : -1,
        ),
    ];
    hexes[2].object = TileObject.town;
    final state = GameState(
      config: const GameConfig(playerCount: 1),
      modId: 'classic_steppe',
      width: 7,
      height: 1,
      hexes: hexes,
      waterCells: [
        WaterCell(
          index: 0,
          tiles: [3],
          neighbors: [1],
          coastTiles: [0],
          navigable: true,
        ),
        WaterCell(index: 1, tiles: [4], neighbors: [0, 2], navigable: true),
        WaterCell(index: 2, tiles: [5], neighbors: [1], navigable: true),
        WaterCell(index: 3, tiles: [6], coastTiles: [0, 1], navigable: false),
      ],
      provinces: [
        Province(id: 1, owner: 0, tiles: [0, 1, 2], money: 100, capital: 2),
      ],
      turn: 0,
      round: 1,
      rngState: 1,
      nextProvinceId: 2,
    );
    final engine = GameEngine(mod: mod, state: state);

    expect(engine.buildTargets(1, TileObject.port1), contains(0));
    expect(engine.buildTargets(1, TileObject.port1), isNot(contains(1)));
    expect(engine.build(1, 0, TileObject.port1), isTrue);
    expect(engine.boatBuildTargets(1, 0, 1), {0});
  });

  test('unit purchase can attack a valid border tile directly', () {
    final state = MapGenerator(mod).generate(const GameConfig(seed: 17));
    final engine = GameEngine(mod: mod, state: state);
    final province = engine.provincesOf(0).first;
    province.money = 100;
    final target = engine
        .unitBuildTargets(province.id, 4)
        .firstWhere((index) => state.hexes[index].owner != state.turn);

    expect(engine.buyUnit(province.id, target, 4), isTrue);
    expect(state.hexes[target].owner, state.turn);
    expect(state.hexes[target].unit?.strength, 4);
    expect(state.hexes[target].unit?.ready, isFalse);
    expect(province.money, 60);
  });

  test('controller undo restores money, unit, and province selection', () {
    SharedPreferences.setMockInitialValues({});
    final state = MapGenerator(mod).generate(const GameConfig(seed: 23));
    final engine = GameEngine(mod: mod, state: state);
    final province = engine.provincesOf(0).first;
    province.money = 50;
    final target = engine
        .unitBuildTargets(province.id, 1)
        .firstWhere((index) => state.hexes[index].owner == state.turn);
    final controller = GameController(
      mod: mod,
      state: state,
      saves: SaveRepository(),
      autosaveEnabled: false,
    );

    controller.tapTile(province.capital);
    controller.setTool(PlayerTool.unit1);
    controller.tapTile(target);
    expect(state.hexes[target].unit, isNotNull);
    expect(province.money, 40);
    expect(controller.canUndo, isTrue);

    controller.undo();
    expect(state.hexes[target].unit, isNull);
    expect(controller.selectedTile, province.capital);
    expect(controller.selectedProvince?.money, 50);
    controller.dispose();
  });

  test('tapping the selected ready unit again clears its move zone', () {
    SharedPreferences.setMockInitialValues({});
    final state = MapGenerator(mod).generate(const GameConfig(seed: 31));
    final engine = GameEngine(mod: mod, state: state);
    final province = engine.provincesOf(0).first;
    province.money = 50;
    final target = engine
        .unitBuildTargets(province.id, 1)
        .firstWhere((index) => state.hexes[index].owner == state.turn);
    expect(engine.buyUnit(province.id, target, 1), isTrue);
    final controller = GameController(
      mod: mod,
      state: state,
      saves: SaveRepository(),
    );

    controller.tapTile(target);
    expect(controller.selectedTile, target);
    expect(controller.targetTiles, isNotEmpty);

    controller.tapTile(target);
    expect(controller.selectedTile, isNull);
    expect(controller.targetTiles, isEmpty);
    controller.dispose();
  });

  test('tapping any selected land tile again clears selection', () {
    SharedPreferences.setMockInitialValues({});
    final state = _linearState([0, 0, 0, 1, 1]);
    final controller = GameController(
      mod: mod,
      state: state,
      saves: SaveRepository(),
    );
    final capital = controller.engine.provincesOf(0).single.capital;

    controller.tapTile(capital);
    expect(controller.selectedTile, capital);
    expect(controller.selectedOwnProvince, isNotNull);
    controller.tapTile(capital);
    expect(controller.selectedTile, isNull);
    expect(controller.selectedOwnProvince, isNull);
    controller.dispose();
  });

  test('selecting an opponent tile does not expose its economy', () {
    SharedPreferences.setMockInitialValues({});
    final state = MapGenerator(mod).generate(const GameConfig(seed: 37));
    final controller = GameController(
      mod: mod,
      state: state,
      saves: SaveRepository(),
    );
    final ownProvince = controller.engine.provincesOf(state.turn).first;
    final opponentProvince = state.provinces.firstWhere(
      (province) => province.owner != state.turn,
    );

    controller.tapTile(ownProvince.capital);
    expect(controller.selectedOwnProvince, same(ownProvince));

    controller.tapTile(opponentProvince.capital);
    expect(controller.selectedProvince, same(opponentProvince));
    expect(controller.selectedOwnProvince, isNull);
    controller.dispose();
  });

  testWidgets('HUD never combines money from disconnected provinces', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final state = _linearState([0, 0, -1, 0, 0, 1, 1]);
    final own = state.provinces
        .where((province) => province.owner == 0)
        .toList();
    own[0].money = 17;
    own[1].money = 29;
    final controller = GameController(
      mod: mod,
      state: state,
      saves: SaveRepository(),
    );
    controller.tapTile(own.first.capital);
    await tester.pumpWidget(
      MaterialApp(home: GameScreen(controller: controller)),
    );
    await tester.pump();
    expect(find.text('17'), findsOneWidget);
    expect(find.text('46'), findsNothing);

    controller.tapTile(state.provinces.last.capital);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('46'), findsNothing);
    expect(find.text('—'), findsNothing);
    expect(find.bySemanticsLabel('Доход рейтингі'), findsNothing);
    expect(find.bySemanticsLabel('Доход есебі'), findsNothing);
    expect(find.bySemanticsLabel('Ферма, бағасы 12'), findsNothing);
    expect(find.bySemanticsLabel('Мәзір'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  test('invalid construction tap cancels the active tool and mask', () {
    SharedPreferences.setMockInitialValues({});
    final state = _linearState([0, 0, 0, 1, 1]);
    final controller = GameController(
      mod: mod,
      state: state,
      saves: SaveRepository(),
    );
    final province = controller.engine.provincesOf(0).single..money = 100;
    controller.tapTile(province.capital);
    controller.setTool(PlayerTool.farm);
    expect(controller.tool, PlayerTool.farm);

    controller.tapTile(province.capital);
    expect(controller.tool, PlayerTool.select);
    expect(state.hexes[province.capital].object, TileObject.town);
    expect(controller.targetTiles, isEmpty);
    controller.dispose();
  });

  test('merging two ready units keeps the combined unit ready', () {
    final state = MapGenerator(mod).generate(const GameConfig(seed: 41));
    final engine = GameEngine(mod: mod, state: state);
    final province = engine.provincesOf(state.turn).first;
    late int from;
    late int to;
    var found = false;
    for (final index in province.tiles) {
      for (final neighbor in state.hexes[index].neighbors) {
        if (province.tiles.contains(neighbor)) {
          from = index;
          to = neighbor;
          found = true;
          break;
        }
      }
      if (found) break;
    }
    expect(found, isTrue);
    state.hexes[from]
      ..object = TileObject.none
      ..unit = GameUnit(strength: 1, ready: true);
    state.hexes[to]
      ..object = TileObject.none
      ..unit = GameUnit(strength: 1, ready: true);

    expect(engine.moveUnit(from, to), isTrue);
    expect(state.hexes[from].unit, isNull);
    expect(state.hexes[to].unit?.strength, 2);
    expect(state.hexes[to].unit?.ready, isTrue);
    expect(engine.moveTargets(to), isNotEmpty);
  });

  test('tree reward is paid only for clearing a tree on owned land', () {
    final state = _linearState([0, 0, 0, 1, 1]);
    final engine = GameEngine(mod: mod, state: state);
    final province = engine.provincesOf(0).first;
    province.money = 20;
    state.hexes[1].object = TileObject.pine;
    state.hexes[2]
      ..object = TileObject.none
      ..unit = GameUnit(strength: 1, ready: true);

    expect(engine.moveUnit(2, 1), isTrue);
    expect(province.money, 23);
    expect(state.hexes[1].object, TileObject.none);

    state.hexes[2].unit = GameUnit(strength: 1, ready: true);
    state.hexes[3].object = TileObject.pine;
    expect(engine.moveUnit(2, 3), isTrue);
    expect(engine.provincesOf(0).first.money, 23);
    expect(state.hexes[3].object, TileObject.none);
  });

  test('classic income, upkeep, and prices match Antiyoy rules', () {
    final state = _linearState([0, 0, 0, 0, 0, 1, 1]);
    final engine = GameEngine(mod: mod, state: state);
    final province = engine.provincesOf(0).first;
    for (final index in province.tiles) {
      state.hexes[index]
        ..object = TileObject.none
        ..unit = null;
    }
    state.hexes[0].object = TileObject.farm;
    state.hexes[1].object = TileObject.pine;
    state.hexes[2].unit = GameUnit(strength: 1);
    state.hexes[3].unit = GameUnit(strength: 2);
    state.hexes[4].object = TileObject.tower;

    expect(engine.income(province), 8);
    expect(engine.upkeep(province), 9);
    expect(engine.balance(province), -1);
    expect(engine.playerIncome(0), 8);
    expect(mod.rules.unitUpkeep, [0, 2, 6, 18, 36]);
    expect(mod.rules.towerPrice, 15);
    expect(mod.rules.strongTowerPrice, 35);
  });

  test('economy is credited only when the full round ends', () {
    final state = _linearState([0, 0, 1, 1]);
    final engine = GameEngine(mod: mod, state: state);
    final first = engine.provincesOf(0).single;
    final second = engine.provincesOf(1).single;

    expect(first.money, 10);
    expect(second.money, 10);
    engine.endTurn();

    expect(state.turn, 1);
    expect(first.money, 10);
    expect(second.money, 10);
    engine.endTurn();
    expect(state.turn, 0);
    expect(first.money, 12);
    expect(second.money, 12);
  });

  test('an unpaid unit leaves a grave for one full round before a tree', () {
    final state = _linearState([0, 0, 1, 1]);
    final province = state.provinces.first;
    province.money = 0;
    state.hexes[1].unit = GameUnit(strength: 4);
    final engine = GameEngine(mod: mod, state: state);

    engine.endTurn();
    engine.endTurn();
    expect(state.hexes[1].unit, isNull);
    expect(state.hexes[1].object, TileObject.grave);

    engine.endTurn();
    engine.endTurn();
    expect(state.hexes[1].object, anyOf(TileObject.pine, TileObject.palm));
  });

  test('ports launch bounded boats with capacity and water upkeep', () {
    final state = _controllerNavalState();
    final engine = GameEngine(mod: mod, state: state);
    final province = state.provinces.single;

    expect(engine.buildTargets(province.id, TileObject.port1), contains(1));
    expect(engine.build(province.id, 1, TileObject.port1), isTrue);
    expect(engine.boatBuildTargets(province.id, 1, 1), {0});
    expect(engine.buildBoat(province.id, 1, 0, 1), isTrue);
    expect(engine.boatCapacity(1), 4);
    expect(engine.boatCapacity(2), 10);

    state.hexes[0].unit = GameUnit(strength: 4, ready: true);
    expect(engine.unitBoardingTargets(0), {0});
    expect(engine.boardUnit(0, 0), isTrue);
    expect(state.waterCells[0].boat!.usedCapacity, 4);
    final report = engine.economicBreakdown(province);
    expect(report.units, -54);
    expect(report.ports, -mod.rules.port1Upkeep);
    expect(report.boats, -mod.rules.boat1Upkeep);
    expect(report.cargoUnits, -54);
    expect(report.total, -57);

    expect(engine.boatMoveTargets(0), contains(1));
    expect(engine.moveBoat(0, 1), isTrue);
    expect(engine.boatMoveTargets(1), isEmpty);
  });

  test('a level-two port can only be developed from a level-one port', () {
    final state = _controllerNavalState();
    final engine = GameEngine(mod: mod, state: state);
    final province = state.provinces.single;

    expect(engine.buildTargets(province.id, TileObject.port2), isEmpty);
    expect(engine.build(province.id, 1, TileObject.port2), isFalse);
    expect(state.hexes[1].object, TileObject.none);

    expect(engine.build(province.id, 1, TileObject.port1), isTrue);
    expect(engine.upgradePort(1), isTrue);
    expect(state.hexes[1].object, TileObject.port2);
    expect(province.money, 80);
  });

  test('empty artillery reloads automatically without firing', () {
    final state = _artilleryState()..turn = 0;
    final engine = GameEngine(mod: mod, state: state);
    final province = state.provinces.first;
    expect(mod.rules.artilleryAmmoCapacity, [0, 2, 4, 7]);
    state.hexes[1]
      ..object = TileObject.artillery2
      ..artilleryAmmo = 0;

    engine.endTurn();
    engine.endTurn();

    expect(state.hexes[1].artilleryAmmo, 4);
    expect(engine.lastArtilleryStrikes, isEmpty);
    expect(state.waterCells[0].boat, isNotNull);
    expect(province.money, 94);
  });

  test('every empty artillery battery reloads in the same round', () {
    final state = _linearState([0, 0, 0, 1, 1], turn: 1);
    state.hexes[1]
      ..object = TileObject.artillery1
      ..artilleryAmmo = 0;
    state.hexes[2]
      ..object = TileObject.artillery3
      ..artilleryAmmo = 0;
    final engine = GameEngine(mod: mod, state: state);

    engine.endTurn();

    expect(state.hexes[1].artilleryAmmo, 2);
    expect(state.hexes[2].artilleryAmmo, 7);
  });

  test('a newly boarded unit cannot disembark until its next turn', () {
    final state = _controllerNavalState();
    final engine = GameEngine(mod: mod, state: state);
    state.waterCells[0].boat = GameBoat(owner: 0, level: 1, homeProvinceId: 1);
    state.hexes[1].unit = GameUnit(strength: 1, ready: true);

    expect(engine.boardUnit(1, 0), isTrue);
    expect(state.waterCells[0].boat!.cargo.single.ready, isFalse);
    expect(engine.boatDisembarkTargets(0, 0), isEmpty);

    engine.endTurn();
    expect(state.waterCells[0].boat!.cargo.single.ready, isTrue);
    expect(engine.boatDisembarkTargets(0, 0), contains(1));
  });

  test('a purchased unit can enter a nearby boat but spends its turn', () {
    final state = _controllerNavalState();
    final engine = GameEngine(mod: mod, state: state);
    final province = state.provinces.single;
    state.waterCells[0].boat = GameBoat(
      owner: 0,
      level: 1,
      homeProvinceId: province.id,
    );

    expect(engine.unitBoatBuildTargets(province.id, 2), contains(0));
    expect(engine.buyUnitIntoBoat(province.id, 0, 2), isTrue);
    expect(province.money, 180);
    expect(state.waterCells[0].boat!.cargo.single.strength, 2);
    expect(state.waterCells[0].boat!.cargo.single.ready, isFalse);
  });

  test('three occupied landing cells remain linked until one becomes free', () {
    final state = _bridgeheadState();
    final engine = GameEngine(mod: mod, state: state);
    final boat = state.waterCells.single.boat!;

    expect(engine.disembarkUnit(0, 0, 0), isTrue);
    expect(engine.disembarkUnit(0, 0, 1), isTrue);
    expect(engine.disembarkUnit(0, 0, 2), isTrue);
    expect(engine.provinceAt(0)?.navalCapital, isTrue);
    expect(boat.supportedTiles.toSet(), {0, 1, 2});

    state.hexes[2].unit = null;
    engine.rebuildProvinces();
    final landing = engine.provinceAt(0);
    expect(landing, isNotNull);
    expect(landing!.tiles.toSet(), {0, 1, 2});
    expect(landing.capital, 2);
    expect(landing.navalCapital, isFalse);
    expect(landing.navalFounded, isTrue);
    expect(boat.supportedTiles, isEmpty);
  });

  test(
    'fourth marine can land but a bridgehead cannot exceed move radius four',
    () {
      final state = _longBridgeheadState();
      final engine = GameEngine(mod: mod, state: state);
      final boat = state.waterCells.single.boat!;

      for (var target = 0; target < 4; target++) {
        expect(
          engine.boatDisembarkTargets(0, 0),
          contains(target),
          reason: 'landing step ${target + 1} must remain available',
        );
        expect(engine.disembarkUnit(0, 0, target), isTrue);
      }

      expect(engine.provinceAt(0)?.navalCapital, isTrue);
      expect(boat.supportedTiles.toSet(), {0, 1, 2, 3});
      expect(engine.boatDisembarkTargets(0, 0), isNot(contains(4)));

      state.hexes[3].unit = null;
      engine.rebuildProvinces();
      final landing = engine.provinceAt(0);
      expect(landing, isNotNull);
      expect(landing!.tiles.toSet(), {0, 1, 2, 3});
      expect(landing.capital, 3);
      expect(boat.supportedTiles, isEmpty);
    },
  );

  test('a boat can land on every coast tile touching its sea cell', () {
    final state = _bridgeheadState();
    final cell = state.waterCells.single;
    cell.coastTiles.add(2);
    final engine = GameEngine(mod: mod, state: state);

    expect(engine.disembarkUnit(0, 0, 0), isTrue);
    expect(engine.boatDisembarkTargets(0, 0), contains(2));
    expect(engine.disembarkUnit(0, 0, 2), isTrue);
    expect(cell.boat!.supportedTiles.toSet(), {0, 2});
  });

  test('a temporary naval city transfers support without creating money', () {
    final state = _longBridgeheadState();
    final engine = GameEngine(mod: mod, state: state);
    final boat = state.waterCells.single.boat!;
    boat
      ..level = 1
      ..cargo.removeLast();

    for (var target = 0; target < 4; target++) {
      expect(engine.disembarkUnit(0, 0, target), isTrue);
    }
    final landing = engine.provinceAt(0)!;
    final levelOne = engine.economicBreakdown(landing);
    final home = engine.economicBreakdown(engine.provinceAt(6)!);
    expect(landing.navalCapital, isTrue);
    expect(levelOne.land, 4);
    expect(levelOne.navalSupport, 4);
    expect(levelOne.units, -(4 * mod.rules.unitUpkeep[1]));
    expect(levelOne.total, 0);
    expect(home.units, 0);
    expect(home.boats, -mod.rules.boat1Upkeep);
    expect(home.navalTransfer, -(4 + mod.rules.navalSupplyUpkeep));
    expect(landing.money, 0);
    expect(engine.unitBuildTargets(landing.id, 1), isEmpty);

    boat.level = 2;
    final levelTwo = engine.economicBreakdown(landing);
    final levelTwoHome = engine.economicBreakdown(engine.provinceAt(6)!);
    expect(levelTwo.navalSupport, 10);
    expect(levelTwo.total, 6);
    expect(levelTwoHome.boats, -mod.rules.boat2Upkeep);
    expect(levelTwoHome.navalTransfer, -(10 + mod.rules.navalSupplyUpkeep));
  });

  test('one boat shares its support across every disconnected bridgehead', () {
    final state = _bridgeheadState();
    for (final index in const [0, 1, 2]) {
      state.hexes[index].neighbors.clear();
    }
    state.waterCells.single.coastTiles
      ..clear()
      ..addAll(const [0, 1, 2, 4]);
    final engine = GameEngine(mod: mod, state: state);

    for (final target in const [0, 1, 2]) {
      expect(engine.disembarkUnit(0, 0, target), isTrue);
    }

    final bridgeheads = engine
        .provincesOf(0)
        .where((province) => province.navalCapital)
        .toList();
    final reports = bridgeheads.map(engine.economicBreakdown).toList();
    expect(bridgeheads, hasLength(3));
    expect(
      reports.fold<int>(0, (sum, report) => sum + report.navalSupport),
      engine.boatCapacity(1),
    );
    expect(reports.every((report) => report.navalSupport > 0), isTrue);

    engine.endTurn();
    engine.endTurn();

    expect(
      const [0, 1, 2].where((index) => state.hexes[index].unit != null),
      hasLength(3),
    );
  });

  test('home bankruptcy ends subsidy without wiping the bridgehead', () {
    final state = _longBridgeheadState();
    final engine = GameEngine(mod: mod, state: state);
    final boat = state.waterCells.single.boat!;
    boat
      ..level = 1
      ..cargo.removeLast();

    for (var target = 0; target < 4; target++) {
      expect(engine.disembarkUnit(0, 0, target), isTrue);
    }
    final fundedLanding = engine.provinceAt(0)!;
    final marines = fundedLanding.tiles
        .map((index) => state.hexes[index].unit)
        .whereType<GameUnit>()
        .toList();
    expect(marines, hasLength(4));
    expect(
      marines.every((unit) => unit.homeProvinceId == fundedLanding.id),
      isTrue,
    );
    engine.provinceAt(6)!.money = 0;

    engine.endTurn();
    engine.endTurn();

    final landing = engine.provinceAt(0)!;
    expect(state.waterCells.single.boat, isNull);
    expect(state.waterCells.single.seaMint, isTrue);
    expect(landing.navalCapital, isFalse);
    expect(boat.supportedTiles, isEmpty);
    expect(
      landing.tiles.where((index) => state.hexes[index].unit != null),
      hasLength(3),
    );
    expect(
      landing.tiles.where(
        (index) => state.hexes[index].object == TileObject.town,
      ),
      hasLength(1),
    );
    expect(
      landing.tiles.where(
        (index) => state.hexes[index].object == TileObject.grave,
      ),
      isEmpty,
    );
  });

  test('sailing away leaves a one-tile landing to the orphan lifecycle', () {
    final state = _bridgeheadState();
    state.waterCells[0].neighbors.add(1);
    state.waterCells.add(
      WaterCell(index: 1, tiles: [3], neighbors: [0], coastTiles: const []),
    );
    final engine = GameEngine(mod: mod, state: state);
    final boat = state.waterCells[0].boat!;

    expect(engine.disembarkUnit(0, 0, 0), isTrue);
    expect(engine.provinceAt(0)?.navalCapital, isTrue);
    expect(engine.moveBoat(0, 1), isTrue);

    expect(state.waterCells[1].boat, same(boat));
    expect(engine.provinceAt(0), isNull);
    expect(state.hexes[0].object, TileObject.none);
    expect(state.hexes[0].unit, isNotNull);
    expect(boat.supportedTiles, isEmpty);

    engine.endTurn();
    engine.endTurn();
    expect(state.hexes[0].unit, isNull);
    expect(state.hexes[0].object, TileObject.grave);
  });

  test('sailing away materializes a city on two connected land hexes', () {
    final state = _bridgeheadState();
    state.waterCells[0].neighbors.add(1);
    state.waterCells.add(
      WaterCell(index: 1, tiles: [3], neighbors: [0], coastTiles: const []),
    );
    final engine = GameEngine(mod: mod, state: state);
    final boat = state.waterCells[0].boat!;

    expect(engine.disembarkUnit(0, 0, 0), isTrue);
    expect(engine.disembarkUnit(0, 0, 1), isTrue);
    expect(engine.moveBoat(0, 1), isTrue);

    final landing = engine.provinceAt(0)!;
    expect(landing.tiles.toSet(), {0, 1});
    expect(landing.navalCapital, isFalse);
    expect(landing.navalFounded, isTrue);
    expect(state.hexes[landing.capital].object, TileObject.town);
    expect(boat.supportedTiles, isEmpty);
  });

  test('level-two boats build and destroy sea forts', () {
    final state = _controllerNavalState();
    final engine = GameEngine(mod: mod, state: state);
    state.waterCells[0].boat = GameBoat(owner: 0, level: 1, homeProvinceId: 1);

    expect(engine.seaFortBuildBlock(0), SeaFortBuildBlock.levelTwoRequired);
    expect(engine.seaFortBuildTargets(0), isEmpty);

    state.waterCells[0].boat = GameBoat(owner: 0, level: 2, homeProvinceId: 1);
    expect(engine.seaFortBuildTargets(0), {1});
    expect(engine.buildSeaFort(0, 1), isTrue);
    expect(state.waterCells[1].seaFort?.owner, 0);
    expect(engine.playerSeaFortCount(0), 1);
    expect(engine.seaFortBuildTargets(0), isEmpty);
    expect(
      engine.economicBreakdown(state.provinces.single).seaForts,
      -mod.rules.seaFortUpkeep,
    );

    state.waterCells[0].boat!.ready = true;
    state.waterCells.add(WaterCell(index: 3, tiles: const [], neighbors: [0]));
    state.waterCells[0].neighbors.add(3);
    expect(
      engine.seaFortBuildTargets(0),
      {3},
      reason: 'price and upkeep replace the hidden one-fort-per-boat cap',
    );

    state.turn = 1;
    state.waterCells[2].boat = GameBoat(owner: 1, level: 1, homeProvinceId: 2);
    expect(engine.boatMoveTargets(2), isNot(contains(1)));
    state.waterCells[2].boat = GameBoat(owner: 1, level: 2, homeProvinceId: 2);
    expect(engine.boatMoveTargets(2), contains(1));
    expect(engine.moveBoat(2, 1), isTrue);
    expect(state.waterCells[1].seaFort, isNull);
    expect(state.waterCells[1].boat?.owner, 1);
  });

  test('sea fort lock reports the exact failed condition', () {
    final state = _controllerNavalState();
    final engine = GameEngine(mod: mod, state: state);
    final province = state.provinces.single;
    state.waterCells[0].boat = GameBoat(
      owner: 0,
      level: 2,
      homeProvinceId: province.id,
    );

    province.money = mod.rules.seaFortPrice - 1;
    expect(engine.seaFortBuildBlock(0), SeaFortBuildBlock.insufficientFunds);

    province.money = mod.rules.seaFortPrice;
    state.waterCells[0].boat!.ready = false;
    expect(engine.seaFortBuildBlock(0), SeaFortBuildBlock.boatAlreadyActed);
  });

  test('loaded coastal artillery fires by level with no per-shot charge', () {
    final state = _artilleryState();
    final engine = GameEngine(mod: mod, state: state);

    engine.endTurn();

    expect(state.turn, 0);
    expect(state.waterCells[0].boat, isNull);
    expect(state.waterCells[1].boat, isNull);
    expect(state.waterCells[0].seaMint, isTrue);
    expect(state.waterCells[1].seaMint, isTrue);
    expect(engine.lastArtilleryStrikes.length, 3);
    expect(
      engine.lastArtilleryStrikes.map((strike) => strike.toWaterCell).toList(),
      [0, 0, 1],
      reason: 'the cannon must keep firing at one hull until it sinks',
    );
    expect(
      engine.lastArtilleryStrikes.map((strike) => strike.destroyed).toList(),
      [false, true, true],
    );
    expect(
      engine.lastArtilleryStrikes.every((strike) => strike.sourceOwner == 0),
      isTrue,
    );
    expect(state.hexes[1].artilleryCooldown, 1);
    expect(state.hexes[1].artilleryAmmo, 4);
    expect(state.provinces.first.money, 88);

    engine.endTurn();
    engine.endTurn();
    expect(state.hexes[1].artilleryCooldown, 0);
    expect(
      state.hexes[1].artilleryAmmo,
      4,
      reason: 'cooldown must not refill shells that were not spent',
    );
  });

  test('different artillery pieces share simultaneous firing volleys', () {
    ArtilleryStrike shot(int source, int target, {bool destroyed = false}) =>
        ArtilleryStrike(
          fromTile: source,
          toWaterCell: target,
          sourceOwner: 0,
          targetOwner: 1,
          targetLevel: 1,
          destroyed: destroyed,
        );

    final volleys = artilleryStrikeVolleys([
      shot(3, 10),
      shot(3, 11),
      shot(3, 12),
      shot(8, 20),
      shot(8, 21),
    ]);

    expect(volleys, hasLength(3));
    expect(volleys[0].map((strike) => strike.fromTile), [3, 8]);
    expect(volleys[1].map((strike) => strike.fromTile), [3, 8]);
    expect(volleys[2].map((strike) => strike.fromTile), [3]);
  });

  test('holding a sea area sends all ready boats toward it', () {
    final state = _controllerNavalState();
    state.waterCells[2].neighbors.add(3);
    state.waterCells.addAll([
      WaterCell(index: 3, tiles: [8], neighbors: [2, 4]),
      WaterCell(index: 4, tiles: [9], neighbors: [3]),
    ]);
    state.waterCells[0].boat = GameBoat(owner: 0, level: 1, homeProvinceId: 1);
    state.waterCells[4].boat = GameBoat(owner: 0, level: 1, homeProvinceId: 1);
    final engine = GameEngine(mod: mod, state: state);

    expect(engine.massSail(2), 2);
    expect(state.waterCells[2].boat?.owner, 0);
    expect(state.waterCells.where((cell) => cell.boat != null).length, 2);
    expect(
      state.waterCells
          .where((cell) => cell.boat != null)
          .every((cell) => cell.boat!.ready == false),
      isTrue,
    );
  });

  test('empty sea areas can be selected and held for a group sail', () {
    SharedPreferences.setMockInitialValues({});
    final state = _controllerNavalState();
    state.waterCells[0].boat = GameBoat(owner: 0, level: 1, homeProvinceId: 1);
    final controller = GameController(
      mod: mod,
      state: state,
      saves: SaveRepository(),
    );

    controller.tapWaterCell(1);
    expect(controller.selectedWaterCell, 1);
    controller.tapWaterCell(1);
    expect(controller.selectedWaterCell, isNull);

    controller.longPressWaterCell(1);
    expect(controller.selectedWaterCell, 1);
    expect(state.waterCells[1].boat?.owner, 0);
    expect(state.waterCells[0].boat, isNull);
    expect(controller.canUndo, isTrue);
    controller.dispose();
  });

  test(
    'occupied naval landing stays supplied until a capital tile is free',
    () {
      final state = _bridgeheadState();
      final engine = GameEngine(mod: mod, state: state);
      final boat = state.waterCells.single.boat!;

      expect(engine.disembarkUnit(0, 0, 0), isTrue);
      expect(engine.provinceAt(0)?.navalCapital, isTrue);
      expect(boat.supportedTile, 0);
      expect(state.hexes[0].unit, isNotNull);

      engine.endTurn();
      engine.endTurn();
      expect(state.hexes[0].unit, isNotNull);
      expect(state.hexes[0].unit!.ready, isTrue);
      expect(engine.disembarkUnit(0, 0, 1), isTrue);

      expect(engine.provinceAt(0)?.navalCapital, isTrue);
      expect(boat.supportedTiles.toSet(), {0, 1});
      expect(state.hexes.where((tile) => tile.unit != null).length, 2);

      engine.endTurn();
      engine.endTurn();
      expect(engine.boardUnit(1, 0), isTrue);
      final landing = engine.provinceAt(0);
      expect(landing, isNotNull);
      expect(landing!.tiles.toSet(), {0, 1});
      expect(boat.supportedTiles, isEmpty);
      expect(state.hexes[landing.capital].object, TileObject.town);
      expect(state.hexes[landing.capital].unit, isNull);
      expect(state.hexes[0].unit, isNotNull);
    },
  );

  test('an unsupported one-tile naval city becomes an orphan grave', () {
    final state = _bridgeheadState();
    final engine = GameEngine(mod: mod, state: state);

    expect(engine.disembarkUnit(0, 0, 0), isTrue);
    state.waterCells[0].boat = null;
    engine.endTurn();
    engine.endTurn();

    expect(state.hexes[0].unit, isNull);
    expect(state.hexes[0].object, TileObject.grave);
    expect(engine.provinceAt(0), isNull);
  });

  test('legacy one-tile houses are removed when a save is sanitized', () {
    final state = _bridgeheadState();
    state.waterCells[0].boat = null;
    state.hexes[0]
      ..owner = 0
      ..object = TileObject.town
      ..unit = null;
    state.provinces.add(
      Province(
        id: state.nextProvinceId++,
        owner: 0,
        tiles: const [0],
        money: 0,
        capital: 0,
        navalFounded: true,
      ),
    );
    final engine = GameEngine(mod: mod, state: state);

    engine.sanitizeOverlaps();

    expect(engine.provinceAt(0), isNull);
    expect(state.hexes[0].object, TileObject.palm);
  });

  testWidgets('boat cargo must be selected before landing targets appear', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final state = _controllerNavalState();
    state.waterCells[0].boat = GameBoat(
      owner: 0,
      level: 1,
      homeProvinceId: 1,
      cargo: [
        GameUnit(strength: 1, ready: true),
        GameUnit(strength: 2, ready: true),
      ],
    );
    final controller = GameController(
      mod: mod,
      state: state,
      saves: SaveRepository(),
    );

    controller.tapWaterCell(0);
    expect(controller.targetTiles, isEmpty);
    await tester.pumpWidget(
      MaterialApp(home: GameScreen(controller: controller)),
    );
    await tester.pump();
    expect(find.bySemanticsLabel('1-деңгейлі әскер'), findsOneWidget);
    expect(find.bySemanticsLabel('2-деңгейлі әскер'), findsOneWidget);

    controller.selectBoatCargo(1);
    await tester.pump();
    expect(controller.selectedCargoIndex, 1);
    expect(controller.targetTiles, isNotEmpty);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('tower defense preview appears only while held', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final state = _linearState([0, 0, 0, 1, 1]);
    state.hexes[1].object = TileObject.tower;
    final controller = GameController(
      mod: mod,
      state: state,
      saves: SaveRepository(),
    );

    controller.tapTile(1);
    expect(controller.defensePreviewTiles, isEmpty);

    controller.longPressTile(1);
    expect(controller.defensePreviewTiles, {0, 1, 2});
    await tester.pump(const Duration(milliseconds: 320));
    expect(controller.defensePreviewOpacity, 1);
    await tester.pump(const Duration(milliseconds: 800));
    expect(controller.defensePreviewTiles, isNotEmpty);

    controller.endLongPress();
    await tester.pump(const Duration(milliseconds: 800));
    expect(controller.defensePreviewTiles, isEmpty);
    controller.dispose();
  });

  testWidgets('artillery sea range appears only while held', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final state = _artilleryState()..turn = 0;
    final controller = GameController(
      mod: mod,
      state: state,
      saves: SaveRepository(),
    );
    final expectedTargets = controller.engine.artilleryTargetWaterCells(1);

    controller.longPressTile(1);
    expect(controller.artilleryRangePreview, isTrue);
    expect(controller.defensePreviewTiles, {0, 1});
    expect(controller.defensePreviewWaterCells, expectedTargets);
    expect(expectedTargets, isNotEmpty);
    await tester.pump(const Duration(milliseconds: 320));
    expect(controller.defensePreviewOpacity, 1);

    controller.endLongPress();
    await tester.pump(const Duration(milliseconds: 600));
    expect(controller.artilleryRangePreview, isFalse);
    expect(controller.defensePreviewWaterCells, isEmpty);
    controller.dispose();
  });

  testWidgets('human artillery turn waits for the full firing cinematic', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final state = _artilleryState();
    final controller = GameController(
      mod: mod,
      state: state,
      saves: SaveRepository(),
      autosaveEnabled: false,
    );

    final turnFuture = controller.finishTurn();
    await tester.pump();
    expect(controller.artilleryCinematicActive, isTrue);
    expect(controller.interactionsLocked, isTrue);
    expect(controller.artilleryFireAnimation, hasLength(3));
    expect(controller.artilleryAnimationSerial, 1);

    await tester.pump(const Duration(milliseconds: 2700));
    await _pumpUntilDone(tester, turnFuture);
    expect(controller.artilleryCinematicActive, isFalse);
    expect(controller.artilleryFireAnimation, isEmpty);
    expect(controller.interactionsLocked, isFalse);
    controller.dispose();
  });

  testWidgets('all province defenses and all sea forts preview together', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final state = _linearState([0, 0, 0, 0, 0, 1, 1]);
    state.hexes[1].object = TileObject.tower;
    state.hexes[3].object = TileObject.port1;
    final controller = GameController(
      mod: mod,
      state: state,
      saves: SaveRepository(),
    );
    controller.longPressTile(1);
    expect(controller.defensePreviewTiles, {0, 1, 2, 3, 4});
    controller.endLongPress();
    controller.dispose();

    final naval = _controllerNavalState();
    naval.waterCells[0].seaFort = SeaFort(owner: 0, homeProvinceId: 1);
    naval.waterCells[2].seaFort = SeaFort(owner: 0, homeProvinceId: 1);
    final navalController = GameController(
      mod: mod,
      state: naval,
      saves: SaveRepository(),
    );
    navalController.longPressWaterCell(0);
    expect(navalController.defensePreviewWaterCells, {0, 1, 2});
    navalController.endLongPress();
    navalController.dispose();
  });

  test('ports and artillery require at least a level-two attacker', () {
    final state = _linearState([0, 0, 1, 1]);
    state.hexes[1].object = TileObject.port1;
    state.hexes[2].object = TileObject.artillery3;
    final engine = GameEngine(mod: mod, state: state);

    expect(engine.defenseAt(1), 1);
    expect(engine.defenseAt(2), 1);
    state.hexes[0].object = TileObject.none;
    state.hexes[3].object = TileObject.none;
    expect(engine.defenseAt(1), 1);
    expect(engine.defenseAt(2), 1);

    state.hexes[1].unit = GameUnit(strength: 1, ready: true);
    expect(engine.moveTargets(1), isNot(contains(2)));
    state.hexes[1].unit = GameUnit(strength: 2, ready: true);
    expect(engine.moveTargets(1), contains(2));
  });

  test('holding a port publishes its shield preview', () {
    SharedPreferences.setMockInitialValues({});
    final state = _linearState([0, 0, 0, 1, 1]);
    state.hexes[1].object = TileObject.port2;
    final controller = GameController(
      mod: mod,
      state: state,
      saves: SaveRepository(),
    );

    controller.longPressTile(1);
    expect(controller.defensePreviewTiles, {0, 1, 2});
    expect(controller.defensePreviewWaterCells, isEmpty);
    expect(controller.artilleryRangePreview, isFalse);
    controller.dispose();
  });

  testWidgets('each human player restores their own camera zoom and position', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final controller = GameController(
      mod: mod,
      state: _splitEmpireCameraState(),
      saves: SaveRepository(),
      autosaveEnabled: false,
    );
    await tester.pumpWidget(
      MaterialApp(home: GameScreen(controller: controller)),
    );
    await tester.pump(const Duration(milliseconds: 600));
    final viewer = tester.widget<MapViewport>(find.byType(MapViewport));
    final camera = viewer.transformationController;
    final zoomed = camera.value.clone()
      ..setEntry(0, 0, 1.73)
      ..setEntry(1, 1, 1.73)
      ..setEntry(0, 3, -130);
    final cameraBounds = MapCameraBounds(
      viewport: tester.getSize(find.byType(MapViewport)),
      canvas: HexBoard.canvasSize(controller.state),
      minScale: viewer.minScale,
    );
    camera.value = cameraBounds.constrain(zoomed);
    final firstView = camera.value.clone();

    final firstTurn = controller.finishTurn();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 600));
    await _pumpUntilDone(tester, firstTurn);
    expect(controller.state.turn, 1);

    final secondPlayerZoom = camera.value.clone()
      ..setEntry(0, 0, .82)
      ..setEntry(1, 1, .82);
    camera.value = secondPlayerZoom;
    final secondTurn = controller.finishTurn();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 600));
    await _pumpUntilDone(tester, secondTurn);

    expect(controller.state.turn, 0);
    expect(camera.value.getMaxScaleOnAxis(), closeTo(1.73, .01));
    expect(camera.value.entry(0, 3), closeTo(firstView.entry(0, 3), .01));
    expect(camera.value.entry(1, 3), closeTo(firstView.entry(1, 3), .01));

    final thirdTurn = controller.finishTurn();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 600));
    await _pumpUntilDone(tester, thirdTurn);
    expect(controller.state.turn, 1);
    expect(camera.value.entry(0, 0), closeTo(.82, .01));
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets(
    'startup camera frames a home province instead of distant islands and ships',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final state = _splitEmpireCameraState();
      final expectedCenters = HexBoard.playerFocusCenters(state, 0);
      expect(expectedCenters, [
        HexBoard.centerOf(state.hexes[0]),
        HexBoard.centerOf(state.hexes[1]),
      ]);

      final controller = GameController(
        mod: mod,
        state: state,
        saves: SaveRepository(),
      );
      await tester.pumpWidget(
        MaterialApp(home: GameScreen(controller: controller)),
      );
      await tester.pump(const Duration(milliseconds: 600));
      final viewer = tester.widget<MapViewport>(find.byType(MapViewport));
      final transform = viewer.transformationController.value;
      final scale = transform.entry(0, 0);
      final viewport = tester.getSize(find.byType(MapViewport));
      for (final center in expectedCenters) {
        final visible =
            center * scale +
            Offset(transform.entry(0, 3), transform.entry(1, 3));
        expect((Offset.zero & viewport).contains(visible), isTrue);
      }
      final canvas = HexBoard.canvasSize(state);
      final scaledWidth = canvas.width * scale;
      if (scaledWidth <= viewport.width) {
        expect(
          transform.entry(0, 3),
          closeTo((viewport.width - scaledWidth) / 2, .1),
        );
      } else {
        expect(
          transform.entry(0, 3),
          inInclusiveRange(viewport.width - scaledWidth, 0),
        );
      }
      expect(scale, greaterThan(1));
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  test(
    'startup focus chooses largest province and supports fleet-only players',
    () {
      final state = _splitEmpireCameraState();
      final larger = state.provinces.lastWhere((p) => p.owner == 0);
      state.hexes[8]
        ..active = true
        ..owner = 0;
      state.provinces[state.provinces.indexOf(larger)] = Province(
        id: larger.id,
        owner: larger.owner,
        tiles: [...larger.tiles, 8],
        money: larger.money,
        capital: larger.capital,
      );
      expect(HexBoard.playerFocusCenters(state, 0), [
        for (final index in [...larger.tiles, 8])
          HexBoard.centerOf(state.hexes[index]),
      ]);
      state.provinces.removeWhere((p) => p.owner == 0);
      for (final tile in state.hexes) {
        if (tile.owner == 0) tile.owner = -1;
      }
      expect(HexBoard.playerFocusCenters(state, 0), [
        HexBoard.centerOfWater(state, state.waterCells.last),
      ]);
      state.waterCells.last.boat = null;
      expect(HexBoard.playerFocusCenters(state, 0), isEmpty);
    },
  );

  testWidgets('AI turns never pull the camera away from the human view', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final controller = GameController(
      mod: mod,
      state: _linearState([0, 0, 1, 1], humanCount: 1),
      saves: SaveRepository(),
      autosaveEnabled: false,
    );
    await tester.pumpWidget(
      MaterialApp(home: GameScreen(controller: controller)),
    );
    await tester.pump(const Duration(milliseconds: 600));
    final viewer = tester.widget<MapViewport>(find.byType(MapViewport));
    final camera = viewer.transformationController;
    final humanView = camera.value.clone()
      ..setEntry(0, 0, 1.61)
      ..setEntry(1, 1, 1.61)
      ..setEntry(0, 3, -123)
      ..setEntry(1, 3, -77);
    camera.value = humanView;

    final turnFuture = controller.finishTurn();
    await tester.pump();
    expect(controller.aiThinking, isTrue);
    expect(controller.aiPlayer, 1);
    await tester.pump(const Duration(milliseconds: 200));
    expect(camera.value.entry(0, 3), closeTo(-123, .01));
    expect(camera.value.entry(1, 3), closeTo(-77, .01));
    expect(camera.value.getMaxScaleOnAxis(), closeTo(1.61, .01));

    await tester.pump(const Duration(milliseconds: 700));
    await _pumpUntilDone(tester, turnFuture);
    expect(controller.state.turn, 0);
    expect(camera.value.getMaxScaleOnAxis(), closeTo(1.61, .01));
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  test('enemy defenses never publish a held preview', () {
    SharedPreferences.setMockInitialValues({});
    final state = _linearState([0, 0, 1, 1]);
    state.hexes[2].object = TileObject.tower;
    final controller = GameController(
      mod: mod,
      state: state,
      saves: SaveRepository(),
    );

    controller.longPressTile(2);
    expect(controller.defensePreviewTiles, isEmpty);
    controller.dispose();
  });

  test('controller publishes a battle animation for equal boats', () {
    SharedPreferences.setMockInitialValues({});
    final state = _controllerNavalState();
    state.waterCells[0].boat = GameBoat(owner: 0, level: 1, homeProvinceId: 1);
    state.waterCells[1].boat = GameBoat(owner: 1, level: 1, homeProvinceId: 2);
    final controller = GameController(
      mod: mod,
      state: state,
      saves: SaveRepository(),
    );

    controller.tapWaterCell(0);
    controller.tapWaterCell(1);
    expect(controller.boatBattleAnimation, isNotNull);
    expect(controller.boatBattleAnimation!.bothSunk, isTrue);
    expect(state.waterCells[0].boat, isNull);
    expect(state.waterCells[1].boat, isNull);
    controller.dispose();
  });

  test('controller publishes an animation when a sea fort is destroyed', () {
    SharedPreferences.setMockInitialValues({});
    final state = _controllerNavalState();
    state.waterCells[0].boat = GameBoat(owner: 0, level: 2, homeProvinceId: 1);
    state.waterCells[1].seaFort = SeaFort(owner: 1, homeProvinceId: 2);
    final controller = GameController(
      mod: mod,
      state: state,
      saves: SaveRepository(),
    );

    controller.tapWaterCell(0);
    controller.tapWaterCell(1);
    expect(controller.seaFortDestructionAnimation, isNotNull);
    expect(state.waterCells[1].seaFort, isNull);
    expect(state.waterCells[1].boat?.owner, 0);
    controller.dispose();
  });

  test('ready units bounce only during their owner turn', () {
    final state = _linearState([0, 0, 1, 1]);
    state.hexes[1].unit = GameUnit(strength: 1, ready: true);
    state.hexes[2].unit = GameUnit(strength: 1, ready: true);

    expect(HexUnitPainter.shouldBounceUnit(state, state.hexes[1]), isTrue);
    expect(HexUnitPainter.shouldBounceUnit(state, state.hexes[2]), isFalse);
    state.turn = 1;
    expect(HexUnitPainter.shouldBounceUnit(state, state.hexes[1]), isFalse);
    expect(HexUnitPainter.shouldBounceUnit(state, state.hexes[2]), isTrue);
    state.hexes[2].unit!.ready = false;
    expect(HexUnitPainter.shouldBounceUnit(state, state.hexes[2]), isFalse);
  });

  test('ready boats bounce only during their owner turn', () {
    final state = _navalState();
    final ownBoat = GameBoat(owner: 0, level: 1, homeProvinceId: 1);
    final enemyBoat = GameBoat(owner: 1, level: 1, homeProvinceId: 2);

    expect(HexUnitPainter.shouldBounceBoat(state, ownBoat), isTrue);
    expect(HexUnitPainter.shouldBounceBoat(state, enemyBoat), isFalse);
    ownBoat.ready = false;
    expect(HexUnitPainter.shouldBounceBoat(state, ownBoat), isFalse);
    state.turn = 1;
    expect(HexUnitPainter.shouldBounceBoat(state, enemyBoat), isTrue);
  });

  test('boats move two sea cells and can pass a friendly boat', () {
    final hexes = [
      for (var index = 0; index < 3; index++)
        HexTile(index: index, q: index, r: 0),
    ];
    final state = GameState(
      config: const GameConfig(playerCount: 2),
      modId: 'classic_steppe',
      width: 3,
      height: 1,
      hexes: hexes,
      waterCells: [
        WaterCell(
          index: 0,
          tiles: [0],
          neighbors: [1],
          boat: GameBoat(owner: 0, level: 1, homeProvinceId: 1),
        ),
        WaterCell(
          index: 1,
          tiles: [1],
          neighbors: [0, 2],
          boat: GameBoat(owner: 0, level: 1, homeProvinceId: 1),
        ),
        WaterCell(index: 2, tiles: [2], neighbors: [1]),
      ],
      provinces: [],
      turn: 0,
      round: 1,
      rngState: 1,
      nextProvinceId: 1,
    );
    final engine = GameEngine(mod: mod, state: state);

    expect(mod.rules.boatMoveLimit, 2);
    expect(engine.boatMoveTargets(0), {2});
    expect(engine.moveBoat(0, 2), isTrue);
    expect(state.waterCells[0].boat, isNull);
    expect(state.waterCells[1].boat, isNotNull);
    expect(state.waterCells[2].boat?.owner, 0);
  });

  test('sea mint blocks sailing through and pays seven when cleared', () {
    final state = _controllerNavalState();
    final engine = GameEngine(mod: mod, state: state);
    state.waterCells[0].boat = GameBoat(owner: 0, level: 1, homeProvinceId: 1);
    state.waterCells[1].seaMint = true;
    final province = state.provinces.single;
    final moneyBefore = province.money;

    expect(engine.boatMoveTargets(0), {1});
    expect(engine.moveBoat(0, 1), isTrue);
    expect(state.waterCells[0].boat, isNull);
    expect(state.waterCells[1].seaMint, isFalse);
    expect(state.waterCells[1].boat?.ready, isFalse);
    expect(province.money, moneyBefore + GameEngine.seaMintReward);
  });

  test('launching a boat on coastal mint clears it and spends the move', () {
    final state = _navalState();
    final engine = GameEngine(mod: mod, state: state);
    state.hexes[0].object = TileObject.port1;
    state.waterCells[0].seaMint = true;
    final province = state.provinces.single;
    final moneyBefore = province.money;

    expect(engine.boatBuildTargets(province.id, 0, 1), contains(0));
    expect(engine.buildBoat(province.id, 0, 0, 1), isTrue);
    expect(state.waterCells[0].seaMint, isFalse);
    expect(state.waterCells[0].boat?.ready, isFalse);
    expect(
      province.money,
      moneyBefore - mod.rules.boat1Price + GameEngine.seaMintReward,
    );
  });

  test('mature sea mint spreads to free neighboring water', () {
    final state = _navalState();
    final engine = GameEngine(mod: mod, state: state);
    state.waterCells[0].seaMint = true;
    state.rngState = 1;

    engine.endTurn();

    expect(state.waterCells[0].seaMint, isTrue);
    expect(state.waterCells[1].seaMint, isTrue);
  });

  test('sea mint survives saves and is absent in legacy water JSON', () {
    final state = _navalState();
    state.waterCells[1].seaMint = true;

    final restored = GameState.fromJson(state.toJson());
    expect(restored.waterCells[1].seaMint, isTrue);
    expect(
      WaterCell.fromJson({
        'index': 0,
        'tiles': <int>[0],
        'neighbors': <int>[],
        'coastTiles': <int>[],
      }).seaMint,
      isFalse,
    );
  });

  test('naval combat uses hull plus cargo and sinks equal fleets', () {
    final state = _navalState();
    final engine = GameEngine(mod: mod, state: state);
    state.waterCells[0].boat = GameBoat(
      owner: 0,
      level: 1,
      homeProvinceId: 1,
      cargo: [GameUnit(strength: 3)],
    );
    state.waterCells[1].boat = GameBoat(
      owner: 1,
      level: 1,
      homeProvinceId: 2,
      cargo: [
        GameUnit(strength: 1),
        GameUnit(strength: 1),
        GameUnit(strength: 1),
      ],
    );

    expect(engine.boatCombatPower(state.waterCells[0].boat!), 4);
    expect(engine.boatCombatPower(state.waterCells[1].boat!), 4);
    expect(engine.boatMoveTargets(0), contains(1));
    expect(engine.moveBoat(0, 1), isTrue);
    expect(state.waterCells[0].boat, isNull);
    expect(state.waterCells[1].boat, isNull);
    expect(state.waterCells[1].seaMint, isTrue);

    state.waterCells[0].boat = GameBoat(
      owner: 0,
      level: 2,
      homeProvinceId: 1,
      cargo: [GameUnit(strength: 3)],
    );
    state.waterCells[1]
      ..seaMint = false
      ..boat = GameBoat(
        owner: 1,
        level: 2,
        homeProvinceId: 2,
        cargo: [GameUnit(strength: 2)],
      );
    expect(engine.moveBoat(0, 1), isTrue);
    expect(state.waterCells[0].boat, isNull);
    expect(state.waterCells[1].boat?.owner, 0);
    expect(state.waterCells[1].boat?.ready, isFalse);
  });

  test('a split keeps money with the city and new fragments start at zero', () {
    final state = _linearState([0, 0, 0, 0, 0, 1, 1]);
    final engine = GameEngine(mod: mod, state: state);
    final original = engine.provincesOf(0).single..money = 77;
    final originalId = original.id;
    state.hexes[2].owner = 1;
    state.hexes[3]
      ..object = TileObject.none
      ..unit = GameUnit(strength: 1);
    state.hexes[4]
      ..object = TileObject.none
      ..unit = GameUnit(strength: 2);

    engine.rebuildProvinces();

    final citySide = engine.provinceAt(0)!;
    final fragment = engine.provinceAt(3)!;
    expect(citySide.id, originalId);
    expect(citySide.money, 77);
    expect(fragment.id, isNot(originalId));
    expect(fragment.money, 0);
    expect(fragment.capital, 3);
    expect(state.hexes[3].object, TileObject.town);
    expect(state.hexes[3].unit, isNull);
    expect(state.hexes[4].unit?.strength, 2);
  });

  test('a detached lone city immediately becomes the correct tree', () {
    final coastal = GameState(
      config: const GameConfig(playerCount: 1),
      modId: 'classic_steppe',
      width: 2,
      height: 1,
      hexes: [
        HexTile(
          index: 0,
          q: 0,
          r: 0,
          active: true,
          owner: 0,
          object: TileObject.town,
          neighbors: [1],
        ),
        HexTile(index: 1, q: 1, r: 0, neighbors: [0]),
      ],
      waterCells: [
        WaterCell(index: 0, tiles: [1], coastTiles: [0], navigable: true),
      ],
      provinces: [],
      turn: 0,
      round: 1,
      rngState: 1,
      nextProvinceId: 1,
    );
    GameEngine(mod: mod, state: coastal).rebuildProvinces();
    expect(coastal.hexes[0].object, TileObject.palm);

    final inland = _linearState([0, -1]);
    inland.hexes[0].object = TileObject.town;
    GameEngine(mod: mod, state: inland).rebuildProvinces();
    expect(inland.hexes[0].object, TileObject.pine);

    final port = _linearState([0, -1]);
    port.hexes[0].object = TileObject.port1;
    GameEngine(mod: mod, state: port).rebuildProvinces();
    expect(port.hexes[0].object, TileObject.pine);
  });

  test(
    'mature inland trees spread to multiple eligible cells in one round',
    () {
      final state = _linearState(List<int>.filled(30, 0));
      for (var index = 1; index < 29; index += 2) {
        state.hexes[index]
          ..object = TileObject.pine
          ..treeBorn = -1;
      }
      final before = state.hexes.where((tile) => tile.hasTree).length;
      GameEngine(mod: mod, state: state).endTurn();
      final after = state.hexes.where((tile) => tile.hasTree).length;
      expect(after, greaterThan(before));
    },
  );

  test('invalid unit and tree overlap is cleaned on load', () {
    final state = _linearState([0, 0, 1, 1]);
    state.hexes[1]
      ..object = TileObject.pine
      ..unit = GameUnit(strength: 2);
    GameEngine(mod: mod, state: state).sanitizeOverlaps();
    expect(state.hexes[1].object, TileObject.none);
    expect(state.hexes[1].unit?.strength, 2);
  });

  test('legacy rhombus saves migrate into a finite sea arena', () {
    const width = 17;
    const height = 13;
    final hexes = [
      for (var r = 0; r < height; r++)
        for (var q = 0; q < width; q++)
          HexTile(index: r * width + q, q: q, r: r),
    ];
    final first = 6 * width + 8;
    final second = first + 1;
    hexes[first]
      ..active = true
      ..owner = 0
      ..object = TileObject.town
      ..neighbors.add(second);
    hexes[second]
      ..active = true
      ..owner = 0
      ..neighbors.add(first);
    final state = GameState(
      config: const GameConfig(mapSize: MapSize.small, playerCount: 1),
      modId: 'classic_steppe',
      width: width,
      height: height,
      hexes: hexes,
      provinces: [
        Province(
          id: 1,
          owner: 0,
          tiles: [first, second],
          money: 44,
          capital: first,
        ),
      ],
      turn: 0,
      round: 1,
      rngState: 1,
      nextProvinceId: 2,
    );

    expect(MapGenerator.ensureSeaArena(state), isTrue);
    expect((state.width, state.height), (27, 27));
    expect(state.hexes.where((tile) => tile.active).length, 2);
    expect(state.provinces.single.money, 44);
    expect(state.waterCells, isNotEmpty);
    expect(state.hexes.every((tile) => tile.inWorld), isTrue);
  });

  test(
    'merging provinces keeps the larger province capital and sums money',
    () {
      final state = _linearState([0, 0, -1, 0, 0, 0, 1, 1]);
      final engine = GameEngine(mod: mod, state: state);
      final parts = engine.provincesOf(0).toList();
      final small = parts.firstWhere((province) => province.tiles.length == 2)
        ..money = 17;
      final large = parts.firstWhere((province) => province.tiles.length == 3)
        ..money = 29;
      final largeId = large.id;
      final largeCapital = large.capital;
      state.hexes[2].owner = 0;

      engine.rebuildProvinces();

      final merged = engine.provincesOf(0).single;
      expect(merged.id, largeId);
      expect(merged.capital, largeCapital);
      expect(merged.money, 46);
      expect(state.hexes[largeCapital].object, TileObject.town);
      expect(state.hexes[small.capital].object, TileObject.none);
    },
  );

  testWidgets('purchases and ready-unit merges settle without move targets', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final state = _linearState([0, 0, 0, 0, 1, 1]);
    final province = state.provinces.first..money = 100;
    final controller = GameController(
      mod: mod,
      state: state,
      saves: SaveRepository(),
    );
    controller.tapTile(province.capital);
    controller.setTool(PlayerTool.unit1);
    controller.tapTile(1);
    expect(controller.selectedTile, province.capital);
    expect(controller.targetTiles, isEmpty);

    state.hexes[1].unit = GameUnit(strength: 1, ready: true);
    state.hexes[2].unit = GameUnit(strength: 1, ready: true);
    controller.tapTile(1);
    expect(controller.targetTiles, contains(2));
    controller.tapTile(2);
    expect(state.hexes[2].unit?.strength, 2);
    expect(state.hexes[2].unit?.ready, isTrue);
    expect(controller.selectedTile, province.capital);
    expect(controller.targetTiles, isEmpty);
    controller.dispose();
  });

  testWidgets('foreign selection fades away instead of staying active', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final state = _linearState([0, 0, 1, 1]);
    final controller = GameController(
      mod: mod,
      state: state,
      saves: SaveRepository(),
    );
    controller.tapTile(2);
    expect(controller.selectedTile, 2);
    await tester.pump(const Duration(milliseconds: 450));
    expect(controller.selectedTile, isNull);
    expect(controller.selectionOpacity, 1);
    controller.dispose();
  });

  testWidgets('port actions replace rather than overlap ground actions', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final state = _navalState();
    state.hexes[1].object = TileObject.port1;
    final controller = GameController(
      mod: mod,
      state: state,
      saves: SaveRepository(),
    );
    controller.tapTile(1);
    await tester.pumpWidget(
      MaterialApp(home: GameScreen(controller: controller)),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.bySemanticsLabel('1-деңгейлі қайық, 4 орын, бағасы 40'),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel('1-деңгейлі қамал, бағасы 15'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  test('hex edge directions match the six axial neighbor normals', () {
    const expected = [
      0.5235987755982988,
      -0.5235987755982988,
      -1.5707963267948966,
      -2.6179938779914944,
      2.6179938779914944,
      1.5707963267948966,
    ];
    for (var edge = 0; edge < 6; edge++) {
      expect(HexBoardPainter.edgeNormal(edge), closeTo(expected[edge], 1e-12));
    }
  });

  test('fog masks ownership boundaries unless both cells are visible', () {
    expect(
      HexBoardPainter.fogSafeSameOwner(
        tileOwner: 1,
        neighborOwner: 2,
        tileVisible: false,
        neighborVisible: false,
      ),
      isTrue,
    );
    expect(
      HexBoardPainter.fogSafeSameOwner(
        tileOwner: 0,
        neighborOwner: 1,
        tileVisible: true,
        neighborVisible: false,
      ),
      isTrue,
    );
    expect(
      HexBoardPainter.fogSafeSameOwner(
        tileOwner: 0,
        neighborOwner: 1,
        tileVisible: true,
        neighborVisible: true,
      ),
      isFalse,
    );
  });

  test('different seeds produce varied coastline profiles', () {
    final profiles = <String>{};
    for (var seed = 1; seed <= 8; seed++) {
      final state = MapGenerator(
        mod,
      ).generate(GameConfig(mapSize: MapSize.small, seed: seed));
      final land = state.hexes.where((tile) => tile.active).toList();
      final minQ = land.map((tile) => tile.q).reduce((a, b) => a < b ? a : b);
      final maxQ = land.map((tile) => tile.q).reduce((a, b) => a > b ? a : b);
      final minR = land.map((tile) => tile.r).reduce((a, b) => a < b ? a : b);
      final maxR = land.map((tile) => tile.r).reduce((a, b) => a > b ? a : b);
      final coast = land
          .where(
            (tile) =>
                tile.neighbors.any((neighbor) => !state.hexes[neighbor].active),
          )
          .length;
      profiles.add('${maxQ - minQ}:${maxR - minR}:$coast');
    }
    expect(profiles.length, greaterThanOrEqualTo(3));
  });

  test('farm price grows and it can only be built by a town or farm', () {
    final state = _linearState([0, 0, 0, 0, 1, 1]);
    final engine = GameEngine(mod: mod, state: state);
    final province = engine.provincesOf(0).first..money = 100;

    expect(engine.farmPrice(province), 12);
    expect(engine.buildTargets(province.id, TileObject.farm), {1});
    expect(engine.build(province.id, 1, TileObject.farm), isTrue);
    expect(province.money, 88);
    expect(engine.farmPrice(province), 14);
    expect(engine.buildTargets(province.id, TileObject.farm), contains(2));
    expect(engine.build(province.id, 3, TileObject.farm), isFalse);
  });

  test('unit movement including a capture is limited to four steps', () {
    final state = _linearState([0, 0, 0, 0, 0, -1, 1, 1]);
    final engine = GameEngine(mod: mod, state: state);
    state.hexes[0]
      ..object = TileObject.none
      ..unit = GameUnit(strength: 1, ready: true);

    final targets = engine.moveTargets(0);
    expect(targets, contains(4));
    expect(targets, isNot(contains(5)));
  });

  test('hold-to-march converges every ready province unit on a target', () {
    final state = _linearState([0, 0, 0, 0, 0, 0, 1, 1]);
    final engine = GameEngine(mod: mod, state: state);
    final province = engine.provincesOf(0).single;
    state.hexes[1]
      ..object = TileObject.none
      ..unit = GameUnit(strength: 1, ready: true);
    state.hexes[2]
      ..object = TileObject.none
      ..unit = GameUnit(strength: 1, ready: true);

    expect(engine.massMarch(province.id, 4), 2);
    expect(state.hexes[1].unit, isNull);
    expect(state.hexes[2].unit, isNull);
    expect(state.hexes[3].unit?.ready, isFalse);
    expect(state.hexes[4].unit?.ready, isFalse);
  });

  test('controller hold-to-march is undoable and selects its target', () {
    SharedPreferences.setMockInitialValues({});
    final state = _linearState([0, 0, 0, 0, 0, 0, 1, 1]);
    state.hexes[1]
      ..object = TileObject.none
      ..unit = GameUnit(strength: 1, ready: true);
    state.hexes[2]
      ..object = TileObject.none
      ..unit = GameUnit(strength: 1, ready: true);
    final controller = GameController(
      mod: mod,
      state: state,
      saves: SaveRepository(),
    );

    controller.longPressTile(4);
    expect(controller.selectedTile, 4);
    expect(controller.canUndo, isTrue);
    expect(state.hexes[3].unit, isNotNull);
    expect(state.hexes[4].unit, isNotNull);

    controller.undo();
    expect(state.hexes[1].unit, isNotNull);
    expect(state.hexes[2].unit, isNotNull);
    expect(state.hexes[3].unit, isNull);
    expect(state.hexes[4].unit, isNull);
    controller.dispose();
  });

  test('a level-four unit captures equal defense in classic generic rules', () {
    final state = _linearState([0, 0, 1, 1]);
    final engine = GameEngine(mod: mod, state: state);
    state.hexes[1].unit = GameUnit(strength: 4, ready: true);
    state.hexes[2].unit = GameUnit(strength: 4, ready: true);

    expect(engine.moveTargets(1), contains(2));
    expect(engine.moveUnit(1, 2), isTrue);
    expect(state.hexes[2].owner, 0);
    expect(state.hexes[2].unit?.strength, 4);

    final lower = _linearState([0, 0, 1, 1]);
    lower.hexes[1].unit = GameUnit(strength: 3, ready: true);
    lower.hexes[2].unit = GameUnit(strength: 3, ready: true);
    expect(
      GameEngine(mod: mod, state: lower).moveTargets(1),
      isNot(contains(2)),
    );
  });

  test('orphan pieces follow the classic province lifecycle', () {
    final state = _linearState([0, 0, -1, 0, -1, 0, -1, 0, 1, 1], turn: 1);
    final engine = GameEngine(mod: mod, state: state);
    state.hexes[3].unit = GameUnit(strength: 1, ready: true);
    state.hexes[5].object = TileObject.farm;
    state.hexes[7].object = TileObject.tower;

    engine.rebuildProvinces();
    expect(engine.provinceAt(3), isNull);
    expect(engine.playerIncome(0), 2);
    expect(state.hexes[5].object, TileObject.none);
    expect(state.hexes[7].object, TileObject.tower);

    engine.endTurn();
    expect(state.turn, 0);
    expect(state.hexes[3].unit, isNull);
    expect(state.hexes[3].object, TileObject.grave);

    engine.endTurn();
    engine.endTurn();
    expect(state.turn, 0);
    expect(state.hexes[3].object, anyOf(TileObject.pine, TileObject.palm));
  });

  testWidgets('construction prices and income ranking are available in game', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    SharedPreferences.setMockInitialValues({});
    final state = MapGenerator(mod).generate(const GameConfig(seed: 47));
    final controller = GameController(
      mod: mod,
      state: state,
      saves: SaveRepository(),
    );
    controller.tapTile(controller.engine.provincesOf(state.turn).first.capital);

    await tester.pumpWidget(
      MaterialApp(home: GameScreen(controller: controller)),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      find.bySemanticsLabel('2-деңгейлі қамал, бағасы 35'),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel('1-деңгейлі қамал, бағасы 15'),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel('Ферма, бағасы 12'), findsOneWidget);
    expect(find.bySemanticsLabel('1-деңгейлі порт, бағасы 45'), findsOneWidget);
    expect(find.bySemanticsLabel('2-деңгейлі порт, бағасы 75'), findsNothing);
    expect(
      find.bySemanticsLabel('Жағалау артиллериясы, бағасы 50'),
      findsOneWidget,
    );
    for (var strength = 1; strength <= 4; strength++) {
      expect(
        find.bySemanticsLabel(
          '$strength-деңгейлі әскер, бағасы ${strength * 10}',
        ),
        findsOneWidget,
      );
    }

    await tester.tap(find.bySemanticsLabel('Доход рейтингі'));
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('Доход'), findsOneWidget);
    expect(find.text('${controller.engine.playerIncome(0)}'), findsWidgets);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    semantics.dispose();
  });

  testWidgets('income report exposes every recurring expense category', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.binding.setSurfaceSize(const Size(390, 844));
    SharedPreferences.setMockInitialValues({});
    final state = _controllerNavalState();
    final province = state.provinces.single;
    state.hexes[1].object = TileObject.artillery2;
    state.waterCells[0].boat = GameBoat(
      owner: 0,
      level: 1,
      homeProvinceId: province.id,
      cargo: [GameUnit(strength: 1)],
    );
    state.waterCells[1].seaFort = SeaFort(
      owner: 0,
      homeProvinceId: province.id,
    );
    final controller = GameController(
      mod: mod,
      state: state,
      saves: SaveRepository(),
    );
    controller.tapTile(province.capital);
    expect(controller.selectedOwnProvince, same(province));
    final report = controller.engine.economicBreakdown(province);

    expect(report.artillery, -mod.rules.artilleryUpkeep[2]);
    expect(report.cargoUnits, -3);
    expect(report.boats, -mod.rules.boat1Upkeep);
    expect(report.seaForts, -mod.rules.seaFortUpkeep);

    await tester.pumpWidget(
      MaterialApp(home: GameScreen(controller: controller)),
    );
    await tester.pump(const Duration(milliseconds: 350));
    await tester.tapAt(const Offset(195, 29));
    await tester.pump(const Duration(milliseconds: 250));

    for (final label in const [
      'Құрлық әскері',
      'Кемедегі әскер',
      'Құрлық қамалы',
      'Артиллерия',
      'Порттар',
      'Кемелер',
      'Теңіз қамалдары',
      'Десантты қолдау',
    ]) {
      expect(find.text(label), findsOneWidget);
    }

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    await tester.binding.setSurfaceSize(null);
    semantics.dispose();
  });

  testWidgets('ports and artillery open their own management panels', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    SharedPreferences.setMockInitialValues({});
    final state = _controllerNavalState();
    state.hexes[1].object = TileObject.port1;
    final controller = GameController(
      mod: mod,
      state: state,
      saves: SaveRepository(),
    );
    controller.tapTile(1);

    await tester.pumpWidget(
      MaterialApp(home: GameScreen(controller: controller)),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.bySemanticsLabel('Портты дамыту, бағасы 75'), findsOneWidget);
    expect(
      find.bySemanticsLabel('1-деңгейлі қайық, 4 орын, бағасы 40'),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel('2-деңгейлі қайық, 10 орын, бағасы 110'),
      findsOneWidget,
    );

    await tester.tap(find.bySemanticsLabel('Портты дамыту, бағасы 75'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(state.hexes[1].object, TileObject.port2);
    expect(state.provinces.single.money, 125);

    state.hexes[1]
      ..object = TileObject.artillery1
      ..artilleryAmmo = 0;
    controller.tapTile(1);
    controller.tapTile(1);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.bySemanticsLabel('Автоматты оқтау, тұрақты шығын 4'),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel('Артиллерияны дамыту, бағасы 65'),
      findsOneWidget,
    );

    await tester.tap(find.bySemanticsLabel('Артиллерияны дамыту, бағасы 65'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(state.hexes[1].object, TileObject.artillery2);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    semantics.dispose();
  });

  testWidgets('selected land and sea tools show a large priced preview', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final state = _controllerNavalState();
    state.hexes[1].object = TileObject.port1;
    state.waterCells[0].boat = GameBoat(
      owner: 0,
      level: 1,
      homeProvinceId: state.provinces.single.id,
    );
    final controller = GameController(
      mod: mod,
      state: state,
      saves: SaveRepository(),
    );
    controller.tapTile(0);
    await tester.pumpWidget(
      MaterialApp(home: GameScreen(controller: controller)),
    );

    controller.setTool(PlayerTool.unit1);
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text(r'$10'), findsOneWidget);

    controller.clearSelection();
    controller.tapTile(1);
    controller.setTool(PlayerTool.boat1);
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text(r'$40'), findsOneWidget);

    controller.setTool(PlayerTool.select);
    controller.tapWaterCell(0);
    controller.setTool(PlayerTool.seaFort);
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text(r'$80'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('locked sea fort button explains why it cannot be built', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final state = _controllerNavalState();
    state.provinces.single.money = mod.rules.seaFortPrice - 1;
    state.waterCells[0].boat = GameBoat(
      owner: 0,
      level: 2,
      homeProvinceId: state.provinces.single.id,
    );
    final controller = GameController(
      mod: mod,
      state: state,
      saves: SaveRepository(),
    );
    controller.tapWaterCell(0);
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(home: GameScreen(controller: controller)),
    );

    await tester.tap(find.bySemanticsLabel('Теңіз бекінісі, бағасы 80'));
    await tester.pump();

    expect(controller.hint, 'Теңіз бекінісіне 80 теңге керек');
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    semantics.dispose();
  });

  test('save model round-trips without losing the board', () {
    final state = MapGenerator(mod).generate(const GameConfig(seed: 99));
    final boatCell = state.waterCells.firstWhere((cell) => cell.navigable);
    boatCell.boat = GameBoat(
      owner: 0,
      level: 2,
      homeProvinceId: state.provinces.first.id,
      supportedTiles: [state.provinces.first.tiles.first],
      damage: 1,
    );
    final fortCell = state.waterCells.firstWhere(
      (cell) => cell.navigable && cell.index != boatCell.index,
    );
    fortCell.seaFort = SeaFort(
      owner: 0,
      homeProvinceId: state.provinces.first.id,
    );
    state.hexes[state.provinces.first.tiles.last]
      ..object = TileObject.artillery2
      ..artilleryCooldown = 1
      ..artilleryAmmo = 2;
    final restored = GameState.fromJson(state.toJson());

    expect(restored.hexes.length, state.hexes.length);
    expect(restored.provinces.length, state.provinces.length);
    expect(restored.rngState, state.rngState);
    expect(restored.hexes[10].neighbors, state.hexes[10].neighbors);
    expect(
      restored.waterCells[boatCell.index].boat!.supportedTiles,
      isNotEmpty,
    );
    expect(restored.waterCells[boatCell.index].boat!.damage, 1);
    expect(restored.waterCells[fortCell.index].seaFort?.owner, 0);
    expect(
      restored.hexes[state.provinces.first.tiles.last].artilleryCooldown,
      1,
    );
    expect(restored.hexes[state.provinces.first.tiles.last].artilleryAmmo, 2);
  });

  test('AI simulation advances without corrupting province ownership', () {
    final state = MapGenerator(mod).generate(
      const GameConfig(
        mapSize: MapSize.small,
        playerCount: 3,
        humanCount: 0,
        seed: 12345,
        difficulty: AiDifficulty.easy,
      ),
    );
    final engine = GameEngine(mod: mod, state: state);
    for (var turn = 0; turn < 80 && state.winner == null; turn++) {
      GameAi(mod: mod, engine: engine).takeTurn();
      for (final province in state.provinces) {
        expect(province.tiles.length, greaterThanOrEqualTo(2));
        expect(
          province.tiles.every(
            (index) => state.hexes[index].owner == province.owner,
          ),
          isTrue,
        );
      }
    }
    expect(state.round, greaterThan(1));
  });

  test('AI colors use six profiles and never rush a first-round tower', () {
    final state = MapGenerator(mod).generate(
      const GameConfig(
        mapSize: MapSize.small,
        playerCount: 6,
        humanCount: 0,
        seed: 41,
        difficulty: AiDifficulty.normal,
      ),
    );
    final engine = GameEngine(mod: mod, state: state);
    final profiles = <int>{};
    for (var player = 0; player < 6; player++) {
      state.turn = player;
      profiles.add(GameAi(mod: mod, engine: engine).personalityId);
    }
    expect(profiles, hasLength(6));

    state.turn = 0;
    for (var turn = 0; turn < 6 && state.winner == null; turn++) {
      GameAi(mod: mod, engine: engine).takeTurn();
    }
    expect(state.round, 2);
    expect(
      state.hexes.where(
        (tile) =>
            tile.object == TileObject.tower ||
            tile.object == TileObject.strongTower,
      ),
      isEmpty,
    );
  });

  test('guardian AI reserves money and fortifies a real threatened border', () {
    final raw = _linearState([1, 1, 1, 0, 0], turn: 1, humanCount: 0).toJson()
      ..['config'] = const GameConfig(
        playerCount: 2,
        humanCount: 0,
        seed: 1,
        difficulty: AiDifficulty.master,
        slayRules: true,
      ).toJson()
      ..['round'] = 5;
    final state = GameState.fromJson(raw);
    state.hexes[3].object = TileObject.strongTower;
    state.provinces.firstWhere((province) => province.owner == 1).money = 200;
    final engine = GameEngine(mod: mod, state: state);
    expect(GameAi(mod: mod, engine: engine).personalityId, 2);

    GameAi(mod: mod, engine: engine).takeTurn();

    expect(
      state.hexes.where((tile) => tile.owner == 1).map((tile) => tile.object),
      contains(TileObject.tower),
    );
  });

  test('explicit province count creates one to three starting economies', () {
    for (var count = 1; count <= 3; count++) {
      final state = MapGenerator(mod).generate(
        GameConfig(
          mapSize: MapSize.medium,
          playerCount: 3,
          startingProvinceCount: count,
          seed: 812 + count,
        ),
      );
      for (var player = 0; player < 3; player++) {
        final provinces = state.provinces.where(
          (province) => province.owner == player,
        );
        expect(provinces, hasLength(count));
        expect(
          provinces.every(
            (province) =>
                state.hexes[province.capital].object == TileObject.town,
          ),
          isTrue,
        );
      }
    }
  });

  test('default province setup varies each player between one and three', () {
    final state = MapGenerator(mod).generate(
      const GameConfig(
        mapSize: MapSize.medium,
        playerCount: 6,
        startingProvinceCount: 0,
        seed: 812,
      ),
    );
    final counts = [
      for (var player = 0; player < 6; player++)
        state.provinces.where((province) => province.owner == player).length,
    ];

    expect(counts, everyElement(inInclusiveRange(1, 3)));
    expect(counts.toSet().length, greaterThan(1));
  });

  test('master AI personalities use economy and naval tools', () {
    final state = MapGenerator(mod).generate(
      const GameConfig(
        mapSize: MapSize.medium,
        playerCount: 6,
        humanCount: 0,
        seed: 33,
        difficulty: AiDifficulty.master,
      ),
    );
    for (final province in state.provinces) {
      province.money = 700;
    }
    final engine = GameEngine(mod: mod, state: state);
    var sawFarm = false;
    for (var turn = 0; turn < 54 && state.winner == null; turn++) {
      GameAi(mod: mod, engine: engine).takeTurn();
      sawFarm |= state.hexes.any((tile) => tile.object == TileObject.farm);
    }

    expect(sawFarm, isTrue);
    final coastalJson = _navalState().toJson()
      ..['config'] = const GameConfig(
        playerCount: 1,
        humanCount: 0,
        seed: 1,
        difficulty: AiDifficulty.master,
      ).toJson();
    final coastal = GameState.fromJson(coastalJson);
    coastal.provinces.single.money = 700;
    // The official land phase spends before mod-only naval adapters. Seed the
    // naval fixture with its port so a farm cannot consume its only coast hex.
    coastal.hexes[1].object = TileObject.port1;
    GameAi(
      mod: mod,
      engine: GameEngine(mod: mod, state: coastal),
    ).takeTurn();
    expect(
      coastal.hexes.any((tile) => tile.object == TileObject.port2) ||
          coastal.waterCells.any(
            (cell) => cell.boat != null || cell.seaFort != null,
          ),
      isTrue,
    );
  });

  test('rule options and diplomacy survive save serialization', () {
    final state = MapGenerator(mod).generate(
      const GameConfig(
        mapSize: MapSize.small,
        playerCount: 3,
        humanCount: 0,
        seed: 77,
        slayRules: false,
        fogOfWar: true,
        diplomacy: true,
        campaignLevel: 12,
      ),
    );
    final engine = GameEngine(mod: mod, state: state);
    engine.setDiplomacyStatus(0, 1, DiplomacyStatus.alliance);
    expect(
      engine.sendDiplomacyMessage(from: 0, to: 1, text: 'Шекара тыныш.'),
      isTrue,
    );

    final restored = GameState.fromJson(state.toJson());
    expect(state.toJson()['schema'], 12);
    expect(restored.config.humanCount, 0);
    expect(restored.config.slayRules, isFalse);
    expect(restored.config.fogOfWar, isTrue);
    expect(restored.config.diplomacy, isTrue);
    expect(restored.config.campaignLevel, 12);
    expect(restored.diplomacyRelations[1][0], DiplomacyStatus.alliance);
    expect(restored.diplomacyMessages.single.text, 'Шекара тыныш.');
  });

  test('peace and alliance block attacks while war enables them', () {
    final raw = _linearState([0, 0, 1, 1]).toJson()
      ..['config'] = const GameConfig(
        playerCount: 2,
        humanCount: 2,
        diplomacy: true,
      ).toJson();
    final state = GameState.fromJson(raw);
    state.hexes[1].unit = GameUnit(strength: 4);
    final engine = GameEngine(mod: mod, state: state);
    expect(engine.moveTargets(1), contains(2));

    engine.setDiplomacyStatus(0, 1, DiplomacyStatus.peace);
    expect(engine.moveTargets(1), isNot(contains(2)));
    engine.setDiplomacyStatus(0, 1, DiplomacyStatus.alliance);
    expect(engine.moveTargets(1), isNot(contains(2)));
    engine.setDiplomacyStatus(0, 1, DiplomacyStatus.war);
    expect(engine.moveTargets(1), contains(2));
  });

  test('Slay requires strict strength while generic level four may tie', () {
    final base = _linearState([0, 0, 1, 1]).toJson();
    base['config'] = const GameConfig(
      playerCount: 2,
      humanCount: 2,
      slayRules: false,
    ).toJson();
    var state = GameState.fromJson(base);
    state.hexes[1].unit = GameUnit(strength: 4);
    state.hexes[2].unit = GameUnit(strength: 4);
    expect(GameEngine(mod: mod, state: state).moveTargets(1), contains(2));

    base['config'] = const GameConfig(
      playerCount: 2,
      humanCount: 2,
      slayRules: true,
    ).toJson();
    state = GameState.fromJson(base);
    state.hexes[1].unit = GameUnit(strength: 4);
    state.hexes[2].unit = GameUnit(strength: 4);
    expect(
      GameEngine(mod: mod, state: state).moveTargets(1),
      isNot(contains(2)),
    );
  });

  test('Slay generator fills the island with balanced small kingdoms', () {
    for (final seed in const [7, 824, 1901]) {
      final state = MapGenerator(mod).generate(
        GameConfig(
          mapSize: MapSize.small,
          playerCount: 15,
          humanCount: 1,
          seed: seed,
          slayRules: true,
        ),
      );
      final active = state.hexes.where((tile) => tile.active).toList();
      expect(active, isNotEmpty);
      expect(active.every((tile) => tile.owner >= 0), isTrue);
      expect(
        state.provinces.every(
          (province) =>
              province.tiles.length >= 2 &&
              province.tiles.length <= 5 &&
              province.money == mod.rules.initialMoney &&
              state.hexes[province.capital].object == TileObject.town,
        ),
        isTrue,
      );
      for (var owner = 0; owner < state.config.playerCount; owner++) {
        expect(
          state.provinces.where((province) => province.owner == owner),
          isNotEmpty,
          reason: 'Slay colour $owner must start with a real province',
        );
      }

      final seen = <int>{};
      for (final tile in active) {
        if (!seen.add(tile.index)) continue;
        final component = <int>[];
        final queue = <int>[tile.index];
        for (var cursor = 0; cursor < queue.length; cursor++) {
          final index = queue[cursor];
          component.add(index);
          for (final neighbor in state.hexes[index].neighbors) {
            if (state.hexes[neighbor].active &&
                state.hexes[neighbor].owner == tile.owner &&
                seen.add(neighbor)) {
              queue.add(neighbor);
            }
          }
        }
        expect(component.length, lessThanOrEqualTo(5));
        final matching = state.provinces.where(
          (province) => province.tiles.toSet().containsAll(component),
        );
        expect(
          matching.length,
          component.length >= 2 ? 1 : 0,
          reason: 'Only connected Slay land of two or more hexes is a city',
        );
      }
    }
  });

  test('fog exposes own border but hides distant enemy pieces', () {
    final raw = _linearState([0, 0, -1, -1, 1, 1]).toJson()
      ..['config'] = const GameConfig(
        playerCount: 2,
        humanCount: 1,
        fogOfWar: true,
      ).toJson();
    final controller = GameController(
      mod: mod,
      state: GameState.fromJson(raw),
      saves: SaveRepository(),
      autosaveEnabled: false,
    );
    addTearDown(controller.dispose);

    expect(controller.visibleTileIndices, containsAll(<int>[0, 1, 2]));
    expect(controller.visibleTileIndices, contains(4));
    expect(controller.visibleTileIndices, isNot(contains(5)));
  });

  test('fog reveals identities only after their land enters vision', () {
    final raw = _linearState([0, 0, -1, -1, 1, 1, 2, 2]).toJson()
      ..['config'] = const GameConfig(
        playerCount: 3,
        humanCount: 1,
        fogOfWar: true,
      ).toJson();
    final controller = GameController(
      mod: mod,
      state: GameState.fromJson(raw),
      saves: SaveRepository(),
      autosaveEnabled: false,
    );
    addTearDown(controller.dispose);

    expect(controller.visiblePlayerIndices, containsAll(<int>[0, 1]));
    expect(controller.visiblePlayerIndices, isNot(contains(2)));
  });

  test('fog blocks hidden land from diplomacy map selection', () {
    final raw = _linearState([0, 0, -1, -1, 1, 1]).toJson()
      ..['config'] = const GameConfig(
        playerCount: 2,
        humanCount: 1,
        fogOfWar: true,
        diplomacy: true,
      ).toJson();
    final controller = GameController(
      mod: mod,
      state: GameState.fromJson(raw),
      saves: SaveRepository(),
      autosaveEnabled: false,
    );
    addTearDown(controller.dispose);

    expect(controller.canSelectDiplomacyLandTile(giver: 1, index: 4), isTrue);
    expect(
      controller.canSelectDiplomacyLandTile(giver: 1, index: 5),
      isFalse,
      reason: 'the hidden half of the same enemy province must not leak',
    );
  });

  testWidgets('fog greys out unseen factions in the income ranking', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final raw = _linearState([0, 0, -1, -1, 1, 1, 2, 2]).toJson()
      ..['config'] = const GameConfig(
        playerCount: 3,
        humanCount: 1,
        fogOfWar: true,
      ).toJson();
    final controller = GameController(
      mod: mod,
      state: GameState.fromJson(raw),
      saves: SaveRepository(),
      autosaveEnabled: false,
    );
    controller.tapTile(controller.engine.provincesOf(0).first.capital);

    await tester.pumpWidget(
      MaterialApp(home: GameScreen(controller: controller)),
    );
    await tester.tap(find.bySemanticsLabel('Доход рейтингі'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      find.bySemanticsLabel(
        RegExp(
          '${RegExp.escape(controller.state.playerPossessiveName(1))} доходы: .*түсі көрінеді',
        ),
      ),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel(
        RegExp(
          '${RegExp.escape(controller.state.playerPossessiveName(2))} доходы: .*түсі жасырын',
        ),
      ),
      findsOneWidget,
    );
    semantics.dispose();
  });

  test('province money alerts never reveal hidden or enemy capitals', () {
    final state = _linearState([0, 0, -1, 1, 1]);
    final own = state.provinces.firstWhere((province) => province.owner == 0)
      ..money = 20;
    final enemy = state.provinces.firstWhere((province) => province.owner == 1)
      ..money = 20;

    expect(
      HexUnitPainter.shouldDrawProvinceAlert(
        province: own,
        alertOwner: 0,
        selectedProvinceId: null,
        visibleTiles: {own.capital},
      ),
      isTrue,
    );
    expect(
      HexUnitPainter.shouldDrawProvinceAlert(
        province: own,
        alertOwner: 0,
        selectedProvinceId: null,
        visibleTiles: const <int>{},
      ),
      isFalse,
    );
    expect(
      HexUnitPainter.shouldDrawProvinceAlert(
        province: enemy,
        alertOwner: 0,
        selectedProvinceId: null,
        visibleTiles: {enemy.capital},
      ),
      isFalse,
    );
  });

  test('capital diplomacy markers are relation-colored and fog safe', () {
    final raw = _linearState([0, 0, -1, 1, 1]).toJson()
      ..['config'] = const GameConfig(
        playerCount: 2,
        humanCount: 1,
        fogOfWar: true,
        diplomacy: true,
      ).toJson();
    final state = GameState.fromJson(raw);
    final enemy = state.provinces.firstWhere((province) => province.owner == 1);

    expect(
      HexUnitPainter.shouldDrawDiplomaticIndicator(
        state: state,
        province: enemy,
        viewer: 0,
        visibleTiles: {enemy.capital},
      ),
      isTrue,
    );
    expect(
      HexUnitPainter.shouldDrawDiplomaticIndicator(
        state: state,
        province: enemy,
        viewer: 0,
        visibleTiles: const <int>{},
      ),
      isFalse,
    );
    expect(
      HexUnitPainter.relationIndicatorColor(DiplomacyStatus.peace).toARGB32(),
      const Color(0xffe2dfcb).toARGB32(),
    );
    expect(
      HexUnitPainter.relationIndicatorColor(
        DiplomacyStatus.alliance,
      ).toARGB32(),
      const Color(0xff86b793).toARGB32(),
    );
    expect(
      HexUnitPainter.relationIndicatorColor(DiplomacyStatus.war).toARGB32(),
      const Color(0xffce8f7f).toARGB32(),
    );
  });

  test('fog boat reveals its coast and can disembark cargo there', () {
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
    addTearDown(controller.dispose);

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

    expect(controller.visibleTileIndices, contains(landing));
    controller.tapWaterCell(cell.index);
    controller.selectBoatCargo(0);
    expect(controller.targetTiles, contains(landing));

    controller.tapTile(landing);
    expect(controller.state.hexes[landing].unit, isNotNull);
    expect(controller.state.waterCells[cell.index].boat!.cargo, isEmpty);
  });

  test(
    'fog conceals AI identity and freezes the rendered turn state',
    () async {
      final raw = _linearState([0, 0, 1, 1], humanCount: 1).toJson()
        ..['config'] = const GameConfig(
          playerCount: 2,
          humanCount: 1,
          fogOfWar: true,
          difficulty: AiDifficulty.master,
        ).toJson();
      final controller = GameController(
        mod: mod,
        state: GameState.fromJson(raw),
        saves: _CountingSaveRepository(),
        autosaveEnabled: false,
      );
      addTearDown(controller.dispose);
      var observedConcealedTurn = false;
      GameState? frozenView;
      controller.addListener(() {
        if (!controller.aiThinking || !controller.concealedAiTurns) return;
        observedConcealedTurn = true;
        frozenView ??= controller.viewState;
        expect(controller.aiPlayer, isNull);
        expect(identical(controller.viewState, controller.state), isFalse);
      });

      await controller.finishTurn();

      expect(observedConcealedTurn, isTrue);
      expect(frozenView, isNotNull);
      expect(controller.concealedAiTurns, isFalse);
      expect(controller.state.turn, 0);
    },
  );

  test('Slay economy and capital capture follow the strict ruleset', () {
    final raw = _linearState([0, 0, 0, 1, 1, 1]).toJson()
      ..['config'] = const GameConfig(
        playerCount: 2,
        humanCount: 2,
        slayRules: true,
      ).toJson();
    final state = GameState.fromJson(raw);
    state.provinces.first.money = 100;
    state.provinces.last.money = 70;
    state.hexes[2].unit = GameUnit(strength: 2);
    final engine = GameEngine(mod: mod, state: state);

    expect(engine.buildTargets(1, TileObject.farm), isEmpty);
    expect(engine.buildTargets(1, TileObject.strongTower), isEmpty);
    expect(engine.moveUnit(2, 3), isTrue);
    expect(engine.provincesOf(1).single.money, 0);

    state.hexes[3].unit = null;
    state.hexes[1].unit = GameUnit(strength: 4);
    expect(
      engine.economicBreakdown(engine.provincesOf(0).single).landUnits,
      -54,
    );
  });

  test('Slay naval extensions unlock only after a kingdom grows', () {
    GameState slayLine(int blueTiles) {
      final owners = <int>[...List<int>.filled(blueTiles, 0), 1, 1];
      final raw = _linearState(owners).toJson()
        ..['config'] = const GameConfig(
          playerCount: 2,
          humanCount: 2,
          slayRules: true,
        ).toJson();
      return GameState.fromJson(raw);
    }

    var state = slayLine(5);
    var engine = GameEngine(mod: mod, state: state);
    var province = engine.provincesOf(0).single;
    expect(engine.canAddPort(province), isTrue);
    expect(engine.canAddArtillery(province), isFalse);
    state.hexes[province.tiles.first].object = TileObject.port1;
    expect(engine.canAddPort(province), isFalse);

    state = slayLine(7);
    engine = GameEngine(mod: mod, state: state);
    province = engine.provincesOf(0).single;
    expect(engine.canAddArtillery(province), isTrue);
    state.hexes[province.tiles.first].object = TileObject.artillery1;
    expect(engine.canAddArtillery(province), isFalse);
    province.money = 1000;
    expect(engine.canUpgradeArtilleryAt(province.tiles.first), isFalse);

    state = slayLine(10);
    engine = GameEngine(mod: mod, state: state);
    province = engine.provincesOf(0).single..money = 1000;
    final portTile = province.tiles.first;
    state.hexes[portTile].object = TileObject.port1;
    expect(engine.canUpgradePortAt(portTile), isTrue);
    final artilleryTile = province.tiles.last;
    state.hexes[artilleryTile].object = TileObject.artillery1;
    expect(engine.canUpgradeArtilleryAt(artilleryTile), isTrue);

    state = slayLine(14);
    engine = GameEngine(mod: mod, state: state);
    province = engine.provincesOf(0).single..money = 1000;
    final highArtillery = province.tiles.first;
    state.hexes[highArtillery].object = TileObject.artillery2;
    expect(engine.canUpgradeArtilleryAt(highArtillery), isTrue);
  });

  test('diplomacy starts neutral and persists proposals and cooldowns', () {
    final raw = _linearState([0, 0, 1, 1]).toJson()
      ..['config'] = const GameConfig(
        playerCount: 2,
        humanCount: 1,
        diplomacy: true,
      ).toJson()
      ..remove('diplomacyRelations');
    final state = GameState.fromJson(raw);
    final engine = GameEngine(mod: mod, state: state);

    expect(engine.diplomacyBetween(0, 1), DiplomacyStatus.peace);
    expect(engine.worsenDiplomacy(0, 1), isTrue);
    expect(engine.diplomacyBetween(0, 1), DiplomacyStatus.war);
    expect(engine.diplomacyCooldown(0, 1), 10);
    expect(engine.improveDiplomacy(0, 1), isFalse);

    engine.setDiplomacyStatus(0, 1, DiplomacyStatus.peace);
    expect(
      engine.proposeDiplomacy(1, 0, DiplomacyProposalType.friendship),
      isTrue,
    );
    final restored = GameState.fromJson(state.toJson());
    final restoredEngine = GameEngine(mod: mod, state: restored);
    final proposal = restoredEngine.proposalsFor(0).single;
    expect(
      restoredEngine.resolveDiplomacyProposal(proposal, accept: true),
      isTrue,
    );
    expect(restoredEngine.diplomacyBetween(0, 1), DiplomacyStatus.alliance);
    expect(restoredEngine.allianceTurnsLeft(0, 1), 12);
  });

  test('diplomacy peace restricts AI units but not human unit levels', () {
    final raw = _linearState([0, 0, 0, 0, 1, 1]).toJson()
      ..['config'] = const GameConfig(
        playerCount: 2,
        humanCount: 1,
        diplomacy: true,
      ).toJson()
      ..remove('diplomacyRelations');
    final state = GameState.fromJson(raw);
    final engine = GameEngine(mod: mod, state: state);
    final humanProvince = engine.provincesOf(0).single..money = 200;

    for (final strength in [2, 3, 4]) {
      final target = engine
          .unitBuildTargets(humanProvince.id, strength)
          .firstWhere((index) => state.hexes[index].owner == 0);
      expect(engine.buyUnit(humanProvince.id, target, strength), isTrue);
    }

    state.turn = 1;
    final aiProvince = engine.provincesOf(1).single..money = 200;
    expect(engine.unitBuildTargets(aiProvince.id, 1), isNotEmpty);
    expect(engine.unitBuildTargets(aiProvince.id, 2), isEmpty);
    expect(engine.unitBuildTargets(aiProvince.id, 3), isEmpty);
    expect(engine.unitBuildTargets(aiProvince.id, 4), isEmpty);
  });

  test('foreign tile diplomacy shortcut yields only an idle visible rival', () {
    final raw = _linearState([0, 0, 1, 1]).toJson()
      ..['config'] = const GameConfig(
        playerCount: 2,
        humanCount: 1,
        diplomacy: true,
      ).toJson()
      ..remove('diplomacyRelations');
    final controller = GameController(
      mod: mod,
      state: GameState.fromJson(raw),
      saves: _CountingSaveRepository(),
      autosaveEnabled: false,
    );

    expect(controller.diplomacyPlayerForTile(2), 1);
    expect(controller.diplomacyPlayerForTile(0), isNull);
    expect(controller.diplomacyPlayerForTile(-1), isNull);

    controller.tapTile(0);
    expect(controller.selectedTile, 0);
    expect(controller.diplomacyPlayerForTile(2), isNull);
    controller.clearSelection();
    controller.tool = PlayerTool.farm;
    expect(controller.diplomacyPlayerForTile(2), isNull);
    controller.dispose();
  });

  testWidgets('diplomacy opens with the requested foreign player selected', (
    tester,
  ) async {
    final raw = _linearState([0, 0, 1, 1]).toJson()
      ..['config'] = const GameConfig(
        playerCount: 2,
        humanCount: 1,
        diplomacy: true,
      ).toJson()
      ..remove('diplomacyRelations');
    final controller = GameController(
      mod: mod,
      state: GameState.fromJson(raw),
      saves: _CountingSaveRepository(),
      autosaveEnabled: false,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () =>
                showAntiyoyDiplomacy(context, controller, initialPlayer: 1),
            child: const Text('Ашу'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Ашу'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byTooltip('Айырбас'), findsOneWidget);
    expect(find.byTooltip('Достық ұсыну'), findsOneWidget);
    expect(find.byKey(const ValueKey('diplomacy-shell')), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    controller.dispose();
  });

  testWidgets('diplomacy is visible in game and its actions are real', (
    tester,
  ) async {
    final raw = _linearState([0, 0, 1, 1]).toJson()
      ..['config'] = const GameConfig(
        playerCount: 2,
        humanCount: 1,
        diplomacy: true,
      ).toJson()
      ..remove('diplomacyRelations');
    final controller = GameController(
      mod: mod,
      state: GameState.fromJson(raw),
      saves: _CountingSaveRepository(),
      autosaveEnabled: false,
    );
    await tester.pumpWidget(
      MaterialApp(home: GameScreen(controller: controller)),
    );
    await tester.pump();

    expect(find.byIcon(Icons.flag_outlined), findsOneWidget);
    expect(find.byIcon(Icons.mail_outline), findsNothing);
    await tester.tap(find.byIcon(Icons.flag_outlined));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text(controller.playerName(1)).first);
    await tester.pump();
    expect(find.text('Бейтарап'), findsOneWidget);
    expect(find.text('Қатынас: 0'), findsOneWidget);
    expect(find.byTooltip('Достық ұсыну'), findsOneWidget);
    expect(find.byTooltip('Соғыс жариялау'), findsOneWidget);
    expect(find.byTooltip('Қара белгі қою'), findsOneWidget);
    expect(find.byTooltip('Қатынастары'), findsOneWidget);
    expect(find.byTooltip('Хат жіберу'), findsOneWidget);
    expect(find.byTooltip('Айырбас'), findsOneWidget);

    await tester.tap(find.byTooltip('Достық ұсыну'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 900));
    expect(find.text('Достық'), findsOneWidget);
    expect(find.textContaining('Субсидия'), findsOneWidget);
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.byTooltip('Артқа'), findsOneWidget);
    await tester.tap(find.byTooltip('Артқа'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(
      find.byKey(const ValueKey('diplomacy-countries-page')),
      findsOneWidget,
    );

    await tester.tap(find.byTooltip('Хат жіберу'));
    await tester.pump();
    expect(find.text('Хат мәтіні'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Сәлем!');
    await tester.tap(find.text('Жіберу'));
    await tester.pump();
    expect(controller.state.diplomacyMessages.single.text, 'Сәлем!');

    await tester.tap(find.byTooltip('Қатынастары'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.textContaining('Қатынастар'), findsWidgets);
    expect(find.text('Қазына'), findsNothing);
    expect(find.text('Жалпы кіріс'), findsNothing);
    await tester.tap(find.byTooltip('Артқа'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    await tester.tap(find.text(controller.playerName(1)).first);
    await tester.pump();
    expect(find.byTooltip('Соғыс жариялау'), findsNothing);
    await tester.tap(find.text(controller.playerName(1)).first);
    await tester.pump();
    await tester.tap(find.byTooltip('Соғыс жариялау'));
    await tester.pump();
    expect(controller.engine.diplomacyBetween(0, 1), DiplomacyStatus.peace);
    expect(find.textContaining('шынымен соғыс'), findsOneWidget);
    await tester.tap(find.text('Иә'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(controller.engine.diplomacyBetween(0, 1), DiplomacyStatus.war);
    expect(controller.engine.diplomacyCooldown(0, 1), 10);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets(
    'classic exchange stays in one shell with choices, land and state picker',
    (tester) async {
      Future<void> settleOverlay() async {
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 450));
      }

      final raw = _linearState([0, 0, 1, 1]).toJson()
        ..['config'] = const GameConfig(
          playerCount: 2,
          humanCount: 1,
          diplomacy: true,
        ).toJson()
        ..remove('diplomacyRelations');
      final controller = GameController(
        mod: mod,
        state: GameState.fromJson(raw),
        saves: _CountingSaveRepository(),
        autosaveEnabled: false,
      );
      await tester.pumpWidget(
        MaterialApp(home: GameScreen(controller: controller)),
      );
      await tester.pump();
      await tester.tap(find.byIcon(Icons.flag_outlined));
      await settleOverlay();
      await tester.tap(find.text(controller.playerName(1)).first);
      await tester.pump();
      await tester.tap(find.byTooltip('Айырбас'));
      await settleOverlay();

      final shellSize = tester.getSize(
        find.byKey(const ValueKey('diplomacy-shell')),
      );
      expect(
        tester
            .getSize(find.byKey(const ValueKey('diplomacy-exchange-page')))
            .height,
        shellSize.height,
      );
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.byTooltip('Артқа'), findsOneWidget);

      final firstOfferType = find.byKey(const ValueKey('offer-type-1-0'));
      await tester.ensureVisible(firstOfferType);
      await tester.tap(firstOfferType);
      await settleOverlay();
      var previousRowY = -1.0;
      var visibleIndex = 0;
      for (final type in DiplomacyExchangeType.values) {
        final option = find.byKey(ValueKey('offer-type-option-${type.name}'));
        if (!controller.engine.canChooseExchangeType(1, 0, type, [])) {
          expect(option, findsNothing);
          continue;
        }
        expect(option, findsOneWidget);
        final y = tester.getTopLeft(option).dy;
        if (visibleIndex.isEven) {
          expect(y, greaterThan(previousRowY));
          previousRowY = y;
        } else {
          expect(y, closeTo(previousRowY, .1));
        }
        visibleIndex++;
      }

      final warOption = find.byKey(
        const ValueKey('offer-type-option-warDeclaration'),
      );
      await tester.ensureVisible(warOption);
      await tester.tap(warOption);
      await settleOverlay();
      await tester.tap(find.byKey(const ValueKey('war-target-1-0')));
      await settleOverlay();
      expect(find.byKey(const ValueKey('war-target-option-0')), findsOneWidget);
      expect(find.byKey(const ValueKey('war-target-option-1')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('war-target-option-0')));
      await settleOverlay();

      await tester.ensureVisible(firstOfferType);
      await tester.tap(firstOfferType);
      await settleOverlay();
      final moneyOption = find.byKey(const ValueKey('offer-type-option-money'));
      await tester.ensureVisible(moneyOption);
      await tester.tap(moneyOption);
      await settleOverlay();
      final moneySlider = find.byKey(const ValueKey('money-slider-1-0'));
      await tester.ensureVisible(moneySlider);
      await tester.drag(moneySlider, const Offset(600, 0));
      await tester.pump();
      expect(find.text('10000'), findsOneWidget);

      await tester.ensureVisible(firstOfferType);
      await tester.tap(firstOfferType);
      await settleOverlay();
      final subsidiesOption = find.byKey(
        const ValueKey('offer-type-option-subsidies'),
      );
      final exchangeScrollable = find
          .descendant(
            of: find.byKey(const ValueKey('diplomacy-exchange-page')),
            matching: find.byType(Scrollable),
          )
          .first;
      // The final Classic option can sit exactly beneath the fixed submit bar;
      // move the exchange list itself so the tap hits the row, not the bar.
      await tester.drag(exchangeScrollable, const Offset(0, -180));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.ensureVisible(subsidiesOption);
      await tester.tap(subsidiesOption);
      await settleOverlay();
      final subsidySlider = find.byKey(const ValueKey('subsidy-slider-1-0'));
      final subsidyDuration = find.byKey(
        const ValueKey('subsidy-duration-1-0'),
      );
      await tester.drag(exchangeScrollable, const Offset(0, -140));
      await tester.pump(const Duration(seconds: 1));
      await tester.ensureVisible(subsidySlider);
      final actualSubsidySlider = find.descendant(
        of: subsidySlider,
        matching: find.byType(Slider),
      );
      final amountControl = tester.widget<Slider>(actualSubsidySlider);
      amountControl.onChanged!(amountControl.max);
      await tester.pump();
      await tester.ensureVisible(subsidyDuration);
      final durationControl = tester.widget<Slider>(subsidyDuration);
      durationControl.onChanged!(durationControl.max);
      await tester.pump();
      expect(find.text('250'), findsOneWidget);
      expect(find.text('20 ход'), findsOneWidget);

      await tester.ensureVisible(firstOfferType);
      await tester.tap(firstOfferType);
      await settleOverlay();
      final landOption = find.byKey(const ValueKey('offer-type-option-lands'));
      await tester.ensureVisible(landOption);
      await tester.tap(landOption);
      await settleOverlay();
      await tester.tap(find.byKey(const ValueKey('land-map-picker-1')));
      await settleOverlay();
      expect(
        find.byKey(const ValueKey('diplomacy-land-selection-page')),
        findsOneWidget,
      );
      expect(find.textContaining(RegExp(r'#\d+')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('land-selection-cancel')));
      await settleOverlay();

      await tester.tap(find.byTooltip('Артқа'));
      await settleOverlay();
      expect(
        find.byKey(const ValueKey('diplomacy-countries-page')),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('diplomacy inbox is separate and pause has no diplomacy entry', (
    tester,
  ) async {
    final raw = _linearState([0, 0, 1, 1, 2, 2]).toJson()
      ..['config'] = const GameConfig(
        playerCount: 3,
        humanCount: 1,
        diplomacy: true,
      ).toJson()
      ..remove('diplomacyRelations');
    final state = GameState.fromJson(raw);
    final engine = GameEngine(mod: mod, state: state);
    expect(
      engine.sendDiplomacyMessage(from: 1, to: 0, text: 'Шекара тыныш.'),
      isTrue,
    );
    expect(
      engine.proposeExchange(
        from: 2,
        to: 0,
        fromOffer: const DiplomacyOffer(
          type: DiplomacyExchangeType.money,
          amount: 5,
        ),
        toOffer: const DiplomacyOffer(),
      ),
      isTrue,
    );
    final controller = GameController(
      mod: mod,
      state: state,
      saves: _CountingSaveRepository(),
      autosaveEnabled: false,
    );
    await tester.pumpWidget(
      MaterialApp(home: GameScreen(controller: controller)),
    );
    await tester.pump();

    expect(find.byIcon(Icons.flag_outlined), findsOneWidget);
    expect(find.byIcon(Icons.mail_outline), findsOneWidget);
    await tester.tap(find.byIcon(Icons.mail_outline));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('Хаттар'), findsOneWidget);
    expect(find.text('↓ Ақша'), findsOneWidget);
    expect(find.text('Шекара тыныш.'), findsOneWidget);

    await tester.tap(find.text('↓ Ақша'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('Қабылдау'), findsOneWidget);
    expect(find.text('Бас тарту'), findsOneWidget);
    await tester.tap(find.text('Бас тарту'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(engine.proposalsFor(0), isEmpty);
    expect(find.text('Шекара тыныш.'), findsOneWidget);

    Navigator.of(tester.element(find.byType(GameScreen))).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.tap(find.bySemanticsLabel('Мәзір'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('Жалғастыру'), findsOneWidget);
    expect(find.text('Дипломатия'), findsNothing);
  });

  test('black marks block new friendships and have a removal cooldown', () {
    final raw = _linearState([0, 0, 1, 1, 2, 2]).toJson()
      ..['config'] = const GameConfig(
        playerCount: 3,
        humanCount: 1,
        diplomacy: true,
      ).toJson();
    final state = GameState.fromJson(raw);
    final engine = GameEngine(mod: mod, state: state);

    engine.setDiplomacyStatus(0, 2, DiplomacyStatus.alliance);
    engine.setDiplomacyStatus(1, 2, DiplomacyStatus.alliance);

    expect(engine.placeBlackMark(0, 1), isTrue);
    expect(engine.diplomacyBetween(0, 2), DiplomacyStatus.alliance);
    expect(engine.diplomacyBetween(1, 2), DiplomacyStatus.peace);
    expect(engine.canBecomeFriends(0, 1), isFalse);
    expect(
      engine.proposeDiplomacy(0, 1, DiplomacyProposalType.friendship),
      isFalse,
    );
    expect(engine.removeBlackMark(0, 1), isTrue);
    expect(engine.blackMarkCooldown(0, 1), 10);
    expect(engine.placeBlackMark(0, 1), isFalse);

    final restored = GameState.fromJson(state.toJson());
    expect(restored.diplomacyBlackMarks[0][1], isFalse);
    expect(restored.diplomacyBlackMarkCooldowns[1][0], 10);
  });

  test(
    'first black-mark camp keeps shared friends and blocks cross-camp ties',
    () {
      final raw = _linearState([0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5]).toJson()
        ..['config'] = const GameConfig(
          playerCount: 6,
          humanCount: 6,
          diplomacy: true,
        ).toJson();
      final state = GameState.fromJson(raw);
      final engine = GameEngine(mod: mod, state: state);

      // Player 1 marks player 3. Players 2 and 4 are mutual friends, while
      // player 5 belongs only to player 3's camp.
      engine.setDiplomacyStatus(0, 1, DiplomacyStatus.alliance);
      engine.setDiplomacyStatus(0, 3, DiplomacyStatus.alliance);
      engine.setDiplomacyStatus(2, 1, DiplomacyStatus.alliance);
      engine.setDiplomacyStatus(2, 3, DiplomacyStatus.alliance);
      engine.setDiplomacyStatus(2, 4, DiplomacyStatus.alliance);

      expect(engine.placeBlackMark(0, 2), isTrue);
      expect(engine.diplomacyBetween(0, 1), DiplomacyStatus.alliance);
      expect(engine.diplomacyBetween(0, 3), DiplomacyStatus.alliance);
      expect(engine.diplomacyBetween(2, 1), DiplomacyStatus.peace);
      expect(engine.diplomacyBetween(2, 3), DiplomacyStatus.peace);
      expect(engine.diplomacyBetween(2, 4), DiplomacyStatus.alliance);
      expect(engine.canBecomeFriends(0, 4), isFalse);
      expect(engine.canBecomeFriends(1, 2), isFalse);
    },
  );

  test('exchange applies money and a twelve-turn friendship together', () {
    final raw = _linearState([0, 0, 1, 1]).toJson()
      ..['config'] = const GameConfig(
        playerCount: 2,
        humanCount: 2,
        diplomacy: true,
      ).toJson()
      ..remove('diplomacyRelations');
    final state = GameState.fromJson(raw);
    state.provinces.where((province) => province.owner == 0).single.money = 60;
    state.provinces.where((province) => province.owner == 1).single.money = 10;
    final engine = GameEngine(mod: mod, state: state);

    expect(
      engine.proposeExchange(
        from: 0,
        to: 1,
        fromOffer: const DiplomacyOffer(
          type: DiplomacyExchangeType.money,
          amount: 30,
        ),
        toOffer: const DiplomacyOffer(
          type: DiplomacyExchangeType.friendship,
          duration: 12,
        ),
      ),
      isTrue,
    );
    final proposal = engine.proposalsFor(1).single;
    expect(engine.resolveDiplomacyProposal(proposal, accept: true), isTrue);
    expect(engine.playerMoney(0), 30);
    expect(engine.playerMoney(1), 40);
    expect(engine.diplomacyBetween(0, 1), DiplomacyStatus.alliance);
    expect(engine.allianceTurnsLeft(0, 1), 12);
  });

  test('war preserves debt and an accepted ceasefire locks new war', () {
    final raw = _linearState([0, 0, 1, 1]).toJson()
      ..['config'] = const GameConfig(
        playerCount: 2,
        humanCount: 2,
        diplomacy: true,
      ).toJson()
      ..remove('diplomacyRelations');
    final state = GameState.fromJson(raw);
    final engine = GameEngine(mod: mod, state: state);
    state.diplomacyDebts[0][1] = 12;
    state.diplomacyDebts[1][0] = 5;
    state.diplomacySubsidies.add(
      const DiplomacySubsidy(payer: 0, receiver: 1, amount: 3, turnsLeft: 5),
    );
    expect(
      engine.proposeDiplomacy(0, 1, DiplomacyProposalType.friendship),
      isTrue,
    );

    expect(engine.worsenDiplomacy(0, 1), isTrue);
    expect(state.diplomacyDebts[0][1], 12);
    expect(state.diplomacyDebts[1][0], 5);
    expect(state.diplomacySubsidies, isEmpty);
    expect(state.diplomacyProposals, isEmpty);

    state.diplomacyWarCooldowns[0][1] = 0;
    state.diplomacyWarCooldowns[1][0] = 0;
    expect(
      engine.proposeExchange(
        from: 0,
        to: 1,
        fromOffer: const DiplomacyOffer(type: DiplomacyExchangeType.ceasefire),
        toOffer: const DiplomacyOffer(),
      ),
      isTrue,
    );
    expect(
      engine.resolveDiplomacyProposal(
        engine.proposalsFor(1).single,
        accept: true,
      ),
      isTrue,
    );
    expect(engine.diplomacyBetween(0, 1), DiplomacyStatus.peace);
    expect(engine.diplomacyCooldown(0, 1), 9);
    expect(engine.worsenDiplomacy(0, 1), isFalse);
  });

  test(
    'enemies may negotiate other deals but cannot become friends directly',
    () {
      final raw = _linearState([0, 0, 1, 1]).toJson()
        ..['config'] = const GameConfig(
          playerCount: 2,
          humanCount: 2,
          diplomacy: true,
        ).toJson();
      final state = GameState.fromJson(raw);
      final engine = GameEngine(mod: mod, state: state);
      engine.setDiplomacyStatus(0, 1, DiplomacyStatus.war);

      expect(
        engine.proposeExchange(
          from: 0,
          to: 1,
          fromOffer: const DiplomacyOffer(
            type: DiplomacyExchangeType.money,
            amount: 7,
          ),
          toOffer: const DiplomacyOffer(),
        ),
        isTrue,
      );
      state.diplomacyProposals.clear();
      expect(
        engine.proposeExchange(
          from: 0,
          to: 1,
          fromOffer: const DiplomacyOffer(
            type: DiplomacyExchangeType.friendship,
            duration: 12,
          ),
          toOffer: const DiplomacyOffer(),
        ),
        isFalse,
      );
    },
  );

  test('war-declaration deal may target the receiver but never its giver', () {
    final raw = _linearState([0, 0, 1, 1]).toJson()
      ..['config'] = const GameConfig(
        playerCount: 2,
        humanCount: 2,
        diplomacy: true,
      ).toJson()
      ..remove('diplomacyRelations');
    final state = GameState.fromJson(raw);
    final engine = GameEngine(mod: mod, state: state);

    expect(
      engine.proposeExchange(
        from: 0,
        to: 1,
        fromOffer: const DiplomacyOffer(
          type: DiplomacyExchangeType.warDeclaration,
          targetPlayer: 1,
        ),
        toOffer: const DiplomacyOffer(),
      ),
      isTrue,
    );
    state.diplomacyProposals.clear();
    expect(
      engine.proposeExchange(
        from: 0,
        to: 1,
        fromOffer: const DiplomacyOffer(
          type: DiplomacyExchangeType.warDeclaration,
          targetPlayer: 0,
        ),
        toOffer: const DiplomacyOffer(),
      ),
      isFalse,
    );
  });

  test('early friendship break pays the former friend for remaining turns', () {
    GameEngine createEngine(int turns) {
      final raw = _linearState([0, 0, 1, 1]).toJson()
        ..['config'] = const GameConfig(
          playerCount: 2,
          humanCount: 2,
          diplomacy: true,
        ).toJson();
      final state = GameState.fromJson(raw);
      final engine = GameEngine(mod: mod, state: state);
      engine.setDiplomacyStatus(0, 1, DiplomacyStatus.alliance);
      state.diplomacyAllianceTurns[0][1] = turns;
      state.diplomacyAllianceTurns[1][0] = turns;
      return engine;
    }

    final fresh = createEngine(12);
    final short = createEngine(2);
    expect(
      fresh.friendshipBreakCompensationTotal(0, 1),
      greaterThan(short.friendshipBreakCompensationTotal(0, 1)),
    );
    final fine = fresh.friendshipBreakFinePerTurn(0);
    expect(fresh.worsenDiplomacy(0, 1), isTrue);
    final compensation = fresh.state.diplomacySubsidies.single;
    expect(compensation.mandatory, isTrue);
    expect(compensation.payer, 0);
    expect(compensation.receiver, 1);
    expect(compensation.amount, fine);
    expect(compensation.turnsLeft, 12);
    final restored = GameState.fromJson(fresh.state.toJson());
    expect(restored.diplomacySubsidies.single.mandatory, isTrue);
    final effectiveFine = fine < fresh.playerIncome(0)
        ? fine
        : fresh.playerIncome(0);
    expect(
      fresh.playerEconomicBreakdown(0).diplomacy,
      lessThanOrEqualTo(-effectiveFine),
    );
    expect(
      fresh.playerEconomicBreakdown(1).diplomacy,
      greaterThanOrEqualTo(effectiveFine),
    );

    // Ending the friendship is one step; a later declaration of war is a
    // second step and cannot erase the compensation contract.
    expect(fresh.worsenDiplomacy(0, 1), isTrue);
    expect(fresh.diplomacyBetween(0, 1), DiplomacyStatus.war);
    expect(fresh.state.diplomacySubsidies.single.mandatory, isTrue);
  });

  test('friendship compensation transfers exactly once per round', () {
    final raw = _linearState([0, 0, 1, 1]).toJson()
      ..['config'] = const GameConfig(
        playerCount: 2,
        humanCount: 2,
        diplomacy: true,
      ).toJson();
    final state = GameState.fromJson(raw);
    final engine = GameEngine(mod: mod, state: state);
    engine.setDiplomacyStatus(0, 1, DiplomacyStatus.alliance);
    state.diplomacyAllianceTurns[0][1] = 2;
    state.diplomacyAllianceTurns[1][0] = 2;

    final payerBefore = engine.playerMoney(0);
    final receiverBefore = engine.playerMoney(1);
    final payerEconomy = engine
        .provincesOf(0)
        .fold<int>(
          0,
          (total, province) =>
              total +
              engine.economicBreakdown(province, includeDiplomacy: false).total,
        );
    final receiverEconomy = engine
        .provincesOf(1)
        .fold<int>(
          0,
          (total, province) =>
              total +
              engine.economicBreakdown(province, includeDiplomacy: false).total,
        );
    final payment = math.min(
      engine.friendshipBreakFinePerTurn(0),
      engine.playerIncome(0),
    );

    expect(engine.worsenDiplomacy(0, 1), isTrue);
    engine.endTurn();
    engine.endTurn();

    expect(engine.playerMoney(0), payerBefore + payerEconomy - payment);
    expect(engine.playerMoney(1), receiverBefore + receiverEconomy + payment);
    expect(state.diplomacySubsidies.single.turnsLeft, 1);
  });

  test('defender allies punish the aggressor, not the defender', () {
    final raw = _linearState([0, 0, 1, 1, 2, 2]).toJson()
      ..['config'] = const GameConfig(
        playerCount: 3,
        humanCount: 3,
        diplomacy: true,
      ).toJson()
      ..remove('diplomacyRelations');
    final state = GameState.fromJson(raw);
    final engine = GameEngine(mod: mod, state: state);
    engine.setDiplomacyStatus(0, 2, DiplomacyStatus.alliance);
    engine.setDiplomacyStatus(1, 2, DiplomacyStatus.alliance);

    expect(engine.worsenDiplomacy(0, 1), isTrue);
    expect(engine.diplomacyBetween(0, 2), DiplomacyStatus.peace);
    final compensation = state.diplomacySubsidies.singleWhere(
      (item) => item.payer == 0 && item.receiver == 2,
    );
    expect(compensation.mandatory, isTrue);
    expect(compensation.turnsLeft, 1);
    expect(state.diplomacyTraitorTurns[1], 0);
    expect(state.diplomacyTraitorTurns[2], 0);
  });

  test('allied players do not trigger a diplomatic victory', () {
    final raw = _linearState([0, 0, 1, 1, 1, 1, 2, 2]).toJson()
      ..['config'] = const GameConfig(
        playerCount: 3,
        humanCount: 3,
        diplomacy: true,
      ).toJson()
      ..remove('diplomacyRelations');
    final state = GameState.fromJson(raw);
    final engine = GameEngine(mod: mod, state: state);

    expect(engine.improveDiplomacy(0, 1), isTrue);
    expect(engine.improveDiplomacy(0, 2), isTrue);
    expect(engine.improveDiplomacy(1, 2), isTrue);
    expect(state.winner, isNull);
  });

  test('diplomacy appraises ports and artillery at their real build cost', () {
    final raw = _linearState([0, 0, 0, 0, 1, 1]).toJson()
      ..['config'] = const GameConfig(
        playerCount: 2,
        humanCount: 2,
        diplomacy: true,
      ).toJson()
      ..remove('diplomacyRelations');
    final state = GameState.fromJson(raw);
    final engine = GameEngine(mod: mod, state: state);
    state.hexes[1].object = TileObject.port2;
    state.hexes[2].object = TileObject.artillery3;

    expect(
      engine.diplomacyLandPrice(1),
      mod.rules.port1Price + mod.rules.port2Price,
    );
    expect(
      engine.diplomacyLandPrice(2),
      mod.rules.artilleryCosts[1] +
          mod.rules.artilleryCosts[2] +
          mod.rules.artilleryCosts[3],
    );
    expect(
      engine.proposeExchange(
        from: 0,
        to: 1,
        fromOffer: const DiplomacyOffer(
          type: DiplomacyExchangeType.lands,
          tiles: [1],
        ),
        toOffer: const DiplomacyOffer(),
      ),
      isFalse,
      reason: 'selling the bridge tile must not split the seller province',
    );
  });

  test('traitor fine preview equals the amount charged each round', () {
    final raw = _linearState([0, 0, 1, 1]).toJson()
      ..['config'] = const GameConfig(
        playerCount: 2,
        humanCount: 2,
        diplomacy: true,
      ).toJson()
      ..remove('diplomacyRelations');
    final state = GameState.fromJson(raw);
    final engine = GameEngine(mod: mod, state: state);
    final province = state.provinces.singleWhere(
      (candidate) => candidate.owner == 0,
    );
    province.money = 100;
    state.diplomacyTraitorTurns[0] = 2;

    final base = engine
        .economicBreakdown(province, includeDiplomacy: false)
        .total;
    final preview = engine.playerEconomicBreakdown(0);
    final fine = -preview.diplomacy;
    expect(fine, greaterThanOrEqualTo(5));

    engine.endTurn();
    engine.endTurn();

    expect(province.money, 100 + base - fine);
    expect(state.diplomacyTraitorTurns[0], 1);
  });

  test('subsidies are recurring, expire, and survive save serialization', () {
    final raw = _linearState([0, 0, 1, 1]).toJson()
      ..['config'] = const GameConfig(
        playerCount: 2,
        humanCount: 2,
        diplomacy: true,
      ).toJson()
      ..remove('diplomacyRelations');
    final state = GameState.fromJson(raw);
    state.provinces.where((province) => province.owner == 0).single.money = 50;
    final engine = GameEngine(mod: mod, state: state);
    expect(
      engine.proposeExchange(
        from: 0,
        to: 1,
        fromOffer: const DiplomacyOffer(
          type: DiplomacyExchangeType.subsidies,
          amount: 3,
          duration: 2,
        ),
        toOffer: const DiplomacyOffer(),
      ),
      isTrue,
    );
    engine.resolveDiplomacyProposal(
      engine.proposalsFor(1).single,
      accept: true,
    );
    expect(
      GameState.fromJson(state.toJson()).diplomacySubsidies.single.turnsLeft,
      2,
    );

    engine.endTurn();
    engine.endTurn();
    expect(state.diplomacySubsidies.single.turnsLeft, 1);
    expect(engine.playerMoney(0), 50);
    expect(engine.playerMoney(1), 14);
    engine.endTurn();
    engine.endTurn();
    expect(state.diplomacySubsidies, isEmpty);
    expect(engine.playerMoney(0), 50);
    expect(engine.playerMoney(1), 18);
  });
}

GameState _navalState() {
  final hexes = <HexTile>[
    HexTile(index: 0, q: 0, r: 0, active: true, owner: 0, neighbors: [1]),
    HexTile(index: 1, q: 1, r: 0, active: true, owner: 0, neighbors: [0, 2]),
    HexTile(index: 2, q: 2, r: 0, neighbors: [1, 3]),
    HexTile(index: 3, q: 3, r: 0, neighbors: [2]),
  ];
  hexes[0].object = TileObject.town;
  return GameState(
    config: const GameConfig(playerCount: 1, humanCount: 1),
    modId: 'classic_steppe',
    width: 4,
    height: 1,
    hexes: hexes,
    waterCells: [
      WaterCell(index: 0, tiles: [2], neighbors: [1], coastTiles: [0, 1]),
      WaterCell(index: 1, tiles: [3], neighbors: [0], coastTiles: [0]),
    ],
    provinces: [
      Province(id: 1, owner: 0, tiles: [0, 1], money: 200, capital: 0),
    ],
    turn: 0,
    round: 1,
    rngState: 1,
    nextProvinceId: 2,
  );
}

GameState _controllerNavalState() {
  final hexes = <HexTile>[
    HexTile(index: 0, q: 0, r: 0, active: true, owner: 0, neighbors: [1]),
    HexTile(index: 1, q: 1, r: 0, active: true, owner: 0, neighbors: [0, 2]),
    for (var index = 2; index < 11; index++)
      HexTile(
        index: index,
        q: index,
        r: 0,
        neighbors: [if (index > 2) index - 1, if (index < 10) index + 1],
      ),
  ];
  hexes[0].object = TileObject.town;
  return GameState(
    config: const GameConfig(playerCount: 2, humanCount: 2),
    modId: 'classic_steppe',
    width: 11,
    height: 1,
    hexes: hexes,
    waterCells: [
      WaterCell(index: 0, tiles: [2, 3, 4], neighbors: [1], coastTiles: [0, 1]),
      WaterCell(index: 1, tiles: [5, 6, 7], neighbors: [0, 2], coastTiles: [0]),
      WaterCell(index: 2, tiles: [8, 9, 10], neighbors: [1]),
    ],
    provinces: [
      Province(id: 1, owner: 0, tiles: [0, 1], money: 200, capital: 0),
    ],
    turn: 0,
    round: 1,
    rngState: 1,
    nextProvinceId: 2,
  );
}

GameState _bridgeheadState() {
  final hexes = <HexTile>[
    HexTile(index: 0, q: 0, r: 0, active: true, owner: -1, neighbors: [1]),
    HexTile(index: 1, q: 1, r: 0, active: true, owner: -1, neighbors: [0, 2]),
    HexTile(index: 2, q: 2, r: 0, active: true, owner: -1, neighbors: [1]),
    HexTile(index: 3, q: 3, r: 0),
    HexTile(index: 4, q: 4, r: 0, active: true, owner: 0, neighbors: [5]),
    HexTile(index: 5, q: 5, r: 0, active: true, owner: 0, neighbors: [4]),
    HexTile(index: 6, q: 6, r: 0, active: true, owner: 1, neighbors: [7]),
    HexTile(index: 7, q: 7, r: 0, active: true, owner: 1, neighbors: [6]),
  ];
  hexes[4].object = TileObject.town;
  hexes[6].object = TileObject.town;
  return GameState(
    config: const GameConfig(playerCount: 2, humanCount: 2),
    modId: 'classic_steppe',
    width: 8,
    height: 1,
    hexes: hexes,
    waterCells: [
      WaterCell(
        index: 0,
        tiles: [3],
        coastTiles: [0, 4],
        boat: GameBoat(
          owner: 0,
          level: 1,
          homeProvinceId: 1,
          cargo: [
            GameUnit(strength: 1, ready: true),
            GameUnit(strength: 1, ready: true),
            GameUnit(strength: 1, ready: true),
          ],
        ),
      ),
    ],
    provinces: [
      Province(id: 1, owner: 0, tiles: [4, 5], money: 100, capital: 4),
      Province(id: 2, owner: 1, tiles: [6, 7], money: 100, capital: 6),
    ],
    turn: 0,
    round: 1,
    rngState: 1,
    nextProvinceId: 3,
  );
}

GameState _longBridgeheadState() {
  final hexes = <HexTile>[
    HexTile(index: 0, q: 0, r: 0, active: true, owner: -1, neighbors: [1]),
    HexTile(index: 1, q: 1, r: 0, active: true, owner: -1, neighbors: [0, 2]),
    HexTile(index: 2, q: 2, r: 0, active: true, owner: -1, neighbors: [1, 3]),
    HexTile(index: 3, q: 3, r: 0, active: true, owner: -1, neighbors: [2, 4]),
    HexTile(index: 4, q: 4, r: 0, active: true, owner: -1, neighbors: [3]),
    HexTile(index: 5, q: 5, r: 0),
    HexTile(index: 6, q: 6, r: 0, active: true, owner: 0, neighbors: [7]),
    HexTile(index: 7, q: 7, r: 0, active: true, owner: 0, neighbors: [6]),
    HexTile(index: 8, q: 8, r: 0, active: true, owner: 1, neighbors: [9]),
    HexTile(index: 9, q: 9, r: 0, active: true, owner: 1, neighbors: [8]),
  ];
  hexes[6].object = TileObject.town;
  hexes[8].object = TileObject.town;
  return GameState(
    config: const GameConfig(playerCount: 2, humanCount: 2),
    modId: 'classic_steppe',
    width: 10,
    height: 1,
    hexes: hexes,
    waterCells: [
      WaterCell(
        index: 0,
        tiles: [5],
        coastTiles: [0, 6],
        boat: GameBoat(
          owner: 0,
          level: 2,
          homeProvinceId: 1,
          cargo: [
            for (var i = 0; i < 5; i++) GameUnit(strength: 1, ready: true),
          ],
        ),
      ),
    ],
    provinces: [
      Province(id: 1, owner: 0, tiles: [6, 7], money: 100, capital: 6),
      Province(id: 2, owner: 1, tiles: [8, 9], money: 100, capital: 8),
    ],
    turn: 0,
    round: 1,
    rngState: 1,
    nextProvinceId: 3,
  );
}

GameState _artilleryState() {
  final hexes = <HexTile>[
    HexTile(
      index: 0,
      q: 0,
      r: 0,
      active: true,
      owner: 0,
      object: TileObject.town,
      neighbors: [1],
    ),
    HexTile(
      index: 1,
      q: 1,
      r: 0,
      active: true,
      owner: 0,
      object: TileObject.artillery3,
      artilleryAmmo: 7,
      neighbors: [0, 4],
    ),
    HexTile(
      index: 2,
      q: 2,
      r: 0,
      active: true,
      owner: 1,
      object: TileObject.town,
      neighbors: [3],
    ),
    HexTile(index: 3, q: 3, r: 0, active: true, owner: 1, neighbors: [2]),
    HexTile(index: 4, q: 4, r: 0, neighbors: [1, 5]),
    HexTile(index: 5, q: 5, r: 0, neighbors: [4, 6]),
    HexTile(index: 6, q: 6, r: 0, neighbors: [5, 7]),
    HexTile(index: 7, q: 7, r: 0, neighbors: [6, 8]),
    HexTile(index: 8, q: 8, r: 0, neighbors: [7, 9]),
    HexTile(index: 9, q: 9, r: 0, neighbors: [8, 10]),
    HexTile(index: 10, q: 10, r: 0, neighbors: [9, 11]),
    HexTile(index: 11, q: 11, r: 0, neighbors: [10, 12]),
    HexTile(index: 12, q: 12, r: 0, neighbors: [11]),
  ];
  return GameState(
    config: const GameConfig(playerCount: 2, humanCount: 2),
    modId: 'classic_steppe',
    width: 13,
    height: 1,
    hexes: hexes,
    waterCells: [
      WaterCell(
        index: 0,
        tiles: [4, 5, 6],
        neighbors: [1],
        coastTiles: [1],
        boat: GameBoat(owner: 1, level: 2, homeProvinceId: 2),
      ),
      WaterCell(
        index: 1,
        tiles: [7, 8, 9],
        neighbors: [0, 2],
        boat: GameBoat(owner: 1, level: 1, homeProvinceId: 2),
      ),
      WaterCell(index: 2, tiles: [10, 11, 12], neighbors: [1]),
    ],
    provinces: [
      Province(id: 1, owner: 0, tiles: [0, 1], money: 100, capital: 0),
      Province(id: 2, owner: 1, tiles: [2, 3], money: 100, capital: 2),
    ],
    turn: 1,
    round: 1,
    rngState: 1,
    nextProvinceId: 3,
  );
}

GameState _linearState(List<int> owners, {int turn = 0, int humanCount = 2}) {
  final hexes = [
    for (var index = 0; index < owners.length; index++)
      HexTile(
        index: index,
        q: index,
        r: 0,
        active: true,
        owner: owners[index],
        neighbors: [
          if (index > 0) index - 1,
          if (index + 1 < owners.length) index + 1,
        ],
      ),
  ];
  final provinces = <Province>[];
  var nextId = 1;
  var index = 0;
  while (index < owners.length) {
    final owner = owners[index];
    final start = index;
    while (index < owners.length && owners[index] == owner) {
      index++;
    }
    final tiles = [for (var tile = start; tile < index; tile++) tile];
    if (owner < 0 || tiles.length < 2) continue;
    hexes[start].object = TileObject.town;
    provinces.add(
      Province(
        id: nextId++,
        owner: owner,
        tiles: tiles,
        money: 10,
        capital: start,
      ),
    );
  }
  return GameState(
    config: GameConfig(
      playerCount: owners
          .where((owner) => owner >= 0)
          .fold<int>(
            0,
            (highest, owner) => owner + 1 > highest ? owner + 1 : highest,
          ),
      humanCount: humanCount,
      seed: 1,
    ),
    modId: 'classic_steppe',
    width: owners.length,
    height: 1,
    hexes: hexes,
    provinces: provinces,
    turn: turn,
    round: 1,
    rngState: 1,
    nextProvinceId: nextId,
  );
}

GameState _splitEmpireCameraState() {
  final state = _linearState([0, 0, 1, 1, 1, 1, 0, 0]);
  state.width = 17;
  state.hexes.addAll([
    for (var index = 8; index < 17; index++)
      HexTile(
        index: index,
        q: index,
        r: 0,
        neighbors: [if (index > 8) index - 1, if (index < 16) index + 1],
      ),
  ]);
  state.waterCells.addAll([
    WaterCell(index: 0, tiles: [8, 9, 10], neighbors: [1]),
    WaterCell(index: 1, tiles: [11, 12, 13], neighbors: [0, 2]),
    WaterCell(
      index: 2,
      tiles: [14, 15, 16],
      neighbors: [1],
      boat: GameBoat(owner: 0, level: 1, homeProvinceId: 1),
    ),
  ]);
  return state;
}

class _CountingSaveRepository extends SaveRepository {
  int saveCount = 0;

  @override
  Future<void> save(GameState state) async {
    saveCount++;
  }
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
