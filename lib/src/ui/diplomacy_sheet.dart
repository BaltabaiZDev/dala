import '../l10n/game_locale.dart';
import 'dala_theme.dart';
import 'dala_art.dart';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../game/game_controller.dart';
import '../game/game_engine.dart';
import '../game/models.dart';
import 'classic_assets.dart';
import 'diplomacy_badge.dart';
import 'diplomacy_overview.dart';
import 'hex_board.dart';
import 'organic_cells.dart';
import 'map_viewport.dart';
import 'top_snack_bar.dart';

const _classicMoneyValues = <int>[
  1,
  2,
  5,
  10,
  15,
  20,
  25,
  30,
  40,
  50,
  75,
  100,
  125,
  150,
  175,
  200,
  250,
  300,
  400,
  500,
  750,
  1000,
  2000,
  5000,
  10000,
];

const _classicSubsidyValues = <int>[
  1,
  2,
  5,
  10,
  15,
  20,
  25,
  30,
  40,
  50,
  75,
  100,
  125,
  150,
  175,
  200,
  250,
];

int _classicValueIndex(List<int> values, int value) {
  for (var index = 0; index < values.length; index++) {
    if (value <= values[index]) return index;
  }
  return values.length - 1;
}

int _snapClassicValue(List<int> values, int value) =>
    values[_classicValueIndex(values, value)];

DiplomacyOffer _withClassicAmount(DiplomacyOffer offer) => switch (offer.type) {
  DiplomacyExchangeType.militaryAlliance => offer.copyWith(
    duration: offer.duration > 0 ? offer.duration : 12,
  ),
  DiplomacyExchangeType.money => offer.copyWith(
    amount: _snapClassicValue(_classicMoneyValues, offer.amount),
  ),
  DiplomacyExchangeType.subsidies => offer.copyWith(
    amount: _snapClassicValue(_classicSubsidyValues, offer.amount),
    duration: math.max(1, math.min(20, offer.duration)),
  ),
  _ => offer,
};

Future<void> showAntiyoyDiplomacy(
  BuildContext context,
  GameController controller, {
  int? initialPlayer,
}) {
  final screenHeight = MediaQuery.sizeOf(context).height;
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    barrierColor: Colors.transparent,
    backgroundColor: Colors.transparent,
    constraints: BoxConstraints.tightFor(height: screenHeight * .50),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    clipBehavior: Clip.antiAlias,
    builder: (_) => _DiplomacySheet(
      controller: controller,
      screenHeight: screenHeight,
      initialPlayer: initialPlayer,
    ),
  );
}

Future<void> showAntiyoyDiplomacyInbox(
  BuildContext context,
  GameController controller,
) {
  final screenHeight = MediaQuery.sizeOf(context).height;
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    barrierColor: Colors.transparent,
    backgroundColor: DalaTheme.paper,
    constraints: BoxConstraints.tightFor(height: screenHeight * .50),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    clipBehavior: Clip.antiAlias,
    builder: (_) => _DiplomacyInboxSheet(controller: controller),
  );
}

class _DiplomacyInboxSheet extends StatefulWidget {
  const _DiplomacyInboxSheet({required this.controller});

  final GameController controller;

  @override
  State<_DiplomacyInboxSheet> createState() => _DiplomacyInboxSheetState();
}

enum _DiplomacyInboxPage { list, conferenceReview, conferenceCompose, letter }

class _DiplomacyInboxSheetState extends State<_DiplomacyInboxSheet> {
  _DiplomacyInboxPage _page = _DiplomacyInboxPage.list;
  DiplomacyProposal? _selectedProposal;
  DiplomacyMessage? _selectedMessage;
  int? _conferenceId;
  Map<int, Set<int>> _allocationDraft = <int, Set<int>>{};
  bool _movingForward = true;

  GameController get controller => widget.controller;
  int get current => controller.state.turn;
  List<DiplomacyProposal> get proposals =>
      controller.engine.proposalsFor(current).toList();
  List<DiplomacyMessage> get messages =>
      controller.engine.incomingDiplomacyMessages(current).toList();
  List<PeaceConference> get conferences =>
      controller.engine.peaceConferencesFor(current).toList()
        ..sort((a, b) => a.id.compareTo(b.id));

  PeaceConference? get selectedConference {
    final id = _conferenceId;
    return id == null ? null : controller.engine.peaceConferenceById(id);
  }

