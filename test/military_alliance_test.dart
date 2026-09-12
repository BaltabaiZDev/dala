import 'package:antiyoy_self/src/game/game_engine.dart';
import 'package:antiyoy_self/src/game/models.dart';
import 'package:antiyoy_self/src/modding/game_mod.dart';
import 'package:antiyoy_self/src/persistence/editor_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late GameMod mod;

  setUpAll(() async {
    mod = await GameMod.loadDefault();
  });

  group('military alliances', () {
    test(
      'isolated holdings can be taken in every diplomatic status without declaring war',
      () {
        for (final status in DiplomacyStatus.values) {
          final state = _isolatedHoldingState();
          final engine = GameEngine(mod: mod, state: state);
          engine.setDiplomacyStatus(0, 1, status);
          expect(engine.isIsolatedHolding(2), isTrue);
          expect(engine.moveTargets(1), contains(2), reason: status.name);
          expect(engine.moveUnit(1, 2), isTrue);
          expect(state.hexes[2].owner, 0);
          expect(engine.diplomacyBetween(0, 1), status);
          expect(state.campaigns, isEmpty);
          expect(state.hexes[4].owner, 1);
          expect(EditorRepository.isValidState(state), isTrue);
        }
      },
    );

    test(
      'adjacent same-owner land removes isolated conquest permission, including stale zones',
      () {
        final state = _isolatedHoldingState();
        final engine = GameEngine(mod: mod, state: state);
        final oldTargets = engine.moveTargets(1);
        expect(oldTargets, contains(2));
        state.hexes[3].owner = 1;
        engine.rebuildProvinces();
        expect(engine.isIsolatedHolding(2), isFalse);
        expect(engine.moveUnit(1, 2, knownTargets: oldTargets), isFalse);
        expect(state.hexes[2].owner, 1);
      },
    );

    test(
      'isolated capture still respects strength and supports direct recruitment',
      () {
        final state = _isolatedHoldingState();
        final engine = GameEngine(mod: mod, state: state);
        state.hexes[2].object = TileObject.tower;
        expect(engine.moveTargets(1), isNot(contains(2)));
        expect(engine.unitBuildTargets(1, 3), contains(2));
        expect(engine.buyUnit(1, 2, 3), isTrue);
        expect(state.hexes[2].owner, 0);
        expect(state.hexes[2].unit!.strength, 3);
      },
    );

    for (final home in ['empty', 'merge', 'full', 'island']) {
      test(
        'expired alliance returns guest troops safely when home is $home',
        () {
          final state = _transitState();
          final engine = GameEngine(mod: mod, state: state);
          _formCoalition(engine, 0, 1);
          expect(engine.moveUnit(1, 2), isTrue);
          final guest = state.hexes[2].unit!;
          if (home == 'merge' || home == 'full') {
            state.hexes[1].unit = GameUnit(
              strength: home == 'merge' ? 1 : 4,
              owner: 0,
              homeProvinceId: 1,
            );
          }
          if (home == 'island') {
            state.hexes[1].neighbors.remove(2);
            state.hexes[2].neighbors.remove(1);
          }
          state.diplomacyAllianceTurns[0][1] = 1;
          state.diplomacyAllianceTurns[1][0] = 1;
          final treasury = engine.provincesOf(0).single;
          final before = treasury.money;
          state.turn = 2;
          engine.endTurn();
          expect(engine.hasMilitaryAccess(0, 1), isFalse);
          expect(engine.diplomacyBetween(0, 1), DiplomacyStatus.alliance);
          expect(state.diplomacyAllianceTurns[0][1], 6);
          expect(state.hexes[2].unit, isNull);
          expect(state.hexes[2].object, TileObject.pine);
          if (home == 'full') {
            expect(state.hexes[1].unit!.strength, 4);
            expect(
              treasury.money,
              before +
                  2 * mod.rules.unitPricePerLevel +
                  engine
                      .economicBreakdown(treasury, includeDiplomacy: false)
                      .total,
            );
            expect(
              state.diplomacyLog.any((s) => s.contains('қазынаға')),
              isTrue,
            );
          } else {
            expect(state.hexes[1].unit!.strength, home == 'merge' ? 3 : 2);
            if (home != 'merge') expect(state.hexes[1].unit, same(guest));
            expect(state.hexes[1].unit!.homeProvinceId, treasury.id);
            expect(state.hexes[1].unit!.transitAllies, isEmpty);
          }
          expect(
            engine.economicBreakdown(engine.provincesOf(1).single).landUnits,
            0,
          );
          if (home != 'island') {
            expect(EditorRepository.decodeStateJson(state.toJson()), isNotNull);
          }
        },
      );
    }

    test(
      'expiry keeps alternate coalition access and freezes an unsettled shared war',
      () {
        final state = _transitState();
        final engine = GameEngine(mod: mod, state: state);
        _formCoalition(engine, 0, 1);
        _formCoalition(engine, 1, 2);
        _formCoalition(engine, 0, 2);
        expect(engine.moveUnit(1, 2), isTrue);
        final guest = state.hexes[2].unit;
        state.diplomacyAllianceTurns[0][1] = 1;
        state.diplomacyAllianceTurns[1][0] = 1;
        state.turn = 2;
        engine.endTurn();
        expect(engine.hasMilitaryAccess(0, 1), isTrue);
        expect(state.hexes[2].unit, same(guest));
        final result = _captureAfterAlliedTransit(mod);
        result.state.diplomacyAllianceTurns[0][1] = 1;
        result.state.diplomacyAllianceTurns[1][0] = 1;
        result.state.turn = 2;
        result.engine.endTurn();
        expect(result.state.diplomacyAllianceTurns[0][1], 1);
        expect(result.engine.hasMilitaryAccess(0, 1), isTrue);
      },
    );

    test('black mark cannot silently split an active military contract', () {
      final result = _captureAfterAlliedTransit(mod);
      expect(result.engine.placeBlackMark(0, 1), isFalse);
      expect(result.engine.hasBlackMark(0, 1), isFalse);
      expect(result.engine.hasMilitaryAccess(0, 1), isTrue);
    });

    test('black mark ends direct and transitive peacetime military links', () {
      final engine = GameEngine(mod: mod, state: _blocState(3));
      _formCoalition(engine, 0, 1);
      _formCoalition(engine, 1, 2);
      expect(engine.placeBlackMark(0, 2), isTrue);
      expect(engine.hasMilitaryAccess(0, 2), isFalse);
      expect(engine.hasMilitaryAccess(0, 1), isTrue);
    });

    test(
      'leaving coalition resolves outstanding pool without dangling treaty',
      () {
        for (final duringWar in [true, false]) {
          final result = _captureAfterAlliedTransit(mod);
          if (!duringWar) expect(result.engine.makePeace(0, 2), isTrue);
          expect(result.engine.neutralizeDepartedPlayer(0), isTrue);
          expect(result.state.campaigns, isEmpty);
          expect(result.state.peaceConferences, isEmpty);
          expect(result.state.hexes[4].coalitionClaim, isNull);
          expect(result.state.hexes[4].owner, 2);
          expect(
            result.state.provinces.any((province) => province.owner == 0),
            isFalse,
          );
          expect(result.engine.declareWar(1, 2), isFalse);
        }
      },
    );

    test('return to own land clears expedition credit even after merging', () {
      final state = _transitState();
      final engine = GameEngine(mod: mod, state: state);
      _formCoalition(engine, 0, 1);
      expect(engine.moveUnit(1, 2), isTrue);
      state.hexes[2].unit!.ready = true;
      state.hexes[1].unit = GameUnit(
        strength: 1,
        owner: 0,
        homeProvinceId: 1,
        transitAllies: [1],
      );
      expect(engine.moveUnit(2, 1), isTrue);
      expect(state.hexes[1].unit!.transitAllies, isEmpty);
      expect(state.hexes[1].unit!.strength, 3);
    });

    test(
      'funded claim army survives strict save during war and conference',
      () {
        final result = _captureAfterAlliedTransit(mod);
        expect(
          EditorRepository.decodeStateJson(result.state.toJson()),
          isNotNull,
        );
        expect(result.engine.makePeace(0, 2), isTrue);
        final loaded = EditorRepository.decodeStateJson(result.state.toJson());
        expect(loaded, isNotNull);
        expect(loaded!.hexes[4].unit?.owner, 0);
        expect(loaded.hexes[4].unit?.homeProvinceId, 1);
      },
    );

    test(
      'peace capital creation relocates troops instead of overlapping town',
      () {
        final state = _blocState(3);
        final engine = GameEngine(mod: mod, state: state);
        state.hexes[2].object = TileObject.none;
        state.hexes[3].object = TileObject.none;
        for (final index in [2, 3]) {
          state.hexes[index].unit = GameUnit(
            strength: 1,
            owner: 1,
            homeProvinceId: 2,
          );
        }
        engine.rebuildProvinces(preserveNewCapitalUnits: true);
        expect(
          state.hexes.any(
            (tile) => tile.unit != null && tile.object == TileObject.town,
          ),
          isFalse,
        );
        expect(EditorRepository.isValidState(state), isTrue);
      },
    );

    test('one move credits allied terrain crossed without stopping', () {
      final state = _transitState();
      final engine = GameEngine(mod: mod, state: state);
      _formCoalition(engine, 0, 1);
      expect(engine.declareWar(0, 2), isTrue);
      expect(engine.moveUnit(1, 4), isTrue);
      expect(state.hexes[4].coalitionClaim?.contributors, [0, 1]);
      expect(state.hexes[4].unit?.homeProvinceId, 1);
    });

    test('shared claim army survives separation but not home bankruptcy', () {
      final result = _captureAfterAlliedTransit(mod);
      final state = result.state;
      final engine = result.engine;
      final unit = state.hexes[4].unit!;
      engine.rebuildProvinces();
      expect(state.hexes[4].unit, same(unit));
      expect(
        engine.economicBreakdown(engine.provincesOf(0).single).landUnits,
        -mod.rules.unitUpkeep[2],
      );
      engine.provincesOf(0).single.money = 0;
      for (var i = 0; i < 3; i++) {
        engine.endTurn();
      }
      expect(state.hexes[4].unit, isNull);
      expect(state.hexes[4].coalitionClaim, isNotNull);
    });

    test(
      'peace conference land cannot be attacked through no-province loophole',
      () {
        final result = _captureAfterAlliedTransit(mod);
        final state = result.state;
        final engine = result.engine;
        expect(engine.makePeace(0, 2), isTrue);
        state.turn = 2;
        state.hexes[6].unit = GameUnit(strength: 4);
        expect(engine.moveTargets(6), isNot(contains(4)));
        expect(engine.moveUnit(6, 4), isFalse);
        expect(state.peaceConferences, hasLength(1));
      },
    );

    test(
      'guest on allied tree survives save and bankruptcy preserves host tree',
      () {
        final state = _transitState();
        final engine = GameEngine(mod: mod, state: state);
        _formCoalition(engine, 0, 1);
        expect(engine.moveUnit(1, 2), isTrue);
        expect(EditorRepository.isValidState(state), isTrue);
        final restored = GameState.fromJson(state.toJson());
        GameEngine(mod: mod, state: restored).sanitizeOverlaps();
        expect(restored.hexes[2].object, TileObject.pine);
        expect(restored.hexes[2].unit?.owner, 0);
        engine.provincesOf(0).single.money = 0;
        for (var i = 0; i < 3; i++) {
          engine.endTurn();
        }
        expect(state.hexes[2].unit, isNull);
        expect(state.hexes[2].object, TileObject.pine);
      },
    );

    test('military membership is frozen through war and peace conference', () {
      final state = _transitStateWithReserveAlly();
      final engine = GameEngine(mod: mod, state: state);
      _formCoalition(engine, 0, 1);
      expect(engine.declareWar(0, 2), isTrue);
      expect(engine.canFormMilitaryAlliance(0, 3), isFalse);
      expect(engine.moveUnit(1, 2), isTrue);
      state.hexes[2].unit!.ready = true;
      expect(engine.moveUnit(2, 4), isTrue);
      expect(engine.makePeace(0, 2), isTrue);
      expect(engine.worsenDiplomacy(0, 1), isFalse);
      expect(engine.canFormMilitaryAlliance(0, 3), isFalse);
    });

    test('transitive alliance break cannot strand a third member army', () {
      final state = _blocState(3);
      final engine = GameEngine(mod: mod, state: state);
      _formCoalition(engine, 0, 1);
      _formCoalition(engine, 1, 2);
      state.hexes[5].unit = GameUnit(strength: 1, owner: 0, homeProvinceId: 1);
      expect(engine.worsenDiplomacy(1, 2), isFalse);
      expect(engine.hasMilitaryAccess(0, 2), isTrue);
    });

    test('round-one neutral countries can exchange a military alliance', () {
      final state = _blocState(2);
      final engine = GameEngine(mod: mod, state: state);
      const allianceOffer = DiplomacyOffer(
        type: DiplomacyExchangeType.militaryAlliance,
      );

      expect(state.round, 1);
      expect(engine.diplomacyBetween(0, 1), DiplomacyStatus.peace);
      expect(
        engine.proposeExchange(
          from: 0,
          to: 1,
          fromOffer: allianceOffer,
          toOffer: allianceOffer,
        ),
        isTrue,
      );

      final proposal = state.diplomacyProposals.single;
      expect(engine.resolveDiplomacyProposal(proposal, accept: true), isTrue);
      expect(engine.diplomacyBetween(0, 1), DiplomacyStatus.coalition);
    });

    test('war still blocks a military-alliance exchange', () {
      final state = _blocState(2);
      final engine = GameEngine(mod: mod, state: state);
      const allianceOffer = DiplomacyOffer(
        type: DiplomacyExchangeType.militaryAlliance,
      );
      engine.setDiplomacyStatus(0, 1, DiplomacyStatus.war);

      expect(engine.canFormMilitaryAlliance(0, 1), isFalse);
      expect(
        engine.proposeExchange(
          from: 0,
          to: 1,
          fromOffer: allianceOffer,
          toOffer: allianceOffer,
        ),
        isFalse,
      );
    });

    test('a black mark still blocks a military-alliance exchange', () {
      final state = _blocState(2);
      final engine = GameEngine(mod: mod, state: state);
      const allianceOffer = DiplomacyOffer(
        type: DiplomacyExchangeType.militaryAlliance,
      );

      expect(engine.placeBlackMark(0, 1), isTrue);
      expect(engine.canFormMilitaryAlliance(0, 1), isFalse);
      expect(
        engine.proposeExchange(
          from: 0,
          to: 1,
          fromOffer: allianceOffer,
          toOffer: allianceOffer,
        ),
        isFalse,
      );
    });

    test('a military alliance cannot bypass a friend camp black mark', () {
      final state = _blocState(3);
      final engine = GameEngine(mod: mod, state: state);
      engine.setDiplomacyStatus(0, 2, DiplomacyStatus.alliance);
      state.diplomacyAllianceTurns[0][2] = 12;
      state.diplomacyAllianceTurns[2][0] = 12;
      expect(engine.placeBlackMark(1, 2), isTrue);

      expect(engine.canBecomeFriends(0, 1), isFalse);
      expect(engine.canFormMilitaryAlliance(0, 1), isFalse);
    });

    test('coalition access is transitive across the complete component', () {
      final engine = GameEngine(mod: mod, state: _blocState(3));

      _formCoalition(engine, 0, 1);
      _formCoalition(engine, 1, 2);

      expect(engine.militaryAllianceComponent(0), {0, 1, 2});
      expect(engine.militaryAllianceComponent(2), {0, 1, 2});
      expect(engine.hasMilitaryAccess(0, 2), isTrue);
      expect(engine.hasMilitaryAccess(2, 0), isTrue);
      expect(
        engine.diplomacyBetween(0, 2),
        DiplomacyStatus.peace,
        reason: 'transitive access must not rewrite an unrelated direct edge',
      );
    });

    test(
      'a declaration propagates to both blocs and serializes its campaign',
      () {
        final state = _blocState(4);
        final engine = GameEngine(mod: mod, state: state);
        _formCoalition(engine, 0, 1);
        _formCoalition(engine, 2, 3);

        expect(engine.declareWar(1, 3), isTrue);
        for (final attacker in const [0, 1]) {
          for (final defender in const [2, 3]) {
            expect(
              engine.diplomacyBetween(attacker, defender),
              DiplomacyStatus.war,
            );
          }
        }

        final campaign = state.campaigns.single;
        expect(campaign.attackerLeader, 1);
        expect(campaign.defenderLeader, 3);
        expect(campaign.sideA, [0, 1]);
        expect(campaign.sideB, [2, 3]);

        final restored = GameState.fromJson(state.toJson());
        expect(restored.toJson()['schema'], 12);
        expect(restored.nextWarCampaignId, 2);
        expect(restored.campaigns, hasLength(1));
        expect(restored.campaigns.single.id, campaign.id);
        expect(restored.campaigns.single.sideA, [0, 1]);
        expect(restored.campaigns.single.sideB, [2, 3]);
        expect(restored.diplomacyRelations[0][1], DiplomacyStatus.coalition);
        expect(restored.diplomacyRelations[2][3], DiplomacyStatus.coalition);
      },
    );

    test('peace with one opponent ends the whole bloc campaign', () {
      final state = _blocState(4);
      final engine = GameEngine(mod: mod, state: state);
      _formCoalition(engine, 0, 1);
      _formCoalition(engine, 2, 3);
      expect(engine.declareWar(0, 2), isTrue);

      expect(engine.makePeace(1, 3), isTrue);

      expect(state.campaigns, isEmpty);
      for (final first in const [0, 1]) {
        for (final second in const [2, 3]) {
          expect(engine.diplomacyBetween(first, second), DiplomacyStatus.peace);
          expect(state.diplomacyWarCooldowns[first][second], 9);
        }
      }
      expect(engine.diplomacyBetween(0, 1), DiplomacyStatus.coalition);
      expect(engine.diplomacyBetween(2, 3), DiplomacyStatus.coalition);
    });

    test(
      'allied traversal preserves host land and charges the origin province',
      () {
        final state = _transitState();
        final engine = GameEngine(mod: mod, state: state);
        _formCoalition(engine, 0, 1);
        final home = engine.provincesOf(0).single;
        final host = engine.provincesOf(1).single;
        final homeUpkeepBefore = engine.economicBreakdown(home).landUnits;
        final hostUpkeepBefore = engine.economicBreakdown(host).landUnits;

        expect(engine.moveUnit(1, 2), isTrue);

        final guest = state.hexes[2].unit!;
        expect(state.hexes[2].owner, 1);
        expect(state.hexes[2].object, TileObject.pine);
        expect(guest.owner, 0);
        expect(guest.homeProvinceId, home.id);
        expect(guest.transitAllies, [1]);
        engine.rebuildProvinces();
        expect(state.hexes[2].unit!.homeProvinceId, home.id);
        expect(engine.economicBreakdown(home).landUnits, homeUpkeepBefore);
        expect(engine.economicBreakdown(host).landUnits, hostUpkeepBefore);
      },
    );

    test('a direct solo conquest remains ordinary sovereign land', () {
      final state = _soloCaptureState();
      final engine = GameEngine(mod: mod, state: state);

      expect(engine.declareWar(0, 1), isTrue);
      expect(engine.moveUnit(1, 2), isTrue);

      expect(state.hexes[2].owner, 0);
      expect(state.hexes[2].coalitionClaim, isNull);
      expect(state.hexes[2].object, TileObject.none);
      expect(engine.provinceAt(2)?.owner, 0);
    });

    test(
      'capture after allied transit creates a non-province shared claim',
      () {
        final result = _captureAfterAlliedTransit(mod);
        final state = result.state;
        final engine = result.engine;
        final claim = state.hexes[4].coalitionClaim;

        expect(claim, isNotNull);
        expect(claim!.campaignId, state.campaigns.single.id);
        expect(claim.originalOwner, 2);
        expect(claim.members, [0, 1]);
        expect(claim.contributors, [0, 1]);
        expect(claim.captor, 0);
        expect(claim.settlementValue, 25);
        expect(claim.conferenceId, -1);
        expect(state.hexes[4].owner, 0);
        expect(state.hexes[4].object, TileObject.none);
        expect(engine.provinceAt(4), isNull);
      },
    );

    test('peace opens a persisted five-round conference for shared claims', () {
      final result = _captureAfterAlliedTransit(mod);
      final state = result.state;
      final engine = result.engine;

      expect(engine.makePeace(0, 2), isTrue);

      expect(state.campaigns, isEmpty);
      expect(state.hexes[4].coalitionClaim, isNotNull);
      expect(state.hexes[4].owner, 0);
      expect(state.hexes[4].object, TileObject.none);
      expect(engine.diplomacyBetween(0, 2), DiplomacyStatus.peace);
      expect(engine.diplomacyBetween(1, 2), DiplomacyStatus.peace);

      final conference = state.peaceConferences.single;
      expect(conference.sourceCampaignId, 1);
      expect(conference.originalOwner, 2);
      expect(conference.claimTiles, [4]);
      expect(conference.participants, [0, 1]);
      expect(conference.tileValues, {4: 25});
      expect(conference.contributionPoints, {0: 13, 1: 12});
      expect(conference.openedRound, 1);
      expect(conference.deadlineRound, 6);
      expect(state.hexes[4].coalitionClaim!.conferenceId, conference.id);

      final restored = GameState.fromJson(state.toJson());
      expect(restored.toJson()['schema'], 12);
      expect(restored.nextPeaceConferenceId, 2);
      expect(restored.peaceConferences.single.tileValues, {4: 25});
      expect(restored.peaceConferences.single.contributionPoints, {
        0: 13,
        1: 12,
      });
    });

    test('direct conquest stays sovereign when that war makes peace', () {
      final state = _directPeaceState();
      final engine = GameEngine(mod: mod, state: state);
      expect(engine.declareWar(0, 1), isTrue);
      expect(engine.moveUnit(1, 2), isTrue);

      expect(engine.makePeace(0, 1), isTrue);

      expect(state.peaceConferences, isEmpty);
      expect(state.hexes[2].coalitionClaim, isNull);
      expect(state.hexes[2].owner, 0);
    });

    test(
      'claim keeps full campaign access but credits only traversed allies',
      () {
        final state = _transitStateWithReserveAlly();
        final engine = GameEngine(mod: mod, state: state);
        _formCoalition(engine, 0, 1);
        _formCoalition(engine, 0, 3);
        expect(engine.declareWar(0, 2), isTrue);
        expect(engine.moveUnit(1, 2), isTrue);
        state.hexes[2].unit!.ready = true;
        expect(engine.moveUnit(2, 4), isTrue);

        final claim = state.hexes[4].coalitionClaim!;
        expect(claim.members, [0, 1, 3]);
        expect(claim.contributors, [0, 1]);
        expect(claim.settlementValue, 100);
      },
    );

    test('counteroffer replaces allocations and unanimous consent settles', () {
      final result = _openTwoClaimConference(mod);
      final state = result.state;
      final engine = result.engine;
      final conference = state.peaceConferences.single;

      expect(conference.contributionPoints, {0: 25, 1: 25});
      expect(
        engine.submitPeaceConferenceProposal(conference.id, 0, {
          0: [4, 6],
        }),
        isFalse,
        reason: 'assigned value may not exceed the participant quota',
      );
      expect(
        engine.submitPeaceConferenceProposal(conference.id, 0, {
          0: [4],
          1: [4],
        }),
        isFalse,
        reason: 'one disputed tile cannot be assigned twice',
      );
      expect(
        engine.submitPeaceConferenceProposal(conference.id, 0, {
          0: [4],
          1: [6],
        }),
        isTrue,
      );
      expect(conference.revision, 1);
      expect(conference.acceptedBy, [0]);

      expect(
        engine.submitPeaceConferenceProposal(conference.id, 1, {
          0: [6],
          1: [4],
        }),
        isTrue,
      );
      expect(conference.revision, 2);
      expect(conference.acceptedBy, [1]);
      expect(engine.acceptPeaceConference(conference.id, 0), isTrue);

      expect(state.peaceConferences, isEmpty);
      expect(state.hexes[4].coalitionClaim, isNull);
      expect(state.hexes[6].coalitionClaim, isNull);
      expect(state.hexes[4].owner, 1);
      expect(state.hexes[6].owner, 0);
      expect(state.diplomacyWarCooldowns[0][2], 10);
      expect(state.diplomacyWarCooldowns[1][2], 10);
    });

    test(
      'fifth completed round restores omitted claims and repatriates army',
      () {
        final result = _captureAfterAlliedTransit(mod);
        final state = result.state;
        final engine = result.engine;
        expect(engine.makePeace(0, 2), isTrue);
        expect(state.round, 1);
        expect(state.peaceConferences.single.deadlineRound, 6);

        for (var turn = 0; turn < 15; turn++) {
          engine.endTurn();
        }

        expect(state.round, 6);
        expect(state.peaceConferences, isEmpty);
        expect(state.hexes[4].coalitionClaim, isNull);
        expect(state.hexes[4].owner, 2);
        expect(state.hexes[4].unit, isNull);
        expect(
          state.hexes.where((tile) => tile.unit?.owner == 0),
          hasLength(1),
        );
        expect(state.diplomacyWarCooldowns[0][2], 10);
        expect(state.diplomacyWarCooldowns[1][2], 10);
        expect(engine.declareWar(0, 2), isFalse);

        for (var turn = 0; turn < 27; turn++) {
          engine.endTurn();
        }
        expect(state.diplomacyWarCooldowns[0][2], 1);
        expect(engine.declareWar(0, 2), isFalse);
        for (var turn = 0; turn < 3; turn++) {
          engine.endTurn();
        }
        expect(state.diplomacyWarCooldowns[0][2], 0);
        expect(engine.declareWar(0, 2), isTrue);
      },
    );

    test('a bloc member cannot bypass another member war ban', () {
      final state = _blocState(3);
      final engine = GameEngine(mod: mod, state: state);
      _formCoalition(engine, 0, 1);
      state.diplomacyWarCooldowns[0][2] = 10;
      state.diplomacyWarCooldowns[2][0] = 10;

      expect(state.diplomacyWarCooldowns[1][2], 0);
      expect(engine.declareWar(1, 2), isFalse);
      expect(state.campaigns, isEmpty);
      expect(engine.diplomacyBetween(0, 2), DiplomacyStatus.peace);
      expect(engine.diplomacyBetween(1, 2), DiplomacyStatus.peace);
    });
  });
}

