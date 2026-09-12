import '../l10n/game_locale.dart';
import 'dala_theme.dart';
import 'dart:async';

import 'package:flutter/material.dart';

import '../game/game_controller.dart';
import '../game/models.dart';
import '../game/turn_replay.dart';
import '../modding/game_mod.dart';
import '../persistence/save_repository.dart';
import 'antiyoy_background.dart';
import 'antiyoy_pressable.dart';
import 'hex_board.dart';
import 'top_snack_bar.dart';

class MatchStatistics {
  const MatchStatistics({
    required this.turns,
    required this.unitsBuilt,
    required this.unitsLost,
    required this.moneySpent,
    required this.elapsed,
  });

  final int turns;
  final int unitsBuilt;
  final int unitsLost;
  final int moneySpent;
  final Duration elapsed;
}

/// Statistics observe actions, replay frames observe completed player turns.
class MatchRecorder {
  MatchRecorder(GameState initial) {
    _stopwatch.start();
    _previousUnits = _unitCount(initial);
    _previousMoney = _money(initial);
    _previousTurnKey = '${initial.round}:${initial.turn}';
    _frames = TurnReplayFrames(initial);
    _fingerprint = _stateFingerprint(initial);
    _previousWinner = initial.winner;
  }

  final Stopwatch _stopwatch = Stopwatch();
  late final TurnReplayFrames _frames;
  int? _previousWinner;
  int? _fingerprint;
  int _previousUnits = 0;
  int _previousMoney = 0;
  String _previousTurnKey = '';
  int _turns = 0;
  int _unitsBuilt = 0;
  int _unitsLost = 0;
  int _moneySpent = 0;

  MatchStatistics get statistics => MatchStatistics(
    turns: _turns,
    unitsBuilt: _unitsBuilt,
    unitsLost: _unitsLost,
    moneySpent: _moneySpent,
    elapsed: _stopwatch.elapsed,
  );

  List<Map<String, dynamic>> get frames => _frames;

  void capture(GameState state) {
    final fingerprint = _stateFingerprint(state);
    if (_fingerprint == fingerprint) return;
    _fingerprint = fingerprint;

    final units = _unitCount(state);
    final money = _money(state);
    final turnKey = '${state.round}:${state.turn}';
    final turnChanged = turnKey != _previousTurnKey;
    if (_frames.isNotEmpty) {
      if (units > _previousUnits) _unitsBuilt += units - _previousUnits;
      if (units < _previousUnits) _unitsLost += _previousUnits - units;
      if (money < _previousMoney) _moneySpent += _previousMoney - money;
      if (turnChanged) {
        _turns++;
        _previousTurnKey = turnKey;
      }
    }
    _previousUnits = units;
    _previousMoney = money;
    if (turnChanged || state.winner != _previousWinner) {
      _frames.captureTurn(state);
    }
    _previousWinner = state.winner;
  }

  static int _unitCount(GameState state) {
    var result = 0;
    for (final tile in state.hexes) {
      if (tile.unit != null) result++;
    }
    for (final cell in state.waterCells) {
      final boat = cell.boat;
      if (boat == null) continue;
      result += 1 + boat.cargo.length;
    }
    return result;
  }

  static int _money(GameState state) =>
      state.provinces.fold<int>(0, (sum, province) => sum + province.money);

  static int _stateFingerprint(GameState state) {
    var hash = Object.hash(
      state.turn,
      state.round,
      state.winner,
      state.provinces.length,
      state.waterCells.length,
      state.diplomacyMessages.length,
      state.diplomacyProposals.length,
    );
    for (final tile in state.hexes) {
      hash = Object.hash(
        hash,
        tile.active,
        tile.owner + 1,
        tile.object.index,
        tile.unit?.strength,
        tile.coalitionClaim?.contributors.length,
      );
    }
    for (final province in state.provinces) {
      hash = Object.hash(hash, province.id, province.owner, province.money);
    }
    for (final cell in state.waterCells) {
      hash = Object.hash(
        hash,
        cell.boat?.owner,
        cell.boat?.level,
        cell.boat?.cargo.length,
        cell.seaFort?.owner,
        cell.seaMint,
      );
    }
    return hash;
  }
}

class MatchStatisticsScreen extends StatelessWidget {
  const MatchStatisticsScreen({
    required this.statistics,
    required this.onReplay,
    super.key,
  });

  final MatchStatistics statistics;
  final VoidCallback onReplay;

