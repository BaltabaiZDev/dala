import 'package:antiyoy_self/src/game/game_ai.dart';
import 'package:antiyoy_self/src/game/game_engine.dart';
import 'package:antiyoy_self/src/game/map_generator.dart';
import 'package:antiyoy_self/src/game/models.dart';
import 'package:antiyoy_self/src/modding/game_mod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late GameMod mod;

  setUpAll(() async {
    mod = await GameMod.loadDefault();
  });

  test('large empires process every unit that was ready at turn start', () {
    final state = _largeEmpireState();
    final startingUnits = state.hexes
        .where((tile) => tile.owner == 0 && tile.unit != null)
        .map((tile) => tile.unit!)
        .toList(growable: false);

    GameAi(
      mod: mod,
      engine: GameEngine(mod: mod, state: state),
    ).takeTurn();

    expect(startingUnits, hasLength(16));
    expect(startingUnits.every((unit) => !unit.ready), isTrue);
    expect(
      startingUnits.every(
        (unit) => state.hexes.any((tile) => identical(tile.unit, unit)),
      ),
      isTrue,
    );
  });

  test('a friendly unit bought after movement never re-enters movement', () {
    final state = _friendlyPurchaseState();

    GameAi(
      mod: mod,
      engine: GameEngine(mod: mod, state: state),
    ).takeTurn();

    final bought = state.hexes
        .where((tile) => tile.owner == 0 && tile.unit != null)
        .toList(growable: false);
    expect(bought, hasLength(1));
    expect(bought.single.index, lessThanOrEqualTo(4));
    expect(bought.single.owner, 0);
    expect(state.hexes[5].owner, -1);
  });

  test('unit survival forecast consumes configured upkeep', () {
    final affordable = _upkeepAttackState();
    GameAi(
      mod: mod,
      engine: GameEngine(mod: mod, state: affordable),
    ).takeTurn();

    final expensiveMod = _withUnitUpkeep(mod, const [0, 20, 60, 180, 360]);
    final rejected = _upkeepAttackState();
    GameAi(
      mod: expensiveMod,
      engine: GameEngine(mod: expensiveMod, state: rejected),
    ).takeTurn();

    expect(affordable.hexes[2].owner, 0);
    expect(rejected.hexes[2].owner, -1);
    expect(
      rejected.provinces.firstWhere((province) => province.owner == 0).money,
      10,
    );
  });

  test('a free merge needs survival and diplomacy, not purchase cash', () {
    final ordinary = _mergeState(diplomacy: false);
    GameAi(
      mod: mod,
      engine: GameEngine(mod: mod, state: ordinary),
    ).takeTurn();
    final merged = ordinary.hexes
        .where((tile) => tile.owner == 0 && tile.unit != null)
        .map((tile) => tile.unit!)
        .toList();
    expect(merged, hasLength(1));
    expect(merged.single.strength, 2);

    final peaceful = _mergeState(diplomacy: true);
    GameAi(
      mod: mod,
      engine: GameEngine(mod: mod, state: peaceful),
    ).takeTurn();
    final blocked = peaceful.hexes
        .where((tile) => tile.owner == 0 && tile.unit != null)
        .map((tile) => tile.unit!)
        .toList();
    expect(blocked, hasLength(2));
    expect(
      blocked,
      everyElement(predicate<GameUnit>((unit) => unit.strength == 1)),
    );
  });

  test('Hard uses strength-plus-one rather than Balancer five-turn gate', () {
    final state = _hardForecastState();

    GameAi(
      mod: mod,
      engine: GameEngine(mod: mod, state: state),
    ).takeTurn();

    expect(state.hexes[4].owner, 0);
    expect(state.hexes[4].unit?.strength, 1);
  });

  test('Slay level-four forecast uses the charged 54 upkeep', () {
    final state = _slayBaronForecastState();

    GameAi(
      mod: mod,
      engine: GameEngine(mod: mod, state: state),
    ).takeTurn();

    expect(state.hexes[30].owner, 1);
    expect(
      state.provinces.firstWhere((province) => province.owner == 0).money,
      40,
    );
  });

  test('Classic farm limit applies to extra cost and permits price 92', () {
    final state = _maximumFarmPriceState();

    GameAi(
      mod: mod,
      engine: GameEngine(mod: mod, state: state),
    ).takeTurn();

    expect(state.hexes[41].object, TileObject.farm);
  });

  test('land targeting never crosses a peaceful diplomatic border', () {
    final state = _diplomaticForkState();
    final engine = GameEngine(mod: mod, state: state);
    engine.setDiplomacyStatus(0, 2, DiplomacyStatus.war);

    GameAi(mod: mod, engine: engine).takeTurn();

    expect(state.hexes[2].owner, 1);
    expect(state.hexes[3].owner, 1);
    expect(state.hexes[4].owner, 0);
  });

  test('HD diplomacy runs after the complete land phase', () {
    final state = _diplomacyAfterLandState();
    final engine = GameEngine(mod: mod, state: state);
    engine.setDiplomacyStatus(0, 1, DiplomacyStatus.war);
    expect(engine.proposeDiplomacy(1, 0, DiplomacyProposalType.peace), isTrue);

    GameAi(mod: mod, engine: engine).takeTurn();

    expect(state.hexes[2].owner, 0);
  });

  test('six personalities resolve official-random ties non-identically', () {
    final personalities = <int>{};
    final destinations = <int>{};
    for (var player = 0; player < 6; player++) {
      final state = _personalityTieState(player);
      final unit = state.hexes[0].unit!;
      final ai = GameAi(
        mod: mod,
        engine: GameEngine(mod: mod, state: state),
      );
      personalities.add(ai.personalityId);

      ai.takeTurn();

      destinations.add(
        state.hexes.firstWhere((tile) => identical(tile.unit, unit)).index,
      );
    }

    expect(personalities, hasLength(6));
    expect(destinations.length, greaterThan(1));
  });

  test('cooperative and synchronous land turns are state-identical', () async {
    final syncState = _diplomaticForkState();
    final asyncState = GameState.fromJson(syncState.toJson());

    GameAi(
      mod: mod,
      engine: GameEngine(mod: mod, state: syncState),
    ).takeTurn();
    await GameAi(
      mod: mod,
      engine: GameEngine(mod: mod, state: asyncState),
    ).takeTurnAsync();

    expect(asyncState.toJson(), syncState.toJson());
  });

  test('Hard takes an exposed enemy capital before an ordinary farm', () {
    final state = _capitalChoiceState();

    GameAi(
      mod: mod,
      engine: GameEngine(mod: mod, state: state),
    ).takeTurn();

    expect(state.hexes[3].owner, 0);
    expect(state.hexes[2].owner, 1);
  });

  test('cooperative Hard turn stays bounded on a huge generated map', () async {
    final state = MapGenerator(mod).generate(
      const GameConfig(
        mapSize: MapSize.huge,
        playerCount: 8,
        humanCount: 0,
        seed: 81831,
        difficulty: AiDifficulty.hard,
        treePercent: 50,
        diplomacy: true,
      ),
    );
    final stopwatch = Stopwatch()..start();

    await GameAi(
      mod: mod,
      engine: GameEngine(mod: mod, state: state),
    ).takeTurnAsync();

    stopwatch.stop();
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 5)));
  });

  test('15-color giant AI round stays bounded', () async {
    final state = MapGenerator(mod).generate(
      const GameConfig(
        mapSize: MapSize.giant,
        playerCount: 15,
        humanCount: 1,
        seed: 83115,
        difficulty: AiDifficulty.hard,
        treePercent: 50,
        diplomacy: true,
      ),
    );
    final engine = GameEngine(mod: mod, state: state);
    final land = state.hexes.where((tile) => tile.active).toList();
    final minQ = land.map((tile) => tile.q).reduce((a, b) => a < b ? a : b);
    final maxQ = land.map((tile) => tile.q).reduce((a, b) => a > b ? a : b);
    final width = maxQ - minQ + 1;
    for (final tile in land) {
      tile.owner = ((tile.q - minQ) * 15 ~/ width).clamp(0, 14);
      tile.object = TileObject.none;
      tile.unit = null;
    }
    engine.rebuildProvinces();
    for (final province in state.provinces) {
      province.money = 2000;
      for (final tileIndex in province.tiles.take(30)) {
        final tile = state.hexes[tileIndex];
        tile.unit = GameUnit(
          strength: 1,
          owner: province.owner,
          homeProvinceId: province.id,
        );
      }
    }
    state.turn = 1;
    final stopwatch = Stopwatch()..start();
    var completedTurns = 0;

    while (!state.currentPlayerIsHuman &&
        state.winner == null &&
        completedTurns < 15) {
      await GameAi(
        mod: mod,
        engine: engine,
      ).takeTurnAsync(yieldBeforeWork: completedTurns == 0);
      completedTurns++;
    }

    stopwatch.stop();
    // Kept in the failure message so a regression reports the real round cost.
    expect(
      stopwatch.elapsed,
      lessThan(const Duration(seconds: 3)),
      reason: '14 AI turns took ${stopwatch.elapsedMilliseconds} ms',
    );
    expect(completedTurns, 14);
    expect(state.turn, 0);
  });
}