void _formCoalition(GameEngine engine, int first, int second) {
  engine.setDiplomacyStatus(first, second, DiplomacyStatus.alliance);
  expect(engine.formMilitaryAlliance(first, second), isTrue);
}

GameState _blocState(int playerCount) {
  final owners = <int>[
    for (var owner = 0; owner < playerCount; owner++) ...[owner, owner],
  ];
  final hexes = <HexTile>[
    for (var index = 0; index < owners.length; index++)
      HexTile(
        index: index,
        q: index,
        r: 0,
        active: true,
        owner: owners[index],
        object: index.isEven ? TileObject.town : TileObject.none,
        neighbors: [
          if (index > 0) index - 1,
          if (index + 1 < owners.length) index + 1,
        ],
      ),
  ];
  return GameState(
    config: GameConfig(
      playerCount: playerCount,
      humanCount: playerCount,
      diplomacy: true,
      seed: 1,
    ),
    modId: 'classic_steppe',
    width: hexes.length,
    height: 1,
    hexes: hexes,
    provinces: [
      for (var owner = 0; owner < playerCount; owner++)
        Province(
          id: owner + 1,
          owner: owner,
          tiles: [owner * 2, owner * 2 + 1],
          money: 100,
          capital: owner * 2,
        ),
    ],
    turn: 0,
    round: 1,
    rngState: 1,
    nextProvinceId: playerCount + 1,
  );
}

