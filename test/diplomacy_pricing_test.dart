import 'package:antiyoy_self/src/game/game_engine.dart';
import 'package:antiyoy_self/src/game/models.dart';
import 'package:antiyoy_self/src/modding/game_mod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late GameMod mod;
  late GameState state;
  late GameEngine engine;

  setUpAll(() async {
    mod = await GameMod.loadDefault();
  });

  setUp(() {
    final hexes = <HexTile>[
      for (var index = 0; index < 5; index++)
        HexTile(
          index: index,
          q: index,
          r: 0,
          active: true,
          owner: index < 4 ? 0 : 1,
          neighbors: <int>[if (index > 0) index - 1, if (index < 4) index + 1],
        ),
    ];
    state = GameState(
      config: const GameConfig(playerCount: 2, humanCount: 2, diplomacy: true),
      modId: 'classic',
      width: 5,
      height: 1,
      hexes: hexes,
      provinces: <Province>[
        Province(
          id: 1,
          owner: 0,
          tiles: const [0, 1, 2, 3],
          money: 50,
          capital: 0,
        ),
        Province(id: 2, owner: 1, tiles: const [4], money: 50, capital: 4),
      ],
      turn: 0,
      round: 0,
      rngState: 1,
      nextProvinceId: 3,
    );
    engine = GameEngine(mod: mod, state: state);
  });

  test('Classic land diplomacy values are preserved for every land piece', () {
    final cases = <TileObject, int>{
      TileObject.none: 25,
      TileObject.grave: 25,
      TileObject.pine: 15,
      TileObject.palm: 15,
      TileObject.town: 40,
      TileObject.tower: 50,
      TileObject.farm: 100,
      TileObject.strongTower: 75,
      TileObject.port1: mod.rules.port1Price,
      TileObject.port2: mod.rules.port1Price + mod.rules.port2Price,
      TileObject.artillery1: mod.rules.artilleryCosts[1],
      TileObject.artillery2:
          mod.rules.artilleryCosts[1] + mod.rules.artilleryCosts[2],
      TileObject.artillery3:
          mod.rules.artilleryCosts[1] +
          mod.rules.artilleryCosts[2] +
          mod.rules.artilleryCosts[3],
    };

    for (final entry in cases.entries) {
      state.hexes[0]
        ..object = entry.key
        ..unit = null;
      expect(
        engine.diplomacyLandPrice(0),
        entry.value,
        reason: '${entry.key.name} must use the Classic valuation',
      );
    }
  });

  test('unit value overrides the object and scales with strength', () {
    for (var strength = 1; strength <= 4; strength++) {
      state.hexes[0]
        ..object = TileObject.farm
        ..unit = GameUnit(strength: strength);
      expect(engine.diplomacyLandPrice(0), 25 + 15 * strength);
    }
  });

  test('town value follows the current province land count', () {
    state.hexes[0].object = TileObject.town;
    expect(engine.diplomacyLandPrice(0), 40);

    state.provinces[0] = Province(
      id: 1,
      owner: 0,
      tiles: const [0, 1],
      money: 50,
      capital: 0,
    );
    expect(engine.diplomacyLandPrice(0), 20);
  });
}
