import 'package:antiyoy_self/src/game/game_controller.dart';
import 'package:antiyoy_self/src/game/models.dart';
import 'package:antiyoy_self/src/modding/game_mod.dart';
import 'package:antiyoy_self/src/persistence/save_repository.dart';
import 'package:antiyoy_self/src/ui/game_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'peace conference stays in inbox and uses one review-compose flow',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      SharedPreferences.setMockInitialValues({});
      final mod = await GameMod.loadDefault();
      final state = _conferenceState();
      final controller = GameController(
        mod: mod,
        state: state,
        saves: SaveRepository(),
        autosaveEnabled: false,
      );

      await tester.pumpWidget(
        MaterialApp(home: GameScreen(controller: controller)),
      );
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byIcon(Icons.mail_outline), findsOneWidget);
      await tester.tap(find.byIcon(Icons.mail_outline));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        find.byKey(const ValueKey('peace-conference-inbox-1')),
        findsOneWidget,
      );
      expect(
        find.text('Тазарту'),
        findsNothing,
        reason: 'a mandatory conference cannot be cleared like ordinary mail',
      );

      await tester.tap(find.byKey(const ValueKey('peace-conference-inbox-1')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        find.byKey(const ValueKey('peace-conference-review')),
        findsOneWidget,
      );
      expect(find.textContaining('Қалғаны: 5 ход'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('peace-conference-counter')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        find.byKey(const ValueKey('peace-conference-compose')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('peace-allocation-row-0')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('peace-allocation-row-1')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('peace-allocation-row-0')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        find.byKey(const ValueKey('peace-allocation-picker-0')),
        findsOneWidget,
      );
      expect(find.text('Жер және теңіз активтері'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('peace-allocation-confirm')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        find.byKey(const ValueKey('peace-conference-compose')),
        findsOneWidget,
      );

      final submit = tester.widget<FilledButton>(
        find.byKey(const ValueKey('peace-allocation-submit')),
      );
      submit.onPressed!();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(state.peaceConferences.single.revision, 1);
      expect(state.peaceConferences.single.acceptedBy, [0]);
      expect(
        find.byKey(const ValueKey('peace-conference-review')),
        findsOneWidget,
      );
    },
  );
}

GameState _conferenceState() {
  final owners = <int>[0, 0, 1, 1, 0, 0, 2, 2];
  final hexes = <HexTile>[
    for (var index = 0; index < owners.length; index++)
      HexTile(
        index: index,
        q: index,
        r: 0,
        active: true,
        owner: owners[index],
        object: index == 0 || index == 2 || index == 6
            ? TileObject.town
            : TileObject.none,
        neighbors: [
          if (index > 0) index - 1,
          if (index + 1 < owners.length) index + 1,
        ],
      ),
  ];
  for (final index in const [4, 5]) {
    hexes[index]
      ..object = TileObject.none
      ..coalitionClaim = const CoalitionClaim(
        campaignId: 1,
        originalOwner: 2,
        members: [0, 1],
        contributors: [0, 1],
        captor: 0,
        settlementValue: 25,
        conferenceId: 1,
      );
  }
  return GameState(
    config: const GameConfig(
      playerCount: 3,
      humanCount: 1,
      diplomacy: true,
      seed: 1,
    ),
    modId: 'classic_steppe',
    width: owners.length,
    height: 1,
    hexes: hexes,
    provinces: [
      Province(id: 1, owner: 0, tiles: [0, 1], money: 100, capital: 0),
      Province(id: 2, owner: 1, tiles: [2, 3], money: 100, capital: 2),
      Province(id: 3, owner: 2, tiles: [6, 7], money: 100, capital: 6),
    ],
    turn: 0,
    round: 1,
    rngState: 1,
    nextProvinceId: 4,
    nextPeaceConferenceId: 2,
    peaceConferences: [
      PeaceConference(
        id: 1,
        sourceCampaignId: 1,
        originalOwner: 2,
        claimTiles: const [4, 5],
        participants: const [0, 1],
        openedRound: 1,
        deadlineRound: 6,
        tileValues: const {4: 25, 5: 25},
        contributionPoints: const {0: 25, 1: 25},
      ),
    ],
  );
}