GameState _isolatedHoldingState() {
  final state = _blocState(4);
  const owners = [0, 0, 1, -1, 1, 1, 2, 2];
  for (var i = 0; i < state.hexes.length; i++) {
    state.hexes[i]
      ..owner = owners[i]
      ..object = TileObject.none;
  }
  for (final i in [0, 4, 6]) {
    state.hexes[i].object = TileObject.town;
  }
  state.hexes[1].unit = GameUnit(strength: 2, owner: 0, homeProvinceId: 1);
  state.hexes[2].object = TileObject.pine;
  state.provinces
    ..clear()
    ..addAll([
      Province(id: 1, owner: 0, tiles: [0, 1], money: 100, capital: 0),
      Province(id: 2, owner: 1, tiles: [4, 5], money: 100, capital: 4),
      Province(id: 3, owner: 2, tiles: [6, 7], money: 100, capital: 6),
    ]);
  return state;
}

GameState _transitState() {
  final owners = <int>[0, 0, 1, 1, 2, 2, 2];
  final hexes = <HexTile>[
    for (var index = 0; index < owners.length; index++)
      HexTile(
        index: index,
        q: index,
        r: 0,
        active: true,
        owner: owners[index],
        neighbors: [
          if (index > 0) index - 1,
          if (index + 1 < owners.length) index + 1,
        ],
      ),
  ];
  hexes[0].object = TileObject.town;
  hexes[1].unit = GameUnit(strength: 2);
  hexes[2]
    ..object = TileObject.pine
    ..treeBorn = 0;
  hexes[3].object = TileObject.town;
  hexes[5].object = TileObject.town;
  return GameState(
    config: const GameConfig(
      playerCount: 3,
      humanCount: 3,
      diplomacy: true,
      seed: 1,
    ),
    modId: 'classic_steppe',
    width: hexes.length,
    height: 1,
    hexes: hexes,
    provinces: [
      Province(id: 1, owner: 0, tiles: [0, 1], money: 100, capital: 0),
      Province(id: 2, owner: 1, tiles: [2, 3], money: 100, capital: 3),
      Province(id: 3, owner: 2, tiles: [4, 5, 6], money: 100, capital: 5),
    ],
    turn: 0,
    round: 1,
    rngState: 1,
    nextProvinceId: 4,
  );
}