  @override
  Widget build(BuildContext context) {
    final minutes = statistics.elapsed.inMinutes;
    final seconds = statistics.elapsed.inSeconds.remainder(60);
    return Scaffold(
      backgroundColor: DalaTheme.canvas,
      body: Stack(
        fit: StackFit.expand,
        children: [
          const AntiyoyAnimatedParticles(),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                children: [
                  Row(
                    children: [
                      _SummaryButton(
                        label: '←',
                        color: DalaTheme.gold,
                        onTap: () => Navigator.pop(context),
                      ),
                      const Spacer(),
                      _SummaryButton(
                        label: 'Повтор',
                        color: DalaTheme.green,
                        onTap: onReplay,
                      ),
                    ],
                  ),
                  const SizedBox(height: 34),
                  Expanded(
                    child: Center(
                      child: Container(
                        width: 560,
                        padding: const EdgeInsets.all(22),
                        decoration: _summaryDecoration(),
                        child: DefaultTextStyle(
                          style: const TextStyle(
                            color: Colors.black,
                            fontSize: 18,
                            height: 1.4,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const GameText(
                                'Статистика',
                                style: TextStyle(fontSize: 23),
                              ),
                              GameText('Ход жасалды: ${statistics.turns}'),
                              GameText(
                                'Әскер жоғалды: ${statistics.unitsLost}',
                              ),
                              GameText(
                                'Әскер салынды: ${statistics.unitsBuilt}',
                              ),
                              GameText(
                                'Жұмсалған ақша: \$${statistics.moneySpent}',
                              ),
                              GameText(
                                'Уақыт: $minutes:${seconds.toString().padLeft(2, '0')}',
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
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

class MatchReplayScreen extends StatefulWidget {
  const MatchReplayScreen({
    required this.mod,
    required this.saves,
    required this.frames,
    super.key,
  });

  final GameMod mod;
  final SaveRepository saves;
  final List<Map<String, dynamic>> frames;

  @override
  State<MatchReplayScreen> createState() => _MatchReplayScreenState();
}

class _MatchReplayScreenState extends State<MatchReplayScreen> {
  late final GameController _controller;
  Timer? _timer;
  int _index = 0;
  bool _playing = false;
  bool _fast = false;

  @override
  void initState() {
    super.initState();
    final first = GameState.fromJson(widget.frames.first);
    _controller = GameController(
      mod: widget.mod,
      state: first,
      saves: widget.saves,
      autosaveEnabled: false,
      authoritativeSimulation: false,
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _schedule() {
    _timer?.cancel();
    if (!_playing) return;
    _timer = Timer.periodic(
      Duration(milliseconds: _fast ? 210 : 650),
      (_) => _advance(),
    );
  }

  void _advance() {
    if (_index >= widget.frames.length - 1) {
      setState(() => _playing = false);
      _timer?.cancel();
      return;
    }
    setState(() => _index++);
    _controller.replaceStateFromNetwork(widget.frames[_index]);
  }

  void _stop() {
    _timer?.cancel();
    setState(() {
      _playing = false;
      _index = 0;
    });
    _controller.replaceStateFromNetwork(widget.frames.first);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    body: SafeArea(
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            bottom: 66,
            child: HexBoard(controller: _controller, readOnly: true),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              height: 66,
              color: DalaTheme.line,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  IconButton(
                    tooltip: context.trNullable('Тоқтату'),
                    onPressed: _stop,
                    icon: const Icon(Icons.stop, size: 39),
                  ),
                  IconButton(
                    tooltip: context.trNullable(_playing ? 'Пауза' : 'Ойнату'),
                    onPressed: () {
                      setState(() => _playing = !_playing);
                      _schedule();
                    },
                    icon: Icon(
                      _playing ? Icons.pause : Icons.play_arrow,
                      size: 43,
                    ),
                  ),
                  IconButton(
                    tooltip: context.trNullable('Жылдамдық'),
                    onPressed: () {
                      setState(() => _fast = !_fast);
                      _schedule();
                    },
                    color: _fast ? const Color(0xff174f70) : Colors.black,
                    icon: const Icon(Icons.fast_forward, size: 43),
                  ),
                  IconButton(
                    tooltip: context.trNullable('Осы кадрды сақтау'),
                    onPressed: () async {
                      await widget.saves.save(_controller.state);
                      if (context.mounted) {
                        showTopSnackBar(context, 'Повтор күйі сақталды');
                      }
                    },
                    icon: const Icon(Icons.save, size: 38),
                  ),
                ],
              ),
            ),
          ),
          Positioned(
            top: 8,
            right: 8,
            child: IconButton.filled(
              tooltip: 'Жабу',
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.close),
            ),
          ),
          Positioned(
            top: 12,
            left: 12,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: const Color(0xcc111111),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                child: GameText(
                  'Ход $_index / ${widget.frames.length - 1}',
                  style: const TextStyle(color: Colors.white),
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class _SummaryButton extends StatelessWidget {
  const _SummaryButton({
    required this.label,
    required this.color,
    required this.onTap,
  });

  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => AntiyoyPressable(
    onTap: onTap,
    child: Container(
      constraints: const BoxConstraints(minWidth: 126),
      height: 58,
      padding: const EdgeInsets.symmetric(horizontal: 18),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(16),
        boxShadow: const [
          BoxShadow(color: Colors.black45, blurRadius: 7, offset: Offset(0, 5)),
        ],
      ),
      child: GameText(label, style: const TextStyle(fontSize: 25)),
    ),
  );
}

BoxDecoration _summaryDecoration() => DalaTheme.panel();