GameState _capitalChoiceState() {
  final hexes = <HexTile>[
    HexTile(
      index: 0,
      q: 0,
      r: 0,
      active: true,
      owner: 0,
      unit: GameUnit(strength: 2),
      neighbors: const [1, 2, 3],
    ),
    HexTile(
      index: 1,
      q: -1,
      r: 0,
      active: true,
      owner: 0,
      object: TileObject.town,
      neighbors: const [0],
    ),
    HexTile(
      index: 2,
      q: 1,
      r: 0,
      active: true,
      owner: 1,
      object: TileObject.farm,
      neighbors: const [0, 3],
    ),
    HexTile(
      index: 3,
      q: 0,
      r: 1,
      active: true,
      owner: 1,
      object: TileObject.town,
      neighbors: const [0, 2],
    ),
  ];
  return GameState(
    config: const GameConfig(
      playerCount: 2,
      humanCount: 0,
      seed: 8183,
      difficulty: AiDifficulty.hard,
    ),
    modId: 'classic_steppe',
    width: 2,
    height: 2,
    hexes: hexes,
    provinces: [
      Province(id: 1, owner: 0, tiles: const [0, 1], money: 0, capital: 1),
      Province(id: 2, owner: 1, tiles: const [2, 3], money: 0, capital: 3),
    ],
    turn: 0,
    round: 1,
    rngState: 1,
    nextProvinceId: 3,
  );
}

