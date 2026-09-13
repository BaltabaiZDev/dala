import 'dart:convert';

import 'package:antiyoy_self/src/game/game_ai.dart';
import 'package:antiyoy_self/src/game/game_controller.dart';
import 'package:antiyoy_self/src/game/game_engine.dart';
import 'package:antiyoy_self/src/game/models.dart';
import 'package:antiyoy_self/src/lan/lan_state_patch.dart';
import 'package:antiyoy_self/src/lan/lan_protocol.dart';
import 'package:antiyoy_self/src/lan/lan_command_dispatcher.dart';
import 'package:antiyoy_self/src/modding/game_mod.dart';
import 'package:antiyoy_self/src/persistence/editor_repository.dart';
import 'package:antiyoy_self/src/persistence/save_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late GameMod mod;
  setUpAll(() async {
    mod = await GameMod.loadDefault();
  });
  GameEngine engine({int humans = 3}) => GameEngine(
    mod: mod,
    state: socialFixture(humans: humans),
  );

  test(
    'relationship is shared bounded and retains reasons without repeated gain',
    () {
      final e = engine();
      e.changeOpinion(1, 0, 15, 'Сынақ');
      e.changeOpinion(1, 0, 15, 'Сынақ');
      expect(e.opinionOf(1, 0), 15);
      expect(e.opinionOf(0, 1), 15);
      e.changeOpinion(1, 0, 200, 'Көмек');
      expect(e.opinionOf(1, 0), 100);
      e.changeOpinion(1, 0, -500, 'Қақтығыс');
      expect(e.opinionOf(1, 0), -100);
      expect(e.state.diplomacySocial.events.last.reason, 'Қақтығыс');
    },
  );

  test(
    'embassy costs ten and action cooldown survives strict save and round ticks',
    () {
      final e = engine();
      expect(e.influenceOpinion(0, 1, improve: true), isTrue);
      expect(e.playerMoney(0), 90);
      expect(e.opinionOf(1, 0), 12);
      expect(e.influenceOpinion(0, 1, improve: false), isFalse);
      final loaded = EditorRepository.decodeStateJson(
        e.state.toJson(),
        rules: mod.rules,
      );
      expect(loaded, isNotNull);
      expect(loaded!.diplomacySocial.actionCooldowns[0][1], 3);
      for (var i = 0; i < 9; i++) {
        e.endTurn();
      }
      expect(e.influenceOpinion(0, 1, improve: false), isTrue);
      expect(e.opinionOf(1, 0), -3);
    },
  );

  test(
    'empty treasury war and black mark prohibit an embassy without mutation',
    () {
      final e = engine();
      e.state.provinces[0].money = 0;
      final before = jsonEncode(e.state.toJson());
      expect(e.influenceOpinion(0, 1, improve: true), isFalse);
      expect(jsonEncode(e.state.toJson()), before);
      e.state.provinces[0].money = 100;
      e.placeBlackMark(0, 1);
      expect(e.influenceOpinion(0, 1, improve: true), isFalse);
      expect(e.declareWar(0, 2), isTrue);
      expect(e.influenceOpinion(0, 2, improve: true), isFalse);
    },
  );

  test(
    'war friendship betrayal and black marks affect opinions with reasons',
    () {
      final e = engine();
      e.improveDiplomacy(0, 1);
      expect(e.opinionOf(1, 0), 20);
      e.worsenDiplomacy(0, 1);
      expect(e.opinionOf(1, 0), -10);
      e.declareWar(0, 1);
      expect(e.opinionOf(1, 0), -55);
      expect(
        e.state.diplomacyMessages.any(
          (m) => m.to == 1 && m.text.contains('соғыс'),
        ),
        isTrue,
      );
    },
  );

  test(
    'three independently directed transfers execute including all one-way',
    () {
      for (final directions in [
        [true, true, true],
        [false, false, false],
        [true, false, true],
      ]) {
        final e = engine();
        final terms = [
          for (var i = 0; i < 3; i++)
            DiplomacyTerm(
              fromSender: directions[i],
              offer: DiplomacyOffer(
                type: DiplomacyExchangeType.money,
                amount: (i + 1) * 10,
              ),
            ),
        ];
        expect(e.proposeExchange(from: 0, to: 1, terms: terms), isTrue);
        final proposal = e.proposalsFor(1).single;
        final roundTrip = DiplomacyProposal.fromJson(
          jsonDecode(jsonEncode(proposal.toJson())) as Map<String, dynamic>,
        );
        expect(roundTrip.effectiveTerms.map((t) => t.fromSender), directions);
        expect(e.resolveDiplomacyProposal(proposal, accept: true), isTrue);
        final net = List.generate(
          3,
          (i) => (directions[i] ? -1 : 1) * (i + 1) * 10,
        ).reduce((a, b) => a + b);
        expect(e.playerMoney(0), 100 + net);
        expect(e.playerMoney(1), 100 - net);
      }
    },
  );

  test('old two-sided proposals and missing social section migrate', () {
    final e = engine();
    e.proposeExchange(
      from: 0,
      to: 1,
      fromOffer: const DiplomacyOffer(
        type: DiplomacyExchangeType.money,
        amount: 20,
      ),
      toOffer: const DiplomacyOffer(
        type: DiplomacyExchangeType.friendship,
        duration: 12,
      ),
    );
    final json = e.state.toJson()..remove('diplomacySocial');
    final restored = EditorRepository.decodeStateJson(json, rules: mod.rules);
    expect(restored, isNotNull);
    expect(restored!.diplomacySocial.opinions[0][1], 0);
    expect(restored.diplomacyProposals.single.effectiveTerms.length, 2);
  });

  test(
    'malformed opinions or directional terms are rejected by strict importer',
    () {
      final e = engine();
      var raw =
          jsonDecode(jsonEncode(e.state.toJson())) as Map<String, dynamic>;
      raw['diplomacySocial']['opinions'][0][1] = 101;
      expect(EditorRepository.decodeStateJson(raw), isNull);
      e.proposeExchange(
        from: 0,
        to: 1,
        terms: [
          const DiplomacyTerm(
            fromSender: true,
            offer: DiplomacyOffer(
              type: DiplomacyExchangeType.money,
              amount: 10,
            ),
          ),
        ],
      );
      raw = jsonDecode(jsonEncode(e.state.toJson())) as Map<String, dynamic>;
      raw['diplomacyProposals'][0]['terms'][0]['fromSender'] = 'yes';
      expect(EditorRepository.decodeStateJson(raw), isNull);
    },
  );

  test(
    'duplicate assets and contradictory relations fail without any mutation',
    () {
      final e = engine();
      final before = jsonEncode(e.state.toJson());
      expect(
        e.proposeExchange(
          from: 0,
          to: 1,
          terms: const [
            DiplomacyTerm(
              fromSender: true,
              offer: DiplomacyOffer(
                type: DiplomacyExchangeType.lands,
                tiles: [3],
              ),
            ),
            DiplomacyTerm(
              fromSender: true,
              offer: DiplomacyOffer(
                type: DiplomacyExchangeType.lands,
                tiles: [3],
              ),
            ),
          ],
        ),
        isFalse,
      );
      expect(
        e.proposeExchange(
          from: 0,
          to: 1,
          terms: const [
            DiplomacyTerm(
              fromSender: true,
              offer: DiplomacyOffer(type: DiplomacyExchangeType.friendship),
            ),
            DiplomacyTerm(
              fromSender: false,
              offer: DiplomacyOffer(
                type: DiplomacyExchangeType.militaryAlliance,
              ),
            ),
          ],
        ),
        isFalse,
      );
      expect(jsonEncode(e.state.toJson()), before);
    },
  );

  test('stale third term rejects the entire agreement and preserves inbox', () {
    final e = engine();
    expect(
      e.proposeExchange(
        from: 0,
        to: 1,
        terms: const [
          DiplomacyTerm(
            fromSender: true,
            offer: DiplomacyOffer(
              type: DiplomacyExchangeType.money,
              amount: 20,
            ),
          ),
          DiplomacyTerm(
            fromSender: false,
            offer: DiplomacyOffer(
              type: DiplomacyExchangeType.money,
              amount: 10,
            ),
          ),
          DiplomacyTerm(
            fromSender: true,
            offer: DiplomacyOffer(
              type: DiplomacyExchangeType.lands,
              tiles: [3],
            ),
          ),
        ],
      ),
      isTrue,
    );
    e.state.hexes[3].owner = 2;
    e.rebuildProvinces();
    final before = jsonEncode(e.state.toJson());
    expect(
      e.resolveDiplomacyProposal(e.proposalsFor(1).single, accept: true),
      isFalse,
    );
    expect(jsonEncode(e.state.toJson()), before);
  });

  test('war condition never enrolls a third country with its own truce', () {
    final e = engine();
    expect(e.formMilitaryAlliance(0, 1), isFalse);
    e.state.diplomacyWarCooldowns[1][2] = 8;
    e.state.diplomacyWarCooldowns[2][1] = 8;
    expect(
      e.proposeExchange(
        from: 0,
        to: 1,
        terms: const [
          DiplomacyTerm(
            fromSender: true,
            offer: DiplomacyOffer(
              type: DiplomacyExchangeType.warDeclaration,
              targetPlayer: 2,
            ),
          ),
        ],
      ),
      isTrue,
    );
    expect(
      e.resolveDiplomacyProposal(e.proposalsFor(1).single, accept: true),
      isTrue,
    );
    expect(e.areEnemies(0, 2), isTrue);
    expect(e.areEnemies(1, 2), isFalse);
    expect(e.diplomacyCooldown(1, 2), 8);
  });

  test('stale friendship cannot turn into an unintended ceasefire', () {
    final e = engine();
    e.proposeDiplomacy(0, 1, DiplomacyProposalType.friendship);
    final proposal = e.proposalsFor(1).single;
    e.state.diplomacyRelations[0][1] = DiplomacyStatus.war;
    e.state.diplomacyRelations[1][0] = DiplomacyStatus.war;
    expect(e.resolveDiplomacyProposal(proposal, accept: true), isFalse);
    expect(e.diplomacyBetween(0, 1), DiplomacyStatus.war);
  });

  test('isolated healthy bots do not send pointless peacetime gifts', () {
    final e = engine(humans: 1);
    final types = <DiplomacyExchangeType>{};
    var sent = 0;
    for (var round = 1; round <= 60; round++) {
      e.state.round = round;
      e.state.turn = 1;
      for (final province in e.state.provinces) {
        province.money = 100;
      }
      GameAi(mod: mod, engine: e).takeTurn();
      expect(e.proposalsFor(0).length, lessThanOrEqualTo(2));
      for (final proposal in e.proposalsFor(0).toList()) {
        types.addAll(proposal.effectiveTerms.map((t) => t.offer.type));
        sent++;
        e.resolveDiplomacyProposal(proposal, accept: true);
      }
    }
    expect(sent, 0);
    expect(types, isEmpty);
  });

  test(
    'repeat trade rewards stay limited after history eviction and reload',
    () {
      final e = engine();
      void trade(GameEngine target) {
        expect(
          target.proposeExchange(
            from: 0,
            to: 1,
            terms: const [
              DiplomacyTerm(
                fromSender: true,
                offer: DiplomacyOffer(
                  type: DiplomacyExchangeType.money,
                  amount: 10,
                ),
              ),
            ],
          ),
          isTrue,
        );
        expect(
          target.resolveDiplomacyProposal(
            target.proposalsFor(1).single,
            accept: true,
          ),
          isTrue,
        );
      }

      trade(e);
      final score = e.opinionOf(1, 0);
      for (var i = 0; i < 170; i++) {
        e.changeOpinion(2, 0, i.isEven ? 1 : -1, 'Test event $i');
      }
      expect(e.state.diplomacySocial.events.length, 160);
      final restored = EditorRepository.decodeStateJson(
        e.state.toJson(),
        rules: mod.rules,
      )!;
      final loaded = GameEngine(mod: mod, state: restored);
      trade(loaded);
      expect(loaded.opinionOf(1, 0), score);
    },
  );

  test(
    'different friendship durations reject instead of silently using first',
    () {
      final e = engine();
      expect(
        e.proposeExchange(
          from: 0,
          to: 1,
          terms: const [
            DiplomacyTerm(
              fromSender: true,
              offer: DiplomacyOffer(
                type: DiplomacyExchangeType.friendship,
                duration: 5,
              ),
            ),
            DiplomacyTerm(
              fromSender: false,
              offer: DiplomacyOffer(
                type: DiplomacyExchangeType.friendship,
                duration: 12,
              ),
            ),
          ],
        ),
        isFalse,
      );
      expect(e.diplomacyBetween(0, 1), DiplomacyStatus.peace);
    },
  );

  test('both parties can commit to war against the same third country', () {
    final e = engine();
    expect(
      e.proposeExchange(
        from: 0,
        to: 1,
        terms: const [
          DiplomacyTerm(
            fromSender: true,
            offer: DiplomacyOffer(
              type: DiplomacyExchangeType.warDeclaration,
              targetPlayer: 2,
            ),
          ),
          DiplomacyTerm(
            fromSender: false,
            offer: DiplomacyOffer(
              type: DiplomacyExchangeType.warDeclaration,
              targetPlayer: 2,
            ),
          ),
        ],
      ),
      isTrue,
    );
    expect(
      e.resolveDiplomacyProposal(e.proposalsFor(1).single, accept: true),
      isTrue,
    );
    expect(e.areEnemies(0, 2), isTrue);
    expect(e.areEnemies(1, 2), isTrue);
  });

  test(
    'LAN acceptance rejects replaced conditions from the same round',
    () async {
      SharedPreferences.setMockInitialValues({});
      final e = engine();
      final controller = GameController(
        mod: mod,
        state: e.state,
        saves: SaveRepository(),
      );
      addTearDown(controller.dispose);
      e.proposeExchange(
        from: 0,
        to: 1,
        terms: const [
          DiplomacyTerm(
            fromSender: true,
            offer: DiplomacyOffer(
              type: DiplomacyExchangeType.money,
              amount: 10,
            ),
          ),
        ],
      );
      final stale = e.proposalsFor(1).single.toJson();
      e.proposeExchange(
        from: 0,
        to: 1,
        terms: const [
          DiplomacyTerm(
            fromSender: false,
            offer: DiplomacyOffer(
              type: DiplomacyExchangeType.money,
              amount: 90,
            ),
          ),
        ],
      );
      e.state.turn = 1;
      await expectLater(
        const LanCommandDispatcher().dispatch(
          controller: controller,
          player: 1,
          command: LanGameCommand(
            id: 1,
            baseRevision: 0,
            action: 'resolveDiplomacyProposal',
            arguments: {'proposal': stale, 'accept': true},
            ui: const LanUiState(),
          ),
        ),
        throwsStateError,
      );
      expect(e.playerMoney(1), 100);
      expect(e.proposalsFor(1).single.effectiveTerms.single.offer.amount, 90);
    },
  );

  test('LAN patch and undo preserve social section and human consent', () {
    SharedPreferences.setMockInitialValues({});
    final e = engine();
    final controller = GameController(
      mod: mod,
      state: e.state,
      saves: SaveRepository(),
    );
    final builder = LanStatePatchBuilder()..prime(e.state);
    final copy =
        jsonDecode(jsonEncode(e.state.toJson())) as Map<String, dynamic>;
    controller.influenceDiplomacyOpinion(1, improve: true);
    final patch = builder.build(e.state)!;
    expect((patch['sections'] as Map).containsKey('diplomacySocial'), isTrue);
    applyLanPatchToJson(copy, patch);
    expect(
      jsonEncode(GameState.fromJson(copy).toJson()),
      jsonEncode(e.state.toJson()),
    );
    controller.undo();
    expect(e.opinionOf(1, 0), 0);
    expect(e.playerMoney(0), 100);
    controller.requestBetterDiplomacy(1);
    expect(e.diplomacyBetween(0, 1), DiplomacyStatus.peace);
    expect(e.proposalsFor(1), hasLength(1));
    controller.dispose();
  });
}

GameState socialFixture({int humans = 3}) => GameState(
  config: GameConfig(
    playerCount: 3,
    humanCount: humans,
    diplomacy: true,
    difficulty: AiDifficulty.veryEasy,
    seed: 7,
  ),
  modId: 'classic_steppe',
  width: 12,
  height: 1,
  hexes: [
    for (var i = 0; i < 12; i++)
      HexTile(
        index: i,
        q: i,
        r: 0,
        active: true,
        owner: i ~/ 4,
        object: i % 4 == 0 ? TileObject.town : TileObject.none,
        neighbors: [if (i % 4 > 0) i - 1, if (i % 4 < 3) i + 1],
      ),
  ],
  provinces: [
    for (var p = 0; p < 3; p++)
      Province(
        id: p + 1,
        owner: p,
        tiles: List.generate(4, (i) => p * 4 + i),
        money: 100,
        capital: p * 4,
      ),
  ],
  turn: 0,
  round: 1,
  rngState: 1,
  nextProvinceId: 4,
);
