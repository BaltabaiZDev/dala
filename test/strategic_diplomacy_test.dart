import 'dart:convert';

import 'package:antiyoy_self/src/game/diplomacy_ai.dart';
import 'package:antiyoy_self/src/game/game_ai.dart';
import 'package:antiyoy_self/src/game/game_engine.dart';
import 'package:antiyoy_self/src/game/models.dart';
import 'package:antiyoy_self/src/lan/lan_protocol.dart';
import 'package:antiyoy_self/src/lan/lan_state_patch.dart';
import 'package:antiyoy_self/src/modding/game_mod.dart';
import 'package:antiyoy_self/src/persistence/editor_repository.dart';
import 'package:flutter_test/flutter_test.dart';

GameState strategicFixture({
  int players = 3,
  int humans = 1,
  int width = 12,
  int height = 8,
  AiDifficulty difficulty = AiDifficulty.hard,
  int Function(int, int)? ownerAt,
}) {
  final hexes = <HexTile>[];
  for (var r = 0; r < height; r++) {
    for (var q = 0; q < width; q++) {
      final index = r * width + q;
      final owner = ownerAt?.call(q, r) ?? (q >= 6 ? 2 : (r < 4 ? 0 : 1));
      hexes.add(
        HexTile(
          index: index,
          q: q,
          r: r,
          active: true,
          owner: owner,
          neighbors: [
            for (final (dq, dr) in [
              (1, 0),
              (-1, 0),
              (0, 1),
              (0, -1),
              (1, -1),
              (-1, 1),
            ])
              if (q + dq >= 0 &&
                  q + dq < width &&
                  r + dr >= 0 &&
                  r + dr < height)
                (r + dr) * width + q + dq,
          ],
        ),
      );
    }
  }
  final provinces = <Province>[];
  for (var p = 0; p < players; p++) {
    final tiles = hexes.where((h) => h.owner == p).map((h) => h.index).toList();
    if (tiles.isEmpty) continue;
    hexes[tiles.first].object = TileObject.town;
    provinces.add(
      Province(
        id: p + 1,
        owner: p,
        tiles: tiles,
        money: 100,
        capital: tiles.first,
      ),
    );
  }
  return GameState(
    config: GameConfig(
      playerCount: players,
      humanCount: humans,
      diplomacy: true,
      difficulty: difficulty,
      seed: 17,
    ),
    modId: 'classic_steppe',
    width: width,
    height: height,
    hexes: hexes,
    provinces: provinces,
    turn: 1,
    round: 10,
    rngState: 17,
    nextProvinceId: players + 1,
  );
}

void trust(GameEngine e, int a, int b, int score) {
  e.state.diplomacySocial.opinions[a][b] = score;
  e.state.diplomacySocial.opinions[b][a] = score;
}

