import 'dart:ui' as ui;
import 'package:antiyoy_self/src/game/game_controller.dart';
import 'package:antiyoy_self/src/game/map_generator.dart';
import 'package:antiyoy_self/src/game/models.dart';
import 'package:antiyoy_self/src/modding/game_mod.dart';
import 'package:antiyoy_self/src/persistence/save_repository.dart';
import 'package:antiyoy_self/src/ui/game_screen.dart';
import 'package:antiyoy_self/src/ui/hex_board.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('giant capture immediately changes cached terrain pixels', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final mod = await GameMod.loadDefault();
    final watch = Stopwatch()..start();
    final state = MapGenerator(mod).generate(
      const GameConfig(
        mapSize: MapSize.giant,
        playerCount: 15,
        humanCount: 15,
        startingProvinceCount: 1,
        treePercent: 0,
        seed: 20260903,
      ),
    );
    debugPrint('GIANT_GENERATION ${watch.elapsedMilliseconds}ms');
    final controller = GameController(
      mod: mod,
      state: state,
      saves: SaveRepository(),
      autosaveEnabled: false,
      authoritativeSimulation: false,
    );
    final p = state.provinces.firstWhere((p) => p.owner == 0);
    p.money = 1000;
    final target = p.tiles
        .expand((i) => state.hexes[i].neighbors)
        .firstWhere((i) => state.hexes[i].active && state.hexes[i].owner < 0);
    await tester.pumpWidget(
      MaterialApp(home: GameScreen(controller: controller)),
    );
    await tester.pump();
    HexBoardPainter painter() => tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((w) => w.painter)
        .whereType<HexBoardPainter>()
        .single;
    Future<int> pixel(HexBoardPainter p) async {
      final rec = ui.PictureRecorder();
      final canvas = Canvas(rec);
      final point = HexBoard.centerOf(state.hexes[target]);
      canvas.translate(4 - point.dx, 4 - point.dy + 15);
      p.paint(canvas, HexBoard.canvasSize(state));
      final picture = rec.endRecording();
      final image = await picture.toImage(8, 8);
      final bytes = (await image.toByteData())!.buffer.asUint8List();
      final value = (bytes[144] << 16) | (bytes[145] << 8) | bytes[146];
      image.dispose();
      picture.dispose();
      return value;
    }

    final before = painter();
    final oldPixel = await tester.runAsync(() => pixel(before));
    controller.tapTile(p.capital);
    controller.setTool(PlayerTool.unit1);
    controller.tapTile(target);
    expect(state.hexes[target].owner, 0);
    await tester.pump();
    final after = painter();
    debugPrint(
      'PAINTER same=${identical(before, after)} before=${before.terrainSignature} after=${after.terrainSignature} minus=${(-1).hashCode} zero=${0.hashCode} owner=${after.state.hexes[target].owner}',
    );
    expect(after.terrainSignature, isNot(before.terrainSignature));
    final newPixel = await tester.runAsync(() => pixel(after));
    expect(newPixel, isNot(oldPixel));
    expect(newPixel, mod.palette[0].toARGB32() & 0xffffff);
    await tester.pumpWidget(const SizedBox());
  });
}
