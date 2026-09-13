part of 'game_engine.dart';

extension DiplomacyRules on GameEngine {
  static const maxTerms = 3;

  /// Type-level choices for an unfinished draft. Concrete amounts and cells
  /// still use the authoritative validator when the proposal is submitted.
  bool canChooseExchangeType(
    int giver,
    int receiver,
    DiplomacyExchangeType type,
    Iterable<DiplomacyTerm> otherTerms,
  ) {
    if (type == DiplomacyExchangeType.nothing) return true;
    if (!_validDiplomacyPair(giver, receiver)) return false;
    const relationTypes = {
      DiplomacyExchangeType.friendship,
      DiplomacyExchangeType.militaryAlliance,
      DiplomacyExchangeType.ceasefire,
      DiplomacyExchangeType.removeBlackMark,
    };
    final types = otherTerms.map((t) => t.offer.type).toSet();
    if (relationTypes.contains(type) &&
        types.any(
          (t) =>
              (relationTypes.contains(t) && t != type) ||
              t == DiplomacyExchangeType.warDeclaration,
        )) {
      return false;
    }
    if (type == DiplomacyExchangeType.warDeclaration &&
        types.any(relationTypes.contains)) {
      return false;
    }
    return switch (type) {
      DiplomacyExchangeType.friendship =>
        diplomacyBetween(giver, receiver) != DiplomacyStatus.war &&
            diplomacyBetween(giver, receiver) != DiplomacyStatus.coalition &&
            canBecomeFriends(giver, receiver),
      DiplomacyExchangeType.militaryAlliance => canFormMilitaryAlliance(
        giver,
        receiver,
      ),
      DiplomacyExchangeType.ceasefire =>
        areEnemies(giver, receiver) && diplomacyCooldown(giver, receiver) == 0,
      DiplomacyExchangeType.removeBlackMark => hasBlackMark(giver, receiver),
      DiplomacyExchangeType.warDeclaration => List.generate(
        state.config.playerCount,
        (p) => p,
      ).any((p) => canDeclareWar(giver, p)),
      DiplomacyExchangeType.lands => state.hexes.any(
        (t) => t.active && t.owner == giver && t.coalitionClaim == null,
      ),
      _ => true,
    };
  }

  int opinionOf(int observer, int subject) =>
      _validDiplomacyIndexes(observer, subject)
      ? state.diplomacySocial.relationship(observer, subject)
      : 0;

  void changeOpinion(int observer, int subject, int delta, String reason) {
    if (!state.config.diplomacy ||
        observer == subject ||
        delta == 0 ||
        !_validDiplomacyIndexes(observer, subject)) {
      return;
    }
    final social = state.diplomacySocial;
    if (social.events.any(
      (event) =>
          ((event.observer == observer && event.subject == subject) ||
              (event.observer == subject && event.subject == observer)) &&
          event.round == state.round &&
          event.reason == reason,
    )) {
      return;
    }
    final old = opinionOf(observer, subject);
    final value = (old + delta).clamp(-100, 100);
    if (old == value) return;
    social.opinions[observer][subject] = value;
    social.opinions[subject][observer] = value;
    social.events.add(
      DiplomacyOpinionEvent(
        observer: observer,
        subject: subject,
        delta: value - old,
        round: state.round,
        reason: reason,
      ),
    );
    if (social.events.length > 160) social.events.removeAt(0);
  }

  int militaryAllianceTrustRequired(int first, int second) => 0;
  String? botAllianceAdmissionError(int first, int second) =>
      'Әскери одақ қолдау таппайды';
  bool botWantsMilitaryAlliance(int bot, int other) => false;

  int opinionActionCooldown(int actor, int other) => math.max(
    state.diplomacySocial.actionCooldowns[actor][other],
    state.diplomacySocial.actionCooldowns[other][actor],
  );