GameState _directPeaceState() {
  final owners = <int>[0, 0, 1, 1, 1];
  final hexes = <HexTile>[
    for (var index = 0; index < owners.length; index++)
      HexTile(
        index: index,
        q: index,
        r: 0,
        active: true,
        owner: owners[index],
        neighbors: [
          if (index > 0) index - 1,
          if (index + 1 < owners.length) index + 1,
        ],
      ),
  ];
  hexes[0].object = TileObject.town;
  hexes[1].unit = GameUnit(strength: 2);
  hexes[3].object = TileObject.town;
  return GameState(
    config: const GameConfig(
      playerCount: 2,
      humanCount: 2,
      diplomacy: true,
      seed: 1,
    ),
    modId: 'classic_steppe',
    width: hexes.length,
    height: 1,
    hexes: hexes,
    provinces: [
      Province(id: 1, owner: 0, tiles: [0, 1], money: 100, capital: 0),
      Province(id: 2, owner: 1, tiles: [2, 3, 4], money: 100, capital: 3),
    ],
    turn: 0,
    round: 1,
    rngState: 1,
    nextProvinceId: 3,
  );
}

GameState _transitStateWithReserveAlly() {
  final owners = <int>[0, 0, 1, 1, 2, 2, 2, 3, 3];
  final hexes = <HexTile>[
    for (var index = 0; index < owners.length; index++)
      HexTile(
        index: index,
        q: index,
        r: 0,
        active: true,
        owner: owners[index],
        neighbors: [
          if (index > 0) index - 1,
          if (index + 1 < owners.length) index + 1,
        ],
      ),
  ];
  hexes[0].object = TileObject.town;
  hexes[1].unit = GameUnit(strength: 2);
  hexes[3].object = TileObject.town;
  hexes[4].object = TileObject.farm;
  hexes[5].object = TileObject.town;
  hexes[7].object = TileObject.town;
  return GameState(
    config: const GameConfig(
      playerCount: 4,
      humanCount: 4,
      diplomacy: true,
      seed: 1,
    ),
    modId: 'classic_steppe',
    width: hexes.length,
    height: 1,
    hexes: hexes,
    provinces: [
      Province(id: 1, owner: 0, tiles: [0, 1], money: 100, capital: 0),
      Province(id: 2, owner: 1, tiles: [2, 3], money: 100, capital: 3),
      Province(id: 3, owner: 2, tiles: [4, 5, 6], money: 100, capital: 5),
      Province(id: 4, owner: 3, tiles: [7, 8], money: 100, capital: 7),
    ],
    turn: 0,
    round: 1,
    rngState: 1,
    nextProvinceId: 5,
  );
}

GameState _soloCaptureState() {
  final state = _blocState(2);
  state.hexes[1].unit = GameUnit(strength: 2);
  return state;
}

({GameState state, GameEngine engine}) _captureAfterAlliedTransit(GameMod mod) {
  final state = _transitState();
  final engine = GameEngine(mod: mod, state: state);
  _formCoalition(engine, 0, 1);
  expect(engine.declareWar(0, 2), isTrue);
  expect(engine.moveUnit(1, 2), isTrue);
  state.hexes[2].unit!.ready = true;
  expect(engine.moveUnit(2, 4), isTrue);
  return (state: state, engine: engine);
}

({GameState state, GameEngine engine}) _openTwoClaimConference(GameMod mod) {
  final result = _captureAfterAlliedTransit(mod);
  final state = result.state;
  final engine = result.engine;
  final campaign = state.campaigns.single;
  state.hexes[6]
    ..owner = 0
    ..object = TileObject.none
    ..coalitionClaim = CoalitionClaim(
      campaignId: campaign.id,
      originalOwner: 2,
      members: const [0, 1],
      captor: 0,
      contributors: const [0, 1],
      settlementValue: 25,
    );
  expect(engine.makePeace(0, 2), isTrue);
  return result;
}
