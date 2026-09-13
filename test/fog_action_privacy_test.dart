import 'dart:ui' as ui;
import 'package:antiyoy_self/src/game/game_controller.dart';
import 'package:antiyoy_self/src/modding/game_mod.dart';
import 'package:antiyoy_self/src/persistence/save_repository.dart';
import 'package:antiyoy_self/src/ui/hex_board.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'mod_types_test.dart' show modFixture;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late GameMod mod;
  setUpAll(() async => mod = await GameMod.loadDefault());

  test('action shading never paints hidden land or hidden water', () async {
    final state = modFixture(mod).state;
    final controller = GameController(
      mod: mod,
      state: state,
      saves: SaveRepository(),
      autosaveEnabled: false,
      authoritativeSimulation: false,
    );
    final land = controller.visibleTileIndices;
    final water = controller.visibleWaterCellIndices;
    final recorder = ui.PictureRecorder();
    final size = HexBoard.canvasSize(state);
    HexActionMaskPainter(
      state: state,
      targets: {land.first},
      waterTargets: {},
      selected: null,
      selectedWater: null,
      visibleTiles: land,
      visibleWaterCells: water,
    ).paint(Canvas(recorder), size);
    final picture = recorder.endRecording();
    final image = await picture.toImage(size.width.ceil(), size.height.ceil());
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    int alpha(int tile) {
      final p = HexBoard.centerOf(state.hexes[tile]);
      return bytes.getUint8(
        (p.dy.round() * image.width + p.dx.round()) * 4 + 3,
      );
    }

    final hiddenLand = state.hexes.where(
      (t) => t.active && !land.contains(t.index),
    );
    expect(hiddenLand, isNotEmpty);
    for (final tile in hiddenLand) {
      expect(alpha(tile.index), 0);
    }
    for (final cell in state.waterCells.where(
      (c) => !water.contains(c.index),
    )) {
      for (final tile in cell.tiles) {
        expect(alpha(tile), 0);
      }
    }
    expect(land.where((i) => i != land.first).any((i) => alpha(i) > 0), isTrue);
    image.dispose();
    picture.dispose();
    controller.dispose();
  });

  test(
    'last LAN player may act without changing host fog in any frame',
    () async {
      final state = modFixture(mod).state..turn = 1;
      final controller = GameController(
        mod: mod,
        state: state,
        localPlayer: 0,
        networkRole: GameNetworkRole.host,
        saves: SaveRepository(),
        autosaveEnabled: false,
        authoritativeSimulation: false,
      );
      final hidden = state.hexes.firstWhere((t) => t.owner == 1).index;
      final own = Set<int>.of(controller.visibleTileIndices);
      var frames = 0;
      void inspect() {
        frames++;
        expect(controller.visibilityPlayer, 0);
        expect(controller.fogActive, isTrue);
        expect(controller.visibleTileIndices, own);
        expect(controller.visibleTileIndices, isNot(contains(hidden)));
      }

      controller.addListener(inspect);
      await controller.runAsNetworkPlayer(1, () async {
        expect(
          controller.isTileVisible(hidden),
          isTrue,
          reason: 'The command actor can act on its own visible land',
        );
        inspect();
        await controller.finishTurn();
      });
      expect(frames, greaterThan(1));
      expect(state.round, 1);
      expect(state.turn, 0);
      controller.removeListener(inspect);
      state.provinces.removeWhere((p) => p.owner == 0);
      for (final tile in state.hexes.where((t) => t.owner == 0)) {
        tile.owner = -1;
      }
      expect(controller.fogActive, isTrue);
      expect(
        controller.visibleTileIndices,
        isEmpty,
        reason: 'Elimination must not silently reveal the whole world',
      );
      controller.dispose();
    },
  );
}
