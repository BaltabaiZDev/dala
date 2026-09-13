import 'dart:convert';

import 'package:antiyoy_self/src/game/game_controller.dart';
import 'package:antiyoy_self/src/game/models.dart';
import 'package:antiyoy_self/src/modding/game_mod.dart';
import 'package:antiyoy_self/src/persistence/save_repository.dart';
import 'package:antiyoy_self/src/ui/diplomacy_sheet.dart';
import 'package:antiyoy_self/src/ui/diplomacy_route.dart';
import 'package:antiyoy_self/src/ui/hex_board.dart';
import 'package:antiyoy_self/src/ui/game_screen.dart';
import 'package:antiyoy_self/src/ui/map_viewport.dart';
import 'package:antiyoy_self/src/ui/dala_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'diplomacy_social_test.dart' show socialFixture;
import 'render_test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late GameMod mod;
  setUpAll(() async {
    mod = await GameMod.loadDefault();
    await (FontLoader(
      'Dala Sans',
    )..addFont(rootBundle.load('assets/dala/fonts/NotoSans.ttf'))).load();
  });
  testWidgets(
    'territory editing passes gestures to the board and restores the camera',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      await tester.binding.setSurfaceSize(const Size(390, 844));
      final game = GameController(
        mod: mod,
        state: socialFixture(),
        saves: SaveRepository(),
        autosaveEnabled: false,
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        game.dispose();
        await tester.binding.setSurfaceSize(null);
      });
      DiplomacyOffer? draft = const DiplomacyOffer(
        type: DiplomacyExchangeType.lands,
        tiles: [2],
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: DalaTheme.light,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!,
          ),
          home: Scaffold(
            body: Stack(
              children: [
                AnimatedBuilder(
                  animation: game,
                  builder: (_, _) => HexBoard(controller: game),
                ),
                Builder(
                  builder: (context) => TextButton(
                    onPressed: () => showDalaDiplomacyPanel(
                      context,
                      game,
                      Center(
                        child: TextButton(
                          onPressed: () async {
                            final selected = await game.beginTerritorySelection(
                              giver: 0,
                              offer: draft!,
                            );
                            if (selected != null) draft = selected;
                          },
                          child: const Text('Select land'),
                        ),
                      ),
                    ),
                    child: const Text('Diplomacy'),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await waitForMapSprites(tester);
      await tester.pumpAndSettle();
      final board = tester.state(find.byType(HexBoard));
      final view = tester.widget<MapViewport>(find.byType(MapViewport));
      final original = Matrix4.copy(view.transformationController.value);
      await tester.tap(find.text('Diplomacy'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Select land'));
      await tester.pumpAndSettle();
      final beforePan = Matrix4.copy(view.transformationController.value);
      await tester.dragFrom(const Offset(195, 350), const Offset(35, 50));
      await tester.pumpAndSettle();
      expect(view.transformationController.value, isNot(beforePan));
      final point = MatrixUtils.transformPoint(
        view.transformationController.value,
        HexBoard.centerOf(game.state.hexes[3]),
      );
      await tester.tapAt(point);
      await tester.pump();
      expect(game.territorySelection!.tiles, {2, 3});
      await tester.tap(find.byKey(const ValueKey('territory-confirm')));
      await tester.pumpAndSettle();
      expect(draft!.tiles, [2, 3]);
      expect(
        game.state.hexes[3].owner,
        0,
        reason: 'Selecting never transfers ownership',
      );
      expect(tester.state(find.byType(HexBoard)), same(board));
      expect(view.transformationController.value, original);
      await tester.tap(find.text('Select land'));
      await tester.pumpAndSettle();
      game.toggleTerritoryTile(3);
      await tester.pump();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(draft!.tiles, [
        2,
        3,
      ], reason: 'Back discards the edit and keeps the draft');
      expect(find.text('Select land'), findsOneWidget);
      await tester.tap(find.text('Select land'));
      await tester.pumpAndSettle();
      game.state.turn = 1;
      game.tapTile(6);
      await tester.pumpAndSettle();
      expect(
        game.territorySelection,
        isNull,
        reason: 'A changed LAN turn cancels stale editing',
      );
      expect(draft!.tiles, [2, 3]);
      expect(tester.takeException(), isNull);
    },
  );
  for (final width in [320.0, 390.0, 1280.0]) {
    testWidgets('field HUD keeps pause at the edge and map open at $width', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      await tester.binding.setSurfaceSize(Size(width, 720));
      final controller = GameController(
        mod: mod,
        state: socialFixture(),
        saves: SaveRepository(),
        autosaveEnabled: false,
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        controller.dispose();
        await tester.binding.setSurfaceSize(null);
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: DalaTheme.light,
          home: GameScreen(controller: controller, disposeController: false),
        ),
      );
      await waitForMapSprites(tester);
      final status = find.byKey(const ValueKey('field-hud-status'));
      final menu = find.byKey(const ValueKey('field-hud-menu'));
      for (final money in [null, 17, 1000000000]) {
        if (money != null) {
          controller.state.provinces.first.money = money;
          controller.tapTile(0);
          await tester.pump(const Duration(milliseconds: 400));
        }
        expect(tester.getRect(menu).right, closeTo(width - 8, .1));
        expect(tester.getSize(menu).height, greaterThanOrEqualTo(44));
        expect(
          tester.getRect(status).right + 12,
          lessThanOrEqualTo(tester.getRect(menu).left),
        );
        expect(tester.takeException(), isNull);
      }
      await tester.tap(find.bySemanticsLabel('Мәзір'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Жалғастыру'), findsOneWidget);
    });
  }
  testWidgets('incoming gift and demand show the exact land without consent', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.binding.setSurfaceSize(const Size(320, 720));
    final controller = GameController(
      mod: mod,
      state: socialFixture(),
      saves: SaveRepository(),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      await tester.binding.setSurfaceSize(null);
    });
    controller.engine.proposeExchange(
      from: 1,
      to: 0,
      terms: const [
        DiplomacyTerm(
          fromSender: true,
          offer: DiplomacyOffer(
            type: DiplomacyExchangeType.lands,
            tiles: [6, 7],
          ),
        ),
        DiplomacyTerm(
          fromSender: false,
          offer: DiplomacyOffer(
            type: DiplomacyExchangeType.lands,
            tiles: [2, 3],
          ),
        ),
      ],
    );
    final before = jsonEncode(controller.state.toJson());
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: DalaTheme.light,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: Scaffold(
          body: Stack(
            children: [
              AnimatedBuilder(
                animation: controller,
                builder: (context, _) => HexBoard(controller: controller),
              ),
              Builder(
                builder: (context) => TextButton(
                  onPressed: () =>
                      showAntiyoyDiplomacyInbox(context, controller),
                  child: const Text('Inbox'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await waitForMapSprites(tester);
    final originalBoard = tester.state(find.byType(HexBoard));
    await tester.tap(find.text('Inbox'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('↓ Жер'));
    await tester.pumpAndSettle();
    for (final (key, tiles) in [
      ('territory-preview-1-0', {6, 7}),
      ('territory-preview-0-1', {2, 3}),
    ]) {
      final button = find.byKey(ValueKey(key));
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      await waitForMapSprites(tester);
      expect(find.byKey(const ValueKey('territory-cancel')), findsOneWidget);
      expect(find.byKey(const ValueKey('territory-confirm')), findsNothing);
      final overlay =
          tester
                  .widgetList<CustomPaint>(find.byType(CustomPaint))
                  .firstWhere(
                    (w) =>
                        w.painter.runtimeType.toString() ==
                        'HexTerritoryPainter',
                  )
                  .painter
              as dynamic;
      expect(overlay.tiles, tiles);
      expect(tester.state(find.byType(HexBoard)), same(originalBoard));
      final viewport = tester.widget<MapViewport>(find.byType(MapViewport));
      final bounds = Offset.zero & tester.getSize(find.byType(MapViewport));
      for (final index in tiles) {
        final center = MatrixUtils.transformPoint(
          viewport.transformationController.value,
          HexBoard.centerOf(controller.state.hexes[index]),
        );
        expect(
          bounds.contains(center),
          isTrue,
          reason: 'Offered cell must be in view',
        );
      }
      await tester.tapAt(tester.getCenter(find.byType(MapViewport)));
      await tester.pump();
      expect(jsonEncode(controller.state.toJson()), before);
      if (key == 'territory-preview-1-0') {
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('goldens/territory_preview_phone.png'),
        );
      }
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('diplomacy-letter-page')),
        findsOneWidget,
      );
    }
    expect(jsonEncode(controller.state.toJson()), before);
    expect(controller.engine.proposalsFor(0), hasLength(1));
    await tester.ensureVisible(find.text('Қабылдау'));
    await tester.tap(find.text('Қабылдау'));
    await tester.pumpAndSettle();
    expect(controller.engine.proposalsFor(0), isEmpty);
    expect(controller.state.hexes[6].owner, 0);
    expect(controller.state.hexes[2].owner, 1);
    expect(tester.takeException(), isNull);
  });
}
