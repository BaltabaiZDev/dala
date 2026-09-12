import 'package:antiyoy_self/src/game/game_ai.dart';
import 'package:antiyoy_self/src/game/game_engine.dart';
import 'package:antiyoy_self/src/game/models.dart';
import 'package:antiyoy_self/src/modding/game_mod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'AI proposes a fair split and the next AI participant accepts it',
    () async {
      final mod = await GameMod.loadDefault();
      final state = _conferenceState();
      final engine = GameEngine(mod: mod, state: state);

      GameAi(mod: mod, engine: engine).takeTurn();

      expect(state.turn, 2);
      final proposal = state.peaceConferences.single;
      expect(proposal.revision, 1);
      expect(proposal.proposer, 1);
      expect(proposal.acceptedBy, [1]);
      expect(proposal.allocations[1], [6]);
      expect(proposal.allocations[2], [7]);

      GameAi(mod: mod, engine: engine).takeTurn();

      expect(state.peaceConferences, isEmpty);
      expect(state.hexes[6].coalitionClaim, isNull);
      expect(state.hexes[7].coalitionClaim, isNull);
      expect(state.hexes[6].owner, 1);
      expect(state.hexes[7].owner, 2);
    },
  );
}

GameState _conferenceState() {
  final hexes = <HexTile>[
    for (var index = 0; index < 8; index++)
      HexTile(
        index: index,
        q: index,
        r: 0,
        active: true,
        owner: index < 2
            ? 0
            : index < 4
            ? 1
            : index < 6
            ? 2
            : 1,
        object: index == 0 || index == 2 || index == 4
            ? TileObject.town
            : TileObject.none,
        neighbors: [if (index > 0) index - 1, if (index + 1 < 8) index + 1],
      ),
  ];
  for (final index in const [6, 7]) {
    hexes[index].coalitionClaim = const CoalitionClaim(
      campaignId: 9,
      originalOwner: 0,
      members: [1, 2],
      captor: 1,
      contributors: [1, 2],
      settlementValue: 25,
      conferenceId: 1,
    );
  }
  return GameState(
    config: const GameConfig(
      playerCount: 3,
      humanCount: 1,
      diplomacy: true,
      difficulty: AiDifficulty.veryEasy,
      seed: 7,
    ),
    modId: 'classic_steppe',
    width: 8,
    height: 1,
    hexes: hexes,
    provinces: [
      Province(id: 1, owner: 0, tiles: const [0, 1], money: 0, capital: 0),
      Province(id: 2, owner: 1, tiles: const [2, 3], money: 0, capital: 2),
      Province(id: 3, owner: 2, tiles: const [4, 5], money: 0, capital: 4),
    ],
    turn: 1,
    round: 1,
    rngState: 1,
    nextProvinceId: 4,
    nextPeaceConferenceId: 2,
    peaceConferences: [
      PeaceConference(
        id: 1,
        sourceCampaignId: 9,
        originalOwner: 0,
        claimTiles: const [6, 7],
        participants: const [1, 2],
        openedRound: 1,
        deadlineRound: 6,
        tileValues: const {6: 25, 7: 25},
        contributionPoints: const {1: 25, 2: 25},
      ),
    ],
  );
}