  @override
  Widget build(BuildContext context) {
    final conference = selectedConference;
    if ((_page == _DiplomacyInboxPage.conferenceReview ||
            _page == _DiplomacyInboxPage.conferenceCompose) &&
        conference == null) {
      _page = _DiplomacyInboxPage.list;
      _conferenceId = null;
      _allocationDraft = <int, Set<int>>{};
    }
    return PopScope(
      canPop: _page == _DiplomacyInboxPage.list,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _backInsideInbox();
      },
      child: Material(
        color: DalaTheme.paper,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 230),
          reverseDuration: const Duration(milliseconds: 200),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          layoutBuilder: (currentChild, previousChildren) => Stack(
            fit: StackFit.expand,
            children: [...previousChildren, ?currentChild],
          ),
          transitionBuilder: (child, animation) => FadeTransition(
            opacity: animation,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: Offset(_movingForward ? .14 : -.14, 0),
                end: Offset.zero,
              ).animate(animation),
              child: child,
            ),
          ),
          child: switch (_page) {
            _DiplomacyInboxPage.list => _buildInboxList(),
            _DiplomacyInboxPage.letter => _buildLetter(),
            _DiplomacyInboxPage.conferenceReview => _buildConferenceReview(
              conference!,
            ),
            _DiplomacyInboxPage.conferenceCompose => _buildConferenceComposer(
              conference!,
            ),
          },
        ),
      ),
    );
  }

  Widget _buildInboxList() {
    final incomingProposals = proposals;
    final incomingMessages = messages;
    final pendingConferences = conferences;
    final empty =
        incomingProposals.isEmpty &&
        incomingMessages.isEmpty &&
        pendingConferences.isEmpty;
    return Column(
      key: const ValueKey('diplomacy-inbox-list'),
      children: [
        const _ClassicTitleBar(title: 'Хаттар', height: 72),
        Expanded(
          child: empty
              ? const Center(
                  child: GameText(
                    'Жаңа хаттар жоқ',
                    style: TextStyle(fontSize: 17),
                  ),
                )
              : ListView(
                  padding: EdgeInsets.zero,
                  children: [
                    for (final conference in pendingConferences)
                      _InboxRow(
                        key: ValueKey(
                          'peace-conference-inbox-${conference.id}',
                        ),
                        color:
                            controller.mod.palette[conference
                                    .participants
                                    .first %
                                controller.mod.palette.length],
                        title: _peaceConferenceInboxLabel(
                          controller,
                          conference,
                        ),
                        onTap: () => _openConference(conference),
                      ),
                    for (final proposal in incomingProposals)
                      _InboxRow(
                        color:
                            controller.mod.palette[proposal.from %
                                controller.mod.palette.length],
                        title: _inboxProposalLabel(proposal),
                        onTap: () => _openProposal(proposal),
                      ),
                    for (final message in incomingMessages)
                      _InboxRow(
                        color:
                            controller.mod.palette[message.from %
                                controller.mod.palette.length],
                        title: message.text,
                        onTap: () => _openMessage(message),
                      ),
                    if (incomingProposals.isNotEmpty ||
                        incomingMessages.isNotEmpty)
                      InkWell(
                        onTap: () {
                          controller.clearDiplomacyInbox();
                          setState(() {});
                        },
                        child: const SizedBox(
                          height: 64,
                          child: Center(
                            child: GameText(
                              'Тазарту',
                              style: TextStyle(fontSize: 20),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }

  void _backInsideInbox() {
    setState(() {
      _movingForward = false;
      if (_page == _DiplomacyInboxPage.conferenceCompose) {
        _page = _DiplomacyInboxPage.conferenceReview;
      } else {
        _page = _DiplomacyInboxPage.list;
        _conferenceId = null;
        _allocationDraft = <int, Set<int>>{};
      }
    });
  }

  void _openConference(PeaceConference conference) {
    setState(() {
      _conferenceId = conference.id;
      _allocationDraft = <int, Set<int>>{};
      _movingForward = true;
      _page = _DiplomacyInboxPage.conferenceReview;
    });
  }

  Widget _buildConferenceReview(PeaceConference conference) {
    final totalPoints = conference.contributionPoints.values.fold<int>(
      0,
      (sum, value) => sum + value,
    );
    final allocated = conference.allocations.values
        .expand((tiles) => tiles)
        .toSet();
    final unassigned = conference.claimTiles
        .where((tile) => !allocated.contains(tile))
        .toList();
    final unassignedValue = unassigned.fold<int>(
      0,
      (sum, tile) =>
          sum + controller.engine.peaceConferenceTileValue(conference.id, tile),
    );
    final remaining = math.max(
      0,
      conference.deadlineRound - controller.state.round,
    );
    final hasProposal = conference.proposer >= 0 && conference.revision > 0;
    final alreadyAccepted = conference.acceptedBy.contains(current);
    final enabled =
        controller.isLocalHumanTurn && !controller.interactionsLocked;
    return Column(
      key: const ValueKey('peace-conference-review'),
      children: [
        _ClassicTitleBar(
          title: 'Соғыстан кейінгі жер бөлісу',
          onClose: _backInsideInbox,
          height: 56,
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 12),
            children: [
              Container(
                color: DalaTheme.paper,
                padding: const EdgeInsets.all(10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    GameText(
                      '${controller.playerName(conference.originalOwner)} ойыншысының '
                      '${conference.claimTiles.length} даулы жері',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 3),
                    GameText(
                      'Қалғаны: $remaining ход · Ұсыныс №${conference.revision}',
                      style: const TextStyle(fontSize: 14),
                    ),
                    if (!hasProposal)
                      const Padding(
                        padding: EdgeInsets.only(top: 7),
                        child: GameText(
                          'Алғашқы жер бөлу ұсынысы әлі жасалмады.',
                          style: TextStyle(fontSize: 15),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              for (final player in conference.participants)
                _buildConferenceParticipantRow(
                  conference: conference,
                  player: player,
                  totalPoints: totalPoints,
                  assignedValue: controller.engine.peaceConferenceAssignedValue(
                    conference.id,
                    player,
                  ),
                  accepted: conference.acceptedBy.contains(player),
                ),
              Container(
                margin: const EdgeInsets.only(top: 4),
                color: DalaTheme.line,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 9,
                ),
                child: Row(
                  children: [
                    const Expanded(
                      child: GameText(
                        'Бөлінбегені бұрынғы иесіне қайтады',
                        style: TextStyle(fontSize: 15),
                      ),
                    ),
                    GameText(
                      '${unassigned.length} жер · $unassignedValue',
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 54,
          child: Row(
            children: [
              Expanded(
                child: TextButton(
                  key: const ValueKey('peace-conference-counter'),
                  style: TextButton.styleFrom(
                    backgroundColor: DalaTheme.gold,
                    foregroundColor: Colors.black,
                    shape: const RoundedRectangleBorder(),
                  ),
                  onPressed: enabled
                      ? () => _startConferenceComposer(conference)
                      : null,
                  child: GameText(
                    conference.proposer == current ? 'Өзгерту' : 'Қарсы ұсыныс',
                    style: const TextStyle(fontSize: 18),
                  ),
                ),
              ),
              Expanded(
                child: FilledButton(
                  key: const ValueKey('peace-conference-accept'),
                  style: FilledButton.styleFrom(
                    backgroundColor: DalaTheme.green,
                    foregroundColor: Colors.black,
                    disabledBackgroundColor: const Color(0xff8d9b90),
                    shape: const RoundedRectangleBorder(),
                  ),
                  onPressed: enabled && hasProposal && !alreadyAccepted
                      ? () => _acceptConference(conference)
                      : null,
                  child: GameText(
                    alreadyAccepted ? 'Қабылданды' : 'Қабылдау',
                    style: const TextStyle(fontSize: 18),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildConferenceParticipantRow({
    required PeaceConference conference,
    required int player,
    required int totalPoints,
    required int assignedValue,
    required bool accepted,
    VoidCallback? onTap,
  }) {
    final quota = controller.engine.peaceConferenceQuota(conference.id, player);
    final percent = totalPoints <= 0 ? 0 : (quota * 100 / totalPoints).round();
    return InkWell(
      key: ValueKey('peace-allocation-row-$player'),
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 3),
        color: controller.mod.palette[player % controller.mod.palette.length],
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  GameText(
                    '${controller.playerName(player)} · $percent%',
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  GameText(
                    'Бөлінді: $assignedValue / үлесі: $quota',
                    style: const TextStyle(fontSize: 14),
                  ),
                ],
              ),
            ),
            if (accepted)
              const Icon(Icons.check_circle, color: Color(0xff174d22))
            else if (onTap != null)
              const Icon(Icons.chevron_right),
          ],
        ),
      ),
    );
  }

  void _startConferenceComposer(PeaceConference conference) {
    setState(() {
      _allocationDraft = <int, Set<int>>{
        for (final player in conference.participants)
          player: (conference.allocations[player] ?? const <int>[]).toSet(),
      };
      _movingForward = true;
      _page = _DiplomacyInboxPage.conferenceCompose;
    });
  }

  Widget _buildConferenceComposer(PeaceConference conference) {
    final totalPoints = conference.contributionPoints.values.fold<int>(
      0,
      (sum, value) => sum + value,
    );
    final assigned = _allocationDraft.values.expand((tiles) => tiles).toSet();
    final unassigned = conference.claimTiles
        .where((tile) => !assigned.contains(tile))
        .toList();
    final unassignedValue = unassigned.fold<int>(
      0,
      (sum, tile) =>
          sum + controller.engine.peaceConferenceTileValue(conference.id, tile),
    );
    final enabled =
        controller.isLocalHumanTurn && !controller.interactionsLocked;
    return Column(
      key: const ValueKey('peace-conference-compose'),
      children: [
        _ClassicTitleBar(
          title: 'Жер үлесін ұсыну',
          onClose: _backInsideInbox,
          height: 56,
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(10, 7, 10, 12),
            children: [
              const Padding(
                padding: EdgeInsets.only(bottom: 7),
                child: GameText(
                  'Ойыншыны басып, картадан оған берілетін даулы жерлерді таңдаңыз.',
                  style: TextStyle(fontSize: 15),
                ),
              ),
              for (final player in conference.participants)
                _buildConferenceParticipantRow(
                  conference: conference,
                  player: player,
                  totalPoints: totalPoints,
                  assignedValue: _draftAssignedValue(conference, player),
                  accepted: false,
                  onTap: enabled
                      ? () => _openPeaceAllocationPicker(conference, player)
                      : null,
                ),
              Container(
                color: DalaTheme.line,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 9,
                ),
                child: Row(
                  children: [
                    const Expanded(
                      child: GameText(
                        'Бұрынғы иесіне қайтарылады',
                        style: TextStyle(fontSize: 15),
                      ),
                    ),
                    GameText(
                      '${unassigned.length} жер · $unassignedValue',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 52,
          width: double.infinity,
          child: FilledButton(
            key: const ValueKey('peace-allocation-submit'),
            style: FilledButton.styleFrom(
              backgroundColor: DalaTheme.green,
              foregroundColor: Colors.black,
              shape: const RoundedRectangleBorder(),
            ),
            onPressed: enabled ? () => _submitConference(conference) : null,
            child: const GameText('Ұсыну', style: TextStyle(fontSize: 18)),
          ),
        ),
      ],
    );
  }

  int _draftAssignedValue(PeaceConference conference, int player) =>
      (_allocationDraft[player] ?? const <int>{}).fold<int>(
        0,
        (sum, tile) =>
            sum +
            controller.engine.peaceConferenceTileValue(conference.id, tile),
      );

  Map<int, int> _draftAllocationOwners() => <int, int>{
    for (final entry in _allocationDraft.entries)
      for (final tile in entry.value) tile: entry.key,
  };

  Future<void> _openPeaceAllocationPicker(
    PeaceConference conference,
    int recipient,
  ) async {
    final lockedTiles = <int>{
      for (final entry in _allocationDraft.entries)
        if (entry.key != recipient) ...entry.value,
    };
    final selection = await Navigator.of(context, rootNavigator: true)
        .push<_TerritorySelectionResult>(
          MaterialPageRoute<_TerritorySelectionResult>(
            fullscreenDialog: true,
            builder: (_) => _DiplomacyLandSelectionPage(
              controller: controller,
              giver: recipient,
              initialTiles: (_allocationDraft[recipient] ?? const <int>{})
                  .toList(),
              initialNaval: const <NavalAssetRef>[],
              conferenceId: conference.id,
              conferenceRecipient: recipient,
              lockedConferenceTiles: lockedTiles,
              conferenceAllocations: _draftAllocationOwners(),
            ),
          ),
        );
    if (selection == null || !mounted) return;
    setState(() {
      _allocationDraft[recipient] = selection.tiles.toSet();
    });
  }

  void _submitConference(PeaceConference conference) {
    final allocations = <int, List<int>>{
      for (final player in conference.participants)
        player: (_allocationDraft[player] ?? const <int>{}).toList()..sort(),
    };
    final submitted = controller.submitPeaceConferenceProposal(
      conferenceId: conference.id,
      allocations: allocations,
    );
    if (!submitted) {
      showTopSnackBar(context, 'Жер үлесі немесе таңдалған клеткалар жарамсыз');
      return;
    }
    setState(() {
      _movingForward = false;
      _page = _DiplomacyInboxPage.conferenceReview;
    });
  }

  void _acceptConference(PeaceConference conference) {
    final accepted = controller.acceptPeaceConference(conference.id);
    if (!accepted) {
      showTopSnackBar(context, 'Бұл ұсынысты қазір қабылдауға болмайды');
      return;
    }
    setState(() {
      if (controller.engine.peaceConferenceById(conference.id) == null) {
        _movingForward = false;
        _page = _DiplomacyInboxPage.list;
        _conferenceId = null;
      }
    });
  }

  void _openProposal(DiplomacyProposal proposal) {
    setState(() {
      _selectedProposal = proposal;
      _selectedMessage = null;
      _movingForward = true;
      _page = _DiplomacyInboxPage.letter;
    });
  }

  void _openMessage(DiplomacyMessage message) {
    setState(() {
      _selectedMessage = message;
      _selectedProposal = null;
      _movingForward = true;
      _page = _DiplomacyInboxPage.letter;
    });
  }

  Widget _buildLetter() {
    final proposal = _selectedProposal;
    final message = _selectedMessage;
    final sender = proposal?.from ?? message!.from;
    return Column(
      key: const ValueKey('diplomacy-letter-page'),
      children: [
        _ClassicTitleBar(
          title: controller.playerName(sender),
          onClose: _backInsideInbox,
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                GameText(
                  proposal == null ? 'Хат' : _proposalTitle(proposal),
                  style: const TextStyle(fontSize: 16),
                ),
                const SizedBox(height: 8),
                if (proposal?.type == DiplomacyProposalType.exchange)
                  _LetterTerms(
                    controller: controller,
                    proposal: proposal!,
                    concise: true,
                  ),
                if (proposal != null &&
                    proposal.type != DiplomacyProposalType.exchange)
                  for (final term in _proposalTerms(controller, proposal))
                    Container(
                      margin: const EdgeInsets.only(bottom: 5),
                      padding: const EdgeInsets.all(8),
                      color: const Color(0xffd7e7d3),
                      child: GameText(
                        term,
                        style: const TextStyle(fontSize: 13),
                      ),
                    )
                else if (proposal == null)
                  GameText(
                    message!.text,
                    translate: false,
                    style: const TextStyle(fontSize: 14),
                  ),
                if (proposal != null)
                  for (final term in proposal.effectiveTerms.where(
                    (t) => t.offer.type == DiplomacyExchangeType.lands,
                  ))
                    _TerritoryPreviewButton(
                      controller: controller,
                      giver: term.fromSender ? proposal.from : proposal.to,
                      receiver: term.fromSender ? proposal.to : proposal.from,
                      offer: term.offer,
                    ),
                if (proposal != null)
                  _DiplomacyDetails(
                    key: const ValueKey('diplomacy-letter-details'),
                    children: [
                      if (proposal.type == DiplomacyProposalType.exchange)
                        _LetterTerms(
                          controller: controller,
                          proposal: proposal,
                          concise: false,
                        )
                      else
                        for (final text in _proposalTerms(
                          controller,
                          proposal,
                          concise: false,
                        ))
                          GameText(text, style: const TextStyle(fontSize: 13)),
                      if (proposal.rationale.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        GameText(
                          proposal.rationale,
                          key: const ValueKey('diplomacy-letter-rationale'),
                          style: const TextStyle(fontSize: 13, height: 1.2),
                        ),
                      ],
                    ],
                  ),
              ],
            ),
          ),
        ),
        if (proposal != null)
          Row(
            children: [
              Expanded(
                child: _DiplomacyBandButton(
                  label: 'Бас тарту',
                  color: DalaTheme.gold,
                  onPressed: () => _answerLetter(proposal, false),
                ),
              ),
              Expanded(
                child: _DiplomacyBandButton(
                  label: 'Қабылдау',
                  color: DalaTheme.green,
                  onPressed: () => _answerLetter(proposal, true),
                ),
              ),
            ],
          )
        else
          _DiplomacyBandButton(
            label: 'Жабу',
            color: DalaTheme.green,
            onPressed: () {
              controller.dismissDiplomacyMessage(message!);
              _backInsideInbox();
            },
          ),
      ],
    );
  }

  void _answerLetter(DiplomacyProposal proposal, bool accept) {
    final resolved = controller.resolveDiplomacyProposal(
      proposal,
      accept: accept,
    );
    if (!resolved) {
      showTopSnackBar(context, 'Ұсыныс шарттары енді жарамсыз');
      return;
    }
    showTopSnackBar(
      context,
      accept ? 'Келісім қабылданды' : 'Бас тарту жіберілді',
    );
    _backInsideInbox();
  }
}

class _InboxRow extends StatelessWidget {
  const _InboxRow({
    super.key,
    required this.color,
    required this.title,
    required this.onTap,
  });

  final Color color;
  final String title;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    child: Container(
      constraints: const BoxConstraints(minHeight: 52),
      color: color,
      padding: const EdgeInsets.fromLTRB(16, 7, 14, 7),
      alignment: Alignment.centerLeft,
      child: GameText(
        title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
      ),
    ),
  );
}

String _inboxProposalLabel(DiplomacyProposal proposal) =>
    proposal.type == DiplomacyProposalType.exchange
    ? proposal.effectiveTerms
          .where((t) => t.offer.type != DiplomacyExchangeType.nothing)
          .map((t) => '${t.fromSender ? '↓' : '↑'} ${_offerName(t.offer.type)}')
          .join(' · ')
    : _proposalTitle(proposal);

String _peaceConferenceInboxLabel(
  GameController controller,
  PeaceConference conference,
) =>
    'Жер бөлісу · ${controller.playerName(conference.originalOwner)} · '
    '${conference.claimTiles.length} жер';

class _DiplomacySheet extends StatefulWidget {
  const _DiplomacySheet({
    required this.controller,
    required this.screenHeight,
    this.initialPlayer,
  });

  final GameController controller;
  final double screenHeight;
  final int? initialPlayer;

  @override
  State<_DiplomacySheet> createState() => _DiplomacySheetState();
}

enum _DiplomacyPanelPage { countries, exchange, info, blackMark }

class _DiplomacySheetState extends State<_DiplomacySheet> {
  int? _selected;
  _DiplomacyPanelPage _page = _DiplomacyPanelPage.countries;
  int? _exchangeOther;
  DiplomacyOffer _initialFromOffer = const DiplomacyOffer();
  DiplomacyOffer _initialToOffer = const DiplomacyOffer();
  bool _movingForward = true;

  GameController get controller => widget.controller;
  int get current => controller.visibilityPlayer;

  List<int> get aliveOthers => [
    for (var player = 0; player < controller.state.config.playerCount; player++)
      if (player != current && controller.engine.provincesOf(player).isNotEmpty)
        player,
  ];

  @override
  void initState() {
    super.initState();
    controller.addListener(_refresh);
    final requested = widget.initialPlayer;
    if (requested != null && aliveOthers.contains(requested)) {
      _selected = requested;
    }
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    controller.removeListener(_refresh);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screenHeight = widget.screenHeight;
    return PopScope(
      canPop: _page == _DiplomacyPanelPage.countries,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _showCountries();
      },
      child: Container(
        key: const ValueKey('diplomacy-shell'),
        height: screenHeight * .50,
        color: DalaTheme.paper,
        child: ClipRect(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 230),
            reverseDuration: const Duration(milliseconds: 200),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            layoutBuilder: (currentChild, previousChildren) => Stack(
              fit: StackFit.expand,
              children: [...previousChildren, ?currentChild],
            ),
            transitionBuilder: (child, animation) => FadeTransition(
              opacity: animation,
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: Offset(_movingForward ? .14 : -.14, 0),
                  end: Offset.zero,
                ).animate(animation),
                child: child,
              ),
            ),
            child: _buildCurrentPage(),
          ),
        ),
      ),
    );
  }

  Widget _buildCurrentPage() {
    final other = _exchangeOther;
    if (_page == _DiplomacyPanelPage.info && _selected != null) {
      return _CountryInfoPage(
        key: const ValueKey('diplomacy-info-page'),
        controller: controller,
        current: current,
        other: _selected!,
        onBack: _showCountries,
      );
    }
    if (_page == _DiplomacyPanelPage.blackMark && _selected != null) {
      return _buildBlackMark();
    }
    if (_page == _DiplomacyPanelPage.exchange && other != null) {
      return _ExchangePage(
        key: const ValueKey('diplomacy-exchange-switcher-page'),
        controller: controller,
        current: current,
        other: other,
        initialFromOffer: _initialFromOffer,
        initialToOffer: _initialToOffer,
        onBack: _showCountries,
        onSent: _showCountries,
      );
    }
    return KeyedSubtree(
      key: const ValueKey('diplomacy-countries-page'),
      child: _buildCountries(),
    );
  }

  void _showCountries() {
    if (_page == _DiplomacyPanelPage.countries) return;
    setState(() {
      _movingForward = false;
      _page = _DiplomacyPanelPage.countries;
    });
  }

  Widget _buildCountries() {
    final selected = _selected;
    final overviews = {
      for (final player in aliveOthers)
        player: DiplomacyOverview.fromState(controller.state, current, player),
    };
    return Column(
      children: [
        if (selected == null)
          const _ClassicTitleBar(title: 'Дипломатия')
        else
          _buildActionStrip(selected),
        if (overviews.values.any((item) => item.obligations.isNotEmpty))
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: GameText(
                'Төлемдер: + сізге · − сізден',
                style: TextStyle(fontSize: 12, color: Colors.black87),
              ),
            ),
          ),
        Expanded(
          child: ListView(
            padding: EdgeInsets.zero,
            children: [
              for (final entry in overviews.entries)
                _buildCountryRow(entry.key, entry.value),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildActionStrip(int other) {
    final status = controller.engine.diplomacyBetween(current, other);
    final cooldown = controller.engine.diplomacyCooldown(current, other);
    final enabled =
        controller.isLocalHumanTurn && !controller.interactionsLocked;
    return Container(
      height: 50,
      color: const Color(0xffdfe5df),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          if (status != DiplomacyStatus.alliance &&
              status != DiplomacyStatus.coalition)
            _ActionIcon(
              tooltip: status == DiplomacyStatus.war
                  ? 'Бітім ұсыну'
                  : 'Достық ұсыну',
              asset: 'assets/classic/diplomacy/like_icon.png',
              enabled:
                  enabled && !(status == DiplomacyStatus.war && cooldown > 0),
              onTap: () => _openPositiveExchange(other),
            ),
          if (status != DiplomacyStatus.war)
            _ActionIcon(
              tooltip: status == DiplomacyStatus.alliance
                  ? 'Достықты тоқтату'
                  : status == DiplomacyStatus.coalition
                  ? 'Әскери одақты тоқтату'
                  : 'Соғыс жариялау',
              asset: 'assets/classic/diplomacy/dislike_icon.png',
              enabled:
                  enabled && !(status == DiplomacyStatus.peace && cooldown > 0),
              onTap: () => _confirmWorsen(other),
            ),
          if (status != DiplomacyStatus.alliance &&
              status != DiplomacyStatus.coalition)
            _ActionIcon(
              tooltip: controller.engine.hasBlackMark(current, other)
                  ? 'Қара белгіні алу'
                  : 'Қара белгі қою',
              asset: 'assets/classic/diplomacy/black_mark_icon.png',
              enabled:
                  enabled &&
                  (controller.engine.hasBlackMark(current, other) ||
                      controller.engine.blackMarkCooldown(current, other) == 0),
              onTap: () => _confirmBlackMark(other),
            ),
          _ActionIcon(
            tooltip: 'Қатынастары',
            asset: 'assets/classic/diplomacy/info_icon.png',
            onTap: () => _openInfo(other),
          ),
          _ActionIcon(
            tooltip: 'Хат жіберу',
            asset: 'assets/classic/diplomacy/mail_icon.png',
            enabled: enabled,
            onTap: () => _openMail(other),
          ),
          _ActionIcon(
            tooltip: 'Айырбас',
            asset: 'assets/classic/diplomacy/exchange_icon.png',
            enabled: enabled,
            onTap: () => _openExchange(other),
          ),
        ],
      ),
    );
  }

  Widget _buildCountryRow(int player, DiplomacyOverview overview) {
    final status = overview.status;
    final selected = _selected == player;
    final color =
        controller.mod.palette[player % controller.mod.palette.length];
    return InkWell(
      key: ValueKey('diplomacy-country-$player'),
      onTap: () => setState(() => _selected = selected ? null : player),
      child: Container(
        constraints: const BoxConstraints(minHeight: 58),
        margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        decoration: BoxDecoration(
          color: Color.lerp(DalaTheme.paper, color, selected ? .70 : .38),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected ? DalaTheme.deepWater : color,
            width: selected ? 2 : 1,
          ),
        ),
        padding: const EdgeInsets.fromLTRB(12, 5, 12, 5),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      GameText(
                        controller.playerName(player),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      GameText(
                        overview.statusLabel,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ],
                  ),
                ),
                if (overview.blackMark) ...[
                  Tooltip(
                    message: context.trNullable('Араларыңызда қара белгі бар'),
                    child: DalaAsset(
                      'assets/classic/diplomacy/black_mark_icon.png',
                      width: 23,
                      height: 23,
                    ),
                  ),
                  const SizedBox(width: 7),
                ],
                DiplomacyStatusBadge(status: status, size: 29),
              ],
            ),
            GameText(
              'Қатынас: ${_signed(overview.relationship)}',
              semanticsLabel:
                  'Ортақ қатынас: ${_signed(overview.relationship)}',
              style: const TextStyle(fontSize: 12),
            ),
            if (overview.obligations.isNotEmpty) ...[
              const SizedBox(height: 4),
              Wrap(
                spacing: 5,
                runSpacing: 4,
                children: [
                  for (final obligation in overview.obligations)
                    _ObligationChip(obligation: obligation),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _openPositiveExchange(int other) {
    final status = controller.engine.diplomacyBetween(current, other);
    DiplomacyOffer fromOffer;
    DiplomacyOffer toOffer;
    if (status == DiplomacyStatus.war) {
      toOffer = const DiplomacyOffer(type: DiplomacyExchangeType.ceasefire);
      fromOffer = const DiplomacyOffer(
        type: DiplomacyExchangeType.subsidies,
        amount: 10,
        duration: 10,
      );
    } else {
      final price = math.max(
        5,
        (controller.engine.playerEconomicBreakdown(other).total * 2.5).round(),
      );
      fromOffer = DiplomacyOffer(
        type: DiplomacyExchangeType.subsidies,
        amount: math.max(1, (price / 12).ceil()),
        duration: 12,
      );
      toOffer = const DiplomacyOffer(
        type: DiplomacyExchangeType.friendship,
        duration: 12,
      );
    }
    _pushExchange(other, initialFromOffer: fromOffer, initialToOffer: toOffer);
  }

  void _openExchange(int other) => _pushExchange(
    other,
    initialFromOffer: const DiplomacyOffer(),
    initialToOffer: const DiplomacyOffer(),
  );

  void _pushExchange(
    int other, {
    required DiplomacyOffer initialFromOffer,
    required DiplomacyOffer initialToOffer,
  }) async {
    setState(() {
      _selected = other;
      _exchangeOther = other;
      _initialFromOffer = initialFromOffer;
      _initialToOffer = initialToOffer;
      _movingForward = true;
      _page = _DiplomacyPanelPage.exchange;
    });
  }

  Future<void> _openMail(int other) async {
    setState(() => _selected = other);
    final input = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        shape: const RoundedRectangleBorder(),
        title: GameText('${controller.playerName(other)} ойыншысына хат'),
        content: TextField(
          controller: input,
          autofocus: true,
          minLines: 2,
          maxLines: 5,
          maxLength: 400,
          decoration: const InputDecoration(
            hint: GameText('Хат мәтіні'),
            border: OutlineInputBorder(borderRadius: BorderRadius.zero),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const GameText('Бас тарту'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: DalaTheme.green,
              shape: const RoundedRectangleBorder(),
            ),
            onPressed: () => Navigator.pop(dialogContext, input.text.trim()),
            child: const GameText('Жіберу'),
          ),
        ],
      ),
    );
    input.dispose();
    if (text != null && text.isNotEmpty) {
      final sent = controller.sendDiplomacyMessage(other: other, text: text);
      if (sent && mounted) showTopSnackBar(context, 'Хат жіберілді');
    }
    if (mounted) setState(() {});
  }

  Future<void> _openInfo(int other) async {
    setState(() {
      _selected = other;
      _movingForward = true;
      _page = _DiplomacyPanelPage.info;
    });
  }

  Future<void> _confirmBlackMark(int other) async {
    setState(() {
      _selected = other;
      _movingForward = true;
      _page = _DiplomacyPanelPage.blackMark;
    });
  }

  Widget _buildBlackMark() {
    final other = _selected!;
    final removing = controller.engine.hasBlackMark(current, other);
    return Material(
      key: const ValueKey('black-mark-panel'),
      color: DalaTheme.paper,
      child: Column(
        children: [
          _ClassicTitleBar(
            title: removing ? 'Қара белгіні алу' : 'Қара белгі',
            onClose: _showCountries,
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  DalaAsset(
                    'assets/classic/diplomacy/black_mark_icon.png',
                    width: 64,
                    height: 64,
                  ),
                  const SizedBox(height: 16),
                  GameText(
                    controller.playerName(other),
                    style: const TextStyle(fontSize: 20),
                  ),
                  const SizedBox(height: 12),
                  GameText(
                    removing
                        ? 'Белгі алынады. Қайта қоюға 10 ход күту керек.'
                        : 'Қатынас −35. Өзара және достармен достық шектеледі.',
                    style: const TextStyle(fontSize: 15, height: 1.4),
                  ),
                  if (!removing)
                    const _DiplomacyDetails(
                      children: [
                        GameText(
                          'Оның сізбен және сіздің достарыңызбен достығы тоқтайды. Кейін екі жақ қарсы тараптың достарымен жаңа достық құра алмайды.\n\nОртақ қатынас: −35.\nБелсенді ортақ соғыс, жер бөлісу немесе қонақ әскер бар болса, одақ бұзылмайды.',
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ),
          _DiplomacyBandButton(
            label: removing ? 'Белгіні алу' : 'Қара белгі қою',
            color: DalaTheme.gold,
            onPressed: () {
              final changed = controller.toggleBlackMark(other);
              showTopSnackBar(
                context,
                changed
                    ? 'Дипломатиялық өзгеріс жіберілді'
                    : 'Қазір одақ міндеттемелері белгіні қоюға жол бермейді',
              );
              if (changed) _showCountries();
            },
          ),
        ],
      ),
    );
  }

  Future<void> _confirmWorsen(int other) async {
    final status = controller.engine.diplomacyBetween(current, other);
    if (status == DiplomacyStatus.war) return;
    final finePerTurn = status == DiplomacyStatus.alliance
        ? controller.engine.friendshipBreakFinePerTurn(current)
        : 0;
    final fineTurns = status == DiplomacyStatus.alliance
        ? controller.engine.friendshipBreakCompensationTurns(current, other)
        : 0;
    final totalFine = finePerTurn * fineTurns;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        shape: const RoundedRectangleBorder(),
        title: GameText(
          status == DiplomacyStatus.alliance
              ? 'Достықты тоқтату'
              : status == DiplomacyStatus.coalition
              ? 'Әскери одақты тоқтату'
              : 'Соғыс жариялау',
        ),
        content: GameText(
          status == DiplomacyStatus.alliance
              ? 'Достықты шынымен тоқтатасыз ба? '
                    '${controller.playerName(other)} ойыншысына $finePerTurn ақша × $fineTurns ход '
                    '= $totalFine ақша өтем төлейсіз.'
              : status == DiplomacyStatus.coalition
              ? 'Әскери одақты тоқтатасыз ба? Белсенді ортақ соғыс немесе '
                    'одақтас жерінде әскер тұрса, одақты бұзуға болмайды.'
              : '${controller.playerName(other)} ойыншысына шынымен соғыс жариялайсыз ба?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const GameText('Жоқ'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: DalaTheme.rose,
              shape: const RoundedRectangleBorder(),
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const GameText('Иә'),
          ),
        ],
      ),
    );
    if (accepted == true && mounted) {
      final previous = controller.engine.diplomacyBetween(current, other);
      controller.worsenDiplomacy(other);
      final changed =
          controller.engine.diplomacyBetween(current, other) != previous;
      if (changed) {
        showTopSnackBar(
          context,
          previous == DiplomacyStatus.peace
              ? 'Соғыс жариялау туралы хат жіберілді'
              : 'Дипломатиялық өзгеріс жіберілді',
        );
      }
      setState(() {});
    }
  }
}

/// Keep the decision visible; explanations open only when requested.
class _DiplomacyDetails extends StatefulWidget {
  const _DiplomacyDetails({required this.children, super.key});
  final List<Widget> children;
  @override
  State<_DiplomacyDetails> createState() => _DiplomacyDetailsState();
}

class _DiplomacyDetailsState extends State<_DiplomacyDetails> {
  bool _expanded = false;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      TextButton.icon(
        onPressed: () => setState(() => _expanded = !_expanded),
        icon: Icon(_expanded ? Icons.expand_less : Icons.expand_more, size: 18),
        label: GameText(_expanded ? 'Түсіндірмені жабу' : 'Толық түсіндірме'),
      ),
      if (_expanded) ...widget.children,
    ],
  );
}

class _LetterTerms extends StatelessWidget {
  const _LetterTerms({
    required this.controller,
    required this.proposal,
    required this.concise,
  });
  final GameController controller;
  final DiplomacyProposal proposal;
  final bool concise;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (final term in proposal.effectiveTerms.where(
        (t) => t.offer.type != DiplomacyExchangeType.nothing,
      ))
        Container(
          margin: const EdgeInsets.only(bottom: 5),
          padding: const EdgeInsets.all(8),
          color: term.fromSender
              ? const Color(0xffd7e7d3)
              : const Color(0xffecd1c9),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              GameText(
                term.fromSender ? 'Сіз аласыз' : 'Сіз бересіз',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
              GameText(
                _offerSummary(
                  controller,
                  term.fromSender ? proposal.from : proposal.to,
                  term.fromSender ? proposal.to : proposal.from,
                  term.offer,
                  concise: concise,
                ),
                style: const TextStyle(fontSize: 13),
              ),
            ],
          ),
        ),
    ],
  );
}

class _ObligationChip extends StatelessWidget {
  const _ObligationChip({required this.obligation});

  final DiplomacyObligation obligation;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: context.trNullable(obligation.description),
    child: Semantics(
      label: context.trNullable(obligation.description),
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
        decoration: BoxDecoration(
          color: obligation.amount > 0
              ? const Color(0xffd0e4ce)
              : const Color(0xffecd1c9),
          borderRadius: BorderRadius.circular(3),
        ),
        child: GameText(
          obligation.label,
          style: const TextStyle(fontSize: 12, color: Colors.black87),
        ),
      ),
    ),
  );
}

class _ExchangePage extends StatefulWidget {
  const _ExchangePage({
    super.key,
    required this.controller,
    required this.current,
    required this.other,
    required this.initialFromOffer,
    required this.initialToOffer,
    required this.onBack,
    required this.onSent,
  });

  final GameController controller;
  final int current;
  final int other;
  final DiplomacyOffer initialFromOffer;
  final DiplomacyOffer initialToOffer;
  final VoidCallback onBack;
  final VoidCallback onSent;

  @override
  State<_ExchangePage> createState() => _ExchangePageState();
}

class _ExchangePageState extends State<_ExchangePage> {
  late List<DiplomacyTerm> _terms;
  String? _openPicker;
  int _editingTerm = 0;

  @override
  void initState() {
    super.initState();
    _terms = [
      DiplomacyTerm(
        fromSender: false,
        offer: _withClassicAmount(widget.initialToOffer),
      ),
      DiplomacyTerm(
        fromSender: true,
        offer: _withClassicAmount(widget.initialFromOffer),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final status = controller.engine.diplomacyBetween(
      widget.current,
      widget.other,
    );
    return RepaintBoundary(
      key: const ValueKey('diplomacy-exchange-page'),
      child: Material(
        color: DalaTheme.paper,
        child: SafeArea(
          top: false,
          child: Column(
            children: [
              _ClassicTitleBar(
                title:
                    '${controller.playerName(widget.other)} · ${_statusName(status)} · Айырбас',
                onClose: widget.onBack,
                height: 50,
              ),
              Expanded(
                child: SingleChildScrollView(
                  padding: EdgeInsets.zero,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var index = 0; index < _terms.length; index++)
                        _buildTerm(index),
                      if (_terms.length < 3)
                        TextButton(
                          key: const ValueKey('add-diplomacy-term'),
                          onPressed: () => setState(() {
                            _terms.add(
                              const DiplomacyTerm(
                                fromSender: false,
                                offer: DiplomacyOffer(),
                              ),
                            );
                            _openPicker = null;
                          }),
                          child: const GameText(
                            '+ Шарт қосу',
                            style: TextStyle(fontSize: 14, color: Colors.black),
                          ),
                        ),
                      for (final term in _terms.where(
                        (t) =>
                            t.offer.type == DiplomacyExchangeType.lands &&
                            (t.offer.tiles.isNotEmpty ||
                                t.offer.navalRefs.isNotEmpty),
                      ))
                        _TerritoryPreviewButton(
                          controller: controller,
                          giver: term.fromSender
                              ? widget.current
                              : widget.other,
                          receiver: term.fromSender
                              ? widget.other
                              : widget.current,
                          offer: term.offer,
                        ),
                      const SizedBox(height: 8),
                    ],
                  ),
                ),
              ),
              SizedBox(
                height: 50,
                width: double.infinity,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(50),
                    backgroundColor: DalaTheme.green,
                    shape: const RoundedRectangleBorder(),
                  ),
                  onPressed: () {
                    final error = controller.engine.exchangeValidationError(
                      widget.current,
                      widget.other,
                      _terms,
                    );
                    if (error != null) {
                      showTopSnackBar(context, error);
                      return;
                    }
                    final sent = controller.sendDiplomacyExchange(
                      other: widget.other,
                      terms: _terms,
                    );
                    if (sent) {
                      showTopSnackBar(context, 'Хат жіберілді');
                      widget.onSent();
                    } else {
                      showTopSnackBar(
                        context,
                        'Бұл келісім қазіргі жағдайда мүмкін емес',
                      );
                    }
                  },
                  child: const GameText(
                    'Ұсыну',
                    style: TextStyle(fontSize: 18),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTerm(int index) {
    final term = _terms[index];
    final giver = term.fromSender ? widget.current : widget.other;
    final receiver = term.fromSender ? widget.other : widget.current;
    final color = term.fromSender ? DalaTheme.rose : DalaTheme.green;
    final pickerId = 'term-$index';
    final collapsed =
        _openPicker != null && !_openPicker!.startsWith('$pickerId:');
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: AnimatedSize(
        duration: const Duration(milliseconds: 180),
        alignment: Alignment.topCenter,
        child: Column(
          children: [
            Container(
              color: color,
              height: 32,
              child: Row(
                children: [
                  Expanded(
                    child: InkWell(
                      key: ValueKey('term-direction-$index'),
                      onTap: () => setState(() {
                        // Asset ownership changes with the executor; never silently sell
                        // the previous side's selected cells after reversing an arrow.
                        _terms[index] = DiplomacyTerm(
                          fromSender: !term.fromSender,
                          offer: term.offer.copyWith(
                            tiles: [],
                            navalRefs: [],
                            targetPlayer: -1,
                          ),
                        );
                        _openPicker = null;
                      }),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        child: Row(
                          children: [
                            GameText(
                              '${index + 1}.',
                              style: const TextStyle(fontSize: 13),
                            ),
                            const SizedBox(width: 8),
                            Transform.rotate(
                              angle: term.fromSender ? math.pi : 0,
                              child: DalaAsset(
                                'assets/classic/diplomacy/exchange_down.png',
                                width: 20,
                                height: 20,
                              ),
                            ),
                            const SizedBox(width: 7),
                            Expanded(
                              child: GameText(
                                term.fromSender
                                    ? 'Сіз → ${widget.controller.playerName(widget.other)}'
                                    : '${widget.controller.playerName(widget.other)} → Сіз',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 13),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (_terms.length > 1)
                    IconButton(
                      key: ValueKey('remove-term-$index'),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints.tightFor(
                        width: 34,
                        height: 32,
                      ),
                      icon: const GameText(
                        '×',
                        style: TextStyle(fontSize: 22, height: 1),
                      ),
                      onPressed: () => setState(() {
                        _terms.removeAt(index);
                        _openPicker = null;
                      }),
                    ),
                ],
              ),
            ),
            if (collapsed)
              Container(
                height: 30,
                color: color,
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: GameText(
                  _offerName(term.offer.type),
                  style: const TextStyle(fontSize: 14),
                ),
              )
            else
              _OfferEditor(
                pickerId: pickerId,
                openPicker: _openPicker,
                onPickerChanged: (value) => setState(() {
                  _openPicker = value;
                  _editingTerm = index;
                }),
                title: '',
                color: color,
                giver: giver,
                receiver: receiver,
                offer: term.offer,
                availableTypes: [
                  for (final type in DiplomacyExchangeType.values)
                    if (widget.controller.engine.canChooseExchangeType(
                          giver,
                          receiver,
                          type,
                          [
                            for (var i = 0; i < _terms.length; i++)
                              if (i != index) _terms[i],
                          ],
                        ) &&
                        !(type == DiplomacyExchangeType.subsidies &&
                            _terms.asMap().entries.any(
                              (entry) =>
                                  entry.key != index &&
                                  entry.value.fromSender == term.fromSender &&
                                  entry.value.offer.type == type,
                            )))
                      type,
                ],
                showDetails: _editingTerm == index,
                controller: widget.controller,
                onChanged: (offer) => setState(
                  () => _terms[index] = DiplomacyTerm(
                    fromSender: term.fromSender,
                    offer: offer,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _MailPage extends StatefulWidget {
  const _MailPage({
    required this.controller,
    required this.current,
    required this.other,
  });

  final GameController controller;
  final int current;
  final int other;

  @override
  State<_MailPage> createState() => _MailPageState();
}

class _MailPageState extends State<_MailPage> {
  final TextEditingController _messageController = TextEditingController();

  @override
  void dispose() {
    _messageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final messages = widget.controller.engine
        .messagesBetween(widget.current, widget.other)
        .toList();
    return Scaffold(
      backgroundColor: DalaTheme.paper,
      body: SafeArea(
        child: Column(
          children: [
            _ClassicTitleBar(
              title: '${widget.controller.playerName(widget.other)} · Хат',
              onClose: () => Navigator.pop(context),
            ),
            Expanded(
              child: messages.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: GameText(
                          'Бұл елмен хат алмасу әлі басталған жоқ.',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 17),
                        ),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                      itemCount: messages.length,
                      itemBuilder: (context, index) {
                        final message = messages[index];
                        final own = message.from == widget.current;
                        return Align(
                          alignment: own
                              ? Alignment.centerRight
                              : Alignment.centerLeft,
                          child: Container(
                            constraints: const BoxConstraints(maxWidth: 520),
                            margin: const EdgeInsets.only(bottom: 8),
                            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                            decoration: BoxDecoration(
                              color: own
                                  ? const Color(0xffd4e8d2)
                                  : DalaTheme.paper,
                              border: Border.all(color: Colors.black26),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                GameText(
                                  '${widget.controller.playerName(message.from)} · ${message.createdRound}-раунд',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: Colors.black54,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                GameText(
                                  message.text,
                                  translate: false,
                                  style: const TextStyle(fontSize: 16),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
            Container(
              color: DalaTheme.paper,
              padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _messageController,
                      minLines: 1,
                      maxLines: 4,
                      maxLength: 400,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(
                        hint: GameText('Хабарлама жазыңыз'),
                        filled: true,
                        fillColor: Color(0xfff2f2f2),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.zero,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: DalaTheme.green,
                      shape: const RoundedRectangleBorder(),
                      minimumSize: const Size(88, 48),
                    ),
                    onPressed: _messageController.text.trim().isEmpty
                        ? null
                        : () {
                            final sent = widget.controller.sendDiplomacyMessage(
                              other: widget.other,
                              text: _messageController.text,
                            );
                            if (!sent) return;
                            _messageController.clear();
                            showTopSnackBar(context, 'Хат жіберілді');
                            setState(() {});
                          },
                    child: const GameText('Жіберу'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CountryInfoPage extends StatelessWidget {
  const _CountryInfoPage({
    super.key,
    required this.controller,
    required this.current,
    required this.other,
    required this.onBack,
  });

  final GameController controller;
  final int current;
  final int other;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final engine = controller.engine;
    final state = controller.state;
    final relation = engine.diplomacyBetween(current, other);
    final overview = DiplomacyOverview.fromState(state, current, other);
    final canAct =
        controller.isLocalHumanTurn && !controller.interactionsLocked;
    final alive = [
      for (var player = 0; player < state.config.playerCount; player++)
        if (player != other && engine.provincesOf(player).isNotEmpty) player,
    ];
    return Material(
      color: DalaTheme.paper,
      child: SafeArea(
        child: Column(
          children: [
            _ClassicTitleBar(
              title: '${controller.playerName(other)} · Қатынастар',
              onClose: onBack,
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
                children: [
                  Container(
                    height: 56,
                    alignment: Alignment.center,
                    color: controller
                        .mod
                        .palette[other % controller.mod.palette.length],
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        DiplomacyStatusBadge(status: relation, size: 34),
                        const SizedBox(width: 10),
                        Flexible(
                          child: GameText(
                            overview.statusLabel,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  GameText(
                    'Ортақ қатынас: ${_signed(overview.relationship)}',
                    style: const TextStyle(fontSize: 17),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: _DiplomacyBandButton(
                          label: 'Елшілік +12 · \$10',
                          color: DalaTheme.green,
                          onPressed: canAct
                              ? () => _influence(context, true)
                              : null,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: _DiplomacyBandButton(
                          label: 'Наразылық −15',
                          color: DalaTheme.rose,
                          onPressed: canAct
                              ? () => _influence(context, false)
                              : null,
                        ),
                      ),
                    ],
                  ),
                  GameText(
                    engine.opinionActionCooldown(current, other) > 0
                        ? 'Келесі әрекетке ${engine.opinionActionCooldown(current, other)} ход'
                        : 'Әр 3 ходта бір әрекет. Өзгеріс екі елге ортақ.',
                    style: const TextStyle(fontSize: 12),
                  ),
                  const SizedBox(height: 8),
                  GameText(
                    'Одаққа сенім: +${engine.militaryAllianceTrustRequired(current, other)} және ортақ пайда.',
                    style: const TextStyle(fontSize: 12),
                  ),
                  _DiplomacyDetails(
                    children: [
                      GameText(
                        'Боттар одағы: барлық жұпта кемінде +${engine.militaryAllianceTrustRequired(current, other)}. '
                        'Одақ үлкейген сайын талап өседі; сенімнен бөлек стратегиялық пайда да қажет.',
                      ),
                    ],
                  ),
                  if (relation == DiplomacyStatus.coalition)
                    const GameText(
                      'Одақ біткенде әскер өз еліне қайтады. Орын жоқ болса: біріктіру, болмаса құнын қайтару.',
                      style: TextStyle(fontSize: 12),
                    ),
                  const _SectionLabel('Қарыздар мен төлемдер'),
                  if (overview.obligations.isEmpty)
                    const GameText(
                      'Араларыңызда қарыз немесе төлем келісімі жоқ.',
                      style: TextStyle(fontSize: 13),
                    )
                  else ...[
                    for (final obligation in overview.obligations)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 5),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: _ObligationChip(obligation: obligation),
                        ),
                      ),
                    const GameText(
                      '+ сізге · − сізден · /ход — төлем · x — қалған ход.',
                      style: TextStyle(fontSize: 12),
                    ),
                    const _DiplomacyDetails(
                      children: [
                        GameText(
                          '+ сізге · − сізден. Қарыз — қалған толық сома. '
                          '/ход — келісімдегі төлем; нақты төлем табыс пен қазынаға байланысты. '
                          'x — қалған ход саны.',
                        ),
                      ],
                    ),
                  ],
                  const _SectionLabel('Соңғы себептер'),
                  for (final event
                      in state.diplomacySocial.events.reversed
                          .where(
                            (e) =>
                                (e.observer == other && e.subject == current) ||
                                (e.observer == current && e.subject == other),
                          )
                          .take(5))
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: GameText(
                        '${event.round}-ход · ${event.reason} ${_signed(event.delta)}',
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                  const _SectionLabel('Басқа елдермен қатынасы'),
                  for (final player in alive)
                    _RelationRow(
                      controller: controller,
                      first: other,
                      second: player,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _influence(BuildContext context, bool improve) {
    final changed = controller.influenceDiplomacyOpinion(
      other,
      improve: improve,
    );
    showTopSnackBar(
      context,
      changed
          ? 'Хат жіберілді'
          : 'Күту мерзімін, ақшаны және соғыс/қара белгіні тексеріңіз',
    );
  }
}

class _RelationRow extends StatelessWidget {
  const _RelationRow({
    required this.controller,
    required this.first,
    required this.second,
  });

  final GameController controller;
  final int first;
  final int second;

  @override
  Widget build(BuildContext context) {
    final status = controller.engine.diplomacyBetween(first, second);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: const BoxDecoration(
        color: DalaTheme.paper,
        border: Border(bottom: BorderSide(color: Colors.black12)),
      ),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            color:
                controller.mod.palette[second % controller.mod.palette.length],
            child: GameText('${second + 1}'),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                GameText(
                  controller.playerName(second),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 16),
                ),
                GameText(
                  _statusName(status),
                  style: const TextStyle(fontSize: 13),
                ),
              ],
            ),
          ),
          DiplomacyStatusBadge(status: status, size: 30),
          const SizedBox(width: 8),
          GameText(
            _signed(controller.engine.opinionOf(first, second)),
            style: const TextStyle(fontSize: 14),
          ),
        ],
      ),
    );
  }
}

String _proposalTitle(DiplomacyProposal proposal) => switch (proposal.type) {
  DiplomacyProposalType.exchange => 'Жаңа айырбас ұсынысы',
  DiplomacyProposalType.friendship => 'Достық ұсынысы',
  DiplomacyProposalType.militaryAlliance => 'Әскери одақ ұсынысы',
  DiplomacyProposalType.peace => 'Бітім ұсынысы',
};

List<String> _proposalTerms(
  GameController controller,
  DiplomacyProposal proposal, {
  bool concise = true,
}) => switch (proposal.type) {
  DiplomacyProposalType.friendship => [
    if (concise)
      'Достық · 12 ход'
    else
      '${controller.playerName(proposal.from)} және ${controller.playerName(proposal.to)} 12 ходқа дос болады',
  ],
  DiplomacyProposalType.militaryAlliance => [
    if (concise)
      'Әскери одақ'
    else
      '${controller.playerName(proposal.from)} және ${controller.playerName(proposal.to)} әскери одақ құрады',
  ],
  DiplomacyProposalType.peace => [
    if (concise)
      'Бітім · 9 ход соғыссыз'
    else ...[
      '${controller.playerName(proposal.from)} және ${controller.playerName(proposal.to)} соғысты тоқтатады',
      'Қайта соғыс жариялауға 9 ходтық тыйым қойылады',
    ],
  ],
  DiplomacyProposalType.exchange => [
    for (final term in proposal.effectiveTerms.where(
      (t) => t.offer.type != DiplomacyExchangeType.nothing,
    ))
      '${controller.playerName(term.fromSender ? proposal.from : proposal.to)} → ${controller.playerName(term.fromSender ? proposal.to : proposal.from)}: ${_offerSummary(controller, term.fromSender ? proposal.from : proposal.to, term.fromSender ? proposal.to : proposal.from, term.offer, concise: concise)}',
  ],
};

String _signed(int number) => number > 0 ? '+$number' : '$number';

String _compactOffer(DiplomacyOffer offer) => switch (offer.type) {
  DiplomacyExchangeType.money => 'Ақша · \$${offer.amount}',
  DiplomacyExchangeType.subsidies =>
    'Субсидия · \$${offer.amount} × ${offer.duration}',
  DiplomacyExchangeType.lands =>
    'Жер / теңіз · ${offer.tiles.length + offer.navalRefs.length}',
  DiplomacyExchangeType.friendship => 'Достық · ${offer.duration} ход',
  _ => _offerName(offer.type),
};

class _DiplomacyBandButton extends StatelessWidget {
  const _DiplomacyBandButton({
    required this.label,
    required this.color,
    required this.onPressed,
  });
  final String label;
  final Color color;
  final VoidCallback? onPressed;
  @override
  Widget build(BuildContext context) => SizedBox(
    height: 48,
    width: double.infinity,
    child: TextButton(
      style: TextButton.styleFrom(
        backgroundColor: color,
        foregroundColor: Colors.black,
        shape: const RoundedRectangleBorder(),
        padding: const EdgeInsets.symmetric(horizontal: 6),
      ),
      onPressed: onPressed,
      child: GameText(
        label,
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 15),
      ),
    ),
  );
}

String _offerSummary(
  GameController controller,
  int giver,
  int receiver,
  DiplomacyOffer offer, {
  bool concise = false,
}) {
  switch (offer.type) {
    case DiplomacyExchangeType.nothing:
      return 'ештеңе';
    case DiplomacyExchangeType.money:
      final available = controller.engine
          .provincesOf(giver)
          .fold<int>(0, (sum, province) => sum + math.max(0, province.money));
      final debt = math.max(0, offer.amount - available);
      if (concise && debt > 0) return '${offer.amount} ақша · Қарыз: $debt';
      return debt == 0
          ? '${offer.amount} ақша'
          : '${offer.amount} ақша (қазіргі қазынадан $available, қалған $debt — қарыз)';
    case DiplomacyExchangeType.lands:
      final value =
          offer.tiles.fold<int>(
            0,
            (sum, index) => sum + controller.engine.diplomacyLandPrice(index),
          ) +
          offer.navalRefs.fold<int>(
            0,
            (sum, reference) =>
                sum + controller.engine.diplomacyNavalPrice(reference),
          );
      if (concise) {
        return '${offer.tiles.length} жер · ${offer.navalRefs.length} теңіз · Бағасы $value';
      }
      return '${offer.tiles.length} жер, ${offer.navalRefs.length} теңіз '
          'активі (бағасы $value)';
    case DiplomacyExchangeType.friendship:
      return '${offer.duration > 0 ? offer.duration : 12} ходтық достық';
    case DiplomacyExchangeType.militaryAlliance:
      return '${offer.duration > 0 ? offer.duration : 12} ходтық әскери одақ';
    case DiplomacyExchangeType.warDeclaration:
      return '${controller.playerName(offer.targetPlayer)} ойыншысына соғыс жариялау';
    case DiplomacyExchangeType.ceasefire:
      if (concise) return 'Бітім · 9 ход соғыссыз';
      return '${controller.playerName(receiver)} ойыншысымен соғысты тоқтату және 9 ходтық тыйым';
    case DiplomacyExchangeType.removeBlackMark:
      return '${controller.playerName(receiver)} ойыншысымен қара белгіні алу';
    case DiplomacyExchangeType.subsidies:
      final effective = math.min(
        offer.amount,
        math.max(0, controller.engine.playerIncome(giver)),
      );
      if (concise) {
        return '${offer.amount}/ход × ${offer.duration} · Қазір ≤$effective/ход';
      }
      return '${offer.amount} ақша × ${offer.duration} ход (кіріс шегімен қазір $effective/ход)';
  }
}

String _statusName(DiplomacyStatus status) => switch (status) {
  DiplomacyStatus.war => 'Соғыс',
  DiplomacyStatus.peace => 'Бейтарап',
  DiplomacyStatus.alliance => 'Достық',
  DiplomacyStatus.coalition => 'Әскери одақ',
};

class _ClassicTitleBar extends StatelessWidget {
  const _ClassicTitleBar({required this.title, this.onClose, this.height = 48});

  final String title;
  final VoidCallback? onClose;
  final double height;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: height,
    child: Row(
      children: [
        SizedBox(
          width: 52,
          child: onClose == null
              ? null
              : IconButton(
                  tooltip: context.trNullable('Артқа'),
                  onPressed: onClose,
                  icon: const GameText(
                    '←',
                    style: TextStyle(fontSize: 28, color: Colors.black),
                  ),
                ),
        ),
        Expanded(
          child: GameText(
            title,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w500),
          ),
        ),
        const SizedBox(width: 52),
      ],
    ),
  );
}

class _ActionIcon extends StatelessWidget {
  const _ActionIcon({
    required this.tooltip,
    required this.asset,
    required this.onTap,
    this.enabled = true,
  });

  final String tooltip;
  final String asset;
  final VoidCallback onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: context.trNullable(tooltip),
    onPressed: enabled ? onTap : null,
    icon: Opacity(
      opacity: enabled ? 1 : .25,
      child: DalaAsset(asset, width: 27, height: 27),
    ),
  );
}

class _OfferEditor extends StatefulWidget {
  const _OfferEditor({
    required this.pickerId,
    required this.openPicker,
    required this.onPickerChanged,
    required this.title,
    required this.color,
    required this.giver,
    required this.receiver,
    required this.offer,
    required this.controller,
    required this.onChanged,
    required this.availableTypes,
    this.showDetails = true,
  });

  final String pickerId;
  final String? openPicker;
  final ValueChanged<String?> onPickerChanged;
  final String title;
  final Color color;
  final int giver;
  final int receiver;
  final DiplomacyOffer offer;
  final GameController controller;
  final ValueChanged<DiplomacyOffer> onChanged;
  final List<DiplomacyExchangeType> availableTypes;
  final bool showDetails;

  @override
  State<_OfferEditor> createState() => _OfferEditorState();
}

class _OfferEditorState extends State<_OfferEditor> {
  @override
  Widget build(BuildContext context) {
    final giver = widget.giver;
    final receiver = widget.receiver;
    final offer = widget.offer;
    final controller = widget.controller;
    final typePickerKey = '${widget.pickerId}:type';
    final countryPickerKey = '${widget.pickerId}:country';
    final typePickerOpen = widget.openPicker == typePickerKey;
    final countryPickerOpen = widget.openPicker == countryPickerKey;
    final details = widget.showDetails && !typePickerOpen;
    final targets = [
      for (
        var player = 0;
        player < controller.state.config.playerCount;
        player++
      )
        if (controller.engine.canDeclareWar(giver, player)) player,
    ];
    return Container(
      color: widget.color,
      padding: const EdgeInsets.fromLTRB(10, 5, 10, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.title.isNotEmpty) ...[
            GameText(widget.title, style: const TextStyle(fontSize: 14)),
            const SizedBox(height: 3),
          ],
          InkWell(
            key: ValueKey('offer-type-$giver-$receiver'),
            onTap: () =>
                widget.onPickerChanged(typePickerOpen ? null : typePickerKey),
            child: Container(
              height: 36,
              decoration: BoxDecoration(
                color: DalaTheme.paper,
                border: Border.all(color: Colors.black54),
              ),
              padding: const EdgeInsets.only(left: 10),
              child: Row(
                children: [
                  Expanded(
                    child: GameText(
                      widget.showDetails
                          ? _offerName(offer.type)
                          : _compactOffer(offer),
                      style: const TextStyle(fontSize: 15),
                    ),
                  ),
                  DalaAsset(
                    'assets/classic/diplomacy/exchange_down.png',
                    width: 27,
                    height: 27,
                  ),
                ],
              ),
            ),
          ),
          if (typePickerOpen)
            Container(
              decoration: const BoxDecoration(
                border: Border(
                  left: BorderSide(color: Colors.black45),
                  right: BorderSide(color: Colors.black45),
                  bottom: BorderSide(color: Colors.black45),
                ),
              ),
              child: GridView.count(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                padding: EdgeInsets.zero,
                crossAxisCount: 2,
                childAspectRatio: 4.4,
                children: [
                  for (final type in widget.availableTypes)
                    InkWell(
                      key: ValueKey('offer-type-option-${type.name}'),
                      onTap: () => _selectType(type, targets),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 7),
                        alignment: Alignment.centerLeft,
                        decoration: BoxDecoration(
                          color: type == offer.type
                              ? const Color(0xffb4d4b1)
                              : const Color(0xffd7d7d7),
                          border: const Border(
                            right: BorderSide(color: Colors.black12),
                            bottom: BorderSide(color: Colors.black12),
                          ),
                        ),
                        child: GameText(
                          _offerName(type),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          if (details && offer.type == DiplomacyExchangeType.money) ...[
            _ValueLine(label: 'Ақша', value: '${offer.amount}'),
            _ClassicDiscreteSlider(
              key: ValueKey('money-slider-$giver-$receiver'),
              values: _classicMoneyValues,
              value: offer.amount,
              onChanged: (amount) =>
                  widget.onChanged(offer.copyWith(amount: amount)),
            ),
          ],
          if (details && offer.type == DiplomacyExchangeType.subsidies) ...[
            _ValueLine(
              label: 'Әр ходтағы ақша',
              value: '${math.max(1, offer.amount)}',
            ),
            _ClassicDiscreteSlider(
              key: ValueKey('subsidy-slider-$giver-$receiver'),
              values: _classicSubsidyValues,
              value: offer.amount,
              onChanged: (amount) =>
                  widget.onChanged(offer.copyWith(amount: amount)),
            ),
            _ValueLine(
              label: 'Ұзақтығы',
              value: '${math.max(1, offer.duration)} ход',
            ),
            Slider(
              key: ValueKey('subsidy-duration-$giver-$receiver'),
              min: 1,
              max: 20,
              divisions: 19,
              value: offer.duration.clamp(1, 20).toDouble(),
              onChanged: (value) =>
                  widget.onChanged(offer.copyWith(duration: value.round())),
            ),
          ],
          if (details &&
              (offer.type == DiplomacyExchangeType.friendship ||
                  offer.type == DiplomacyExchangeType.militaryAlliance)) ...[
            _ValueLine(
              label: offer.type == DiplomacyExchangeType.militaryAlliance
                  ? 'Одақ мерзімі'
                  : 'Достық мерзімі',
              value: '${offer.duration.clamp(1, 20)} ход',
            ),
            Slider(
              min: 1,
              max: 20,
              divisions: 19,
              value: offer.duration.clamp(1, 20).toDouble(),
              onChanged: (value) =>
                  widget.onChanged(offer.copyWith(duration: value.round())),
            ),
          ],
          if (details && offer.type == DiplomacyExchangeType.warDeclaration)
            Padding(
              padding: const EdgeInsets.only(top: 7),
              child: InkWell(
                key: ValueKey('war-target-$giver-$receiver'),
                onTap: targets.isEmpty
                    ? null
                    : () => widget.onPickerChanged(
                        countryPickerOpen ? null : countryPickerKey,
                      ),
                child: Container(
                  height: 42,
                  decoration: BoxDecoration(
                    color: DalaTheme.paper,
                    border: Border.all(color: Colors.black45),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Row(
                    children: [
                      Expanded(
                        child: GameText(
                          targets.isEmpty
                              ? 'Қолжетімді мемлекет жоқ'
                              : offer.targetPlayer >= 0 &&
                                    targets.contains(offer.targetPlayer)
                              ? controller.playerName(offer.targetPlayer)
                              : 'Мемлекетті таңдаңыз',
                          style: const TextStyle(fontSize: 15),
                        ),
                      ),
                      DalaAsset(
                        'assets/classic/diplomacy/exchange_down.png',
                        width: 27,
                        height: 27,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (details &&
              offer.type == DiplomacyExchangeType.warDeclaration &&
              countryPickerOpen)
            Container(
              decoration: BoxDecoration(
                border: Border.all(color: Colors.black45),
              ),
              child: Column(
                children: [
                  for (final player in targets)
                    InkWell(
                      key: ValueKey('war-target-option-$player'),
                      onTap: () {
                        widget.onPickerChanged(null);
                        widget.onChanged(offer.copyWith(targetPlayer: player));
                      },
                      child: Container(
                        height: 40,
                        color: controller
                            .mod
                            .palette[player % controller.mod.palette.length],
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Row(
                          children: [
                            Expanded(
                              child: GameText(
                                controller.playerName(player),
                                style: const TextStyle(fontSize: 17),
                              ),
                            ),
                            if (player == offer.targetPlayer)
                              const Icon(Icons.check, size: 22),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          if (details && offer.type == DiplomacyExchangeType.lands)
            _LandPicker(
              giver: giver,
              offer: offer,
              controller: controller,
              onChanged: widget.onChanged,
            ),
        ],
      ),
    );
  }

  void _selectType(DiplomacyExchangeType type, List<int> targets) {
    widget.onPickerChanged(null);
    widget.onChanged(
      DiplomacyOffer(
        type: type,
        amount: switch (type) {
          DiplomacyExchangeType.money || DiplomacyExchangeType.subsidies => 1,
          _ => 0,
        },
        duration: switch (type) {
          DiplomacyExchangeType.friendship ||
          DiplomacyExchangeType.militaryAlliance => 12,
          DiplomacyExchangeType.subsidies => 10,
          _ => 0,
        },
        targetPlayer: type == DiplomacyExchangeType.warDeclaration
            ? targets.firstOrNull ?? -1
            : -1,
      ),
    );
  }
}

class _ClassicDiscreteSlider extends StatelessWidget {
  const _ClassicDiscreteSlider({
    super.key,
    required this.values,
    required this.value,
    required this.onChanged,
  });

  final List<int> values;
  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final index = _classicValueIndex(values, value);
    return SliderTheme(
      data: SliderTheme.of(context).copyWith(
        trackHeight: 5,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 9),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
      ),
      child: Slider(
        min: 0,
        max: (values.length - 1).toDouble(),
        divisions: values.length - 1,
        value: index.toDouble(),
        onChanged: (raw) => onChanged(values[raw.round()]),
      ),
    );
  }
}

class _LandPicker extends StatelessWidget {
  const _LandPicker({
    required this.giver,
    required this.offer,
    required this.controller,
    required this.onChanged,
  });

  final int giver;
  final DiplomacyOffer offer;
  final GameController controller;
  final ValueChanged<DiplomacyOffer> onChanged;

  @override
  Widget build(BuildContext context) {
    final value =
        offer.tiles.fold<int>(
          0,
          (sum, index) => sum + controller.engine.diplomacyLandPrice(index),
        ) +
        offer.navalRefs.fold<int>(
          0,
          (sum, reference) =>
              sum + controller.engine.diplomacyNavalPrice(reference),
        );
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: InkWell(
        key: ValueKey('land-map-picker-$giver'),
        onTap: () async {
          final selection = await Navigator.of(context, rootNavigator: true)
              .push<_TerritorySelectionResult>(
                MaterialPageRoute<_TerritorySelectionResult>(
                  fullscreenDialog: true,
                  builder: (_) => _DiplomacyLandSelectionPage(
                    controller: controller,
                    giver: giver,
                    initialTiles: offer.tiles,
                    initialNaval: offer.navalRefs,
                  ),
                ),
              );
          if (selection != null && context.mounted) {
            onChanged(
              offer.copyWith(
                tiles: selection.tiles,
                navalRefs: selection.navalRefs,
              ),
            );
          }
        },
        child: Container(
          constraints: const BoxConstraints(minHeight: 48),
          decoration: BoxDecoration(
            color: DalaTheme.paper,
            border: Border.all(color: Colors.black45),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          child: Row(
            children: [
              const Icon(Icons.public, size: 28),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const GameText(
                      'Жер мен теңіз активін таңдау',
                      style: TextStyle(fontSize: 17),
                    ),
                    GameText(
                      offer.tiles.isEmpty && offer.navalRefs.isEmpty
                          ? 'Ештеңе таңдалмады'
                          : '${offer.tiles.length} жер · '
                                '${offer.navalRefs.length} теңіз активі · '
                                'бағасы $value',
                      style: const TextStyle(fontSize: 13),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
  }
}

class _TerritoryPreviewButton extends StatelessWidget {
  const _TerritoryPreviewButton({
    required this.controller,
    required this.giver,
    required this.receiver,
    required this.offer,
  });
  final GameController controller;
  final int giver;
  final int receiver;
  final DiplomacyOffer offer;
  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
    key: ValueKey('territory-preview-$giver-$receiver'),
    icon: const Icon(Icons.map_outlined),
    label: Column(
      children: [
        const GameText('Картадан қарау'),
        GameText(
          '${controller.playerName(giver)} → ${controller.playerName(receiver)}',
          translate: false,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12),
        ),
      ],
    ),
    onPressed: () => Navigator.of(context, rootNavigator: true).push<void>(
      MaterialPageRoute(
        builder: (_) => _DiplomacyLandSelectionPage(
          controller: controller,
          giver: giver,
          initialTiles: offer.tiles,
          initialNaval: offer.navalRefs,
          readOnly: true,
          previewTitle:
              '${controller.playerName(giver)} → ${controller.playerName(receiver)}',
        ),
      ),
    ),
  );
}

class _TerritorySelectionResult {
  const _TerritorySelectionResult({
    required this.tiles,
    required this.navalRefs,
  });

  final List<int> tiles;
  final List<NavalAssetRef> navalRefs;
}

String _navalKey(NavalAssetRef reference) =>
    '${reference.kind.name}:${reference.id}';

class _DiplomacyLandSelectionPage extends StatefulWidget {
  const _DiplomacyLandSelectionPage({
    required this.controller,
    required this.giver,
    required this.initialTiles,
    required this.initialNaval,
    this.readOnly = false,
    this.previewTitle,
    this.conferenceId,
    this.conferenceRecipient,
    this.lockedConferenceTiles = const <int>{},
    this.conferenceAllocations = const <int, int>{},
  });

  final GameController controller;
  final int giver;
  final List<int> initialTiles;
  final List<NavalAssetRef> initialNaval;
  final bool readOnly;
  final String? previewTitle;
  final int? conferenceId;
  final int? conferenceRecipient;
  final Set<int> lockedConferenceTiles;
  final Map<int, int> conferenceAllocations;

  @override
  State<_DiplomacyLandSelectionPage> createState() =>
      _DiplomacyLandSelectionPageState();
}

class _DiplomacyLandSelectionPageState
    extends State<_DiplomacyLandSelectionPage>
    with SingleTickerProviderStateMixin {
  final TransformationController _transformation = TransformationController();
  final Set<int> _selected = <int>{};
  final Map<String, NavalAssetRef> _selectedNaval = <String, NavalAssetRef>{};
  ClassicSprites? _sprites;
  final HexTerrainCache _terrainCache = HexTerrainCache();
  final MapPieceCullWindow _objectWindow = MapPieceCullWindow();
  Size _mapViewport = Size.zero;
  double _pixelRatio = 1;
  Rect get _viewBounds => Rect.fromPoints(
    _transformation.toScene(Offset.zero),
    _transformation.toScene(_mapViewport.bottomRight(Offset.zero)),
  );
  void _syncCache() {
    if (_mapViewport.isEmpty) return;
    _terrainCache.setViewport(
      _viewBounds,
      _transformation.value.entry(0, 0) * _pixelRatio,
    );
  }

  bool _cameraFitted = false;
  late final AnimationController _priceAnimation;
  Offset? _priceCenter;
  int _price = 0;

  GameController get controller => widget.controller;
  bool get _conferenceMode => widget.conferenceId != null;

  @override
  void initState() {
    super.initState();
    _transformation.addListener(_syncCache);
    _priceAnimation =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 850),
        )..addListener(() {
          if (mounted) setState(() {});
        });
    final visible = controller.visibleTileIndices;
    if (widget.readOnly) {
      _selected.addAll(
        widget.initialTiles.where(
          (i) =>
              i >= 0 &&
              i < controller.viewState.hexes.length &&
              controller.viewState.hexes[i].inWorld,
        ),
      );
      for (final reference in widget.initialNaval) {
        _selectedNaval[_navalKey(reference)] = reference;
      }
    } else if (_conferenceMode) {
      _selected.addAll(
        widget.initialTiles.where(
          (index) =>
              !widget.lockedConferenceTiles.contains(index) &&
              controller.canSelectPeaceConferenceTile(
                conferenceId: widget.conferenceId!,
                index: index,
              ),
        ),
      );
    } else {
      _selected.addAll(
        widget.initialTiles.where(
          (index) =>
              index >= 0 &&
              index < controller.viewState.hexes.length &&
              visible.contains(index) &&
              controller.canSelectDiplomacyLandTile(
                giver: widget.giver,
                index: index,
              ),
        ),
      );
      for (final reference in widget.initialNaval) {
        for (final cell in controller.viewState.waterCells) {
          if (controller.canSelectDiplomacyNavalAsset(
            giver: widget.giver,
            waterCell: cell.index,
            reference: reference,
          )) {
            _selectedNaval[_navalKey(reference)] = reference;
            break;
          }
        }
      }
    }
    ClassicSprites.load(
      teamColors: controller.mod.palette,
      overrides: controller.mod.sprites,
    ).then((sprites) {
      if (!mounted) {
        sprites.dispose();
        return;
      }
      setState(() => _sprites = sprites);
    });
  }

  @override
  void dispose() {
    _transformation.removeListener(_syncCache);
    _terrainCache.dispose();
    _sprites?.dispose();
    _priceAnimation.dispose();
    _transformation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = controller.viewState;
    final boardSize = HexBoard.canvasSize(state);
    final visibleTiles = controller.visibleTileIndices;
    final visibleWater = controller.visibleWaterCellIndices;
    _pixelRatio = MediaQuery.devicePixelRatioOf(context);
    final mapPainter = HexBoardPainter(
      terrainCache: _terrainCache,
      terrainSignature: Object.hash(
        identityHashCode(state),
        identityHashCode(_sprites),
      ),
      state: state,
      mod: controller.mod,
      fogActive: controller.fogActive,
      sprites: _sprites,
      selected: null,
      selectedWater: null,
      selectionOpacity: 0,
      moveTargets: const <int>{},
      waterTargets: const <int>{},
      defensePreviewTiles: const <int>{},
      defensePreviewWaterCells: const <int>{},
      defensePreviewOpacity: 0,
      artilleryRangePreview: false,
      artilleryVolleys: const [],
      artilleryFireProgress: 0,
      visibleTiles: visibleTiles,
      visibleWaterCells: visibleWater,
    );
    return Scaffold(
      key: ValueKey(
        widget.readOnly
            ? 'diplomacy-territory-preview'
            : _conferenceMode
            ? 'peace-allocation-picker-${widget.conferenceRecipient}'
            : 'diplomacy-land-selection-page',
      ),
      backgroundColor: DalaTheme.deepWater,
      body: SafeArea(
        child: Column(
          children: [
            Container(
              height: 72,
              color: Colors.black.withValues(alpha: .78),
              child: Row(
                children: [
                  SizedBox(
                    width: 76,
                    child: IconButton(
                      key: ValueKey(
                        _conferenceMode
                            ? 'peace-allocation-cancel'
                            : 'land-selection-cancel',
                      ),
                      tooltip: context.trNullable(
                        widget.readOnly ? 'Жабу' : 'Бас тарту',
                      ),
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(
                        Icons.close,
                        color: Color(0xffef3838),
                        size: 46,
                      ),
                    ),
                  ),
                  Expanded(
                    child: GameText(
                      widget.previewTitle ??
                          (_conferenceMode
                              ? '${controller.playerName(widget.conferenceRecipient!)} ойыншысының жер үлесі'
                              : 'Жер және теңіз активтері'),
                      translate: widget.previewTitle == null,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white, fontSize: 24),
                    ),
                  ),
                  if (!widget.readOnly)
                    SizedBox(
                      width: 76,
                      child: IconButton(
                        key: ValueKey(
                          _conferenceMode
                              ? 'peace-allocation-confirm'
                              : 'land-selection-confirm',
                        ),
                        tooltip: context.trNullable('Таңдауды растау'),
                        onPressed:
                            !_conferenceMode &&
                                _selected.isEmpty &&
                                _selectedNaval.isEmpty
                            ? null
                            : () => Navigator.pop(
                                context,
                                _TerritorySelectionResult(
                                  tiles: _selected.toList()..sort(),
                                  navalRefs: _selectedNaval.values.toList()
                                    ..sort((a, b) {
                                      final byKind = a.kind.index.compareTo(
                                        b.kind.index,
                                      );
                                      return byKind != 0
                                          ? byKind
                                          : a.id.compareTo(b.id);
                                    }),
                                ),
                              ),
                        icon: Icon(
                          Icons.check,
                          color:
                              !_conferenceMode &&
                                  _selected.isEmpty &&
                                  _selectedNaval.isEmpty
                              ? Colors.white24
                              : const Color(0xff5fd66c),
                          size: 46,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (widget.readOnly)
              Padding(
                padding: const EdgeInsets.all(8),
                child: GameText(
                  'Белгіленген жерлер ұсынысқа кіреді. Қарау келісімді қабылдамайды.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
              ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  _mapViewport = constraints.biggest;
                  _syncCache();
                  if (!_cameraFitted) {
                    _cameraFitted = true;
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) {
                        _fitCamera(constraints.biggest, boardSize, state);
                      }
                    });
                  }
                  return MapViewport(
                    transformationController: _transformation,
                    canvasSize: boardSize,
                    minScale: MapCameraBounds.fitScale(
                      constraints.biggest,
                      boardSize,
                    ),
                    maxScale: 2.8,
                    child: SizedBox(
                      width: boardSize.width,
                      height: boardSize.height,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTapUp: widget.readOnly
                            ? null
                            : (details) => _toggleTile(
                                _nearestTile(details.localPosition, state),
                                visibleTiles,
                                visibleWater,
                              ),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            CustomPaint(
                              willChange: state.hexes.length >= 1200,
                              painter: mapPainter,
                            ),
                            if (state.hexes.length >= 1200)
                              AnimatedBuilder(
                                animation: _transformation,
                                builder: (context, _) => CustomPaint(
                                  willChange: true,
                                  painter: HexStaticObjectPainter(
                                    source: mapPainter,
                                    viewBounds: _objectWindow.resolve(
                                      _viewBounds.inflate(80),
                                    ),
                                    signature: identityHashCode(mapPainter),
                                    overview:
                                        _transformation.value.entry(0, 0) <=
                                        MapCameraBounds.fitScale(
                                              _mapViewport,
                                              boardSize,
                                            ) *
                                            1.35,
                                  ),
                                ),
                              ),
                            IgnorePointer(
                              child: CustomPaint(
                                painter: HexUnitPainter(
                                  state: state,
                                  mod: controller.mod,
                                  sprites: _sprites,
                                  jumpProgress: 0,
                                  alertOwner: -1,
                                  selectedProvinceId: null,
                                  visibleTiles: visibleTiles,
                                  visibleWaterCells: visibleWater,
                                ),
                              ),
                            ),
                            IgnorePointer(
                              child: CustomPaint(
                                painter: _DiplomacyLandSelectionPainter(
                                  state: state,
                                  selected: _selected,
                                  selectedWaterCells: _selectedWaterCells,
                                  allocatedOwners: _effectiveAllocationOwners,
                                  palette: controller.mod.palette,
                                  priceCenter: _priceCenter,
                                  price: _price,
                                  priceProgress: _priceAnimation.value,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Map<int, int> get _effectiveAllocationOwners {
    if (!_conferenceMode) return const <int, int>{};
    final recipient = widget.conferenceRecipient!;
    final result = Map<int, int>.from(widget.conferenceAllocations)
      ..removeWhere((_, owner) => owner == recipient);
    for (final tile in _selected) {
      result[tile] = recipient;
    }
    return result;
  }

  Set<int> get _selectedWaterCells {
    if (_conferenceMode) return const <int>{};
    final selected = _selectedNaval.keys.toSet();
    return <int>{
      for (final cell in controller.viewState.waterCells)
        if ((!widget.readOnly ||
                controller.visibleWaterCellIndices.contains(cell.index)) &&
            ((cell.boat != null &&
                    selected.contains(
                      _navalKey(
                        NavalAssetRef(
                          kind: NavalAssetKind.boat,
                          id: cell.boat!.id,
                        ),
                      ),
                    )) ||
                (cell.seaFort != null &&
                    selected.contains(
                      _navalKey(
                        NavalAssetRef(
                          kind: NavalAssetKind.seaFort,
                          id: cell.seaFort!.id,
                        ),
                      ),
                    ))))
          cell.index,
    };
  }

  void _toggleTile(int? index, Set<int> visible, Set<int> visibleWater) {
    if (index == null) return;
    if (_conferenceMode) {
      _toggleConferenceTile(index, visible);
      return;
    }
    final tile = controller.viewState.hexes[index];
    if (!tile.active) {
      final cell = controller.viewState.waterCells
          .where((candidate) => candidate.tiles.contains(index))
          .firstOrNull;
      if (cell == null || !visibleWater.contains(cell.index)) {
        _showHint('Тұмандағы теңіз активін таңдауға болмайды');
        return;
      }
      final references =
          <NavalAssetRef>[
                if (cell.boat case final boat?)
                  NavalAssetRef(kind: NavalAssetKind.boat, id: boat.id),
                if (cell.seaFort case final fort?)
                  NavalAssetRef(kind: NavalAssetKind.seaFort, id: fort.id),
              ]
              .where(
                (reference) => controller.canSelectDiplomacyNavalAsset(
                  giver: widget.giver,
                  waterCell: cell.index,
                  reference: reference,
                ),
              )
              .toList();
      if (references.isEmpty) {
        _showHint('Бұл теңіз активін осы тарап бере алмайды');
        return;
      }
      var shownPrice = 0;
      setState(() {
        for (final reference in references) {
          final key = _navalKey(reference);
          if (_selectedNaval.remove(key) == null) {
            _selectedNaval[key] = reference;
            shownPrice += controller.engine.diplomacyNavalPrice(reference);
          }
        }
      });
      if (shownPrice > 0) {
        _showPrice(
          HexBoard.centerOfWater(controller.viewState, cell),
          shownPrice,
        );
      }
      return;
    }
    if (!visible.contains(index)) {
      _showHint('Тұмандағы жерді таңдауға болмайды');
      return;
    }
    if (!controller.canSelectDiplomacyLandTile(
      giver: widget.giver,
      index: index,
    )) {
      _showHint('Бұл жерді осы тарап бере алмайды');
      return;
    }
    var added = false;
    setState(() {
      added = _selected.add(index);
      if (!added) _selected.remove(index);
    });
    if (added) {
      _showPrice(
        HexBoard.centerOf(tile),
        controller.engine.diplomacyLandPrice(index),
      );
    }
  }

  void _toggleConferenceTile(int index, Set<int> visible) {
    if (!visible.contains(index)) {
      _showHint('Тұмандағы даулы жерді таңдауға болмайды');
      return;
    }
    if (widget.lockedConferenceTiles.contains(index)) {
      _showHint('Бұл жер басқа одақтасқа бөлініп қойылған');
      return;
    }
    final conferenceId = widget.conferenceId!;
    if (!controller.canSelectPeaceConferenceTile(
      conferenceId: conferenceId,
      index: index,
    )) {
      _showHint('Бұл клетка осы жер бөлісуге кірмейді');
      return;
    }
    if (_selected.contains(index)) {
      setState(() => _selected.remove(index));
      return;
    }
    final value = controller.engine.peaceConferenceTileValue(
      conferenceId,
      index,
    );
    final currentValue = _selected.fold<int>(
      0,
      (sum, tile) =>
          sum + controller.engine.peaceConferenceTileValue(conferenceId, tile),
    );
    final quota = controller.engine.peaceConferenceQuota(
      conferenceId,
      widget.conferenceRecipient!,
    );
    if (currentValue + value > quota) {
      _showHint('Үлес шегі асып кетті: ${currentValue + value} / $quota');
      return;
    }
    setState(() => _selected.add(index));
    _showPrice(HexBoard.centerOf(controller.viewState.hexes[index]), value);
  }

  void _showPrice(Offset center, int price) {
    setState(() {
      _priceCenter = center;
      _price = price;
    });
    _priceAnimation.forward(from: 0);
  }

  void _showHint(String message) {
    showTopSnackBar(
      context,
      message,
      duration: const Duration(milliseconds: 1100),
    );
  }

  int? _nearestTile(Offset point, GameState state) {
    final coordinate = OrganicCells.coordinateAt(point);
    for (final tile in state.hexes) {
      if (tile.inWorld && tile.q == coordinate.$1 && tile.r == coordinate.$2) {
        return tile.index;
      }
    }
    return null;
  }

  void _fitCamera(Size viewport, Size boardSize, GameState state) {
    final focus = {
      ..._selected,
      for (final i in _selectedWaterCells) ...state.waterCells[i].tiles,
    };
    final centers = state.hexes
        .where(
          (tile) =>
              tile.inWorld && (focus.isEmpty || focus.contains(tile.index)),
        )
        .map(HexBoard.centerOf)
        .toList();
    if (centers.isEmpty || viewport.isEmpty) return;
    var minX = centers.first.dx;
    var maxX = centers.first.dx;
    var minY = centers.first.dy;
    var maxY = centers.first.dy;
    for (final center in centers.skip(1)) {
      minX = math.min(minX, center.dx);
      maxX = math.max(maxX, center.dx);
      minY = math.min(minY, center.dy);
      maxY = math.max(maxY, center.dy);
    }
    final contentWidth = math.max(1.0, maxX - minX + 80);
    final contentHeight = math.max(1.0, maxY - minY + 80);
    final scale = math
        .min(viewport.width / contentWidth, viewport.height / contentHeight)
        .clamp(MapCameraBounds.fitScale(viewport, boardSize), 1.45);
    final target = Offset((minX + maxX) / 2, (minY + maxY) / 2);
    _transformation.value =
        MapCameraBounds(
          viewport: viewport,
          canvas: boardSize,
          minScale: MapCameraBounds.fitScale(viewport, boardSize),
          maxScale: 2.8,
        ).constrain(
          Matrix4.diagonal3Values(scale, scale, scale)..setTranslationRaw(
            viewport.width / 2 - target.dx * scale,
            viewport.height / 2 - target.dy * scale,
            0,
          ),
        );
  }
}

class _DiplomacyLandSelectionPainter extends CustomPainter {
  const _DiplomacyLandSelectionPainter({
    required this.state,
    required this.selected,
    required this.selectedWaterCells,
    required this.allocatedOwners,
    required this.palette,
    required this.priceCenter,
    required this.price,
    required this.priceProgress,
  });

  final GameState state;
  final Set<int> selected;
  final Set<int> selectedWaterCells;
  final Map<int, int> allocatedOwners;
  final List<Color> palette;
  final Offset? priceCenter;
  final int price;
  final double priceProgress;

  @override
  void paint(Canvas canvas, Size size) {
    for (final entry in allocatedOwners.entries) {
      final index = entry.key;
      if (index < 0 || index >= state.hexes.length || palette.isEmpty) continue;
      final path = _hexPath(HexBoard.centerOf(state.hexes[index]), 27);
      final color = palette[entry.value % palette.length];
      canvas.drawPath(path, Paint()..color = color.withValues(alpha: .38));
      canvas.drawPath(
        path,
        Paint()
          ..color = color.withValues(alpha: .95)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.4,
      );
    }
    for (final index in selected) {
      if (index < 0 || index >= state.hexes.length) continue;
      final path = _hexPath(HexBoard.centerOf(state.hexes[index]), 27);
      canvas.drawPath(
        path,
        Paint()..color = Colors.white.withValues(alpha: .24),
      );
      canvas.drawPath(
        path,
        Paint()
          ..color = const Color(0xffeefcff)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4,
      );
    }
    for (final waterCell in selectedWaterCells) {
      if (waterCell < 0 || waterCell >= state.waterCells.length) continue;
      final cell = state.waterCells[waterCell];
      for (final tileIndex in cell.tiles) {
        if (tileIndex < 0 || tileIndex >= state.hexes.length) continue;
        final path = _hexPath(HexBoard.centerOf(state.hexes[tileIndex]), 27);
        canvas.drawPath(
          path,
          Paint()..color = const Color(0xff75eaff).withValues(alpha: .22),
        );
        canvas.drawPath(
          path,
          Paint()
            ..color = const Color(0xff75eaff)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 4,
        );
      }
    }
    final center = priceCenter;
    if (center != null && price > 0 && priceProgress < 1) {
      final opacity = (1 - priceProgress).clamp(0.0, 1.0);
      final painter = TextPainter(
        text: TextSpan(
          text: '\$$price',
          style: TextStyle(
            color: Colors.white.withValues(alpha: opacity),
            fontSize: 22,
            fontWeight: FontWeight.bold,
            shadows: [
              Shadow(
                color: Colors.black.withValues(alpha: opacity),
                blurRadius: 4,
              ),
            ],
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      painter.paint(
        canvas,
        center.translate(-painter.width / 2, -18 - 30 * priceProgress),
      );
    }
  }

  Path _hexPath(Offset center, double radius) =>
      OrganicCells.around(center, inset: 30 - radius);

  @override
  bool shouldRepaint(_DiplomacyLandSelectionPainter oldDelegate) => true;
}

class _ValueLine extends StatelessWidget {
  const _ValueLine({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        GameText(label, style: const TextStyle(fontSize: 14)),
        GameText(
          value,
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
        ),
      ],
    ),
  );
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    color: DalaTheme.line,
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
    child: GameText(text, style: const TextStyle(fontSize: 16)),
  );
}

String _offerName(DiplomacyExchangeType type) => switch (type) {
  DiplomacyExchangeType.nothing => 'Ештеңе',
  DiplomacyExchangeType.money => 'Ақша',
  DiplomacyExchangeType.lands => 'Жер',
  DiplomacyExchangeType.friendship => 'Достық',
  DiplomacyExchangeType.militaryAlliance => 'Әскери одақ',
  DiplomacyExchangeType.warDeclaration => 'Соғыс жариялау',
  DiplomacyExchangeType.ceasefire => 'Бітім',
  DiplomacyExchangeType.removeBlackMark => 'Қара белгіні алу',
  DiplomacyExchangeType.subsidies => 'Субсидия',
};
