import '../l10n/game_locale.dart';
import 'dala_theme.dart';
import 'dala_art.dart';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../game/game_controller.dart';
import '../game/game_engine.dart';
import '../game/models.dart';
import 'antiyoy_background.dart';
import 'antiyoy_pressable.dart';
import 'diplomacy_sheet.dart';
import 'hex_board.dart';
import 'match_replay.dart';
import 'top_snack_bar.dart';

enum GameScreenExit { restart, mainMenu }

enum _PauseAction { continueGame, restart, save, mainMenu }

class GameScreen extends StatefulWidget {
  const GameScreen({
    required this.controller,
    this.onVictory,
    this.disposeController = true,
    super.key,
  });

  final GameController controller;
  final Future<void> Function()? onVictory;
  final bool disposeController;

  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen> {
  late final MatchRecorder _matchRecorder;
  bool _victoryRecorded = false;
  bool _pauseMenuOpen = false;
  bool _allowRouteExit = false;
  bool _turnNoticeOpen = false;
  bool _turnNoticeScheduled = false;
  String? _lastTurnNoticeKey;

  @override
  void initState() {
    super.initState();
    _matchRecorder = MatchRecorder(widget.controller.state);
    widget.controller.addListener(_captureReplay);
    widget.controller.turnCompleted.addListener(_captureReplay);
    widget.controller.addListener(_watchLanTurn);
    WidgetsBinding.instance.addPostFrameCallback((_) => _watchLanTurn());
  }

  @override
  void dispose() {
    widget.controller.removeListener(_captureReplay);
    widget.controller.turnCompleted.removeListener(_captureReplay);
    widget.controller.removeListener(_watchLanTurn);
    if (widget.disposeController) widget.controller.dispose();
    super.dispose();
  }

  void _captureReplay() => _matchRecorder.capture(widget.controller.state);

  void _watchLanTurn() {
    if (!mounted || _turnNoticeOpen || _turnNoticeScheduled) return;
    final controller = widget.controller;
    if (!controller.isLanGame ||
        !controller.isLocalHumanTurn ||
        controller.state.winner != null ||
        controller.turnTransitionActive) {
      return;
    }
    final key = '${controller.state.round}:${controller.state.turn}';
    if (_lastTurnNoticeKey == key) return;
    _turnNoticeScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _turnNoticeScheduled = false;
      if (!mounted ||
          !widget.controller.isLocalHumanTurn ||
          widget.controller.state.winner != null) {
        return;
      }
      _turnNoticeOpen = true;
      _lastTurnNoticeKey = key;
      await _showAntiyoyDecision(
        context,
        title: 'Сенің ходың',
        message:
            '${widget.controller.playerName(widget.controller.state.turn)}, жүрісті бастаңыз',
        confirmLabel: 'Жарайды',
        showCancel: false,
        semanticKey: const ValueKey('lan-your-turn-dialog'),
      );
      _turnNoticeOpen = false;
    });
  }

  void _chooseTool(PlayerTool tool) {
    widget.controller.setTool(
      widget.controller.tool == tool ? PlayerTool.select : tool,
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope<Object?>(
      canPop: _allowRouteExit,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _openPauseMenu(context);
      },
      child: AnimatedBuilder(
        animation: widget.controller,
        builder: (context, _) {
          final controller = widget.controller;
          if (!_victoryRecorded &&
              controller.state.winner != null &&
              controller.state.isHuman(controller.state.winner!)) {
            _victoryRecorded = true;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              widget.onVictory?.call();
            });
          }
          final narrowGroundPanel = MediaQuery.sizeOf(context).width < 720;
          final bottomPanelHeight =
              controller.selectedBoat?.owner == controller.state.turn
              ? 60.0
              : controller.selectedOwnProvince == null
              ? 0.0
              : controller.selectedPortLevel > 0
              ? 66.0
              : controller.selectedArtilleryLevel > 0
              ? 66.0
              : controller.state.config.slayRules
              ? 60.0
              : narrowGroundPanel
              ? 92.0
              : 54.0;
          return Scaffold(
            backgroundColor: Colors.black,
            body: SafeArea(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Positioned.fill(
                    // The camera must constrain to playable space, not to the
                    // area behind the construction/cargo controls. World-space
                    // padding alone becomes too small when zooming out.
                    bottom: bottomPanelHeight,
                    child: HexBoard(
                      controller: controller,
                      onForeignDiplomacyRequested: (player) =>
                          _openDiplomacy(context, initialPlayer: player),
                    ),
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 0,
                    child: _ClassicHud(
                      controller: controller,
                      onRanking: () => _openRanking(context),
                      onReport: () => _openIncomeReport(context),
                      onMenu: () => _openPauseMenu(context),
                    ),
                  ),
                  if (controller.aiThinking)
                    Positioned(
                      top: 58,
                      left: 0,
                      right: 0,
                      child: Center(
                        child: _ThinkingLabel(controller: controller),
                      ),
                    ),
                  if (controller.isLanGame &&
                      (!controller.isLocalHumanTurn ||
                          !controller.networkConnected))
                    Positioned(
                      top: controller.aiThinking ? 104 : 58,
                      left: 44,
                      right: 44,
                      child: IgnorePointer(
                        child: Center(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: const Color(0xdd252525),
                              border: Border.all(color: Colors.white54),
                              borderRadius: BorderRadius.circular(13),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 7,
                              ),
                              child: GameText(
                                !controller.networkConnected
                                    ? 'LAN байланысы қайта орнатылуда…'
                                    : '${controller.playerName(controller.state.turn)} жүріп жатыр',
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (controller.isLanGame &&
                      controller.networkTurnTimerEnabled &&
                      controller.state.winner == null)
                    Positioned(
                      top: 58,
                      right: 10,
                      child: _LanTurnTimerBadge(controller: controller),
                    ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 230),
                      switchInCurve: Curves.easeOutCubic,
                      switchOutCurve: Curves.easeInCubic,
                      transitionBuilder: (child, animation) => FadeTransition(
                        opacity: animation,
                        child: SlideTransition(
                          position: Tween<Offset>(
                            begin: const Offset(0, .45),
                            end: Offset.zero,
                          ).animate(animation),
                          child: child,
                        ),
                      ),
                      child:
                          controller.selectedBoat?.owner ==
                              controller.state.turn
                          ? _BoatCargoPanel(
                              key: const ValueKey('boat-cargo'),
                              controller: controller,
                              onChoose: _chooseTool,
                            )
                          : controller.selectedOwnProvince == null
                          ? const SizedBox.shrink(
                              key: ValueKey('construction-hidden'),
                            )
                          : controller.selectedPortLevel > 0
                          ? _PortManagementPanel(
                              key: const ValueKey('port-management'),
                              controller: controller,
                              onChoose: _chooseTool,
                            )
                          : controller.selectedArtilleryLevel > 0
                          ? _ArtilleryManagementPanel(
                              key: const ValueKey('artillery-management'),
                              controller: controller,
                            )
                          : _FastConstructionPanel(
                              key: const ValueKey('ground-construction'),
                              controller: controller,
                              onChoose: _chooseTool,
                            ),
                    ),
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: bottomPanelHeight + 8,
                    child: IgnorePointer(
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 180),
                        switchInCurve: Curves.easeOutBack,
                        switchOutCurve: Curves.easeInCubic,
                        transitionBuilder: (child, animation) => FadeTransition(
                          opacity: animation,
                          child: ScaleTransition(
                            scale: Tween<double>(
                              begin: .72,
                              end: 1,
                            ).animate(animation),
                            child: child,
                          ),
                        ),
                        child: controller.tool == PlayerTool.select
                            ? const SizedBox.shrink(
                                key: ValueKey('tool-preview-hidden'),
                              )
                            : _SelectedToolPreview(
                                key: ValueKey(controller.tool),
                                controller: controller,
                              ),
                      ),
                    ),
                  ),
                  Positioned(
                    left: controller.leftHanded ? null : 0,
                    right: controller.leftHanded ? 0 : null,
                    bottom: bottomPanelHeight == 0
                        ? 18
                        : bottomPanelHeight + 16,
                    child: _FastSideControls(
                      controller: controller,
                      onFinishTurn: () => _finishTurn(context),
                      onDiplomacy: () => _openDiplomacy(context),
                      onInbox: () => _openDiplomacyInbox(context),
                    ),
                  ),
                  if (controller.state.winner != null)
                    Positioned.fill(
                      child: _VictoryOverlay(
                        controller: controller,
                        statistics: _matchRecorder.statistics,
                        onReplay: _openReplay,
                        onStatistics: _openStatistics,
                        onMainMenu: () => _exitGame(GameScreenExit.mainMenu),
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _openPauseMenu(BuildContext context) async {
    if (_pauseMenuOpen) return;
    _pauseMenuOpen = true;
    try {
      final action = await showGeneralDialog<_PauseAction>(
        context: context,
        barrierDismissible: false,
        barrierLabel: 'Ойын мәзірі',
        barrierColor: Colors.black,
        transitionDuration: const Duration(milliseconds: 180),
        transitionBuilder: (context, animation, secondaryAnimation, child) =>
            FadeTransition(opacity: animation, child: child),
        pageBuilder: (dialogContext, _, _) => _ClassicPausePage(
          onContinue: () =>
              Navigator.pop(dialogContext, _PauseAction.continueGame),
          onRestart: () => Navigator.pop(dialogContext, _PauseAction.restart),
          onSave: () => Navigator.pop(dialogContext, _PauseAction.save),
          onMainMenu: () => Navigator.pop(dialogContext, _PauseAction.mainMenu),
          allowRestart: !widget.controller.isLanClient,
          allowSave: !widget.controller.isLanClient,
        ),
      );
      if (!mounted ||
          !context.mounted ||
          action == null ||
          action == _PauseAction.continueGame) {
        return;
      }
      switch (action) {
        case _PauseAction.continueGame:
          break;
        case _PauseAction.save:
          await widget.controller.saves.save(widget.controller.state);
          if (context.mounted) {
            showTopSnackBar(
              context,
              'Ойын сақталды',
              duration: const Duration(milliseconds: 1400),
            );
          }
          break;
        case _PauseAction.restart:
          await _exitGame(GameScreenExit.restart);
          break;
        case _PauseAction.mainMenu:
          await _exitGame(GameScreenExit.mainMenu);
          break;
      }
    } finally {
      _pauseMenuOpen = false;
    }
  }

  Future<void> _openReplay() async {
    final frames = _matchRecorder.frames;
    if (frames.isEmpty || !mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => MatchReplayScreen(
          mod: widget.controller.mod,
          saves: widget.controller.saves,
          frames: frames,
        ),
      ),
    );
  }

  Future<void> _openStatistics() async {
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => MatchStatisticsScreen(
          statistics: _matchRecorder.statistics,
          onReplay: _openReplay,
        ),
      ),
    );
  }

  Future<void> _exitGame(GameScreenExit result) async {
    if (!mounted) return;
    setState(() => _allowRouteExit = true);
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) Navigator.of(context).pop(result);
  }

  Future<void> _finishTurn(BuildContext context) async {
    if (!widget.controller.isLanGame && !widget.controller.confirmEndTurn) {
      await widget.controller.finishTurn();
      return;
    }
    final confirmed = await _showAntiyoyDecision(
      context,
      title: 'Ходты аяқтау',
      message: 'Осы ходты шынымен аяқтайсыз ба?',
      confirmLabel: 'Иә',
      cancelLabel: 'Жоқ',
      semanticKey: const ValueKey('lan-end-turn-dialog'),
    );
    if (confirmed == true) await widget.controller.finishTurn();
  }

  Future<bool?> _showAntiyoyDecision(
    BuildContext context, {
    required String title,
    required String message,
    required String confirmLabel,
    String cancelLabel = '',
    bool showCancel = true,
    required Key semanticKey,
  }) => showGeneralDialog<bool>(
    context: context,
    barrierDismissible: false,
    barrierLabel: title,
    barrierColor: const Color(0x99000000),
    transitionDuration: const Duration(milliseconds: 170),
    transitionBuilder: (context, animation, _, child) => FadeTransition(
      opacity: animation,
      child: ScaleTransition(
        scale: Tween<double>(begin: .92, end: 1).animate(
          CurvedAnimation(parent: animation, curve: Curves.easeOutBack),
        ),
        child: child,
      ),
    ),
    pageBuilder: (dialogContext, _, _) => PopScope<Object?>(
      canPop: false,
      child: Center(
        child: Material(
          key: semanticKey,
          color: DalaTheme.paper,
          elevation: 11,
          borderRadius: BorderRadius.circular(17),
          clipBehavior: Clip.antiAlias,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 330),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.fromLTRB(18, 15, 18, 13),
                  color: const Color(0xffb7ad50),
                  child: GameText(
                    title,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 25,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(22, 21, 22, 22),
                  child: GameText(
                    message,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 18, height: 1.15),
                  ),
                ),
                Row(
                  children: [
                    if (showCancel)
                      Expanded(
                        child: _AntiyoyDialogBand(
                          key: const ValueKey('antiyoy-dialog-cancel'),
                          color: const Color(0xffd49482),
                          label: cancelLabel,
                          onTap: () => Navigator.pop(dialogContext, false),
                        ),
                      ),
                    Expanded(
                      child: _AntiyoyDialogBand(
                        key: const ValueKey('antiyoy-dialog-confirm'),
                        color: const Color(0xff5ab676),
                        label: confirmLabel,
                        onTap: () => Navigator.pop(dialogContext, true),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  Future<void> _openDiplomacy(
    BuildContext context, {
    int? initialPlayer,
  }) async {
    await showAntiyoyDiplomacy(
      context,
      widget.controller,
      initialPlayer: initialPlayer,
    );
  }

  Future<void> _openDiplomacyInbox(BuildContext context) async {
    await showAntiyoyDiplomacyInbox(context, widget.controller);
  }

  Future<void> _openRanking(BuildContext context) async {
    final controller = widget.controller;
    final incomes = [
      for (
        var player = 0;
        player < controller.state.config.playerCount;
        player++
      )
        controller.engine.playerIncome(player),
    ];
    final visiblePlayers = controller.visiblePlayerIndices;
    await showDialog<void>(
      context: context,
      barrierColor: const Color(0x55000000),
      builder: (dialogContext) => _IncomeRankingDialog(
        incomes: incomes,
        playerNames: [
          for (var player = 0; player < incomes.length; player++)
            controller.playerPossessiveName(player),
        ],
        colors: [
          for (var player = 0; player < incomes.length; player++)
            controller.mod.palette[player % controller.mod.palette.length],
        ],
        revealedPlayers: [
          for (var player = 0; player < incomes.length; player++)
            visiblePlayers.contains(player),
        ],
      ),
    );
  }

  Future<void> _openIncomeReport(BuildContext context) async {
    final province = widget.controller.selectedOwnProvince;
    if (province == null) {
      showTopSnackBar(
        context,
        'Алдымен өз провинцияңызды таңдаңыз',
        duration: const Duration(milliseconds: 1200),
      );
      return;
    }
    final report = widget.controller.engine.economicBreakdown(province);
    final rows = <(String, int)>[
      ('Жер', report.land),
      ('Ферма', report.farms),
      ('Дипломатия', report.diplomacy),
      ('Кеме-қала', report.navalSupport),
      ('Құрлық әскері', report.landUnits),
      ('Кемедегі әскер', report.cargoUnits),
      ('Құрлық қамалы', report.towers),
      ('Артиллерия', report.artillery),
      ('Ағаштар', report.trees),
      ('Порттар', report.ports),
      ('Кемелер', report.boats),
      ('Теңіз қамалдары', report.seaForts),
      ('Десантты қолдау', report.navalTransfer),
    ];
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xff686868),
      showDragHandle: false,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(sheetContext).height * .82,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(22, 16, 22, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const GameText(
                  'Доход есебі',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                for (final row in rows)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: GameText(
                            row.$1,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                            ),
                          ),
                        ),
                        GameText(
                          _signed(row.$2),
                          style: TextStyle(
                            color: row.$2 < 0
                                ? const Color(0xffffb0a8)
                                : const Color(0xffd9ffd8),
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                const Divider(color: Colors.white30),
                Row(
                  children: [
                    const Expanded(
                      child: GameText(
                        'Барлығы',
                        style: TextStyle(color: Colors.white, fontSize: 18),
                      ),
                    ),
                    GameText(
                      _signed(report.total),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _signed(int value) => value > 0 ? '+$value' : '$value';
}

// Kept for save-build compatibility with older widget snapshots; the active
// diplomacy implementation lives in diplomacy_sheet.dart.
// ignore: unused_element
class _DiplomacyRow extends StatelessWidget {
  const _DiplomacyRow({
    required this.player,
    required this.color,
    required this.status,
    required this.cooldown,
    required this.allianceTurns,
    required this.enabled,
    required this.incoming,
    required this.outgoing,
    required this.onBetter,
    required this.onWorse,
    required this.onResolve,
  });

  final int player;
  final Color color;
  final DiplomacyStatus status;
  final int cooldown;
  final int allianceTurns;
  final bool enabled;
  final DiplomacyProposal? incoming;
  final bool outgoing;
  final VoidCallback onBetter;
  final VoidCallback onWorse;
  final ValueChanged<bool> onResolve;

  @override
  Widget build(BuildContext context) {
    final label = switch (status) {
      DiplomacyStatus.war => 'Соғыс',
      DiplomacyStatus.peace => 'Бейтарап',
      DiplomacyStatus.alliance => 'Достық · $allianceTurns ход',
      DiplomacyStatus.coalition => 'Әскери одақ',
    };
    return Material(
      color: const Color(0xff4c4c4c),
      borderRadius: BorderRadius.circular(10),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 11),
        child: Column(
          children: [
            Row(
              children: [
                Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.black54),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: GameText(
                    '${player + 1}-ойыншы',
                    style: const TextStyle(color: Colors.white, fontSize: 18),
                  ),
                ),
                GameText(
                  label,
                  style: TextStyle(
                    color: switch (status) {
                      DiplomacyStatus.war => const Color(0xffff9d94),
                      DiplomacyStatus.peace => const Color(0xffffe59a),
                      DiplomacyStatus.alliance => const Color(0xffb8ffb5),
                      DiplomacyStatus.coalition => const Color(0xff8fe8ff),
                    },
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            if (incoming != null) ...[
              const SizedBox(height: 9),
              Container(
                padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
                color: const Color(0xff333333),
                child: Row(
                  children: [
                    Expanded(
                      child: GameText(
                        incoming!.type == DiplomacyProposalType.friendship
                            ? 'Достық ұсынысы'
                            : 'Бітім ұсынысы',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: enabled ? () => onResolve(false) : null,
                      child: const GameText('Бас тарту'),
                    ),
                    FilledButton(
                      onPressed: enabled ? () => onResolve(true) : null,
                      child: const GameText('Қабылдау'),
                    ),
                  ],
                ),
              ),
            ] else if (outgoing) ...[
              const SizedBox(height: 8),
              const Align(
                alignment: Alignment.centerLeft,
                child: GameText(
                  'Ұсыныс жіберілді — жауап келесі жүрісте келеді',
                  style: TextStyle(color: Colors.white60, fontSize: 13),
                ),
              ),
            ] else ...[
              const SizedBox(height: 9),
              Row(
                children: [
                  if (status != DiplomacyStatus.coalition)
                    Expanded(
                      child: FilledButton.tonal(
                        onPressed:
                            enabled &&
                                !(status == DiplomacyStatus.war && cooldown > 0)
                            ? onBetter
                            : null,
                        child: GameText(
                          status == DiplomacyStatus.war
                              ? cooldown > 0
                                    ? 'Бітім: $cooldown ход'
                                    : 'Бітім ұсыну'
                              : status == DiplomacyStatus.alliance
                              ? 'Әскери одақ ұсыну'
                              : 'Достық ұсыну',
                        ),
                      ),
                    ),
                  if (status != DiplomacyStatus.war &&
                      status != DiplomacyStatus.coalition)
                    const SizedBox(width: 8),
                  if (status != DiplomacyStatus.war)
                    Expanded(
                      child: OutlinedButton(
                        onPressed: enabled ? onWorse : null,
                        child: GameText(
                          status == DiplomacyStatus.coalition
                              ? 'Әскери одақты тоқтату'
                              : status == DiplomacyStatus.alliance
                              ? 'Достықты тоқтату'
                              : 'Соғыс жариялау',
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _IncomeRankingDialog extends StatelessWidget {
  const _IncomeRankingDialog({
    required this.incomes,
    required this.playerNames,
    required this.colors,
    required this.revealedPlayers,
  });

  final List<int> incomes;
  final List<String> playerNames;
  final List<Color> colors;
  final List<bool> revealedPlayers;

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final maxIncome = incomes.fold<int>(1, (best, value) {
      return math.max(best, math.max(0, value));
    });
    return Dialog(
      insetPadding: EdgeInsets.symmetric(
        horizontal: screen.width < 600 ? 0 : 24,
        vertical: 24,
      ),
      backgroundColor: const Color(0xffd7ddd7),
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(),
      child: SizedBox(
        width: math.min(screen.width, 560),
        height: math.min(screen.height * .48, 390),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
          child: Column(
            children: [
              const GameText(
                'Доход',
                style: TextStyle(
                  color: DalaTheme.ink,
                  fontSize: 30,
                  height: 1.1,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 14),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final chartHeight = math.max(
                      1.0,
                      constraints.maxHeight - 36,
                    );
                    return Stack(
                      children: [
                        const Positioned(
                          left: 0,
                          right: 0,
                          bottom: 32,
                          child: ColoredBox(
                            color: DalaTheme.ink,
                            child: SizedBox(height: 3),
                          ),
                        ),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (
                              var player = 0;
                              player < incomes.length;
                              player++
                            )
                              Expanded(
                                child: Column(
                                  children: [
                                    Expanded(
                                      child: Align(
                                        alignment: Alignment.bottomCenter,
                                        child: FractionallySizedBox(
                                          widthFactor: .62,
                                          child: TweenAnimationBuilder<double>(
                                            duration: reduceMotion
                                                ? Duration.zero
                                                : const Duration(
                                                    milliseconds: 320,
                                                  ),
                                            curve: Curves.easeOutCubic,
                                            tween: Tween(
                                              begin: 0,
                                              end:
                                                  math.max(0, incomes[player]) /
                                                  maxIncome,
                                            ),
                                            builder: (context, factor, child) =>
                                                SizedBox(
                                                  height: math.max(
                                                    incomes[player] == 0
                                                        ? 0
                                                        : 5,
                                                    chartHeight * factor,
                                                  ),
                                                  child: child,
                                                ),
                                            child: Semantics(
                                              label: context.trNullable(
                                                '${playerNames[player]} доходы: '
                                                '${incomes[player]}, '
                                                '${revealedPlayers[player] ? 'түсі көрінеді' : 'түсі жасырын'}',
                                              ),
                                              child: DecoratedBox(
                                                decoration: BoxDecoration(
                                                  color: revealedPlayers[player]
                                                      ? colors[player]
                                                      : const Color(0xff8b8f8b),
                                                  border: Border.all(
                                                    color: const Color(
                                                      0xff303030,
                                                    ),
                                                    width: 2,
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                    SizedBox(
                                      height: 35,
                                      child: Center(
                                        child: GameText(
                                          '${incomes[player]}',
                                          style: const TextStyle(
                                            color: DalaTheme.ink,
                                            fontSize: 19,
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AntiyoyDialogBand extends StatelessWidget {
  const _AntiyoyDialogBand({
    required this.color,
    required this.label,
    required this.onTap,
    super.key,
  });

  final Color color;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => AntiyoyPressable(
    onTap: onTap,
    child: ColoredBox(
      color: color,
      child: SizedBox(
        height: 58,
        child: Center(
          child: GameText(
            label,
            style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w800),
          ),
        ),
      ),
    ),
  );
}

class _LanTurnTimerBadge extends StatelessWidget {
  const _LanTurnTimerBadge({required this.controller});

  final GameController controller;

  @override
  Widget build(BuildContext context) {
    final seconds = controller.networkTurnRemainingSeconds;
    final minutes = seconds ~/ 60;
    final rest = seconds % 60;
    return Semantics(
      label: context.trNullable('Ход уақыты: $minutes минут $rest секунд'),
      liveRegion: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: seconds <= 15
              ? const Color(0xffbd6659)
              : const Color(0xddb7ad50),
          border: Border.all(color: Colors.black54),
          borderRadius: BorderRadius.circular(11),
          boxShadow: const [
            BoxShadow(
              color: Colors.black38,
              blurRadius: 4,
              offset: Offset(0, 2),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          child: GameText(
            '$minutes:${rest.toString().padLeft(2, '0')}',
            key: const ValueKey('lan-turn-timer'),
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900),
          ),
        ),
      ),
    );
  }
}

class _ClassicHud extends StatelessWidget {
  const _ClassicHud({
    required this.controller,
    required this.onRanking,
    required this.onReport,
    required this.onMenu,
  });
  final GameController controller;
  final VoidCallback onRanking;
  final VoidCallback onReport;
  final VoidCallback onMenu;

  @override
  Widget build(BuildContext context) {
    final selected = controller.selectedOwnProvince;
    final balance = selected == null ? 0 : controller.engine.balance(selected);
    final player = controller.visibilityPlayer;
    final color =
        controller.mod.palette[player % controller.mod.palette.length];
    Widget action(String label, VoidCallback onTap, Widget child) => Semantics(
      button: true,
      label: context.tr(label),
      excludeSemantics: true,
      child: AntiyoyPressable(
        onTap: onTap,
        child: SizedBox(height: 44, child: child),
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Align(
              alignment: Alignment.topLeft,
              child: _FieldPlaque(
                key: const ValueKey('field-hud-status'),
                child: selected == null
                    ? SizedBox(
                        height: 44,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.flag, color: color, size: 21),
                            const SizedBox(width: 8),
                            Flexible(
                              child: GameText(
                                controller.playerName(player),
                                translate: false,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: DalaTheme.paper,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ],
                        ),
                      )
                    : Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: action(
                              'Доход рейтингі',
                              onRanking,
                              FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    DalaAsset(
                                      'assets/classic/coin.png',
                                      width: 24,
                                      height: 24,
                                    ),
                                    const SizedBox(width: 5),
                                    _HudText('${selected.money}'),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          Container(
                            width: 1,
                            height: 20,
                            margin: const EdgeInsets.symmetric(horizontal: 12),
                            color: DalaTheme.gold,
                          ),
                          Flexible(
                            child: action(
                              'Доход есебі',
                              onReport,
                              FittedBox(
                                fit: BoxFit.scaleDown,
                                child: _HudText(
                                  '${balance >= 0 ? '+' : ''}$balance',
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          _FieldPlaque(
            key: const ValueKey('field-hud-menu'),
            child: action(
              'Мәзір',
              onMenu,
              const SizedBox(
                width: 28,
                child: Icon(Icons.pause, size: 24, color: DalaTheme.gold),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Small cut-corner plaques leave the map visible between the HUD controls.
class _FieldPlaque extends StatelessWidget {
  const _FieldPlaque({required this.child, super.key});
  final Widget child;
  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: const ShapeDecoration(
      color: DalaTheme.ink,
      shape: BeveledRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(5)),
        side: BorderSide(color: DalaTheme.gold, width: 1),
      ),
      shadows: [BoxShadow(color: Color(0x30243e38), offset: Offset(0, 2))],
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: child,
    ),
  );
}

class _HudText extends StatelessWidget {
  const _HudText(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => GameText(
    text,
    style: const TextStyle(
      color: DalaTheme.paper,
      fontSize: 20,
      height: 1,
      fontWeight: FontWeight.w600,
    ),
  );
}

class _FastConstructionPanel extends StatelessWidget {
  const _FastConstructionPanel({
    required this.controller,
    required this.onChoose,
    super.key,
  });

  final GameController controller;
  final ValueChanged<PlayerTool> onChoose;

  @override
  Widget build(BuildContext context) {
    final enabled =
        controller.isLocalHumanTurn &&
        !controller.interactionsLocked &&
        controller.state.winner == null;
    final province = controller.selectedOwnProvince;
    final hasProvince = province != null;
    final rules = controller.mod.rules;
    final playerColor = controller
        .mod
        .palette[controller.state.turn % controller.mod.palette.length];
    final farmPrice = province == null
        ? rules.farmBasePrice
        : controller.engine.farmPrice(province);
    final structures = <Widget>[
      if (!controller.state.config.slayRules)
        _FastBuildItem(
          label: 'Ферма',
          asset: 'farm1.png',
          price: farmPrice,
          selected: controller.tool == PlayerTool.farm,
          enabled: hasProvince,
          tint: playerColor,
          onTap: () => onChoose(PlayerTool.farm),
        ),
      _FastBuildItem(
        label: '1-деңгейлі қамал',
        asset: 'tower.png',
        price: rules.towerPrice,
        selected: controller.tool == PlayerTool.tower,
        enabled: hasProvince,
        tint: playerColor,
        onTap: () => onChoose(PlayerTool.tower),
      ),
      if (!controller.state.config.slayRules)
        _FastBuildItem(
          label: '2-деңгейлі қамал',
          asset: 'strong_tower.png',
          price: rules.strongTowerPrice,
          selected: controller.tool == PlayerTool.strongTower,
          enabled: hasProvince,
          tint: playerColor,
          onTap: () => onChoose(PlayerTool.strongTower),
        ),
      _FastBuildItem(
        label: '1-деңгейлі порт',
        asset: 'port1.png',
        price: rules.port1Price,
        selected: controller.tool == PlayerTool.port1,
        enabled: hasProvince && controller.engine.canAddPort(province),
        tint: playerColor,
        onTap: () => onChoose(PlayerTool.port1),
      ),
      _FastBuildItem(
        label: 'Жағалау артиллериясы',
        asset: 'artillery.png',
        price: rules.artilleryCosts[1],
        selected: controller.tool == PlayerTool.artillery,
        enabled: hasProvince && controller.engine.canAddArtillery(province),
        tint: playerColor,
        hasTeamLayer: false,
        onTap: () => onChoose(PlayerTool.artillery),
      ),
    ];
    final units = <Widget>[
      for (var strength = 1; strength <= 4; strength++)
        _FastBuildItem(
          label: '$strength-деңгейлі әскер',
          asset: 'man${strength - 1}.png',
          price: strength * rules.unitPricePerLevel,
          selected: controller.tool.index == strength,
          enabled: hasProvince,
          tint: playerColor,
          onTap: () => onChoose(PlayerTool.values[strength]),
        ),
    ];
    final slayItems = <Widget>[
      structures.first,
      ...units,
      ...structures.skip(1),
    ];

    Widget itemRow(List<Widget> items, Color color) => ColoredBox(
      color: color,
      child: Row(children: [for (final item in items) Expanded(child: item)]),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < 720;
        return Container(
          height: controller.state.config.slayRules
              ? 60
              : narrow
              ? 92
              : 54,
          decoration: const BoxDecoration(
            color: DalaTheme.paper,
            border: Border(top: BorderSide(color: DalaTheme.gold, width: 2)),
          ),
          clipBehavior: Clip.antiAlias,
          child: IgnorePointer(
            ignoring: !enabled,
            child: Opacity(
              opacity: enabled ? 1 : .5,
              child: controller.state.config.slayRules
                  ? itemRow(slayItems, const Color(0x12000000))
                  : narrow
                  ? Column(
                      children: [
                        Expanded(
                          child: itemRow(structures, const Color(0x09365c68)),
                        ),
                        Container(height: 2, color: DalaTheme.line),
                        Expanded(
                          child: itemRow(units, const Color(0x0cffffff)),
                        ),
                      ],
                    )
                  : Row(
                      children: [
                        Expanded(
                          flex: structures.length,
                          child: itemRow(structures, const Color(0x09365c68)),
                        ),
                        Container(width: 2, color: DalaTheme.line),
                        Expanded(
                          flex: 4,
                          child: itemRow(units, const Color(0x0cffffff)),
                        ),
                      ],
                    ),
            ),
          ),
        );
      },
    );
  }
}

class _PortManagementPanel extends StatelessWidget {
  const _PortManagementPanel({
    required this.controller,
    required this.onChoose,
    super.key,
  });

  final GameController controller;
  final ValueChanged<PlayerTool> onChoose;

  @override
  Widget build(BuildContext context) {
    final rules = controller.mod.rules;
    final province = controller.selectedOwnProvince!;
    final portLevel = controller.selectedPortLevel;
    final slaySizeLocked =
        controller.state.config.slayRules &&
        province.tiles.length < GameEngine.slayPort2MinimumTiles;
    final playerColor = controller
        .mod
        .palette[controller.state.turn % controller.mod.palette.length];
    return Container(
      height: 66,
      decoration: const BoxDecoration(
        color: Color(0xf2365c68),
        border: Border(top: BorderSide(color: Color(0xff292929), width: 2)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _ObjectPanelBadge(
            asset: portLevel == 1 ? 'port1.png' : 'port2.png',
            level: portLevel,
            tint: playerColor,
          ),
          const _PanelDivider(),
          _ContextActionItem(
            label: portLevel >= 2
                ? 'Толық дамыған'
                : slaySizeLocked
                ? '${GameEngine.slayPort2MinimumTiles} жер керек'
                : 'Дамыту',
            semanticsLabel: portLevel < 2
                ? 'Портты дамыту'
                : 'Порт толық дамыған',
            symbol: _ContextActionSymbol.upgrade,
            price: portLevel < 2 ? rules.port2Price : null,
            available: portLevel < 2 && !slaySizeLocked,
            affordable: province.money >= rules.port2Price,
            pulse:
                portLevel < 2 &&
                !slaySizeLocked &&
                province.money >= rules.port2Price,
            onTap: controller.upgradeSelectedPort,
          ),
          const _PanelDivider(),
          _CompactBoatItem(
            label: '1-деңгейлі қайық, 4 орын',
            asset: 'boat1.png',
            price: rules.boat1Price,
            selected: controller.tool == PlayerTool.boat1,
            enabled: controller.selectedPortLevel >= 1,
            tint: playerColor,
            onTap: () => onChoose(PlayerTool.boat1),
          ),
          _CompactBoatItem(
            label: '2-деңгейлі қайық, 10 орын',
            asset: 'boat2.png',
            price: rules.boat2Price,
            selected: controller.tool == PlayerTool.boat2,
            enabled: controller.selectedPortLevel >= 2,
            tint: playerColor,
            onTap: () => onChoose(PlayerTool.boat2),
          ),
        ],
      ),
    );
  }
}

class _ArtilleryManagementPanel extends StatelessWidget {
  const _ArtilleryManagementPanel({required this.controller, super.key});

  final GameController controller;

  @override
  Widget build(BuildContext context) {
    final level = controller.selectedArtilleryLevel;
    final province = controller.selectedOwnProvince!;
    final rules = controller.mod.rules;
    final ammo = controller.selectedArtilleryAmmo;
    final ammoCapacity = controller.selectedArtilleryAmmoCapacity;
    final upkeep = rules.artilleryUpkeep[level];
    final canUpgrade = level < 3;
    final upgradePrice = canUpgrade ? rules.artilleryCosts[level + 1] : 0;
    final minimumTiles = level == 1
        ? GameEngine.slayArtillery2MinimumTiles
        : GameEngine.slayArtillery3MinimumTiles;
    final slaySizeLocked =
        controller.state.config.slayRules &&
        canUpgrade &&
        province.tiles.length < minimumTiles;
    final playerColor = controller
        .mod
        .palette[controller.state.turn % controller.mod.palette.length];
    return Container(
      height: 66,
      decoration: const BoxDecoration(
        color: Color(0xf2365c68),
        border: Border(top: BorderSide(color: Color(0xff292929), width: 2)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _ObjectPanelBadge(
            asset: 'artillery.png',
            level: level,
            tint: playerColor,
            hasTeamLayer: false,
            status: '$ammo/$ammoCapacity оқ',
          ),
          const _PanelDivider(),
          _AutomaticReloadStatus(upkeep: upkeep),
          const _PanelDivider(),
          _ContextActionItem(
            label: !canUpgrade
                ? 'Толық дамыған'
                : slaySizeLocked
                ? '$minimumTiles жер керек'
                : 'Дамыту',
            semanticsLabel: canUpgrade
                ? 'Артиллерияны дамыту'
                : 'Артиллерия толық дамыған',
            symbol: _ContextActionSymbol.upgrade,
            price: canUpgrade ? upgradePrice : null,
            available: canUpgrade && !slaySizeLocked,
            affordable: province.money >= upgradePrice,
            pulse:
                canUpgrade && !slaySizeLocked && province.money >= upgradePrice,
            onTap: controller.upgradeSelectedArtillery,
          ),
        ],
      ),
    );
  }
}

class _PanelDivider extends StatelessWidget {
  const _PanelDivider();

  @override
  Widget build(BuildContext context) =>
      Container(width: 2, height: 46, color: const Color(0x66282828));
}

class _ObjectPanelBadge extends StatelessWidget {
  const _ObjectPanelBadge({
    required this.asset,
    required this.level,
    required this.tint,
    this.hasTeamLayer = true,
    this.status,
  });

  final String asset;
  final int level;
  final Color tint;
  final bool hasTeamLayer;
  final String? status;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 82,
    child: Stack(
      fit: StackFit.expand,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 3, 12, 20),
          child: hasTeamLayer
              ? _TeamColoredAsset(asset: asset, tint: tint)
              : _NeutralTeamMarkedAsset(asset: asset, tint: tint),
        ),
        Positioned(
          left: 2,
          right: 2,
          bottom: 3,
          child: GameText(
            status ?? '${level == 1 ? 'I' : 'II'} деңгей',
            maxLines: 1,
            overflow: TextOverflow.fade,
            softWrap: false,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 9,
              height: 1,
              fontWeight: FontWeight.w700,
              shadows: [Shadow(color: Colors.black, blurRadius: 3)],
            ),
          ),
        ),
      ],
    ),
  );
}

class _AutomaticReloadStatus extends StatelessWidget {
  const _AutomaticReloadStatus({required this.upkeep});

  final int upkeep;

  @override
  Widget build(BuildContext context) => Semantics(
    label: context.trNullable('Автоматты оқтау, тұрақты шығын $upkeep'),
    excludeSemantics: true,
    child: SizedBox(
      width: 86,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const _ActionSymbol(symbol: _ContextActionSymbol.reload),
          const GameText(
            'Авто оқтау',
            maxLines: 1,
            style: TextStyle(
              color: Colors.white,
              fontSize: 9,
              fontWeight: FontWeight.w600,
            ),
          ),
          GameText(
            '−$upkeep/ход',
            style: const TextStyle(
              color: Color(0xffffcdd2),
              fontSize: 10,
              height: 1,
              fontWeight: FontWeight.w700,
              shadows: [Shadow(color: Colors.black, blurRadius: 2)],
            ),
          ),
        ],
      ),
    ),
  );
}

class _ContextActionItem extends StatefulWidget {
  const _ContextActionItem({
    required this.label,
    required this.semanticsLabel,
    required this.symbol,
    required this.price,
    required this.available,
    required this.affordable,
    required this.pulse,
    required this.onTap,
  });

  final String label;
  final String semanticsLabel;
  final _ContextActionSymbol symbol;
  final int? price;
  final bool available;
  final bool affordable;
  final bool pulse;
  final VoidCallback onTap;

  @override
  State<_ContextActionItem> createState() => _ContextActionItemState();
}

class _ContextActionItemState extends State<_ContextActionItem>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 850),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncPulse();
  }

  @override
  void didUpdateWidget(covariant _ContextActionItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncPulse();
  }

  void _syncPulse() {
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (widget.pulse && widget.available && !reduceMotion) {
      if (!_pulseController.isAnimating) {
        _pulseController.repeat(reverse: true);
      }
    } else {
      _pulseController
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    enabled: widget.available,
    label: context.trNullable(
      widget.price == null
          ? widget.semanticsLabel
          : '${widget.semanticsLabel}, бағасы ${widget.price}',
    ),
    excludeSemantics: true,
    child: IgnorePointer(
      ignoring: !widget.available,
      child: AntiyoyPressable(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedBuilder(
          animation: _pulseController,
          builder: (context, child) {
            final glow = _pulseController.value;
            return Transform.scale(
              scale: 1 + glow * .055,
              child: Container(
                width: 86,
                margin: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
                decoration: BoxDecoration(
                  color: widget.affordable
                      ? Color.lerp(
                          const Color(0x22000000),
                          const Color(0x594caf50),
                          glow,
                        )
                      : const Color(0x22000000),
                  borderRadius: BorderRadius.circular(7),
                  border: Border.all(
                    color: glow > 0
                        ? Color.lerp(
                            const Color(0x006ce678),
                            const Color(0xff9cff9f),
                            glow,
                          )!
                        : Colors.transparent,
                  ),
                  boxShadow: glow > 0
                      ? [
                          BoxShadow(
                            color: const Color(
                              0xff74e27b,
                            ).withValues(alpha: .28 * glow),
                            blurRadius: 10 * glow,
                          ),
                        ]
                      : null,
                ),
                child: child,
              ),
            );
          },
          child: Opacity(
            opacity: widget.available
                ? widget.affordable
                      ? 1
                      : .48
                : .32,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _ActionSymbol(symbol: widget.symbol),
                GameText(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.fade,
                  softWrap: false,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 9,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (widget.price != null)
                  GameText(
                    '\$${widget.price}',
                    style: const TextStyle(
                      color: Color(0xffffe082),
                      fontSize: 11,
                      height: 1,
                      fontWeight: FontWeight.w700,
                      shadows: [Shadow(color: Colors.black, blurRadius: 2)],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

enum _ContextActionSymbol { upgrade, reload }

class _ActionSymbol extends StatelessWidget {
  const _ActionSymbol({required this.symbol});

  final _ContextActionSymbol symbol;

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: const Size.square(29),
    painter: _ActionSymbolPainter(symbol),
  );
}

class _ActionSymbolPainter extends CustomPainter {
  const _ActionSymbolPainter(this.symbol);

  final _ContextActionSymbol symbol;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white
      ..strokeWidth = 2.7
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    if (symbol == _ContextActionSymbol.upgrade) {
      final upper = Path()
        ..moveTo(size.width * .2, size.height * .43)
        ..lineTo(size.width * .5, size.height * .16)
        ..lineTo(size.width * .8, size.height * .43);
      final lower = Path()
        ..moveTo(size.width * .2, size.height * .72)
        ..lineTo(size.width * .5, size.height * .45)
        ..lineTo(size.width * .8, size.height * .72);
      canvas
        ..drawPath(upper, paint)
        ..drawPath(lower, paint)
        ..drawLine(
          Offset(size.width * .5, size.height * .48),
          Offset(size.width * .5, size.height * .88),
          paint,
        );
      return;
    }

    final rect = Rect.fromCircle(
      center: Offset(size.width * .5, size.height * .52),
      radius: size.width * .31,
    );
    canvas.drawArc(rect, -.55, math.pi * 1.55, false, paint);
    final arrow = Path()
      ..moveTo(size.width * .72, size.height * .12)
      ..lineTo(size.width * .82, size.height * .38)
      ..lineTo(size.width * .56, size.height * .32);
    canvas.drawPath(arrow, paint..style = PaintingStyle.fill);
  }

  @override
  bool shouldRepaint(covariant _ActionSymbolPainter oldDelegate) =>
      oldDelegate.symbol != symbol;
}

class _SelectedToolPreview extends StatelessWidget {
  const _SelectedToolPreview({required this.controller, super.key});

  final GameController controller;

  @override
  Widget build(BuildContext context) {
    final data = _ToolPreviewData.from(controller);
    if (data == null) return const SizedBox.shrink();
    final tint = controller
        .mod
        .palette[controller.state.turn % controller.mod.palette.length];
    return Center(
      child: SizedBox(
        width: 82,
        height: 96,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(7, 3, 7, 2),
          child: Column(
            children: [
              Expanded(
                child: data.hasTeamLayer
                    ? _TeamColoredAsset(asset: data.asset, tint: tint)
                    : _NeutralTeamMarkedAsset(asset: data.asset, tint: tint),
              ),
              GameText(
                '\$${data.price}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 21,
                  height: 1,
                  fontWeight: FontWeight.w600,
                  shadows: [
                    Shadow(color: Colors.black, blurRadius: 4),
                    Shadow(color: Colors.black, offset: Offset(1, 2)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ToolPreviewData {
  const _ToolPreviewData({
    required this.asset,
    required this.price,
    this.hasTeamLayer = true,
  });

  final String asset;
  final int price;
  final bool hasTeamLayer;

  static _ToolPreviewData? from(GameController controller) {
    final rules = controller.mod.rules;
    final province = controller.selectedOwnProvince;
    return switch (controller.tool) {
      PlayerTool.unit1 => _ToolPreviewData(
        asset: 'man0.png',
        price: rules.unitPricePerLevel,
      ),
      PlayerTool.unit2 => _ToolPreviewData(
        asset: 'man1.png',
        price: rules.unitPricePerLevel * 2,
      ),
      PlayerTool.unit3 => _ToolPreviewData(
        asset: 'man2.png',
        price: rules.unitPricePerLevel * 3,
      ),
      PlayerTool.unit4 => _ToolPreviewData(
        asset: 'man3.png',
        price: rules.unitPricePerLevel * 4,
      ),
      PlayerTool.farm => _ToolPreviewData(
        asset: 'farm1.png',
        price: province == null
            ? rules.farmBasePrice
            : controller.engine.farmPrice(province),
      ),
      PlayerTool.tower => _ToolPreviewData(
        asset: 'tower.png',
        price: rules.towerPrice,
      ),
      PlayerTool.strongTower => _ToolPreviewData(
        asset: 'strong_tower.png',
        price: rules.strongTowerPrice,
      ),
      PlayerTool.port1 => _ToolPreviewData(
        asset: 'port1.png',
        price: rules.port1Price,
      ),
      PlayerTool.port2 => _ToolPreviewData(
        asset: 'port2.png',
        price: rules.port2Price,
      ),
      PlayerTool.boat1 => _ToolPreviewData(
        asset: 'boat1.png',
        price: rules.boat1Price,
      ),
      PlayerTool.boat2 => _ToolPreviewData(
        asset: 'boat2.png',
        price: rules.boat2Price,
      ),
      PlayerTool.artillery => _ToolPreviewData(
        asset: 'artillery.png',
        price: rules.artilleryCosts[1],
        hasTeamLayer: false,
      ),
      PlayerTool.seaFort => _ToolPreviewData(
        asset: 'sea_fort.png',
        price: rules.seaFortPrice,
        hasTeamLayer: false,
      ),
      PlayerTool.select => null,
    };
  }
}

class _BoatCargoPanel extends StatelessWidget {
  const _BoatCargoPanel({
    required this.controller,
    required this.onChoose,
    super.key,
  });

  final GameController controller;
  final ValueChanged<PlayerTool> onChoose;

  @override
  Widget build(BuildContext context) {
    final boat = controller.selectedBoat!;
    final playerColor = controller
        .mod
        .palette[controller.state.turn % controller.mod.palette.length];
    return Container(
      height: 60,
      padding: const EdgeInsets.symmetric(horizontal: 5),
      color: const Color(0xe6365c68),
      child: Row(
        children: [
          SizedBox(
            width: 72,
            child: _FastBuildItem(
              label: 'Теңіз бекінісі',
              asset: 'sea_fort.png',
              price: controller.mod.rules.seaFortPrice,
              selected: controller.tool == PlayerTool.seaFort,
              enabled:
                  controller.selectedWaterCell != null &&
                  controller.engine
                      .seaFortBuildTargets(controller.selectedWaterCell!)
                      .isNotEmpty,
              tint: playerColor,
              hasTeamLayer: false,
              onTap: () => onChoose(PlayerTool.seaFort),
              onDisabledTap: controller.explainSeaFortBuildBlock,
            ),
          ),
          Container(width: 2, color: const Color(0x66000000)),
          Expanded(
            child: boat.cargo.isEmpty
                ? const Center(
                    child: GameText(
                      'Кемеде әскер жоқ',
                      style: TextStyle(color: Colors.white54, fontSize: 12),
                    ),
                  )
                : Row(
                    children: [
                      for (var index = 0; index < boat.cargo.length; index++)
                        Expanded(
                          child: _CargoUnitItem(
                            strength: boat.cargo[index].strength,
                            ready: boat.cargo[index].ready,
                            selected: controller.selectedCargoIndex == index,
                            tint: playerColor,
                            onTap: () => controller.selectBoatCargo(index),
                          ),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _CargoUnitItem extends StatelessWidget {
  const _CargoUnitItem({
    required this.strength,
    required this.ready,
    required this.selected,
    required this.tint,
    required this.onTap,
  });

  final int strength;
  final bool ready;
  final bool selected;
  final Color tint;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: context.trNullable(
      '$strength-деңгейлі әскер${ready ? '' : ', келесі ходта дайын'}',
    ),
    selected: selected,
    excludeSemantics: true,
    child: AntiyoyPressable(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        margin: const EdgeInsets.symmetric(horizontal: 1, vertical: 4),
        decoration: BoxDecoration(
          color: selected ? const Color(0x78000000) : Colors.transparent,
          border: Border(
            top: BorderSide(
              color: selected ? Colors.white : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Opacity(
          opacity: ready ? 1 : .38,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(2, 2, 2, 13),
                child: _TeamColoredAsset(
                  asset: 'man${strength - 1}.png',
                  tint: tint,
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 1,
                child: GameText(
                  ready ? '$strength' : '…',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    height: 1,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    shadows: [Shadow(color: Colors.black, blurRadius: 3)],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _CompactBoatItem extends StatelessWidget {
  const _CompactBoatItem({
    required this.label,
    required this.asset,
    required this.price,
    required this.selected,
    required this.enabled,
    required this.tint,
    required this.onTap,
  });

  final String label;
  final String asset;
  final int price;
  final bool selected;
  final bool enabled;
  final Color tint;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: context.trNullable('$label, бағасы $price'),
    excludeSemantics: true,
    child: IgnorePointer(
      ignoring: !enabled,
      child: AntiyoyPressable(
        onTap: onTap,
        child: Opacity(
          opacity: enabled ? 1 : .35,
          child: Container(
            width: 82,
            color: selected ? const Color(0x66000000) : Colors.transparent,
            child: Center(
              child: _TeamColoredAsset(
                asset: asset,
                width: 54,
                height: 60,
                tint: tint,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class _FastBuildItem extends StatelessWidget {
  const _FastBuildItem({
    required this.label,
    required this.asset,
    required this.price,
    required this.selected,
    required this.enabled,
    required this.tint,
    required this.onTap,
    this.onDisabledTap,
    this.hasTeamLayer = true,
  });

  final String label;
  final String asset;
  final int price;
  final bool selected;
  final bool enabled;
  final Color tint;
  final VoidCallback onTap;
  final VoidCallback? onDisabledTap;
  final bool hasTeamLayer;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: context.trNullable('$label, бағасы $price'),
    excludeSemantics: true,
    child: AntiyoyPressable(
      onTap: enabled ? onTap : onDisabledTap,
      behavior: HitTestBehavior.opaque,
      child: Opacity(
        opacity: enabled ? 1 : .42,
        child: Container(
          width: double.infinity,
          height: double.infinity,
          color: selected ? const Color(0x66000000) : Colors.transparent,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Padding(
                padding: const EdgeInsets.all(5),
                child: hasTeamLayer
                    ? _TeamColoredAsset(asset: asset, tint: tint)
                    : _NeutralTeamMarkedAsset(asset: asset, tint: tint),
              ),
              if (!enabled)
                const Positioned(
                  top: 3,
                  right: 3,
                  child: Icon(
                    Icons.lock,
                    size: 13,
                    color: Color(0xfff2f2f2),
                    shadows: [Shadow(color: Colors.black, blurRadius: 3)],
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _TeamColoredAsset extends StatelessWidget {
  const _TeamColoredAsset({
    required this.asset,
    required this.tint,
    this.width,
    this.height,
  });

  final String asset;
  final Color tint;
  final double? width;
  final double? height;

  @override
  Widget build(BuildContext context) {
    final base = 'assets/classic/field_elements/$asset';
    final team =
        'assets/classic/field_elements/${asset.substring(0, asset.length - 4)}_team.png';
    return SizedBox(
      width: width,
      height: height,
      child: Stack(
        fit: StackFit.expand,
        children: [
          DalaAsset(base, fit: BoxFit.contain),
          DalaAsset(
            team,
            fit: BoxFit.contain,
            color: tint,
            colorBlendMode: BlendMode.srcIn,
          ),
        ],
      ),
    );
  }
}

class _NeutralTeamMarkedAsset extends StatelessWidget {
  const _NeutralTeamMarkedAsset({required this.asset, required this.tint});

  final String asset;
  final Color tint;

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      DalaAsset('assets/classic/field_elements/$asset', fit: BoxFit.contain),
      Positioned(
        top: 5,
        right: 5,
        child: CustomPaint(
          size: const Size(17, 14),
          painter: _TinyTeamFlagPainter(tint),
        ),
      ),
    ],
  );
}

class _TinyTeamFlagPainter extends CustomPainter {
  const _TinyTeamFlagPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawLine(
      Offset(2, 1),
      Offset(2, size.height),
      Paint()
        ..color = const Color(0xff24201c)
        ..strokeWidth = 1.5,
    );
    final flag = Path()
      ..moveTo(2, 1)
      ..lineTo(size.width, 5)
      ..lineTo(2, 9)
      ..close();
    canvas.drawPath(flag, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_TinyTeamFlagPainter oldDelegate) =>
      oldDelegate.color != color;
}

class _FastSideControls extends StatelessWidget {
  const _FastSideControls({
    required this.controller,
    required this.onFinishTurn,
    required this.onDiplomacy,
    required this.onInbox,
  });

  final GameController controller;
  final VoidCallback onFinishTurn;
  final VoidCallback onDiplomacy;
  final VoidCallback onInbox;

  @override
  Widget build(BuildContext context) {
    final canInteract =
        controller.isLocalHumanTurn &&
        !controller.interactionsLocked &&
        controller.state.winner == null;
    final hasInbox =
        controller.state.config.diplomacy &&
        canInteract &&
        controller.engine.hasDiplomacyInbox(controller.state.turn);
    return Column(
      children: [
        if (hasInbox) ...[
          _FloatingIconControl(
            label: 'Кіріс хаттар',
            icon: Icons.mail_outline,
            enabled: canInteract,
            hasNotification: false,
            bare: true,
            onTap: onInbox,
          ),
          const SizedBox(height: 4),
        ],
        if (controller.state.config.diplomacy) ...[
          _FloatingIconControl(
            label: 'Дипломатия',
            icon: Icons.flag_outlined,
            enabled: canInteract,
            hasNotification: false,
            bare: true,
            onTap: onDiplomacy,
          ),
          const SizedBox(height: 8),
        ],
        _FloatingAssetControl(
          label: 'Жүрісті аяқтау',
          asset: 'assets/classic/end_turn.png',
          enabled: canInteract,
          onTap: onFinishTurn,
        ),
        const SizedBox(height: 18),
        _FloatingAssetControl(
          label: 'Әрекетті қайтару',
          asset: 'assets/classic/undo.png',
          enabled: controller.canUndo,
          onTap: controller.undo,
        ),
      ],
    );
  }
}

class _FloatingIconControl extends StatelessWidget {
  const _FloatingIconControl({
    required this.label,
    required this.icon,
    required this.enabled,
    required this.hasNotification,
    required this.onTap,
    this.bare = false,
  });

  final String label;
  final IconData icon;
  final bool enabled;
  final bool hasNotification;
  final VoidCallback onTap;
  final bool bare;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: context.trNullable(label),
    child: IgnorePointer(
      ignoring: !enabled,
      child: AntiyoyPressable(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Opacity(
          opacity: enabled ? 1 : .28,
          child: Container(
            decoration: DalaTheme.panel(),
            width: 54,
            height: 54,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Icon(icon, color: DalaTheme.ink, size: 28),
                if (hasNotification)
                  Positioned(
                    right: 2,
                    top: 2,
                    child: Container(
                      width: 14,
                      height: 14,
                      decoration: const BoxDecoration(
                        color: Color(0xffff5d55),
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class _FloatingAssetControl extends StatelessWidget {
  const _FloatingAssetControl({
    required this.label,
    required this.asset,
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final String asset;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: context.trNullable(label),
    child: IgnorePointer(
      ignoring: !enabled,
      child: AntiyoyPressable(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Opacity(
          opacity: enabled ? 1 : .28,
          child: Container(
            decoration: DalaTheme.panel(),
            width: 54,
            height: 54,
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: DalaAsset(asset, fit: BoxFit.contain),
            ),
          ),
        ),
      ),
    ),
  );
}

class _ThinkingLabel extends StatelessWidget {
  const _ThinkingLabel({required this.controller});

  final GameController controller;

  @override
  Widget build(BuildContext context) {
    if (controller.concealedAiTurns) {
      return IgnorePointer(
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 7, 14, 7),
          decoration: BoxDecoration(
            color: const Color(0xee151515),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: Colors.white54, width: 1.5),
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 17,
                height: 17,
                child: CircularProgressIndicator(
                  strokeWidth: 2.4,
                  color: Colors.white,
                ),
              ),
              SizedBox(width: 9),
              GameText(
                'Қарсыластар жүріп жатыр',
                style: TextStyle(color: Colors.white, fontSize: 14),
              ),
            ],
          ),
        ),
      );
    }
    final player = controller.aiPlayer ?? controller.state.turn;
    final color =
        controller.mod.palette[player % controller.mod.palette.length];
    return IgnorePointer(
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        padding: const EdgeInsets.fromLTRB(11, 7, 13, 7),
        decoration: BoxDecoration(
          color: const Color(0xdd151515),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: color, width: 2),
          boxShadow: const [
            BoxShadow(
              color: Colors.black45,
              blurRadius: 5,
              offset: Offset(0, 3),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 17,
              height: 17,
              child: TweenAnimationBuilder<double>(
                duration: const Duration(milliseconds: 120),
                tween: Tween(begin: 0, end: controller.aiProgress),
                builder: (context, progress, _) => CircularProgressIndicator(
                  value: progress == 0 ? null : progress,
                  strokeWidth: 2.4,
                  color: color,
                  backgroundColor: Colors.white24,
                ),
              ),
            ),
            const SizedBox(width: 9),
            GameText(
              'AI ${player + 1} жүрісі',
              style: const TextStyle(color: Colors.white, fontSize: 14),
            ),
            const SizedBox(width: 8),
            GameText(
              '${(controller.aiProgress * 100).round()}%',
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

class _ClassicPausePage extends StatelessWidget {
  const _ClassicPausePage({
    required this.onContinue,
    required this.onRestart,
    required this.onSave,
    required this.onMainMenu,
    this.allowRestart = true,
    this.allowSave = true,
  });

  final VoidCallback onContinue;
  final VoidCallback onRestart;
  final VoidCallback onSave;
  final VoidCallback onMainMenu;
  final bool allowRestart;
  final bool allowSave;

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    final rowHeight = (screen.height * .087).clamp(60.0, 78.0);
    return PopScope<Object?>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) onMainMenu();
      },
      child: Scaffold(
        backgroundColor: DalaTheme.canvas,
        body: DecoratedBox(
          decoration: const BoxDecoration(
            color: DalaTheme.canvas,
            gradient: LinearGradient(
              colors: [DalaTheme.paper, DalaTheme.canvas],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              const _PauseParticles(),
              SafeArea(
                child: Align(
                  alignment: const Alignment(0, .12),
                  child: SizedBox(
                    width: math.min(screen.width * .76, 548),
                    child: DecoratedBox(
                      decoration: DalaTheme.panel(),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(17),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _PauseBand(
                              label: 'Жалғастыру',
                              color: DalaTheme.gold,
                              height: rowHeight,
                              onTap: onContinue,
                            ),
                            if (allowRestart)
                              _PauseBand(
                                label: 'Қайта бастау',
                                color: DalaTheme.green,
                                height: rowHeight,
                                onTap: onRestart,
                              ),
                            if (allowSave)
                              _PauseBand(
                                label: 'Сақтау',
                                color: DalaTheme.blue,
                                height: rowHeight,
                                onTap: onSave,
                              ),
                            _PauseBand(
                              label: 'Басты мәзір',
                              color: DalaTheme.gold,
                              height: rowHeight,
                              onTap: onMainMenu,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PauseBand extends StatelessWidget {
  const _PauseBand({
    required this.label,
    required this.color,
    required this.height,
    required this.onTap,
  });

  final String label;
  final Color color;
  final double height;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: context.trNullable(label),
    child: AntiyoyPressable(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.all(5),
        decoration: BoxDecoration(
          color: Color.lerp(DalaTheme.paper, color, .4),
          borderRadius: BorderRadius.circular(16),
        ),
        child: SizedBox(
          width: double.infinity,
          height: height,
          child: Center(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: GameText(
                label,
                style: const TextStyle(
                  color: DalaTheme.ink,
                  fontSize: 24,
                  fontWeight: FontWeight.w600,
                  height: 1,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class _PauseParticles extends StatelessWidget {
  const _PauseParticles();

  @override
  Widget build(BuildContext context) =>
      const AntiyoyAnimatedParticles(color: Color(0xff567275));
}

class _VictoryOverlay extends StatelessWidget {
  const _VictoryOverlay({
    required this.controller,
    required this.statistics,
    required this.onReplay,
    required this.onStatistics,
    required this.onMainMenu,
  });

  final GameController controller;
  final MatchStatistics statistics;
  final VoidCallback onReplay;
  final VoidCallback onStatistics;
  final VoidCallback onMainMenu;

  @override
  Widget build(BuildContext context) {
    final winner = controller.state.winner!;
    final color =
        controller.mod.palette[winner % controller.mod.palette.length];
    return ColoredBox(
      color: DalaTheme.canvas,
      child: Stack(
        fit: StackFit.expand,
        children: [
          const AntiyoyAnimatedParticles(color: Color(0xff567275)),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(22),
              child: Column(
                children: [
                  Align(
                    alignment: Alignment.topRight,
                    child: _FlatMenuButton(
                      width: 170,
                      color: DalaTheme.gold,
                      label: 'Повтор',
                      onTap: onReplay,
                    ),
                  ),
                  const Spacer(),
                  Container(
                    width: 580,
                    clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(
                      color: DalaTheme.paper,
                      borderRadius: BorderRadius.circular(18),
                      boxShadow: const [
                        BoxShadow(
                          color: Colors.black45,
                          blurRadius: 8,
                          offset: Offset(0, 6),
                        ),
                      ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(22, 28, 22, 28),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              GameText(
                                'Жеңімпаз: ${winner + 1}',
                                style: const TextStyle(fontSize: 30),
                              ),
                              const SizedBox(width: 18),
                              Container(
                                width: 46,
                                height: 46,
                                decoration: BoxDecoration(
                                  color: color,
                                  border: Border.all(
                                    color: Colors.black54,
                                    width: 2,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        Row(
                          children: [
                            Expanded(
                              child: _FlatMenuButton(
                                color: DalaTheme.blue,
                                label: 'Статистика',
                                onTap: onStatistics,
                              ),
                            ),
                            Expanded(
                              child: _FlatMenuButton(
                                color: DalaTheme.green,
                                label: 'Жарайды',
                                onTap: onMainMenu,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const Spacer(),
                  GameText(
                    '${statistics.turns} ход',
                    style: const TextStyle(color: Colors.black54),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FlatMenuButton extends StatelessWidget {
  const _FlatMenuButton({
    required this.color,
    required this.label,
    required this.onTap,
    this.width,
  });

  final Color color;
  final String label;
  final VoidCallback onTap;
  final double? width;

  @override
  Widget build(BuildContext context) => AntiyoyPressable(
    onTap: onTap,
    child: Container(
      width: width ?? double.infinity,
      height: 58,
      alignment: Alignment.center,
      color: color,
      child: GameText(
        label,
        style: const TextStyle(fontSize: 22, color: Colors.black),
      ),
    ),
  );
}
