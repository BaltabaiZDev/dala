import 'dart:convert';

import 'package:antiyoy_self/src/game/game_controller.dart';
import 'package:antiyoy_self/src/game/map_generator.dart';
import 'package:antiyoy_self/src/game/models.dart';
import 'package:antiyoy_self/src/modding/game_mod.dart';
import 'package:antiyoy_self/src/persistence/save_repository.dart';
import 'package:antiyoy_self/src/ui/hex_board.dart';
import 'package:antiyoy_self/src/ui/map_viewport.dart';
import 'package:antiyoy_self/src/ui/match_replay.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late GameMod mod;
  setUpAll(() async => mod = await GameMod.loadDefault());

  Future<
    ({
      GameController controller,
      TransformationController camera,
      List<Map<String, dynamic>> frames,
      _ReplaySaves saves,
    })
  >
  mount(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final state = MapGenerator(
      mod,
    ).generate(const GameConfig(playerCount: 2, humanCount: 2, seed: 71));
    final frames = List.generate(6, (index) {
      state.turn = index % 2;
      state.provinces.first.money = 100 + index;
      return state.toJson();
    });
    final saves = _ReplaySaves();
    await tester.pumpWidget(
      MaterialApp(
        home: MatchReplayScreen(mod: mod, saves: saves, frames: frames),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
    final controller = tester
        .widget<HexBoard>(find.byType(HexBoard))
        .controller;
    final camera = tester
        .widget<MapViewport>(find.byType(MapViewport))
        .transformationController;
    camera.value = MapCameraBounds.matrix(1.4, const Offset(-400, -450));
    await tester.pump();
    return (
      controller: controller,
      camera: camera,
      frames: frames,
      saves: saves,
    );
  }

  testWidgets('paused replay accepts drag in both directions and pinch zoom', (
    tester,
  ) async {
    final replay = await mount(tester);
    final before = replay.camera.value.clone();
    final finger = await tester.startGesture(const Offset(140, 330));
    await finger.moveBy(const Offset(30, 30));
    await tester.pump();
    for (var i = 0; i < 8; i++) {
      await finger.moveBy(const Offset(5, 5));
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(
      replay.camera.value.entry(0, 3),
      greaterThan(before.entry(0, 3) + 15),
    );
    expect(
      replay.camera.value.entry(1, 3),
      greaterThan(before.entry(1, 3) + 15),
    );
    final outward = replay.camera.value.clone();
    for (var i = 0; i < 12; i++) {
      await finger.moveBy(const Offset(-7, -7));
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(replay.camera.value.entry(0, 3), lessThan(outward.entry(0, 3) - 15));
    expect(replay.camera.value.entry(1, 3), lessThan(outward.entry(1, 3) - 15));
    await finger.up();

    final zoom = MapCameraBounds.scaleOf(replay.camera.value);
    final first = await tester.startGesture(const Offset(120, 400), pointer: 1);
    final second = await tester.startGesture(
      const Offset(260, 400),
      pointer: 2,
    );
    for (var i = 0; i < 10; i++) {
      await first.moveBy(const Offset(-4, 0));
      await second.moveBy(const Offset(4, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(
      MapCameraBounds.scaleOf(replay.camera.value),
      greaterThan(zoom + .2),
    );
    await second.up();
    await first.up();
    expect(replay.controller.state.turn, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('playing, changing human turns and restart preserve camera', (
    tester,
  ) async {
    final replay = await mount(tester);
    final before = replay.camera.value.clone();
    await tester.tap(find.byTooltip('Ойнату'));
    await tester.pump(const Duration(milliseconds: 660));
    await tester.pump(const Duration(milliseconds: 300));
    expect(replay.controller.state.turn, 1);
    expect(replay.camera.value, before);

    // Keep moving while playback crosses another frame boundary.
    final finger = await tester.startGesture(const Offset(140, 330));
    await finger.moveBy(const Offset(30, 30));
    await tester.pump();
    for (var i = 0; i < 25; i++) {
      await finger.moveBy(const Offset(3, 3));
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(replay.controller.state.turn, 0);
    expect(
      replay.camera.value.entry(0, 3),
      greaterThan(before.entry(0, 3) + 25),
    );
    expect(MapCameraBounds.scaleOf(replay.camera.value), closeTo(1.4, .001));
    await finger.up();
    await tester.tap(find.byTooltip('Пауза'));
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    final panned = replay.camera.value.clone();
    await tester.tap(find.byTooltip('Жылдамдық'));
    await tester.tap(find.byTooltip('Ойнату'));
    await tester.pump(const Duration(milliseconds: 850));
    expect(replay.controller.state.toJson(), replay.frames.last);
    expect(replay.camera.value, panned);
    expect(find.byTooltip('Ойнату'), findsOneWidget);

    await tester.tap(find.byTooltip('Тоқтату'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(replay.controller.state.toJson(), replay.frames.first);
    expect(replay.camera.value, panned);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('replay taps and holds cannot select or edit the saved match', (
    tester,
  ) async {
    final replay = await mount(tester);
    final source = jsonEncode(replay.frames);
    final before = jsonEncode(replay.controller.state.toJson());
    final capital = replay.controller.state.provinces
        .firstWhere((province) => province.owner == 0)
        .capital;
    final tile = replay.controller.state.hexes[capital];
    final viewport = tester.getRect(find.byType(MapViewport));
    final point = HexBoard.centerOf(tile);
    replay.camera.value = MapCameraBounds.matrix(
      1.4,
      viewport.size.center(Offset.zero) - point * 1.4,
    );
    await tester.pump();
    final screenPoint =
        viewport.topLeft +
        MatrixUtils.transformPoint(replay.camera.value, point);
    expect(viewport.contains(screenPoint), isTrue);
    await tester.tapAt(screenPoint);
    await tester.pump();
    expect(replay.controller.selectedTile, isNull);
    final finger = await tester.startGesture(screenPoint);
    await tester.pump(const Duration(milliseconds: 750));
    await finger.up();
    await tester.pump();
    expect(replay.controller.selectedTile, isNull);
    expect(replay.controller.defensePreviewTiles, isEmpty);
    expect(jsonEncode(replay.controller.state.toJson()), before);
    expect(jsonEncode(replay.frames), source);
    expect(replay.saves.saved, isEmpty);

    await tester.tap(find.byTooltip('Осы кадрды сақтау'));
    await tester.pump();
    expect(replay.saves.saved, [replay.frames.first]);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

class _ReplaySaves extends SaveRepository {
  final saved = <Map<String, dynamic>>[];

  @override
  Future<void> save(GameState state) async => saved.add(state.toJson());
}