GameState _mergeState({required bool diplomacy}) {
  final hexes = _linearHexes(<int>[...List<int>.filled(12, 0), -1, 1, 1]);
  hexes[12].active = false;
  hexes[0].object = TileObject.town;
  for (var index = 1; index <= 9; index++) {
    hexes[index].object = TileObject.farm;
  }
  hexes[10].unit = GameUnit(strength: 1);
  hexes[11].unit = GameUnit(strength: 1);
  hexes[13].object = TileObject.town;
  return GameState(
    config: GameConfig(
      playerCount: 2,
      humanCount: 0,
      seed: 53,
      difficulty: AiDifficulty.easy,
      diplomacy: diplomacy,
    ),
    modId: 'classic_steppe',
    width: hexes.length,
    height: 1,
    hexes: hexes,
    provinces: [
      Province(
        id: 1,
        owner: 0,
        tiles: [for (var index = 0; index < 12; index++) index],
        money: 0,
        capital: 0,
      ),
      Province(id: 2, owner: 1, tiles: const [13, 14], money: 0, capital: 13),
    ],
    turn: 0,
    round: 1,
    rngState: 1,
    nextProvinceId: 3,
  );
}

GameState _hardForecastState() {
  final hexes = _linearHexes(<int>[0, 0, 0, 0, -1, -1, 1, 1]);
  hexes[0].object = TileObject.town;
  hexes[1].object = TileObject.strongTower;
  hexes[6].object = TileObject.town;
  return GameState(
    config: const GameConfig(
      playerCount: 2,
      humanCount: 0,
      seed: 59,
      difficulty: AiDifficulty.normal,
    ),
    modId: 'classic_steppe',
    width: hexes.length,
    height: 1,
    hexes: hexes,
    provinces: [
      Province(
        id: 1,
        owner: 0,
        tiles: const [0, 1, 2, 3],
        money: 10,
        capital: 0,
      ),
      Province(id: 2, owner: 1, tiles: const [6, 7], money: 0, capital: 6),
    ],
    turn: 0,
    round: 1,
    rngState: 1,
    nextProvinceId: 3,
  );
}

