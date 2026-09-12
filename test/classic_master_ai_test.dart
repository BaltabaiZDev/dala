import 'package:antiyoy_self/src/game/classic_master_ai.dart';
import 'package:antiyoy_self/src/game/game_ai.dart';
import 'package:antiyoy_self/src/game/game_engine.dart';
import 'package:antiyoy_self/src/game/models.dart';
import 'package:antiyoy_self/src/modding/game_mod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late GameMod mod;

  setUpAll(() async {
    mod = await GameMod.loadDefault();
  });

  test('dispatches only Generic Master to the dedicated subsystem', () {
    final generic = _masterState();
    final slay = _masterState(slayRules: true);

    expect(ClassicMasterAi.shouldRunFor(generic), isTrue);
    expect(ClassicMasterAi.shouldRunFor(slay), isFalse);
    expect(
      GameAi(
        mod: mod,
        engine: GameEngine(mod: mod, state: generic),
      ).usesClassicMasterLand,
      isTrue,
    );
    expect(
      GameAi(
        mod: mod,
        engine: GameEngine(mod: mod, state: slay),
      ).usesClassicMasterLand,
      isFalse,
    );
  });

  test('per-province loop is spending-first and capped at seven cycles', () {
    final state = _sevenCycleState();
    final report = ClassicMasterAi(
      mod: mod,
      engine: GameEngine(mod: mod, state: state),
    ).perform();

    expect(report.provinces, isNotEmpty);
    final province = report.provinces.first;
    expect(province.cycles, 7);
    expect(province.attemptOrder.take(2), ['spending', 'action']);
    expect(
      province.attemptOrder.where((entry) => entry == 'spending'),
      hasLength(7),
    );
    expect(report.maximumCycles, 7);
  });

  test('Generic Master does not run the Balancer redundant-unit cleanup', () {
    final state = _cleanupSentinelState();
    final sentinel = state.hexes[1].unit!;

    ClassicMasterAi(
      mod: mod,
      engine: GameEngine(mod: mod, state: state),
    ).perform();

    expect(sentinel.strength, 3);
    expect(
      state.hexes.where((tile) => identical(tile.unit, sentinel)),
      hasLength(1),
    );
  });

  test('Slay Master stays on Expert and never reports Generic Master work', () {
    final state = _masterState(slayRules: true);
    final ai = GameAi(
      mod: mod,
      engine: GameEngine(mod: mod, state: state),
    );

    ai.takeTurn();

    expect(ai.usesClassicMasterLand, isFalse);
    expect(ai.lastClassicMasterReport, isNull);
  });

  test(
    'sync and cooperative Master state machines are deterministic',
    () async {
      final syncState = _sevenCycleState();
      final asyncState = GameState.fromJson(syncState.toJson());
      final syncReport = ClassicMasterAi(
        mod: mod,
        engine: GameEngine(mod: mod, state: syncState),
      ).perform();
      final asyncReport = await ClassicMasterAi(
        mod: mod,
        engine: GameEngine(mod: mod, state: asyncState),
      ).performAsync();

      expect(asyncState.toJson(), syncState.toJson());
      expect(
        asyncReport.provinces.map((province) => province.attemptOrder).toList(),
        syncReport.provinces.map((province) => province.attemptOrder).toList(),
      );
      expect(asyncReport.maximumCycles, syncReport.maximumCycles);
    },
  );
}

GameState _sevenCycleState() {
  final hexes = <HexTile>[
    HexTile(
      index: 0,
      q: 0,
      r: 0,
      active: true,
      owner: 0,
      object: TileObject.town,
      neighbors: [1, 2, 3, 4, ...List<int>.generate(30, (index) => index + 5)],
    ),
    for (var index = 1; index <= 4; index++)
      HexTile(
        index: index,
        q: index,
        r: 0,
        active: true,
        owner: 0,
        object: TileObject.farm,
        neighbors: [0],
      ),
    for (var index = 5; index < 35; index++)
      HexTile(
        index: index,
        q: index,
        r: 1,
        active: true,
        owner: -1,
        neighbors: [0],
      ),
    HexTile(
      index: 35,
      q: 30,
      r: 0,
      active: true,
      owner: 1,
      object: TileObject.town,
      neighbors: const [36],
    ),
    HexTile(
      index: 36,
      q: 31,
      r: 0,
      active: true,
      owner: 1,
      neighbors: const [35],
    ),
  ];
  return _state(
    hexes: hexes,
    provinces: [
      Province(
        id: 1,
        owner: 0,
        tiles: const [0, 1, 2, 3, 4],
        money: 1000,
        capital: 0,
      ),
      Province(id: 2, owner: 1, tiles: const [35, 36], money: 0, capital: 35),
    ],
  );
}

GameState _cleanupSentinelState() {
  final hexes = <HexTile>[
    for (var index = 0; index < 12; index++)
      HexTile(
        index: index,
        q: index,
        r: 0,
        active: true,
        owner: 0,
        object: index == 0 ? TileObject.town : TileObject.none,
        unit: index == 1 ? GameUnit(strength: 3) : null,
        neighbors: [if (index > 0) index - 1, if (index < 11) index + 1],
      ),
    HexTile(
      index: 12,
      q: 20,
      r: 0,
      active: true,
      owner: 1,
      object: TileObject.town,
      neighbors: const [13],
    ),
    HexTile(
      index: 13,
      q: 21,
      r: 0,
      active: true,
      owner: 1,
      neighbors: const [12],
    ),
  ];
  return _state(
    hexes: hexes,
    provinces: [
      Province(
        id: 1,
        owner: 0,
        tiles: List<int>.generate(12, (index) => index),
        money: 100,
        capital: 0,
      ),
      Province(id: 2, owner: 1, tiles: const [12, 13], money: 0, capital: 12),
    ],
  );
}

GameState _masterState({bool slayRules = false}) {
  final hexes = <HexTile>[
    HexTile(
      index: 0,
      q: 0,
      r: 0,
      active: true,
      owner: 0,
      object: TileObject.town,
      neighbors: const [1],
    ),
    HexTile(
      index: 1,
      q: 1,
      r: 0,
      active: true,
      owner: 0,
      neighbors: const [0, 2],
    ),
    HexTile(
      index: 2,
      q: 2,
      r: 0,
      active: true,
      owner: 1,
      neighbors: const [1, 3],
    ),
    HexTile(
      index: 3,
      q: 3,
      r: 0,
      active: true,
      owner: 1,
      object: TileObject.town,
      neighbors: const [2],
    ),
  ];
  return _state(
    hexes: hexes,
    slayRules: slayRules,
    provinces: [
      Province(id: 1, owner: 0, tiles: const [0, 1], money: 0, capital: 0),
      Province(id: 2, owner: 1, tiles: const [2, 3], money: 0, capital: 3),
    ],
  );
}

GameState _state({
  required List<HexTile> hexes,
  required List<Province> provinces,
  bool slayRules = false,
}) => GameState(
  config: GameConfig(
    playerCount: 2,
    humanCount: 0,
    seed: 991,
    difficulty: AiDifficulty.master,
    slayRules: slayRules,
  ),
  modId: 'classic_steppe',
  width: hexes.length,
  height: 1,
  hexes: hexes,
  provinces: provinces,
  turn: 0,
  round: 1,
  rngState: 17,
  nextProvinceId: 3,
);
