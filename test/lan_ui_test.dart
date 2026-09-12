import 'package:antiyoy_self/src/ui/dala_theme.dart';
import 'package:antiyoy_self/src/game/game_controller.dart';
import 'package:antiyoy_self/src/game/models.dart';
import 'package:antiyoy_self/src/modding/game_mod.dart';
import 'package:antiyoy_self/src/persistence/save_repository.dart';
import 'package:antiyoy_self/src/ui/game_screen.dart';
import 'package:antiyoy_self/src/ui/hex_board.dart';
import 'package:antiyoy_self/src/ui/map_viewport.dart';
import 'package:antiyoy_self/src/ui/lan_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late GameMod mod;

  setUpAll(() async {
    final fontLoader = FontLoader('Antiyoy')
      ..addFont(rootBundle.load('assets/classic/font.ttf'));
    await fontLoader.load();
    mod = await GameMod.loadDefault();
  });

  testWidgets('LAN entry renders every host and join control on a phone', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: DalaTheme.light,
        home: LanScreen(
          mod: mod,
          saves: SaveRepository(),
          pickConfig: (_) async => const GameConfig(
            mapSize: MapSize.small,
            playerCount: 2,
            humanCount: 2,
            seed: 7358,
            diplomacy: true,
            fogOfWar: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('LAN ойыны'), findsOneWidget);
    expect(find.byKey(const ValueKey('lan-player-name')), findsOneWidget);
    expect(find.byKey(const ValueKey('lan-address')), findsOneWidget);
    expect(find.byKey(const ValueKey('lan-room-code')), findsOneWidget);
    expect(find.byKey(const ValueKey('lan-host-button')), findsOneWidget);
    expect(find.byKey(const ValueKey('lan-join-button')), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('LAN turn notice and end-turn confirmation use Classic bands', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final state = _separatedPlayersState()..turn = 0;
    final controller = GameController(
      mod: mod,
      state: state,
      saves: SaveRepository(),
      autosaveEnabled: false,
      confirmEndTurn: false,
      localPlayer: 0,
      networkRole: GameNetworkRole.host,
      authoritativeSimulation: false,
    );
    controller.updateNetworkTurnClock(
      enabled: true,
      durationSeconds: 60,
      deadlineEpochMs: DateTime.now()
          .add(const Duration(seconds: 60))
          .millisecondsSinceEpoch,
    );

    await tester.pumpWidget(
      MaterialApp(home: GameScreen(controller: controller)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));
    expect(find.byKey(const ValueKey('lan-your-turn-dialog')), findsOneWidget);
    expect(find.text('Сенің ходың'), findsOneWidget);
    expect(find.byKey(const ValueKey('lan-turn-timer')), findsOneWidget);
    expect(find.text('Хост әрекетті тексеріп жатыр…'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('antiyoy-dialog-confirm')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));
    await tester.tap(find.bySemanticsLabel('Жүрісті аяқтау'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));
    expect(find.byKey(const ValueKey('lan-end-turn-dialog')), findsOneWidget);
    expect(find.text('Осы ходты шынымен аяқтайсыз ба?'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('antiyoy-dialog-cancel')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));
    expect(controller.state.turn, 0);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('LAN camera stays on this device player during a remote turn', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final state = _separatedPlayersState();
    final controller = GameController(
      mod: mod,
      state: state,
      saves: SaveRepository(),
      autosaveEnabled: false,
      localPlayer: 1,
      networkRole: GameNetworkRole.client,
      authoritativeSimulation: false,
    );

    await tester.pumpWidget(
      MaterialApp(home: GameScreen(controller: controller)),
    );
    await tester.pump(const Duration(milliseconds: 600));
    final viewer = tester.widget<MapViewport>(find.byType(MapViewport));
    final transform = viewer.transformationController.value;
    final scale = transform.entry(0, 0);
    final viewport = tester.getSize(find.byType(MapViewport));
    final focusedWorldX = (viewport.width / 2 - transform.entry(0, 3)) / scale;
    final localCenters = HexBoard.playerAssetCenters(state, 1);
    final expectedX =
        localCenters.map((center) => center.dx).reduce((a, b) => a + b) /
        localCenters.length;
    // Finite-board clamping may keep the exact local centroid a fraction of a
    // hex away from viewport center, but it must still frame that device's
    // faction rather than following the remote active player.
    expect(focusedWorldX, closeTo(expectedX, 20));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}

GameState _separatedPlayersState() => GameState(
  config: const GameConfig(playerCount: 2, humanCount: 2, seed: 7358),
  modId: 'classic',
  width: 12,
  height: 1,
  hexes: [
    for (var index = 0; index < 12; index++)
      HexTile(
        index: index,
        q: index,
        r: 0,
        active: index < 2 || index >= 10,
        owner: index < 2 ? 0 : (index >= 10 ? 1 : -1),
        neighbors: [if (index > 0) index - 1, if (index < 11) index + 1],
        object: index == 0 || index == 10 ? TileObject.town : TileObject.none,
      ),
  ],
  provinces: [
    Province(id: 1, owner: 0, tiles: const [0, 1], money: 20, capital: 0),
    Province(id: 2, owner: 1, tiles: const [10, 11], money: 20, capital: 10),
  ],
  turn: 0,
  round: 0,
  rngState: 7358,
  nextProvinceId: 3,
);