DiplomacyTerm money(bool give, int amount) => DiplomacyTerm(
  fromSender: give,
  offer: DiplomacyOffer(type: DiplomacyExchangeType.money, amount: amount),
);
const friendship = DiplomacyTerm(
  fromSender: true,
  offer: DiplomacyOffer(type: DiplomacyExchangeType.friendship, duration: 6),
);
const alliance = DiplomacyTerm(
  fromSender: true,
  offer: DiplomacyOffer(type: DiplomacyExchangeType.militaryAlliance),
);
const peace = DiplomacyTerm(
  fromSender: true,
  offer: DiplomacyOffer(type: DiplomacyExchangeType.ceasefire),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late GameMod mod;
  setUpAll(() async {
    mod = await GameMod.loadDefault();
  });
  GameEngine engine([GameState? state]) =>
      GameEngine(mod: mod, state: state ?? strategicFixture());

  test('shared events are unordered and loyalty ticks only once per round', () {
    final e = engine(strategicFixture(humans: 3));
    e.changeOpinion(0, 1, 15, 'Visit');
    e.changeOpinion(1, 0, 15, 'Visit');
    expect(e.opinionOf(0, 1), 15);
    expect(e.opinionOf(1, 0), 15);
    expect(e.state.diplomacySocial.events, hasLength(1));
    e.setDiplomacyStatus(0, 1, DiplomacyStatus.alliance);
    final before = e.opinionOf(0, 1);
    for (var i = 0; i < 3; i++) {
      e.endTurn();
    }
    expect(e.opinionOf(0, 1), before + 2);
    expect(e.opinionOf(1, 0), before + 2);
  });

  test(
    'legacy directed scores migrate to rounded mean; v2 requires symmetry',
    () {
      final raw =
          jsonDecode(jsonEncode(engine().state.toJson()))
              as Map<String, dynamic>;
      final social = raw['diplomacySocial'] as Map;
      social.remove('relationsVersion');
      social['opinions'][0][1] = 24;
      social['opinions'][1][0] = -8;
      final migrated = EditorRepository.decodeStateJson(raw, rules: mod.rules)!;
      expect(migrated.diplomacySocial.relationship(0, 1), 8);
      expect(migrated.diplomacySocial.opinions[1][0], 8);
      expect(
        EditorRepository.decodeStateJson(migrated.toJson(), rules: mod.rules),
        isNotNull,
      );
      social['relationsVersion'] = 2;
      expect(EditorRepository.decodeStateJson(raw, rules: mod.rules), isNull);
      social['relationsVersion'] = 99;
      expect(EditorRepository.decodeStateJson(raw, rules: mod.rules), isNull);
    },
  );

  test('bloc joining requires every pair and a higher threshold with size', () {
    final e = engine(
      strategicFixture(players: 5, width: 15, ownerAt: (q, r) => q ~/ 3),
    );
    expect(e.militaryAllianceTrustRequired(0, 1), 35);
    trust(e, 0, 1, 35);
    expect(e.formMilitaryAlliance(0, 1), isTrue);
    expect(e.militaryAllianceTrustRequired(0, 2), 43);
    trust(e, 0, 2, 80);
    trust(e, 1, 2, 42);
    expect(e.canFormMilitaryAlliance(0, 2), isFalse);
    trust(e, 1, 2, 43);
    expect(e.formMilitaryAlliance(0, 2), isTrue);
    expect(e.militaryAllianceTrustRequired(0, 3), 51);
    for (var p = 0; p < 3; p++) {
      trust(e, p, 3, 80);
    }
    // The old 1 ↔ 2 pair is also part of the larger group's cohesion.
    expect(e.canFormMilitaryAlliance(0, 3), isFalse);
    trust(e, 1, 2, 60);
    expect(e.canFormMilitaryAlliance(0, 3), isTrue);
  });

  test(
    'human consent remains possible but bots never form an all-world bloc',
    () {
      final e = engine(strategicFixture(humans: 3));
      trust(e, 0, 1, -80);
      expect(e.formMilitaryAlliance(0, 1), isTrue);
      expect(e.formMilitaryAlliance(0, 2), isTrue);
      final bot = engine();
      for (var a = 0; a < 3; a++) {
        for (var b = a + 1; b < 3; b++) {
          trust(bot, a, b, 90);
        }
      }
      expect(bot.formMilitaryAlliance(0, 1), isTrue);
      expect(bot.canFormMilitaryAlliance(0, 2), isFalse);
      expect(bot.botAllianceAdmissionError(0, 2), contains('жеке жеңіс'));
    },
  );

  test('stale alliance proposal cannot bypass another member relationship', () {
    final e = engine(strategicFixture(players: 4, ownerAt: (q, r) => q ~/ 3));
    for (var a = 0; a < 3; a++) {
      for (var b = a + 1; b < 3; b++) {
        trust(e, a, b, 60);
      }
    }
    e.formMilitaryAlliance(0, 1);
    expect(
      e.proposeExchange(from: 0, to: 2, terms: [money(true, 15), alliance]),
      isTrue,
    );
    trust(e, 1, 2, 20);
    final before = jsonEncode(e.state.toJson());
    expect(
      e.resolveDiplomacyProposal(e.proposalsFor(2).single, accept: true),
      isFalse,
    );
    expect(jsonEncode(e.state.toJson()), before);
  });

  test(
    'common stronger neighbor yields a useful explained containment alliance',
    () {
      final e = engine();
      trust(e, 0, 1, 50);
      final ai = StrategicDiplomacyAi(e);
      final plan = ai.bestPlan(1)!;
      expect(plan.other, 0);
      expect(plan.tactic, DiplomacyTactic.containLeader);
      expect(plan.rationale, contains(e.state.playerName(2)));
      expect(ai.utility(0, 1, 0, plan.terms), greaterThan(0));
      expect(ai.utility(1, 1, 0, plan.terms), greaterThan(0));
      expect(
        e.proposeExchange(
          from: 1,
          to: 0,
          terms: plan.terms,
          rationale: plan.rationale,
        ),
        isTrue,
      );
      expect(
        e.resolveDiplomacyProposal(e.proposalsFor(0).single, accept: true),
        isTrue,
      );
      expect(e.hasMilitaryAccess(0, 1), isTrue);
    },
  );

  test('a third member bot can veto an otherwise useful military pact', () {
    final e = engine(strategicFixture(players: 4, ownerAt: (q, r) => q ~/ 3));
    for (var a = 0; a < 3; a++) {
      for (var b = a + 1; b < 3; b++) {
        trust(e, a, b, 75);
      }
    }
    e.formMilitaryAlliance(0, 1);
    final ai = StrategicDiplomacyAi(e);
    // 0 has no common threat or growth frontier with 2; high trust is not enough.
    expect(ai.utility(2, 0, 2, [alliance]), lessThan(-1000));
  });

  test('combined payments and recurring promises cannot bankrupt a bot', () {
    final e = engine();
    final ai = StrategicDiplomacyAi(e);
    expect(
      ai.utility(1, 1, 0, [friendship, money(true, 60), money(true, 60)]),
      lessThan(-1000),
    );
    expect(ai.utility(1, 1, 0, [friendship, money(true, 95)]), lessThan(-1000));
    expect(
      ai.utility(1, 1, 0, [
        friendship,
        const DiplomacyTerm(
          fromSender: true,
          offer: DiplomacyOffer(
            type: DiplomacyExchangeType.subsidies,
            amount: 30,
            duration: 20,
          ),
        ),
      ]),
      lessThan(-1000),
    );
    e.state.provinces[0].money = 0;
    final noCash = StrategicDiplomacyAi(e);
    expect(
      noCash.utility(1, 0, 1, [money(true, 500), money(false, 40)]),
      lessThan(0),
    );
  });

  test(
    'distressed frontier state receives useful liquidity for a land sale',
    () {
      final e = engine();
      e.state.provinces[0].money = 0;
      final ai = StrategicDiplomacyAi(e);
      final trades = ai
          .plansFor(1, 0)
          .where((p) => p.tactic == DiplomacyTactic.trade)
          .toList();
      expect(trades, isNotEmpty);
      expect(
        trades.any(
          (p) =>
              ai.utility(0, 1, 0, p.terms) > 0 &&
              ai.utility(1, 1, 0, p.terms) > 0,
        ),
        isTrue,
      );
      for (final p in trades) {
        for (final t in p.terms.where(
          (t) => t.offer.type == DiplomacyExchangeType.lands,
        )) {
          expect(
            t.offer.tiles.any(
              (i) => e.state.hexes[i].object == TileObject.town,
            ),
            isFalse,
          );
        }
      }
    },
  );

  test('bot never trades its complete sovereign territory for money', () {
    final e = engine();
    final ai = StrategicDiplomacyAi(e);
    expect(
      ai.utility(1, 1, 0, [
        DiplomacyTerm(
          fromSender: true,
          offer: DiplomacyOffer(
            type: DiplomacyExchangeType.lands,
            tiles: e.state.provinces[1].tiles,
          ),
        ),
        money(false, 100),
      ]),
      lessThan(-1000),
    );
  });

  test('wartime plan pays the stronger side and respects ceasefire locks', () {
    final e = engine();
    expect(e.declareWar(1, 2), isTrue);
    e.state.diplomacyWarCooldowns[1][2] = 0;
    e.state.diplomacyWarCooldowns[2][1] = 0;
    final ai = StrategicDiplomacyAi(e);
    final plan = ai.plansFor(1, 2).single;
    expect(plan.tactic, DiplomacyTactic.negotiatePeace);
    expect(plan.terms.last.fromSender, isTrue);
    expect(ai.utility(1, 1, 2, plan.terms), greaterThan(0));
    expect(ai.utility(2, 1, 2, plan.terms), greaterThan(0));
    e.state.diplomacyWarCooldowns[1][2] = 4;
    e.state.diplomacyWarCooldowns[2][1] = 4;
    expect(StrategicDiplomacyAi(e).plansFor(1, 2), isEmpty);
  });

  test('hard tiers recruit another country against an actual enemy', () {
    final e = engine();
    e.declareWar(1, 2);
    final hard = StrategicDiplomacyAi(e);
    final plan = hard
        .plansFor(1, 0)
        .firstWhere((p) => p.tactic == DiplomacyTactic.recruitAgainstEnemy);
    expect(plan.terms.last.offer.targetPlayer, 2);
    expect(plan.terms.last.fromSender, isFalse);
    expect(plan.rationale, contains(e.state.playerName(2)));
    final low = engine(strategicFixture(difficulty: AiDifficulty.easy));
    low.declareWar(1, 2);
    expect(
      StrategicDiplomacyAi(low)
          .plansFor(1, 0)
          .any((p) => p.tactic == DiplomacyTactic.recruitAgainstEnemy),
      isFalse,
    );
  });

  test(
    'bribes cannot make a bot attack its own ally or accept a suicidal war',
    () {
      final e = engine();
      final terms = [
        money(true, 100),
        const DiplomacyTerm(
          fromSender: false,
          offer: DiplomacyOffer(
            type: DiplomacyExchangeType.warDeclaration,
            targetPlayer: 2,
          ),
        ),
      ];
      trust(e, 1, 2, 80);
      expect(StrategicDiplomacyAi(e).utility(1, 0, 1, terms), lessThan(-1000));
      expect(e.improveDiplomacy(1, 2), isTrue);
      expect(
        StrategicDiplomacyAi(e).accepts(
          1,
          DiplomacyProposal(
            from: 0,
            to: 1,
            type: DiplomacyProposalType.exchange,
            createdRound: 10,
            terms: terms,
          ),
        ),
        isFalse,
      );
    },
  );

  test(
    'counteroffer changes price only and keeps executable original terms',
    () {
      final e = engine();
      final proposal = DiplomacyProposal(
        from: 0,
        to: 1,
        type: DiplomacyProposalType.exchange,
        createdRound: 10,
        terms: [friendship, money(false, 45)],
      );
      final ai = StrategicDiplomacyAi(e);
      expect(ai.accepts(1, proposal), isFalse);
      final counter = ai.counterOffer(1, proposal)!;
      expect(counter.tactic, DiplomacyTactic.counterOffer);
      expect(counter.terms.first.offer.toJson(), friendship.offer.toJson());
      expect(counter.terms.last.offer.amount, lessThan(45));
      expect(ai.utility(1, 1, 0, counter.terms), greaterThan(0));
      expect(ai.utility(0, 1, 0, counter.terms), greaterThan(0));
      expect(e.exchangeValidationError(1, 0, counter.terms), isNull);
    },
  );

  test(
    'contextual letters survive save and LAN patch; oversized text rejected',
    () {
      final e = engine();
      final builder = LanStatePatchBuilder()..prime(e.state);
      final copy =
          jsonDecode(jsonEncode(e.state.toJson())) as Map<String, dynamic>;
      trust(e, 0, 1, 50);
      final ai = StrategicDiplomacyAi(e)..takeTurn(1);
      expect(ai.chosenTactic, DiplomacyTactic.containLeader);
      final proposal = e.proposalsFor(0).single;
      expect(proposal.rationale, isNotEmpty);
      applyLanPatchToJson(copy, builder.build(e.state)!);
      final saved = EditorRepository.decodeStateJson(copy, rules: mod.rules)!;
      expect(saved.diplomacyProposals.single.rationale, proposal.rationale);
      expect(saved.diplomacySocial.relationship(0, 1), 50);
      expect(lanProtocolVersion, 7);
      expect(
        e.proposeExchange(
          from: 1,
          to: 0,
          terms: [money(true, 1)],
          rationale: 'a' * 401,
        ),
        isFalse,
      );
      final bad =
          jsonDecode(jsonEncode(e.state.toJson())) as Map<String, dynamic>;
      bad['diplomacyProposals'][0]['rationale'] = 'a' * 401;
      expect(EditorRepository.decodeStateJson(bad, rules: mod.rules), isNull);
    },
  );

  test('contact cooldown and human inbox limit survive round-trip', () {
    final e = engine();
    trust(e, 0, 1, 50);
    StrategicDiplomacyAi(e).takeTurn(1);
    final copy = engine(GameState.fromJson(e.state.toJson()));
    expect(StrategicDiplomacyAi(copy).canContact(1, 0), isFalse);
    copy.resolveDiplomacyProposal(copy.proposalsFor(0).single, accept: false);
    expect(StrategicDiplomacyAi(copy).canContact(1, 0), isFalse);
    copy.state.round += 6;
    expect(StrategicDiplomacyAi(copy).canContact(1, 0), isTrue);
    copy.state.diplomacyProposals.addAll([
      DiplomacyProposal(
        from: 1,
        to: 0,
        type: DiplomacyProposalType.friendship,
        createdRound: 16,
      ),
      DiplomacyProposal(
        from: 2,
        to: 0,
        type: DiplomacyProposalType.friendship,
        createdRound: 16,
      ),
    ]);
    expect(StrategicDiplomacyAi(copy).canContact(1, 0), isFalse);
  });

  test(
    'difficulty scales horizon search and diplomacy frequency without randomness',
    () {
      final easy = StrategicDiplomacyAi(
        engine(strategicFixture(difficulty: AiDifficulty.veryEasy)),
      );
      final master = StrategicDiplomacyAi(
        engine(strategicFixture(difficulty: AiDifficulty.master)),
      );
      expect(easy.candidateLimit, 2);
      expect(master.candidateLimit, 7);
      expect(easy.horizon, 2);
      expect(master.horizon, 7);
      expect(master.contactGap, lessThan(easy.contactGap));
    },
  );

  test(
    'large 15-country diplomacy uses one board scan and bounded candidates',
    () {
      final e = engine(
        strategicFixture(
          players: 15,
          width: 90,
          height: 70,
          difficulty: AiDifficulty.master,
          ownerAt: (q, r) => q ~/ 6,
        ),
      );
      final timer = Stopwatch()..start();
      final ai = StrategicDiplomacyAi(e);
      ai.bestPlan(1);
      timer.stop();
      expect(
        ai.snapshot.visitedCells,
        e.state.hexes.length + e.state.waterCells.length,
      );
      expect(ai.snapshotsBuilt, 1);
      expect(ai.evaluatedPlans, lessThanOrEqualTo(64));
      expect(ai.validatedPlans, lessThan(ai.evaluatedPlans));
      // Diagnostic only: wall time is not a flaky CI pass/fail threshold.
      // ignore: avoid_print
      print(
        '15-country diplomacy: ${timer.elapsedMicroseconds / 1000} ms; ${ai.evaluatedPlans} plans; ${ai.snapshot.visitedCells} cells',
      );
    },
  );

  test('bot explains rejection and does not repeat response letters', () {
    final e = engine();
    // Keep this response test off the separate deterministic war-decision tick.
    e.state.round = 9;
    expect(
      e.proposeExchange(from: 0, to: 1, terms: [money(false, 90)]),
      isTrue,
    );
    StrategicDiplomacyAi(e).takeTurn(1);
    expect(e.proposalsFor(1), isEmpty);
    expect(e.playerMoney(1), 100);
    expect(e.messagesBetween(0, 1).length, 1);
    expect(e.messagesBetween(0, 1).single.text, contains('пайда'));
    e.proposeExchange(from: 0, to: 1, terms: [money(false, 90)]);
    StrategicDiplomacyAi(e).takeTurn(1);
    expect(e.messagesBetween(0, 1).length, 1);
  });

  test('cash relief is chosen to stabilize a buffer under shared threat', () {
    final e = engine();
    e.state.provinces[0].money = 0;
    for (final tile in e.state.provinces[0].tiles.skip(1).take(2)) {
      e.state.hexes[tile].unit = GameUnit(strength: 3);
    }
    final ai = StrategicDiplomacyAi(e);
    expect(ai.snapshot.net[0], lessThan(0));
    final plan = ai.bestPlan(1)!;
    expect(plan.tactic, DiplomacyTactic.relief);
    expect(plan.terms.first.offer.amount, greaterThan(0));
    expect(plan.terms.first.fromSender, isTrue);
    expect(ai.utility(0, 1, 0, plan.terms), greaterThan(0));
  });

  test(
    'shared embassy cooldown prevents paying twice for one shared event',
    () {
      final e = engine();
      expect(e.influenceOpinion(0, 1, improve: true), isTrue);
      final before = jsonEncode(e.state.toJson());
      expect(e.opinionActionCooldown(1, 0), 3);
      expect(e.influenceOpinion(1, 0, improve: true), isFalse);
      expect(jsonEncode(e.state.toJson()), before);
    },
  );

  test(
    'huge payment does not buy a suicidal war with an overwhelming army',
    () {
      final e = engine();
      for (final i in e.state.provinces[2].tiles.skip(1)) {
        e.state.hexes[i].unit = GameUnit(strength: 4);
      }
      final terms = [
        money(true, 100),
        const DiplomacyTerm(
          fromSender: false,
          offer: DiplomacyOffer(
            type: DiplomacyExchangeType.warDeclaration,
            targetPlayer: 2,
          ),
        ),
      ];
      expect(StrategicDiplomacyAi(e).utility(1, 0, 1, terms), lessThan(-1000));
    },
  );

  test(
    'master ends an obsolete pact legally without same-turn surprise war',
    () {
      final e = engine(
        strategicFixture(
          difficulty: AiDifficulty.master,
          ownerAt: (q, r) => q < 3 ? 0 : (q < 11 ? 1 : 2),
        ),
      );
      e.setDiplomacyStatus(0, 1, DiplomacyStatus.alliance);
      e.state.diplomacyAllianceTurns[0][1] = 1;
      e.state.diplomacyAllianceTurns[1][0] = 1;
      e.state.provinces[1].money = 1000;
      final timer = e.friendshipBreakCompensationTotal(1, 0);
      expect(timer, greaterThan(0));
      StrategicDiplomacyAi(e).takeTurn(1);
      expect(e.diplomacyBetween(0, 1), DiplomacyStatus.peace);
      expect(
        e.state.diplomacySubsidies.any(
          (s) => s.payer == 1 && s.receiver == 0 && s.mandatory,
        ),
        isTrue,
      );
      expect(
        e.messagesBetween(0, 1).any((m) => m.text.contains('мүдделер өзгерді')),
        isTrue,
      );
    },
  );

  test('new military pact cannot be obtained by bribing one member only', () {
    final e = engine(strategicFixture(players: 4, ownerAt: (q, r) => q ~/ 3));
    trust(e, 0, 1, 60);
    e.formMilitaryAlliance(0, 1);
    trust(e, 0, 2, 80);
    trust(e, 1, 2, 0);
    expect(
      e.proposeExchange(from: 2, to: 0, terms: [money(true, 100), alliance]),
      isFalse,
    );
    expect(e.exchangeValidationError(2, 0, [alliance]), contains('+43'));
  });

  test(
    'synchronous and yielding full AI produce identical diplomatic state',
    () async {
      final e = engine();
      trust(e, 0, 1, 50);
      final copy = engine(GameState.fromJson(e.state.toJson()));
      GameAi(mod: mod, engine: e).takeTurn();
      await GameAi(mod: mod, engine: copy).takeTurnAsync();
      expect(jsonEncode(copy.state.toJson()), jsonEncode(e.state.toJson()));
    },
  );
  test(
    'long subsidies cannot be bought for the price of the first few turns',
    () {
      final e = engine();
      DiplomacyTerm subsidy(int duration) => DiplomacyTerm(
        fromSender: false,
        offer: DiplomacyOffer(
          type: DiplomacyExchangeType.subsidies,
          amount: 5,
          duration: duration,
        ),
      );
      final ai = StrategicDiplomacyAi(e);
      expect(
        ai.utility(1, 0, 1, [money(true, 50), subsidy(6)]),
        greaterThan(0),
      );
      expect(ai.utility(1, 0, 1, [money(true, 50), subsidy(20)]), lessThan(0));
      expect(
        ai.utility(1, 0, 1, [subsidy(20), money(true, 50)]),
        ai.utility(1, 0, 1, [money(true, 50), subsidy(20)]),
      );
    },
  );

  test('an imported army is rejected when its upkeep cannot be funded', () {
    final e = engine();
    final index = e.state.provinces[0].tiles.last;
    e.state.hexes[index].unit = GameUnit(strength: 4);
    e.state.provinces[1].money = 12;
    final gift = DiplomacyTerm(
      fromSender: true,
      offer: DiplomacyOffer(type: DiplomacyExchangeType.lands, tiles: [index]),
    );
    expect(e.exchangeValidationError(0, 1, [gift]), isNull);
    expect(StrategicDiplomacyAi(e).utility(1, 0, 1, [gift]), lessThan(-1000));
  });

  test(
    'farm sale and subsidy use the income remaining after the whole exchange',
    () {
      final e = engine();
      final index = e.state.provinces[1].tiles.last;
      e.state.hexes[index].object = TileObject.farm;
      e.state.provinces[0].money = 1000;
      final ai = StrategicDiplomacyAi(e);
      final amount = ai.snapshot.net[1] ~/ 2;
      final subsidy = DiplomacyTerm(
        fromSender: false,
        offer: DiplomacyOffer(
          type: DiplomacyExchangeType.subsidies,
          amount: amount,
          duration: 1,
        ),
      );
      final sale = DiplomacyTerm(
        fromSender: false,
        offer: DiplomacyOffer(
          type: DiplomacyExchangeType.lands,
          tiles: [index],
        ),
      );
      expect(ai.utility(1, 0, 1, [money(true, 400), subsidy]), greaterThan(0));
      expect(
        ai.utility(1, 0, 1, [money(true, 400), subsidy, sale]),
        lessThan(-1000),
      );
      expect(
        ai.utility(1, 0, 1, [sale, money(true, 400), subsidy]),
        lessThan(-1000),
      );
    },
  );

  test(
    'subsidy renewal replaces the old commitment instead of double charging',
    () {
      final e = engine();
      e.state.diplomacySubsidies.add(
        DiplomacySubsidy(payer: 1, receiver: 0, amount: 10, turnsLeft: 4),
      );
      final renewal = DiplomacyTerm(
        fromSender: false,
        offer: DiplomacyOffer(
          type: DiplomacyExchangeType.subsidies,
          amount: 10,
          duration: 4,
        ),
      );
      expect(
        StrategicDiplomacyAi(e).utility(1, 0, 1, [money(true, 5), renewal]),
        greaterThan(0),
      );
    },
  );

  test(
    'sustainable income changes war risk and a second major front blocks it',
    () {
      final e = engine(
        strategicFixture(ownerAt: (q, r) => q >= 8 ? 2 : (r < 2 ? 0 : 1)),
      );
      final funded = StrategicDiplomacyAi(e).warValue(1, 2);
      for (final i in e.state.provinces[1].tiles.skip(1)) {
        e.state.hexes[i].object = TileObject.pine;
      }
      final forest = StrategicDiplomacyAi(e).warValue(1, 2);
      expect(funded, greaterThan(forest));
      for (final i in e.state.provinces[0].tiles.skip(1)) {
        e.state.hexes[i].unit = GameUnit(strength: 4);
      }
      expect(e.declareWar(0, 1), isTrue);
      expect(StrategicDiplomacyAi(e).warValue(1, 2), lessThan(-1000));
    },
  );

  test(
    'stronger humans receive the same free beneficial pact candidates as bots',
    () {
      final e = engine(
        strategicFixture(ownerAt: (q, r) => q >= 6 ? 2 : (r < 5 ? 0 : 1)),
      );
      final plans = StrategicDiplomacyAi(e).plansFor(1, 0);
      expect(
        plans.any(
          (p) =>
              p.tactic == DiplomacyTactic.secureBorder && p.terms.length == 1,
        ),
        isTrue,
      );
    },
  );

  test(
    'bounded partner search always considers a relevant human among many bots',
    () {
      final e = engine(
        strategicFixture(
          players: 8,
          width: 21,
          height: 8,
          ownerAt: (q, r) => r < 2 ? 7 : q ~/ 3,
        ),
      );
      for (var p = 1; p < 7; p++) {
        trust(e, 7, p, 60);
      }
      final ai = StrategicDiplomacyAi(e)..bestPlan(7);
      expect(ai.consideredPartners, contains(0));
      expect(
        ai.consideredPartners.length,
        lessThanOrEqualTo(ai.candidateLimit),
      );
      expect(ai.evaluatedPlans, lessThanOrEqualTo(64));
    },
  );
}