GameState _slayBaronForecastState() {
  final owners = <int>[...List<int>.filled(30, 0), 1, 1];
  final hexes = _linearHexes(owners);
  hexes[0].object = TileObject.town;
  for (var index = 1; index < 30; index++) {
    // Farms are inert blockers under Slay and keep this forecast fixture from
    // spending its treasury on towers before evaluating a level-four attack.
    hexes[index].object = TileObject.farm;
  }
  hexes[30].object = TileObject.strongTower;
  hexes[31].object = TileObject.town;
  return GameState(
    config: const GameConfig(
      playerCount: 2,
      humanCount: 0,
      seed: 61,
      difficulty: AiDifficulty.normal,
      slayRules: true,
    ),
    modId: 'classic_steppe',
    width: hexes.length,
    height: 1,
    hexes: hexes,
    provinces: [
      Province(
        id: 1,
        owner: 0,
        tiles: [for (var index = 0; index < 30; index++) index],
        money: 40,
        capital: 0,
      ),
      Province(id: 2, owner: 1, tiles: const [30, 31], money: 0, capital: 31),
    ],
    turn: 0,
    round: 1,
    rngState: 1,
    nextProvinceId: 3,
  );
}

GameState _maximumFarmPriceState() {
  final hexes = _linearHexes(<int>[...List<int>.filled(42, 0), -1, 1, 1]);
  hexes[0].object = TileObject.town;
  for (var index = 1; index <= 40; index++) {
    hexes[index].object = TileObject.farm;
  }
  hexes[43].object = TileObject.town;
  return GameState(
    config: const GameConfig(
      playerCount: 2,
      humanCount: 0,
      seed: 67,
      difficulty: AiDifficulty.easy,
    ),
    modId: 'classic_steppe',
    width: hexes.length,
    height: 1,
    hexes: hexes,
    provinces: [
      Province(
        id: 1,
        owner: 0,
        tiles: [for (var index = 0; index < 42; index++) index],
        money: 92,
        capital: 0,
      ),
      Province(id: 2, owner: 1, tiles: const [43, 44], money: 0, capital: 43),
    ],
    turn: 0,
    round: 1,
    rngState: 1,
    nextProvinceId: 3,
  );
}

GameState _diplomacyAfterLandState() {
  final hexes = _linearHexes(<int>[0, 0, 1, 1, 1]);
  hexes[0].object = TileObject.town;
  hexes[1].unit = GameUnit(strength: 4);
  hexes[4].object = TileObject.town;
  return GameState(
    config: const GameConfig(
      playerCount: 2,
      humanCount: 0,
      seed: 71,
      difficulty: AiDifficulty.hard,
      diplomacy: true,
    ),
    modId: 'classic_steppe',
    width: hexes.length,
    height: 1,
    hexes: hexes,
    provinces: [
      Province(id: 1, owner: 0, tiles: const [0, 1], money: 0, capital: 0),
      Province(id: 2, owner: 1, tiles: const [2, 3, 4], money: 0, capital: 4),
    ],
    turn: 0,
    round: 1,
    rngState: 1,
    nextProvinceId: 3,
  );
}

GameState _largeEmpireState() {
  final hexes = <HexTile>[
    for (var index = 0; index < 52; index++)
      HexTile(
        index: index,
        q: index,
        r: 0,
        active: index != 49,
        owner: index < 49
            ? 0
            : index == 49
            ? -1
            : 1,
        neighbors: [if (index > 0) index - 1, if (index < 51) index + 1],
      ),
  ];
  hexes[0].object = TileObject.town;
  hexes[50].object = TileObject.town;
  for (var index = 2; index < 49; index += 3) {
    hexes[index].unit = GameUnit(strength: 1);
  }
  return GameState(
    config: const GameConfig(
      playerCount: 2,
      humanCount: 0,
      seed: 73,
      difficulty: AiDifficulty.veryEasy,
    ),
    modId: 'classic_steppe',
    width: 52,
    height: 1,
    hexes: hexes,
    provinces: [
      Province(
        id: 1,
        owner: 0,
        tiles: [for (var index = 0; index < 49; index++) index],
        money: 0,
        capital: 0,
      ),
      Province(id: 2, owner: 1, tiles: const [50, 51], money: 0, capital: 50),
    ],
    turn: 0,
    round: 1,
    rngState: 1,
    nextProvinceId: 3,
  );
}