  bool influenceOpinion(int actor, int other, {required bool improve}) {
    if (!_validDiplomacyPair(actor, other) ||
        opinionActionCooldown(actor, other) > 0) {
      return false;
    }
    if (improve &&
        (areEnemies(actor, other) ||
            hasBlackMark(actor, other) ||
            playerMoney(actor) < 10)) {
      return false;
    }
    if (improve) {
      var remaining = 10;
      final provinces = provincesOf(actor).toList()
        ..sort((a, b) => b.money.compareTo(a.money));
      for (final province in provinces) {
        final paid = math.min(remaining, math.max(0, province.money));
        province.money -= paid;
        remaining -= paid;
        if (remaining == 0) break;
      }
    }
    state.diplomacySocial.actionCooldowns[actor][other] = 3;
    changeOpinion(
      other,
      actor,
      improve ? 12 : -15,
      improve ? 'Елшілік сапары' : 'Дипломатиялық наразылық',
    );
    sendDiplomacyMessage(
      from: actor,
      to: other,
      text:
          '${state.playerName(actor)} ${improve ? 'елшілік жіберді. Қатынас +12' : 'наразылық білдірді. Қатынас −15'}',
    );
    return true;
  }

  void _advanceOpinionRound() {
    if (!state.config.diplomacy) return;
    final alive = state.provinces.map((p) => p.owner).toSet();
    for (var a = 0; a < state.config.playerCount; a++) {
      for (var b = 0; b < state.config.playerCount; b++) {
        final cooldown = state.diplomacySocial.actionCooldowns[a][b];
        if (cooldown > 0) {
          state.diplomacySocial.actionCooldowns[a][b] = cooldown - 1;
        }
        if (a >= b || !alive.contains(a) || !alive.contains(b)) continue;
        final status = diplomacyBetween(a, b);
        final score = opinionOf(a, b);
        if ((status == DiplomacyStatus.alliance && score < 60) ||
            (status == DiplomacyStatus.coalition && score < 80)) {
          changeOpinion(a, b, 2, 'Келісімге адалдық');
        } else if (status == DiplomacyStatus.war && score > -80) {
          changeOpinion(a, b, -1, 'Соғыс жалғасуда');
        } else if (status == DiplomacyStatus.peace &&
            state.round % 5 == 0 &&
            score != 0 &&
            !hasBlackMark(a, b)) {
          changeOpinion(a, b, score > 0 ? -1 : 1, 'Уақыт өте бейтараптану');
        }
        if (status != DiplomacyStatus.war &&
            score < 30 &&
            alive.any(
              (enemy) =>
                  enemy != a &&
                  enemy != b &&
                  areEnemies(a, enemy) &&
                  areEnemies(b, enemy),
            )) {
          changeOpinion(a, b, 1, 'Ортақ жау');
        }
      }
    }
  }

  bool canDeclareWar(int attacker, int defender) =>
      _validDiplomacyPair(attacker, defender) &&
      diplomacyBetween(attacker, defender) == DiplomacyStatus.peace &&
      diplomacyCooldown(attacker, defender) == 0;

