import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:archive/archive.dart';
import 'package:antiyoy_self/src/ui/classic_assets.dart';
import 'package:antiyoy_self/src/ui/dala_art.dart';
import 'package:antiyoy_self/src/game/game_ai.dart';
import 'package:antiyoy_self/src/game/game_controller.dart';
import 'package:antiyoy_self/src/game/game_engine.dart';
import 'package:antiyoy_self/src/game/map_generator.dart';
import 'package:antiyoy_self/src/game/models.dart';
import 'package:antiyoy_self/src/game/turn_replay.dart';
import 'package:antiyoy_self/src/lan/lan_command_dispatcher.dart';
import 'package:antiyoy_self/src/lan/lan_protocol.dart';
import 'package:antiyoy_self/src/lan/lan_state_patch.dart';
import 'package:antiyoy_self/src/modding/content_package.dart';
import 'package:antiyoy_self/src/modding/example_mod.dart';
import 'package:antiyoy_self/src/modding/game_mod.dart';
import 'package:antiyoy_self/src/modding/mod_stack.dart';
import 'package:antiyoy_self/src/persistence/save_repository.dart';
import 'package:flutter_test/flutter_test.dart';

const radar = 'my_dala_mod.radar';
const airfield = 'my_dala_mod.airfield';
const aircraft = 'my_dala_mod.aircraft';
const scout = 'my_dala_mod.scout';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late GameMod base, mod;
  setUpAll(() async {
    base = await GameMod.loadDefault();
    mod = createExampleMod(base);
  });

  test(
    'type registry validates fields, references, namespace and fingerprint',
    () {
      expect(GameMod.fromJson(mod.toJson()).fingerprint, mod.fingerprint);
      for (final mutate in <void Function(Map<String, dynamic>)>[
        (j) => (j['buildings'] as List).first['vision'] = 13,
        (j) => (j['buildings'] as List).first['income'] = -1,
        (j) => (j['buildings'] as List).first['id'] = 'other.radar',
        (j) =>
            (j['buildings'] as List).first['id'] = 'my_dala_mod.airfield_team',
        (j) => (j['units'] as List).last['requiresBuilding'] =
            'my_dala_mod.missing',
        (j) => (j['units'] as List).last['strength'] = 5,
        (j) => (j['units'] as List).last['execute'] = 'anything',
        (j) => (j['units'] as List).add((j['units'] as List).first),
      ]) {
        final json =
            jsonDecode(jsonEncode(mod.toJson())) as Map<String, dynamic>;
        mutate(json);
        expect(() => GameMod.fromJson(json), throwsFormatException);
      }
      final changed = mod.toJson();
      (changed['buildings'] as List).first['vision'] = 6;
      expect(GameMod.fromJson(changed).fingerprint, isNot(mod.fingerprint));
      final other = GameMod.fromJson(
        base.toJson()..addAll({
          'id': 'industry',
          'buildings': [
            const ModBuilding(
              id: 'industry.mine',
              name: 'Mine',
              price: 20,
              income: 3,
            ).toJson(),
          ],
        }),
      );
      final stack = ModStack.compose(base, [mod, other]).mod;
      expect(
        stack.buildings.keys,
        containsAll([radar, airfield, 'industry.mine']),
      );
      expect(stack.units.keys, containsAll([scout, aircraft]));
      expect(
        ContentPackage.decode(
          ContentPackage(mod: mod).encode(),
        ).mod.fingerprint,
        mod.fingerprint,
      );
    },
  );

  test(
    'production gates, price, readiness and custom upkeep are real rules',
    () {
      final engine = modFixture(mod);
      final home = engine.provincesOf(0).first;
      expect(engine.modBuildTargets(home.id, aircraft), isEmpty);
      final site = engine.modBuildTargets(home.id, airfield).first;
      final cash = home.money;
      expect(engine.buildModType(home.id, site, airfield), isTrue);
      expect(home.money, cash - mod.buildings[airfield]!.price);
      expect(
        engine.buildTargets(home.id, TileObject.tower),
        isNot(contains(site)),
      );
      expect(engine.unitBuildTargets(home.id, 1), isNot(contains(site)));
      expect(engine.modBuildTargets(home.id, aircraft), contains(site));
      expect(engine.buildModType(home.id, site, aircraft), isTrue);
      expect(engine.state.hexes[site].airUnit!.ready, isFalse);
      expect(engine.airMoveTargets(site), isEmpty);
      expect(engine.economicBreakdown(home).modUpkeep, -6);
      final unitSite = engine.modBuildTargets(home.id, scout).first;
      expect(engine.buildModType(home.id, unitSite, scout), isTrue);
      expect(engine.economicBreakdown(home).landUnits, -2);
      expect(engine.unitBuildTargets(home.id, 1), isNot(contains(unitSite)));
      engine.endTurn();
      engine.endTurn();
      expect(engine.state.hexes[site].airUnit!.ready, isTrue);
      expect(engine.state.hexes[unitSite].unit!.ready, isTrue);
      expect(engine.buildModType(home.id, site, 'unknown.type'), isFalse);
    },
  );

  test(
    'radar and aircraft reveal across water and visibility follows treaties',
    () {
      final engine = modFixture(mod);
      final state = engine.state;
      final home = engine.provincesOf(0).first;
      final site = home.tiles
          .where(
            (i) =>
                state.hexes[i].q == 4 &&
                state.hexes[i].object == TileObject.none,
          )
          .first;
      expect(engine.buildModType(home.id, site, radar), isTrue);
      final revealed = modVisionTiles(
        state,
        mod,
        (p) => engine.areAllies(0, p),
      );
      expect(revealed.any((i) => !state.hexes[i].active), isTrue);
      expect(revealed.any((i) => state.hexes[i].owner == 1), isTrue);
      final controller = GameController(
        mod: mod,
        state: state,
        saves: SaveRepository(),
        autosaveEnabled: false,
        authoritativeSimulation: false,
      );
      expect(controller.visibleWaterCellIndices, isNotEmpty);
      expect(
        controller.visibleTileIndices.any((i) => state.hexes[i].owner == 1),
        isTrue,
      );
      engine.setDiplomacyStatus(0, 1, DiplomacyStatus.alliance);
      expect(
        modVisionTiles(state, mod, (p) => engine.areAllies(1, p)),
        contains(site),
      );
      engine.setDiplomacyStatus(0, 1, DiplomacyStatus.peace);
      expect(
        modVisionTiles(state, mod, (p) => engine.areAllies(1, p)),
        isNot(contains(site)),
      );
      controller.dispose();
    },
  );

  test(
    'flight consumes one action, crosses sea, keeps payer and cannot capture',
    () {
      final engine = modFixture(mod);
      final source = placeAircraft(engine);
      final plane = engine.state.hexes[source].airUnit!;
      final payer = plane.homeProvinceId;
      final sea = engine
          .airMoveTargets(source)
          .firstWhere((i) => !engine.state.hexes[i].active);
      final landBefore = engine.state.hexes.map((t) => t.owner).toList();
      expect(engine.moveAirUnit(source, sea), isTrue);
      expect(engine.state.hexes[sea].airUnit, same(plane));
      expect(plane.homeProvinceId, payer);
      expect(engine.moveAirUnit(sea, source), isFalse);
      expect(engine.state.hexes.map((t) => t.owner), landBefore);
      plane.ready = true;
      expect(
        engine.airMoveTargets(sea).any((i) => engine.state.hexes[i].owner == 1),
        isFalse,
      );
      engine.setDiplomacyStatus(0, 1, DiplomacyStatus.war);
      expect(
        engine.airMoveTargets(sea).any((i) => engine.state.hexes[i].owner == 1),
        isTrue,
      );
    },
  );

  test(
    'air attacks require hostile visible targets and never erase a town or ownership',
    () {
      final engine = modFixture(mod);
      final state = engine.state;
      final from = state.hexes.firstWhere((t) => !t.active && t.q == 9).index;
      placeAircraft(engine, at: from);
      final enemy = engine.provincesOf(1).first;
      final target = enemy.tiles.firstWhere(
        (i) =>
            state.hexes[i].q == 11 && state.hexes[i].object == TileObject.none,
      );
      state.hexes[target].object = TileObject.tower;
      expect(engine.airAttackTargets(from), isNot(contains(target)));
      engine.setDiplomacyStatus(0, 1, DiplomacyStatus.war);
      expect(engine.airAttackTargets(from), contains(target));
      expect(engine.attackWithAirUnit(from, target), isTrue);
      expect(state.hexes[target].owner, 1);
      expect(state.hexes[target].object, TileObject.none);
      expect(engine.attackWithAirUnit(from, target), isFalse);
      state.hexes[from].airUnit!.ready = true;
      expect(engine.airAttackTargets(from), isNot(contains(enemy.capital)));
    },
  );

  test(
    'alliance expiry returns aircraft home; full sky refunds, bankruptcy removes upkeep',
    () {
      final engine = modFixture(mod);
      final home = engine.provincesOf(0).first;
      final foreign = engine.provincesOf(1).first.tiles.first;
      engine.setDiplomacyStatus(0, 1, DiplomacyStatus.coalition);
      placeAircraft(engine, at: foreign);
      engine.state.diplomacyAllianceTurns[0][1] =
          engine.state.diplomacyAllianceTurns[1][0] = 1;
      engine.endTurn();
      engine.endTurn();
      expect(engine.state.hexes[foreign].airUnit, isNull);
      expect(
        engine.state.hexes.any((t) => t.owner == 0 && t.airUnit?.owner == 0),
        isTrue,
      );
      for (final index in home.tiles) {
        placeAircraft(engine, at: index);
      }
      engine.setDiplomacyStatus(0, 1, DiplomacyStatus.coalition);
      placeAircraft(engine, at: foreign);
      final before = home.money;
      engine.setDiplomacyStatus(0, 1, DiplomacyStatus.peace);
      expect(home.money, before + mod.units[aircraft]!.price);
      expect(engine.state.hexes[foreign].airUnit, isNull);
      home.money = -10000;
      engine.endTurn();
      engine.endTurn();
      expect(engine.state.hexes.where((t) => t.airUnit?.owner == 0), isEmpty);
      expect(home.money, 0);
    },
  );

  test(
    'custom ground units keep movement, upkeep, identity and cannot merge',
    () {
      final engine = modFixture(mod);
      final home = engine.provincesOf(0).first;
      final from = engine.modBuildTargets(home.id, scout).first;
      engine.buildModType(home.id, from, scout);
      final unit = engine.state.hexes[from].unit!..ready = true;
      final to = engine
          .moveTargets(from)
          .firstWhere((i) => engine.state.hexes[i].owner == 0);
      expect(engine.moveUnit(from, to), isTrue);
      expect(engine.state.hexes[to].unit, same(unit));
      expect(unit.typeId, scout);
      expect(engine.unitMovement(unit), 6);
      expect(engine.canMergeUnits(unit, GameUnit(strength: 1)), isFalse);
      expect(engine.unitMaintenance(unit), 2);
      expect(engine.unitPrice(unit), 15);
      final restored = GameState.fromJson(engine.state.toJson());
      expect(restored.hexes[to].unit!.typeId, scout);
    },
  );

  test('map/package, replay and LAN patches preserve all custom data', () {
    final engine = modFixture(mod);
    final home = engine.provincesOf(0).first;
    final builder = LanStatePatchBuilder()..prime(engine.state);
    final copy = engine.state.toJson();
    final replay = TurnReplayFrames(engine.state);
    final site = engine.modBuildTargets(home.id, radar).first;
    engine.buildModType(home.id, site, radar);
    placeAircraft(engine);
    applyLanPatchToJson(copy, builder.build(engine.state)!);
    expect(copy, engine.state.toJson());
    replay.captureTurn(engine.state);
    expect(replay.last, engine.state.toJson());
    final map = DalaMap.fromState('Technology', engine.state, mod);
    final roundTrip = DalaMap.decode(
      map.encode(),
      mod: mod,
    ).createState(mod, multiplayer: true);
    expect(roundTrip.hexes[site].buildingTypeId, radar);
    expect(roundTrip.hexes.where((t) => t.airUnit != null), hasLength(1));
    final invalid = GameState.fromJson(engine.state.toJson());
    invalid.hexes[site].buildingTypeId = 'my_dala_mod.missing';
    expect(() => GameEngine(mod: mod, state: invalid), throwsFormatException);
  });

  test(
    'LAN dispatch retains custom UI, authorizes owner and publishes actual changes',
    () async {
      final engine = modFixture(mod);
      final controller = GameController(
        mod: mod,
        state: engine.state,
        saves: SaveRepository(),
        autosaveEnabled: false,
        authoritativeSimulation: false,
      );
      final home = engine.provincesOf(0).first;
      final site = engine.modBuildTargets(home.id, radar).first;
      final ui = LanUiState.fromJson({
        'selectedTile': home.capital,
        'selectedModTypeId': radar,
      });
      final command = LanGameCommand.fromJson(
        LanGameCommand(
          id: 1,
          baseRevision: 0,
          action: 'tapModTile',
          arguments: {'index': site},
          ui: ui,
        ).toJson(),
      );
      expect(command.ui.selectedModTypeId, radar);
      await const LanCommandDispatcher().dispatch(
        controller: controller,
        player: 0,
        command: command,
      );
      expect(engine.state.hexes[site].buildingTypeId, radar);
      final plane = placeAircraft(engine);
      final sea = engine
          .airMoveTargets(plane)
          .firstWhere((i) => !engine.state.hexes[i].active);
      final result = await const LanCommandDispatcher().dispatch(
        controller: controller,
        player: 0,
        command: LanGameCommand(
          id: 2,
          baseRevision: 0,
          action: 'tapModTile',
          arguments: {'index': sea},
          ui: LanUiState(selectedAirTile: plane),
        ),
      );
      expect(engine.state.hexes[sea].airUnit, isNotNull);
      expect(result['selectedAirTile'], sea);
      controller.dispose();
    },
  );

  test(
    'mod AI sync and async agree and use radar/aircraft without money cheats',
    () async {
      final first = modFixture(mod, humans: 0);
      final second = GameEngine(
        mod: mod,
        state: GameState.fromJson(first.state.toJson()),
      );
      GameAi(mod: mod, engine: first).takeTurn();
      await GameAi(mod: mod, engine: second).takeTurnAsync();
      expect(second.state.toJson(), first.state.toJson());
      expect(first.state.hexes.any((t) => t.buildingTypeId == radar), isTrue);
      expect(first.provincesOf(0).every((p) => p.money >= 0), isTrue);
    },
  );

  test('native scouting spots for aircraft and undo restores the strike', () {
    final json = mod.toJson();
    (json['units'] as List).last['vision'] = 0;
    final shortSight = GameMod.fromJson(json);
    final engine = modFixture(shortSight);
    engine.setDiplomacyStatus(0, 1, DiplomacyStatus.war);
    final target = engine.state.hexes
        .firstWhere(
          (t) => t.owner == 1 && t.q == 11 && t.object == TileObject.none,
        )
        .index;
    final from = placeAircraft(
      engine,
      at: engine.state.hexes[target].neighbors.firstWhere(
        (i) => !engine.state.hexes[i].active,
      ),
    );
    engine.state.hexes[target].buildingTypeId = radar;
    final coast = engine.state.waterCells.firstWhere(
      (c) => c.navigable && c.coastTiles.contains(target),
    );
    coast.boat = GameBoat(
      id: engine.state.nextNavalEntityId++,
      level: 1,
      owner: 0,
      homeProvinceId: engine.provincesOf(0).first.id,
    );
    expect(
      modVisionTiles(engine.state, shortSight, (p) => p == 0),
      isNot(contains(target)),
    );
    expect(engine.airAttackTargets(from), contains(target));
    expect(engine.diplomacyLandPrice(target), 55);
    final controller = GameController(
      mod: shortSight,
      state: engine.state,
      saves: SaveRepository(),
      autosaveEnabled: false,
      authoritativeSimulation: false,
    );
    expect(controller.tapModTile(from), isTrue);
    expect(controller.tapModTile(target), isTrue);
    expect(controller.state.hexes[target].buildingTypeId, isNull);
    expect(controller.state.hexes[target].owner, 1);
    controller.undo();
    expect(controller.state.hexes[target].buildingTypeId, radar);
    expect(controller.state.hexes[from].airUnit!.ready, isTrue);
    expect(controller.selectedAirTile, from);
    controller.dispose();
  });

  test(
    'custom structures survive tree growth and unknown saved types are rejected',
    () {
      final engine = modFixture(mod);
      final home = engine.provincesOf(0).first;
      final target = engine.modBuildTargets(home.id, radar).first;
      expect(engine.buildModType(home.id, target, radar), isTrue);
      for (final i in engine.state.hexes[target].neighbors) {
        final tile = engine.state.hexes[i];
        if (tile.active && tile.object == TileObject.none) {
          tile
            ..object = TileObject.pine
            ..treeBorn = -1;
        }
      }
      for (var i = 0; i < 12; i++) {
        engine.endTurn();
      }
      expect(engine.state.hexes[target].buildingTypeId, radar);
      final copy = GameState.fromJson(engine.state.toJson());
      copy.hexes[target].buildingTypeId = 'missing.radar';
      expect(() => GameEngine(mod: mod, state: copy), throwsFormatException);
    },
  );

  test(
    'example repacks editable source and custom PNG assets round-trip',
    () async {
      final folder = Directory('build/mod-types-example')
        ..createSync(recursive: true);
      File(
        '${folder.path}/my_dala_mod.dalamod',
      ).writeAsBytesSync(ContentPackage(mod: mod).encode());
      File('${folder.path}/mod.json').writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert({
          'format': 'dala-mod',
          'version': 2,
          'mod': mod.toJson()..remove('sprites'),
        }),
      );
      final source = File('${folder.path}/mod.json').readAsBytesSync();
      final repacked = ZipEncoder().encode(
        Archive()..addFile(ArchiveFile('mod.json', source.length, source)),
      );
      expect(
        ContentPackage.decode(Uint8List.fromList(repacked)).mod.fingerprint,
        mod.fingerprint,
      );

      final image = await DalaArt.rasterize('radar');
      final png = (await image.toByteData(
        format: ui.ImageByteFormat.png,
      ))!.buffer.asUint8List();
      image.dispose();
      final custom = GameMod.fromJson(
        mod.toJson()..['sprites'] = <String, String>{radar: base64Encode(png)},
      );
      final decoded = ContentPackage.decode(
        ContentPackage(mod: custom).encode(),
      ).mod;
      final sprites = await ClassicSprites.load(overrides: decoded.sprites);
      expect(sprites.images[radar], isNotNull);
      expect(decoded.fingerprint, custom.fingerprint);
      sprites.dispose();
    },
  );
}