GameState _friendlyPurchaseState() {
  final hexes = _linearHexes(<int>[0, 0, 0, 0, 0, -1, 1, 1]);
  hexes[0].object = TileObject.town;
  hexes[6].object = TileObject.town;
  return GameState(
    config: const GameConfig(
      playerCount: 2,
      humanCount: 0,
      seed: 19,
      difficulty: AiDifficulty.veryEasy,
    ),
    modId: 'classic_steppe',
    width: hexes.length,
    height: 1,
    hexes: hexes,
    provinces: [
      Province(
        id: 1,
        owner: 0,
        tiles: const [0, 1, 2, 3, 4],
        money: 10,
        capital: 0,
      ),
      Province(id: 2, owner: 1, tiles: const [6, 7], money: 0, capital: 6),
    ],
    turn: 0,
    round: 1,
    rngState: 1,
    nextProvinceId: 3,
  );
}

GameState _upkeepAttackState() {
  final hexes = _linearHexes(<int>[0, 0, -1, -1, 1, 1]);
  hexes[0].object = TileObject.town;
  hexes[4].object = TileObject.town;
  return GameState(
    config: const GameConfig(
      playerCount: 2,
      humanCount: 0,
      seed: 31,
      difficulty: AiDifficulty.normal,
    ),
    modId: 'classic_steppe',
    width: hexes.length,
    height: 1,
    hexes: hexes,
    provinces: [
      Province(id: 1, owner: 0, tiles: const [0, 1], money: 10, capital: 0),
      Province(id: 2, owner: 1, tiles: const [4, 5], money: 0, capital: 4),
    ],
    turn: 0,
    round: 1,
    rngState: 1,
    nextProvinceId: 3,
  );
}

GameState _diplomaticForkState() {
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
      unit: GameUnit(strength: 2),
      neighbors: const [0, 2, 4],
    ),
    HexTile(
      index: 2,
      q: 2,
      r: -1,
      active: true,
      owner: 1,
      neighbors: const [1, 3],
    ),
    HexTile(
      index: 3,
      q: 3,
      r: -1,
      active: true,
      owner: 1,
      object: TileObject.town,
      neighbors: const [2],
    ),
    HexTile(
      index: 4,
      q: 2,
      r: 0,
      active: true,
      owner: 2,
      neighbors: const [1, 5],
    ),
    HexTile(
      index: 5,
      q: 3,
      r: 0,
      active: true,
      owner: 2,
      object: TileObject.town,
      neighbors: const [4],
    ),
  ];
  return GameState(
    config: const GameConfig(
      playerCount: 3,
      humanCount: 0,
      seed: 43,
      difficulty: AiDifficulty.hard,
      diplomacy: true,
    ),
    modId: 'classic_steppe',
    width: 4,
    height: 2,
    hexes: hexes,
    provinces: [
      Province(id: 1, owner: 0, tiles: const [0, 1], money: 100, capital: 0),
      Province(id: 2, owner: 1, tiles: const [2, 3], money: 0, capital: 3),
      Province(id: 3, owner: 2, tiles: const [4, 5], money: 0, capital: 5),
    ],
    turn: 0,
    round: 1,
    rngState: 1,
    nextProvinceId: 4,
  );
}

