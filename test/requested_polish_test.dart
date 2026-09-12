import 'dart:math' as math;

import 'package:antiyoy_self/src/game/game_engine.dart';
import 'package:antiyoy_self/src/game/game_controller.dart';
import 'package:antiyoy_self/src/game/map_generator.dart';
import 'package:antiyoy_self/src/game/models.dart';
import 'package:antiyoy_self/src/modding/game_mod.dart';
import 'package:antiyoy_self/src/persistence/save_repository.dart';
import 'package:antiyoy_self/src/ui/game_screen.dart';
import 'package:antiyoy_self/src/ui/hex_board.dart';
import 'package:antiyoy_self/src/ui/map_viewport.dart';
import 'package:antiyoy_self/src/ui/match_replay.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late GameMod mod;

  setUpAll(() async {
    mod = await GameMod.loadDefault();
  });

  test('new map grid renders as offset rows instead of a rhombus', () {
    final state = MapGenerator(
      mod,
    ).createBlank(const GameConfig(mapSize: MapSize.small));
    final firstInTopRow = HexBoard.centerOf(state.hexes.first);
    final lastInTopRow = HexBoard.centerOf(state.hexes[state.width - 1]);
    final rowStep = 30 * 1.7320508075688772;

    expect(
      (firstInTopRow.dy - lastInTopRow.dy).abs(),
      lessThanOrEqualTo(rowStep / 2 + .01),
    );
    expect(state.hexes[state.width].neighbors, contains(state.width + 1));
  });

  test('rectangular renderer resolves negative axial rows as real tiles', () {
    final state = MapGenerator(
      mod,
    ).createBlank(const GameConfig(mapSize: MapSize.small));
    const directions = <(int, int)>[
      (1, 0),
      (1, -1),
      (0, -1),
      (-1, 0),
      (-1, 1),
      (0, 1),
    ];
    final axial = HexBoardPainter.axialIndexFor(state);
    final topRight = state.hexes[state.width - 1];

    expect(topRight.r, isNegative);
    for (final tile in state.hexes) {
      final resolved = <int>{
        for (final direction in directions)
          if (axial[(tile.q + direction.$1, tile.r + direction.$2)]
              case final int neighbor)
            neighbor,
      };
      expect(resolved, tile.neighbors.toSet(), reason: 'tile ${tile.index}');
    }
  });

  test('giant map minimum zoom exposes the complete canvas', () {
    final state = MapGenerator(
      mod,
    ).createBlank(const GameConfig(mapSize: MapSize.giant));
    const viewport = Size(390, 650);
    final scale = HexBoard.minimumScaleFor(viewport, state);
    final canvas = HexBoard.canvasSize(state);

    expect(scale, lessThan(.12));
    expect(canvas.width * scale, lessThanOrEqualTo(viewport.width));
    expect(canvas.height * scale, lessThanOrEqualTo(viewport.height));
    expect(
      math.max(
        canvas.width * scale / viewport.width,
        canvas.height * scale / viewport.height,
      ),
      closeTo(1, .0001),
    );
  });

  test('giant camera cannot shrink or drift beyond the fitted board', () {
    final state = MapGenerator(
      mod,
    ).createBlank(const GameConfig(mapSize: MapSize.giant));
    const viewport = Size(390, 650);
    final canvas = HexBoard.canvasSize(state);
    final minimum = HexBoard.minimumScaleFor(viewport, state);
    final constrained = HexBoard.constrainTransform(
      transform: Matrix4.diagonal3Values(minimum / 3, minimum / 3, 1)
        ..setTranslationRaw(-9000, 7000, 0),
      viewport: viewport,
      canvas: canvas,
      minScale: minimum,
    );
    final scale = math.sqrt(
      math.pow(constrained.entry(0, 0), 2) +
          math.pow(constrained.entry(1, 0), 2),
    );
    final scaledWidth = canvas.width * scale;
    final scaledHeight = canvas.height * scale;

    expect(scale, closeTo(minimum, .000001));
    expect(constrained.entry(0, 3), (viewport.width - scaledWidth) / 2);
    expect(constrained.entry(1, 3), (viewport.height - scaledHeight) / 2);
  });

  test(
    'giant input uses direct axial lookup and scale-aware idle animation',
    () {
      final giant = MapGenerator(
        mod,
      ).createBlank(const GameConfig(mapSize: MapSize.giant));
      final small = MapGenerator(
        mod,
      ).createBlank(const GameConfig(mapSize: MapSize.small));

      for (final tile in giant.hexes) {
        expect(HexBoard.axialCoordinateAt(HexBoard.centerOf(tile)), (
          tile.q,
          tile.r,
        ));
      }
      final fit = HexBoard.minimumScaleFor(const Size(390, 650), giant);
      expect(HexBoard.idlePieceAnimationsEnabledFor(giant), isTrue);
      expect(HexBoard.idlePieceAnimationsEnabledFor(small), isTrue);
      expect(
        HexBoard.idlePieceAnimationsEnabledFor(
          giant,
          currentScale: fit,
          minimumScale: fit,
        ),
        isFalse,
      );
      expect(
        HexBoard.idlePieceAnimationsEnabledFor(
          giant,
          currentScale: fit * 1.3,
          minimumScale: fit,
          wasOverviewSuppressed: true,
        ),
        isFalse,
      );
      expect(
        HexBoard.idlePieceAnimationsEnabledFor(
          giant,
          currentScale: fit * 1.45,
          minimumScale: fit,
          wasOverviewSuppressed: true,
        ),
        isTrue,
      );
      expect(
        HexBoard.idlePieceAnimationsEnabledFor(small, disableAnimations: true),
        isFalse,
      );
    },
  );

  testWidgets('whole-map zoom pauses animation and zooming in resumes it', (
    tester,
  ) async {
    final state = MapGenerator(
      mod,
    ).createBlank(const GameConfig(mapSize: MapSize.giant));
    final controller = GameController(
      mod: mod,
      state: state,
      saves: SaveRepository(),
      autosaveEnabled: false,
      confirmEndTurn: false,
      leftHanded: false,
      sensitivity: 5,
      authoritativeSimulation: false,
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 390,
            height: 650,
            child: HexBoard(controller: controller),
          ),
        ),
      ),
    );
    await tester.pump();
    final fit = HexBoard.minimumScaleFor(const Size(390, 650), state);
    final viewer = tester.widget<MapViewport>(find.byType(MapViewport));
    final transformation = viewer.transformationController;
    expect(controller.overviewAnimationsSuppressed, isFalse);

    transformation.value = Matrix4.diagonal3Values(fit, fit, 1);
    await tester.pump();
    expect(controller.overviewAnimationsSuppressed, isTrue);

    transformation.value = Matrix4.diagonal3Values(
      fit * HexBoard.overviewAnimationResumeRatio,
      fit * HexBoard.overviewAnimationResumeRatio,
      1,
    );
    await tester.pump();
    expect(controller.overviewAnimationsSuppressed, isFalse);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('winner is committed only by end turn', () {
    final state = _oneSurvivorState();
    final engine = GameEngine(mod: mod, state: state);

    expect(state.winner, isNull);
    engine.endTurn();
    expect(state.winner, 0);
  });

  test('war declaration produces a target inbox letter', () {
    final state = _twoPlayerState(diplomacy: true);
    final engine = GameEngine(mod: mod, state: state);

    expect(engine.declareWar(0, 1), isTrue);
    final letters = engine.incomingDiplomacyMessages(1).toList();
    expect(letters, hasLength(1));
    expect(letters.single.from, 0);
    expect(letters.single.text, contains('соғыс жариялады'));
  });

  test('match recorder keeps replay frames and statistics', () {
    final state = _twoPlayerState();
    final recorder = MatchRecorder(state);
    state.provinces.first.money -= 5;
    state.hexes[1].unit = GameUnit(strength: 1);
    recorder.capture(state);
    state.turn = 1;
    recorder.capture(state);

    expect(recorder.frames.length, 2);
    expect(recorder.statistics.moneySpent, 5);
    expect(recorder.statistics.unitsBuilt, 1);
    expect(recorder.statistics.turns, 1);
  });

  test('mod payload round-trips for worker generation', () {
    final restored = GameMod.fromJson(mod.toJson());
    expect(restored.id, mod.id);
    expect(restored.rules.boat2Price, mod.rules.boat2Price);
    expect(
      restored.palette.map((color) => color.toARGB32()),
      mod.palette.map((color) => color.toARGB32()),
    );
  });

  testWidgets(
    'victory opens only after end turn and exposes stats and replay',
    (tester) async {
      final controller = GameController(
        mod: mod,
        state: _oneSurvivorState(),
        saves: SaveRepository(),
        autosaveEnabled: false,
        confirmEndTurn: false,
        authoritativeSimulation: false,
      );
      await tester.pumpWidget(
        MaterialApp(home: GameScreen(controller: controller)),
      );
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('Повтор'), findsNothing);

      await tester.tap(find.bySemanticsLabel('Жүрісті аяқтау'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text('Повтор'), findsOneWidget);
      expect(find.text('Статистика'), findsOneWidget);

      await tester.tap(find.text('Статистика'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.textContaining('Ход жасалды:'), findsOneWidget);
      await tester.tap(find.text('Повтор').last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 450));
      expect(find.byTooltip('Жылдамдық'), findsOneWidget);
      expect(find.byTooltip('Осы кадрды сақтау'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );
}

GameState _oneSurvivorState() {
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
    HexTile(index: 1, q: 1, r: 0, active: true, owner: 0, neighbors: const [0]),
  ];
  return GameState(
    config: const GameConfig(playerCount: 2, humanCount: 2, seed: 1),
    modId: 'classic_steppe',
    width: 2,
    height: 1,
    hexes: hexes,
    provinces: <Province>[
      Province(id: 1, owner: 0, tiles: const [0, 1], money: 10, capital: 0),
    ],
    turn: 0,
    round: 1,
    rngState: 1,
    nextProvinceId: 2,
  );
}

GameState _twoPlayerState({bool diplomacy = false}) {
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
      r: -1,
      active: true,
      owner: 1,
      object: TileObject.town,
      neighbors: const [1, 3],
    ),
    HexTile(
      index: 3,
      q: 3,
      r: -1,
      active: true,
      owner: 1,
      neighbors: const [2],
    ),
  ];
  return GameState(
    config: GameConfig(
      playerCount: 2,
      humanCount: 2,
      seed: 2,
      diplomacy: diplomacy,
    ),
    modId: 'classic_steppe',
    width: 4,
    height: 1,
    hexes: hexes,
    provinces: <Province>[
      Province(id: 1, owner: 0, tiles: const [0, 1], money: 20, capital: 0),
      Province(id: 2, owner: 1, tiles: const [2, 3], money: 20, capital: 2),
    ],
    turn: 0,
    round: 1,
    rngState: 2,
    nextProvinceId: 3,
  );
}
