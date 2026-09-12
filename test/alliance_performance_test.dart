import 'package:antiyoy_self/src/game/game_engine.dart';
import 'package:antiyoy_self/src/game/models.dart';
import 'package:antiyoy_self/src/modding/game_mod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('fragmented 15-color rebuild preserves every budget and troop', () async {
    final mod = await GameMod.loadDefault();
    const count = 5040;
    final state = GameState(
      config: const GameConfig(
        playerCount: 15,
        humanCount: 15,
        diplomacy: true,
      ),
      modId: mod.id,
      width: count,
      height: 1,
      hexes: [
        for (var i = 0; i < count; i++)
          HexTile(
            index: i,
            q: i,
            r: 0,
            active: true,
            owner: (i ~/ 2) % 15,
            object: i.isEven ? TileObject.town : TileObject.none,
            unit: i.isOdd
                ? GameUnit(
                    strength: 1,
                    owner: (i ~/ 2) % 15,
                    homeProvinceId: i ~/ 2 + 1,
                  )
                : null,
            neighbors: [if (i > 0) i - 1, if (i < count - 1) i + 1],
          ),
      ],
      provinces: [
        for (var i = 0; i < count; i += 2)
          Province(
            id: i ~/ 2 + 1,
            owner: (i ~/ 2) % 15,
            tiles: [i, i + 1],
            money: 100,
            capital: i,
          ),
      ],
      turn: 0,
      round: 1,
      rngState: 1,
      nextProvinceId: count ~/ 2 + 1,
    );
    final engine = GameEngine(mod: mod, state: state);
    final before = state.toJson();
    final clock = Stopwatch()..start();
    engine.rebuildProvinces();
    clock.stop();
    // Diagnostic only: the bound allows loaded CI machines, identity is exact.
    // ignore: avoid_print
    print(
      '5040 tiles / 2520 provinces rebuild: ${clock.elapsedMilliseconds} ms',
    );
    expect(clock.elapsed, lessThan(const Duration(seconds: 3)));
    expect(state.toJson(), before);
  });
}
