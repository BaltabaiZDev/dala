import 'dart:convert';
import 'package:antiyoy_self/src/game/game_controller.dart';
import 'package:antiyoy_self/src/game/game_engine.dart';
import 'package:antiyoy_self/src/game/models.dart';
import 'package:antiyoy_self/src/lan/lan_command_dispatcher.dart';
import 'package:antiyoy_self/src/lan/lan_protocol.dart';
import 'package:antiyoy_self/src/modding/content_package.dart';
import 'package:antiyoy_self/src/modding/example_mod.dart';
import 'package:antiyoy_self/src/modding/game_mod.dart';
import 'package:antiyoy_self/src/modding/mod_stack.dart';
import 'package:antiyoy_self/src/persistence/save_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'mod_types_test.dart' as fixture;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late GameMod base, mod;
  setUpAll(() async {
    base = await GameMod.loadDefault();
    mod = createExampleMod(base);
  });

  Map<String, dynamic> factoryMod(String id, int buildings, int products) =>
      base.toJson()..addAll({
        'id': id,
        'buildings': [
          for (var i = 0; i < buildings; i++)
            ModBuilding(
              id: '$id.factory$i',
              name: 'Factory $i',
              price: 30,
              production: [
                for (var j = 0; j < products; j++)
                  ModUnitType(
                    id: '$id.product${i}_$j',
                    name: 'Product $i $j',
                    price: 10,
                  ),
              ],
            ).toJson(),
        ],
      });

  test('building count and each producer have independent type budgets', () {
    final a = GameMod.fromJson(factoryMod('alpha', 1, 32));
    final b = GameMod.fromJson(factoryMod('beta', 1, 32));
    final stack = ModStack.compose(base, [a, b]).mod;
    expect(stack.buildings, hasLength(2));
    expect(stack.units, hasLength(64));
    final largestRaw = factoryMod('largest', 32, 32);
    for (final building in largestRaw['buildings']) {
      for (final product in building['production']) {
        product['name'] = List.filled(60, 'Ж').join();
      }
    }
    final largest = GameMod.fromJson(largestRaw);
    expect(largest.units, hasLength(1024));
    expect(
      utf8.encode(jsonEncode(largest.toJson())).length,
      greaterThan(256 * 1024),
    );
    expect(
      ContentPackage.decode(
        ContentPackage(mod: largest).encode(),
      ).mod.fingerprint,
      largest.fingerprint,
    );
    expect(stack.toJson().containsKey('units'), isFalse);
    expect(GameMod.fromJson(stack.toJson()).fingerprint, stack.fingerprint);
    expect(
      ContentPackage.decode(ContentPackage(mod: a).encode()).mod.fingerprint,
      a.fingerprint,
    );
    expect(
      GameMod.fromJson(factoryMod('limit', 32, 1)).buildings,
      hasLength(32),
    );
    expect(
      () => GameMod.fromJson(factoryMod('limit', 33, 0)),
      throwsFormatException,
    );
    expect(
      () => GameMod.fromJson(factoryMod('limit', 1, 33)),
      throwsFormatException,
    );
    final crossLinked = factoryMod('alpha', 2, 1);
    crossLinked['buildings'][0]['production'][0]['requiresBuilding'] =
        'alpha.factory1';
    expect(() => GameMod.fromJson(crossLinked), throwsFormatException);
    final duplicate = factoryMod('alpha', 2, 1);
    duplicate['buildings'][1]['production'][0]['id'] = 'alpha.product0_0';
    expect(() => GameMod.fromJson(duplicate), throwsFormatException);
    final doubled = factoryMod('alpha', 1, 1);
    doubled['units'] = [a.units.values.first.toJson()];
    expect(() => GameMod.fromJson(doubled), throwsFormatException);
  });

  test('flat legacy manifests preserve fingerprints and town production', () {
    final legacyRaw = base.toJson()
      ..addAll({
        'id': 'legacy',
        'units': [
          const ModUnitType(
            id: 'legacy.scout',
            name: 'Scout',
            price: 15,
          ).toJson(),
        ],
      });
    final legacy = GameMod.fromJson(legacyRaw);
    final saved = jsonEncode(legacy.toJson());
    expect(jsonEncode(GameMod.fromJson(jsonDecode(saved)).toJson()), saved);
    final engine = fixture.modFixture(legacy);
    final home = engine.provincesOf(0).first;
    final targets = engine.modBuildTargets(home.id, 'legacy.scout');
    expect(targets, isNotEmpty);
    expect(engine.state.hexes[home.capital].neighbors, containsAll(targets));
    final controller = GameController(
      mod: legacy,
      state: engine.state,
      saves: SaveRepository(),
      autosaveEnabled: false,
      authoritativeSimulation: false,
    );
    controller.tapTile(targets.first);
    controller.selectModType('legacy.scout');
    expect(controller.selectedModTypeId, isNull);
    controller.tapTile(home.capital);
    controller.selectModType('legacy.scout');
    expect(controller.targetTiles, targets);
    final before = home.money;
    controller.tapModTile(targets.first);
    expect(engine.state.hexes[targets.first].unit?.typeId, 'legacy.scout');
    expect(home.money, before - 15);
    controller.dispose();
  });

  test(
    'LAN production uses the selected owned building and supports undo',
    () async {
      final engine = fixture.modFixture(mod);
      final home = engine.provincesOf(0).first;
      final first = engine.modBuildTargets(home.id, fixture.airfield).first;
      expect(engine.buildModType(home.id, first, fixture.airfield), isTrue);
      final second = engine.modBuildTargets(home.id, fixture.airfield).last;
      expect(engine.state.hexes[first].neighbors, isNot(contains(second)));
      // The limit is on declared building types, never copies built in a province.
      expect(engine.buildModType(home.id, second, fixture.airfield), isTrue);
      final controller = GameController(
        mod: mod,
        state: engine.state,
        saves: SaveRepository(),
        autosaveEnabled: false,
        authoritativeSimulation: false,
      );
      controller.tapTile(home.capital);
      controller.selectModType(fixture.aircraft);
      expect(controller.selectedModTypeId, isNull);
      controller.tapTile(first);
      controller.selectModType(fixture.aircraft);
      expect(controller.selectedTile, first);
      expect({
        first,
        ...engine.state.hexes[first].neighbors,
      }, containsAll(controller.targetTiles));
      expect(controller.targetTiles, isNot(contains(second)));
      final cash = home.money;
      Future<void> produce(int target, int source) async {
        final wire = LanGameCommand(
          id: target,
          baseRevision: 0,
          action: 'tapModTile',
          arguments: {'index': target},
          ui: LanUiState(
            selectedTile: source,
            selectedModTypeId: fixture.aircraft,
          ),
        );
        await const LanCommandDispatcher().dispatch(
          controller: controller,
          player: 0,
          command: LanGameCommand.fromJson(wire.toJson()),
        );
      }

      await produce(second, first);
      expect(engine.state.hexes[second].airUnit, isNull);
      expect(home.money, cash);
      await produce(first, home.capital);
      expect(engine.state.hexes[first].airUnit, isNull);
      await produce(first, first);
      expect(engine.state.hexes[first].airUnit?.typeId, fixture.aircraft);
      expect(engine.state.hexes[first].airUnit?.ready, isFalse);
      expect(home.money, cash - mod.units[fixture.aircraft]!.price);
      controller.undo();
      expect(controller.state.hexes[first].airUnit, isNull);
      expect(controller.engine.provincesOf(0).first.money, cash);
      controller.tapTile(first);
      controller.selectModType(fixture.aircraft);
      controller.state.hexes[first].object = TileObject.none;
      expect(controller.targetTiles, isEmpty);
      controller.tapModTile(first);
      expect(controller.state.hexes[first].airUnit, isNull);
      expect(controller.engine.provincesOf(0).first.money, cash);
      controller.dispose();
    },
  );
}