GameState _personalityTieState(int player) {
  final hexes = <HexTile>[
    HexTile(
      index: 0,
      q: 0,
      r: 0,
      active: true,
      owner: player,
      unit: GameUnit(strength: 1),
      neighbors: const [1, 2, 3, 4],
    ),
    HexTile(
      index: 1,
      q: 1,
      r: 0,
      active: true,
      owner: player,
      object: TileObject.town,
      neighbors: const [0],
    ),
    HexTile(
      index: 2,
      q: 0,
      r: 1,
      active: true,
      owner: player,
      neighbors: const [0],
    ),
    HexTile(
      index: 3,
      q: -1,
      r: 1,
      active: true,
      owner: player,
      neighbors: const [0],
    ),
    HexTile(
      index: 4,
      q: -1,
      r: 0,
      active: true,
      owner: player,
      neighbors: const [0],
    ),
  ];
  final provinces = <Province>[
    Province(
      id: 1,
      owner: player,
      tiles: const [0, 1, 2, 3, 4],
      money: 0,
      capital: 1,
    ),
  ];
  for (var owner = 0; owner < 6; owner++) {
    final first = hexes.length;
    hexes.addAll([
      HexTile(
        index: first,
        q: 10 + owner * 2,
        r: 0,
        active: true,
        owner: owner,
        object: TileObject.town,
        neighbors: [first + 1],
      ),
      HexTile(
        index: first + 1,
        q: 11 + owner * 2,
        r: 0,
        active: true,
        owner: owner,
        neighbors: [first],
      ),
    ]);
    provinces.add(
      Province(
        id: owner + 2,
        owner: owner,
        tiles: [first, first + 1],
        money: 0,
        capital: first,
      ),
    );
  }
  return GameState(
    config: const GameConfig(
      playerCount: 6,
      humanCount: 0,
      seed: 41,
      difficulty: AiDifficulty.veryEasy,
    ),
    modId: 'classic_steppe',
    width: 22,
    height: 2,
    hexes: hexes,
    provinces: provinces,
    turn: player,
    round: 1,
    rngState: 1,
    nextProvinceId: 8,
  );
}

List<HexTile> _linearHexes(List<int> owners) => [
  for (var index = 0; index < owners.length; index++)
    HexTile(
      index: index,
      q: index,
      r: 0,
      active: owners[index] >= -1,
      owner: owners[index],
      neighbors: [
        if (index > 0) index - 1,
        if (index + 1 < owners.length) index + 1,
      ],
    ),
];

GameMod _withUnitUpkeep(GameMod source, List<int> unitUpkeep) => GameMod(
  id: source.id,
  name: source.name,
  title: source.title,
  version: source.version,
  palette: source.palette,
  neutralColor: source.neutralColor,
  waterColor: source.waterColor,
  rules: GameRules(
    unitMoveLimit: source.rules.unitMoveLimit,
    unitPricePerLevel: source.rules.unitPricePerLevel,
    farmBasePrice: source.rules.farmBasePrice,
    farmPriceGrowth: source.rules.farmPriceGrowth,
    towerPrice: source.rules.towerPrice,
    strongTowerPrice: source.rules.strongTowerPrice,
    farmIncome: source.rules.farmIncome,
    treeCutReward: source.rules.treeCutReward,
    unitUpkeep: unitUpkeep,
    towerUpkeep: source.rules.towerUpkeep,
    strongTowerUpkeep: source.rules.strongTowerUpkeep,
    port1Price: source.rules.port1Price,
    port2Price: source.rules.port2Price,
    boat1Price: source.rules.boat1Price,
    boat2Price: source.rules.boat2Price,
    port1Upkeep: source.rules.port1Upkeep,
    port2Upkeep: source.rules.port2Upkeep,
    boat1Upkeep: source.rules.boat1Upkeep,
    boat2Upkeep: source.rules.boat2Upkeep,
    boatMoveLimit: source.rules.boatMoveLimit,
    portLaunchRadius: source.rules.portLaunchRadius,
    boat1Capacity: source.rules.boat1Capacity,
    boat2Capacity: source.rules.boat2Capacity,
    seaFortPrice: source.rules.seaFortPrice,
    seaFortUpkeep: source.rules.seaFortUpkeep,
    navalSupplyUpkeep: source.rules.navalSupplyUpkeep,
    artilleryCosts: source.rules.artilleryCosts,
    artilleryUpkeep: source.rules.artilleryUpkeep,
    artilleryAmmoCapacity: source.rules.artilleryAmmoCapacity,
    artilleryShotCost: source.rules.artilleryShotCost,
    initialMoney: source.rules.initialMoney,
    pineSpreadChance: source.rules.pineSpreadChance,
    palmSpreadChance: source.rules.palmSpreadChance,
  ),
);