  /// Validate all conditions against the same pre-contract state. No item is
  /// applied on failure; split land rows cannot evade seller connectivity.
  String? exchangeValidationError(int from, int to, List<DiplomacyTerm> terms) {
    if (!_validDiplomacyPair(from, to)) return 'Ел енді ойында жоқ';
    if (terms.isEmpty || terms.length > maxTerms) {
      return 'Мәміледе 1–3 шарт болуы керек';
    }
    final active = terms
        .where((t) => t.offer.type != DiplomacyExchangeType.nothing)
        .toList();
    if (active.isEmpty) return 'Кемінде бір шарт таңдаңыз';
    final land = <int>{};
    final navy = <NavalAssetRef>{};
    final subsidies = <bool>{};
    final relations = <DiplomacyExchangeType>{};
    int? friendshipDuration;
    var wars = 0;
    for (final term in active) {
      final offer = term.offer;
      if (offer.amount < 0 ||
          offer.amount > 10000 ||
          offer.duration < 0 ||
          offer.duration > 20 ||
          (offer.type == DiplomacyExchangeType.subsidies &&
              offer.amount > 250)) {
        return 'Шарттың мөлшері жарамсыз';
      }
      if (offer.type == DiplomacyExchangeType.lands) {
        for (final tile in offer.tiles) {
          if (!land.add(tile)) return 'Бір жер екі рет берілмейді';
        }
        for (final ref in offer.navalRefs) {
          if (!navy.add(ref)) return 'Бір кеме немесе қамал екі рет берілмейді';
        }
      }
      if (offer.type == DiplomacyExchangeType.subsidies &&
          !subsidies.add(term.fromSender)) {
        return 'Бір тарапқа бір субсидия шартын қолданыңыз';
      }
      if (offer.type == DiplomacyExchangeType.friendship ||
          offer.type == DiplomacyExchangeType.militaryAlliance) {
        final duration = offer.duration > 0 ? offer.duration : 12;
        if (friendshipDuration != null && friendshipDuration != duration) {
          return 'Достықтың екі шартының мерзімі бірдей болуы керек';
        }
        friendshipDuration = duration;
      }
      if ({
        DiplomacyExchangeType.friendship,
        DiplomacyExchangeType.militaryAlliance,
        DiplomacyExchangeType.ceasefire,
        DiplomacyExchangeType.removeBlackMark,
      }.contains(offer.type)) {
        relations.add(offer.type);
      }
      if (offer.type == DiplomacyExchangeType.warDeclaration) wars++;
    }
    // These transitions must be separate agreements, not an order-dependent
    // back door around ceasefire/black-mark/membership restrictions.
    if (relations.length > 1 || (wars > 0 && relations.isNotEmpty)) {
      return 'Алдымен бір дипломатиялық мәртебені келісіңіз';
    }
    for (final term in _normalizedTerms(terms)) {
      if (term.offer.type == DiplomacyExchangeType.militaryAlliance) {
        final admissionError = botAllianceAdmissionError(from, to);
        if (admissionError != null) return admissionError;
      }
      if (!_offerIsValid(
        term.fromSender ? from : to,
        term.fromSender ? to : from,
        term.offer,
      )) {
        return 'Шарт орындалмайды: жер, бітім немесе одақ шектеуін тексеріңіз';
      }
    }
    return null;
  }

  List<DiplomacyTerm> _normalizedTerms(List<DiplomacyTerm> terms) {
    final result = <DiplomacyTerm>[];
    final relations = <DiplomacyExchangeType>{};
    for (final term in terms) {
      final offer = term.offer;
      if (offer.type == DiplomacyExchangeType.nothing) continue;
      if ({
            DiplomacyExchangeType.friendship,
            DiplomacyExchangeType.militaryAlliance,
            DiplomacyExchangeType.ceasefire,
            DiplomacyExchangeType.removeBlackMark,
          }.contains(offer.type) &&
          !relations.add(offer.type)) {
        continue;
      }
      if (offer.type == DiplomacyExchangeType.lands) {
        final index = result.indexWhere(
          (t) =>
              t.fromSender == term.fromSender &&
              t.offer.type == DiplomacyExchangeType.lands,
        );
        if (index >= 0) {
          final old = result[index].offer;
          result[index] = DiplomacyTerm(
            fromSender: term.fromSender,
            offer: old.copyWith(
              tiles: [...old.tiles, ...offer.tiles],
              navalRefs: [...old.navalRefs, ...offer.navalRefs],
            ),
          );
          continue;
        }
      }
      result.add(term);
    }
    return result;
  }

  void _recordAcceptedExchange(DiplomacyProposal proposal) {
    final rewarded = state.diplomacySocial.lastTradeReward;
    if (rewarded[proposal.from][proposal.to] == state.round) return;
    rewarded[proposal.from][proposal.to] = state.round;
    rewarded[proposal.to][proposal.from] = state.round;
    changeOpinion(proposal.from, proposal.to, 3, 'Мәміле орындалды');
  }
}
