import '../game/models.dart';

enum DiplomacyObligationKind { debt, subsidy, compensation }

/// A contractual amount, not a prediction of the next treasury payment.
/// Positive values are receivable by the viewer; negative values are payable.
class DiplomacyObligation {
  const DiplomacyObligation({
    required this.kind,
    required this.amount,
    this.turnsLeft,
    this.paused = false,
  });

  final DiplomacyObligationKind kind;
  final int amount;
  final int? turnsLeft;
  final bool paused;

  String get signedMoney => '${amount > 0 ? '+' : '−'}\$${amount.abs()}';

  String get label => switch (kind) {
    DiplomacyObligationKind.debt =>
      '${amount > 0 ? 'Сізге қарыз' : 'Сіз қарыз'} $signedMoney${paused ? ' · Төлем тоқтаулы' : ''}',
    DiplomacyObligationKind.subsidy =>
      'Субсидия $signedMoney/ход · ${turnsLeft}x',
    DiplomacyObligationKind.compensation =>
      'Өтемақы $signedMoney/ход · ${turnsLeft}x',
  };

  String get description {
    if (kind == DiplomacyObligationKind.debt) {
      final principal = amount > 0
          ? 'Ол сізге \$${amount.abs()} қарыз. Бұл — қалған қарыз, әр ходтағы табыс емес.'
          : 'Сіз оған \$${amount.abs()} қарызсыз. Бұл — қалған қарыз, әр ходтағы шығын емес.';
      return paused
          ? '$principal Соғыс қарызды жоймайды. Бітімнен кейін төлем жалғасады.'
          : principal;
    }
    final direction = amount > 0 ? 'Ол сізге' : 'Сіз оған';
    final reason = kind == DiplomacyObligationKind.compensation
        ? 'достықты бұзғаны үшін өтемақы'
        : 'субсидия';
    final verb = amount > 0 ? 'төлейді' : 'төлейсіз';
    return '$direction әр ходта \$${amount.abs()} $reason $verb. '
        '$turnsLeft ход қалды. Бұл келісім сомасы; нақты төлем төлеушінің табысы мен қазынасына байланысты.';
  }
}

/// Read-only, map-size-independent projection of bilateral diplomacy.
/// Never net opposite debts or merge contracts with different expiry dates.
class DiplomacyOverview {
  DiplomacyOverview.fromState(GameState state, int viewer, int other)
    : status = state.diplomacyRelations[viewer][other],
      relationship = state.diplomacySocial.relationship(viewer, other),
      friendshipTurns = state.diplomacyAllianceTurns[viewer][other],
      cooldown = state.diplomacyWarCooldowns[viewer][other],
      blackMark =
          state.diplomacyBlackMarks[viewer][other] ||
          state.diplomacyBlackMarks[other][viewer] {
    final entries = <DiplomacyObligation>[];
    final incoming = state.diplomacyDebts[other][viewer];
    final outgoing = state.diplomacyDebts[viewer][other];
    if (incoming > 0) {
      entries.add(
        DiplomacyObligation(
          kind: DiplomacyObligationKind.debt,
          amount: incoming,
          paused: status == DiplomacyStatus.war,
        ),
      );
    }
    if (outgoing > 0) {
      entries.add(
        DiplomacyObligation(
          kind: DiplomacyObligationKind.debt,
          amount: -outgoing,
          paused: status == DiplomacyStatus.war,
        ),
      );
    }
    final payments = <(DiplomacyObligationKind, bool, int), int>{};
    for (final subsidy in state.diplomacySubsidies) {
      final incoming = subsidy.payer == other && subsidy.receiver == viewer;
      final outgoing = subsidy.payer == viewer && subsidy.receiver == other;
      if ((!incoming && !outgoing) ||
          subsidy.amount <= 0 ||
          subsidy.turnsLeft <= 0 ||
          (status == DiplomacyStatus.war && !subsidy.mandatory)) {
        continue;
      }
      final kind = subsidy.mandatory
          ? DiplomacyObligationKind.compensation
          : DiplomacyObligationKind.subsidy;
      final key = (kind, incoming, subsidy.turnsLeft);
      payments.update(
        key,
        (sum) => sum + subsidy.amount,
        ifAbsent: () => subsidy.amount,
      );
    }
    final keys = payments.keys.toList()
      ..sort((a, b) {
        final kind = a.$1.index.compareTo(b.$1.index);
        if (kind != 0) return kind;
        if (a.$2 != b.$2) return a.$2 ? -1 : 1;
        return a.$3.compareTo(b.$3);
      });
    for (final key in keys) {
      entries.add(
        DiplomacyObligation(
          kind: key.$1,
          amount: payments[key]! * (key.$2 ? 1 : -1),
          turnsLeft: key.$3,
        ),
      );
    }
    obligations = List.unmodifiable(entries);
  }

  final DiplomacyStatus status;
  final int relationship;
  final int friendshipTurns;
  final int cooldown;
  final bool blackMark;
  late final List<DiplomacyObligation> obligations;

  String get statusLabel => switch (status) {
    DiplomacyStatus.war =>
      cooldown > 0 ? 'Соғыс · Бітімге $cooldown ход' : 'Соғыс',
    DiplomacyStatus.peace =>
      cooldown > 0 ? 'Бейтарап · Соғысқа тыйым: $cooldown ход' : 'Бейтарап',
    DiplomacyStatus.alliance => 'Достық · $friendshipTurns ход',
    DiplomacyStatus.coalition =>
      'Әскери одақ · ${friendshipTurns > 0 ? friendshipTurns : 12} ход',
  };
}
