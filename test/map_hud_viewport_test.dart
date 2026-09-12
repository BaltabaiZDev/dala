import 'dart:math' as math;

import 'package:antiyoy_self/src/game/game_controller.dart';
import 'package:antiyoy_self/src/game/game_engine.dart';
import 'package:antiyoy_self/src/game/map_generator.dart';
import 'package:antiyoy_self/src/game/models.dart';
import 'package:antiyoy_self/src/modding/game_mod.dart';
import 'package:antiyoy_self/src/persistence/save_repository.dart';
import 'package:antiyoy_self/src/ui/game_screen.dart';
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
  test('HUD resizing reveals a clipped cell without changing zoom', () {
    const bounds = MapCameraBounds(
      viewport: Size(390, 652),
      canvas: Size(3000, 5000),
      minScale: .13,
    );
    final initial = MapCameraBounds.matrix(.8, const Offset(-500, -3000));
    const point = Offset(860, 4700);
    final next = bounds.revealPoint(initial, point);
    expect(MapCameraBounds.scaleOf(next), .8);
    final screen = MatrixUtils.transformPoint(next, point);
    expect(screen.dy, lessThanOrEqualTo(616));
    expect(next.entry(0, 3), initial.entry(0, 3));
    expect(bounds.revealPoint(next, point).storage, next.storage);
  });

  for (final slay in [false, true]) {
    testWidgets(
      'bottom cell remains visible and buildable with ${slay ? 'Slay' : 'two-row'} HUD',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        SharedPreferences.setMockInitialValues({});
        final state = MapGenerator(mod).createBlank(
          GameConfig(
            mapSize: MapSize.small,
            playerCount: 2,
            humanCount: 2,
            slayRules: slay,
          ),
        );
        final bottom = state.hexes.where((t) => t.inWorld).reduce((a, b) {
          final ay = HexBoard.centerOf(a).dy;
          final by = HexBoard.centerOf(b).dy;
          return by > ay ||
                  (ay == by &&
                      (b.q - state.width / 2).abs() <
                          (a.q - state.width / 2).abs())
              ? b
              : a;
        });
        final neighbor = state
            .hexes[bottom.neighbors.firstWhere((i) => state.hexes[i].inWorld)];
        for (final tile in [bottom, neighbor]) {
          tile
            ..active = true
            ..owner = 0
            ..object = TileObject.none;
        }
        GameEngine(mod: mod, state: state).rebuildProvinces();
        state.provinces.first.money = 100;
        final controller = GameController(
          mod: mod,
          state: state,
          saves: SaveRepository(),
          autosaveEnabled: false,
          authoritativeSimulation: false,
        );
        await tester.pumpWidget(
          MaterialApp(home: GameScreen(controller: controller)),
        );
        await tester.pump(const Duration(milliseconds: 600));
        var map = tester.widget<MapViewport>(find.byType(MapViewport));
        map.onInteractionStart?.call();
        final point = HexBoard.centerOf(bottom);
        // Start with a bottom cell visible in the area which the HUD will occupy.
        map.transformationController.value =
            MapCameraBounds(
              viewport: const Size(390, 844),
              canvas: map.canvasSize,
              minScale: map.minScale,
            ).constrain(
              MapCameraBounds.matrix(1.1, const Offset(195, 800) - point * 1.1),
            );
        controller.tapTile(bottom.index);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        map = tester.widget<MapViewport>(find.byType(MapViewport));
        final rect = tester.getRect(find.byType(MapViewport));
        expect(rect.height, 844 - (slay ? 60 : 92));
        final panelTop = tester
            .getTopLeft(find.byKey(const ValueKey('ground-construction')))
            .dy;
        expect(rect.bottom, closeTo(panelTop, .01));

        for (final zoom in [map.minScale, .8, 1.6, 2.6]) {
          final bounds = MapCameraBounds(
            viewport: rect.size,
            canvas: map.canvasSize,
            minScale: map.minScale,
          );
          map.transformationController.value = bounds.constrain(
            MapCameraBounds.matrix(
              zoom,
              Offset(rect.width / 2 - point.dx * zoom, -100000),
            ),
          );
          await tester.pump();
          final local = MatrixUtils.transformPoint(
            map.transformationController.value,
            point,
          );
          expect(local.dy + math.min(20, 26 * zoom), lessThan(panelTop));
          expect(local.dy, greaterThan(40));
        }
        // An actual tap on the cell above the panel reaches the game input.
        final target = bottom.object == TileObject.none ? bottom : neighbor;
        controller.setTool(PlayerTool.unit1);
        await tester.pump();
        final targetPoint = HexBoard.centerOf(target);
        map.transformationController.value = MapCameraBounds(
          viewport: rect.size,
          canvas: map.canvasSize,
          minScale: map.minScale,
        ).revealPoint(map.transformationController.value, targetPoint);
        await tester.pump();
        await tester.tapAt(
          rect.topLeft +
              MatrixUtils.transformPoint(
                map.transformationController.value,
                targetPoint,
              ),
        );
        await tester.pump();
        expect(target.unit?.owner, 0);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