GameEngine modFixture(GameMod mod, {int humans = 2}) {
  const width = 16, height = 7;
  final tiles = <HexTile>[];
  for (var row = 0; row < height; row++) {
    for (var column = 0; column < width; column++) {
      final active = row >= 1 && row <= 5 && (column <= 4 || column >= 11);
      tiles.add(
        HexTile(
          index: tiles.length,
          q: column,
          r: row - column ~/ 2,
          active: active,
          owner: active ? (column <= 4 ? 0 : 1) : -1,
        ),
      );
    }
  }
  final positions = {for (final tile in tiles) (tile.q, tile.r): tile.index};
  for (final tile in tiles) {
    for (final d in [(1, 0), (1, -1), (0, -1), (-1, 0), (-1, 1), (0, 1)]) {
      final index = positions[(tile.q + d.$1, tile.r + d.$2)];
      if (index != null) tile.neighbors.add(index);
    }
  }
  final state = GameState(
    config: GameConfig(
      playerCount: 2,
      humanCount: humans,
      fogOfWar: true,
      diplomacy: true,
      seed: 17,
    ),
    modId: mod.id,
    modSnapshot: mod.toJson(),
    width: width,
    height: height,
    hexes: tiles,
    provinces: [],
    turn: 0,
    round: 0,
    rngState: 17,
    nextProvinceId: 1,
  );
  MapGenerator.ensureWaterCells(state);
  final engine = GameEngine(mod: mod, state: state)..rebuildProvinces();
  for (final province in state.provinces) {
    province.money = 500;
  }
  return engine;
}

int placeAircraft(GameEngine engine, {int? at}) {
  final home = engine.provincesOf(0).first;
  final site = at ?? home.capital;
  engine.state.hexes[site].airUnit = GameUnit(
    strength: engine.mod.units[aircraft]!.strength,
    owner: 0,
    homeProvinceId: home.id,
    typeId: aircraft,
  );
  return site;
}
