import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../modding/game_mod.dart';
import '../persistence/save_repository.dart';
import 'game_ai.dart';
import 'game_engine.dart';
import 'map_generator.dart';
import 'models.dart';

enum PlayerTool {
  select,
  unit1,
  unit2,
  unit3,
  unit4,
  farm,
  tower,
  strongTower,
  port1,
  port2,
  boat1,
  boat2,
  artillery,
  seaFort,
}

enum GameNetworkRole { offline, host, client }

abstract interface class GameNetworkDelegate {
  bool get isConnected;

  bool get busy;

  bool sendCommand(
    String action,
    Map<String, dynamic> arguments,
    Map<String, dynamic> uiState,
  );

  Future<bool> sendCommandAsync(
    String action,
    Map<String, dynamic> arguments,
    Map<String, dynamic> uiState,
  );
}

class BoatBattleAnimation {
  const BoatBattleAnimation({
    required this.serial,
    required this.fromWaterCell,
    required this.toWaterCell,
    required this.attackerOwner,
    required this.attackerLevel,
    required this.defenderOwner,
    required this.defenderLevel,
    required this.bothSunk,
  });

  final int serial;
  final int fromWaterCell;
  final int toWaterCell;
  final int attackerOwner;
  final int attackerLevel;
  final int defenderOwner;
  final int defenderLevel;
  final bool bothSunk;
}

class SeaFortDestructionAnimation {
  const SeaFortDestructionAnimation({
    required this.serial,
    required this.fromWaterCell,
    required this.toWaterCell,
    required this.attackerOwner,
    required this.attackerLevel,
    required this.fortOwner,
  });

  final int serial;
  final int fromWaterCell;
  final int toWaterCell;
  final int attackerOwner;
  final int attackerLevel;
  final int fortOwner;
}

class GameController extends ChangeNotifier {
  GameController({
    required this.mod,
    required this.state,
    required this.saves,
    this.autosaveEnabled = true,
    this.confirmEndTurn = true,
    this.leftHanded = false,
    this.sensitivity = 6,
    this.localPlayer,
    this.networkRole = GameNetworkRole.offline,
    this.authoritativeSimulation = true,
  }) : engine = GameEngine(mod: mod, state: state) {
    _visibilityPlayer =
        localPlayer ?? (state.currentPlayerIsHuman ? state.turn : 0);
    MapGenerator.ensureSeaArena(state);
    MapGenerator.ensureWaterCells(state);
    engine.sanitizeOverlaps();
    if (authoritativeSimulation) unawaited(runAiTurns());
  }

  final GameMod mod;
  final GameState state;
  final SaveRepository saves;
  final bool autosaveEnabled;
  final bool confirmEndTurn;
  final bool leftHanded;
  final int sensitivity;
  final int? localPlayer;
  final GameNetworkRole networkRole;
  final bool authoritativeSimulation;
  final GameEngine engine;

  /// Simulation turn boundaries, including AI turns hidden by fog of war.
  /// Separate from UI updates so replay recording does not reveal hidden moves.
  final ChangeNotifier turnCompleted = ChangeNotifier();
  GameNetworkDelegate? networkDelegate;
  PlayerTool tool = PlayerTool.select;
  int? selectedTile;
  int? selectedWaterCell;
  int? selectedCargoIndex;
  String? selectedModTypeId;
  int? selectedAirTile;
  BoatBattleAnimation? boatBattleAnimation;
  SeaFortDestructionAnimation? seaFortDestructionAnimation;
  Set<int> defensePreviewTiles = const {};
  Set<int> defensePreviewWaterCells = const {};
  double defensePreviewOpacity = 0;
  bool artilleryRangePreview = false;
  List<ArtilleryStrike> artilleryFireAnimation = const [];
  double artilleryFireOpacity = 0;
  int artilleryAnimationSerial = 0;
  bool artilleryCinematicActive = false;
  String hint = 'Әскерді немесе аймақты таңдаңыз';
  bool aiThinking = false;
  bool turnTransitionActive = false;
  int? aiPlayer;
  double aiProgress = 0;
  bool _active = true;
  double selectionOpacity = 1;
  Timer? _selectionFadeTimer;
  Timer? _defensePreviewTimer;
  Timer? _artilleryFireTimer;
  Completer<void>? _artilleryAnimationCompleter;
  int _battleSerial = 0;
  int _seaDestructionSerial = 0;
  final List<String> _undoHistory = [];
  GameState? _concealedState;
  int? _visibilityPlayer;
  int? _networkActor;
  bool _networkCanUndo = false;
  bool networkTurnTimerEnabled = false;
  int networkTurnDurationSeconds = 0;
  DateTime? networkTurnDeadline;
  Timer? _networkTurnTicker;
  bool _overviewAnimationsSuppressed = false;

  bool get isLanGame => networkRole != GameNetworkRole.offline;
  bool get isLanHost => networkRole == GameNetworkRole.host;
  bool get isLanClient => networkRole == GameNetworkRole.client;
  bool get networkConnected => networkDelegate?.isConnected ?? true;
  bool get networkBusy => networkDelegate?.busy ?? false;
  int get networkTurnRemainingSeconds {
    final deadline = networkTurnDeadline;
    if (!networkTurnTimerEnabled || deadline == null) return 0;
    final milliseconds = deadline.difference(DateTime.now()).inMilliseconds;
    if (milliseconds <= 0) return 0;
    return (milliseconds / 1000).ceil();
  }

  bool get isLocalHumanTurn =>
      state.currentPlayerIsHuman &&
      (localPlayer == null || state.turn == localPlayer);
  bool get canControlCurrentTurn =>
      state.currentPlayerIsHuman &&
      (localPlayer == null ||
          state.turn == localPlayer ||
          _networkActor == state.turn);

  bool get canUndo =>
      (networkDelegate == null ? _undoHistory.isNotEmpty : _networkCanUndo) &&
      !interactionsLocked;
  bool get interactionsLocked =>
      turnTransitionActive ||
      aiThinking ||
      artilleryCinematicActive ||
      (networkDelegate != null && !(networkDelegate?.isConnected ?? false));

  bool get concealedAiTurns => _concealedState != null;

  GameState get viewState => _concealedState ?? state;

  int get visibilityPlayer => _visibilityPlayer ?? state.turn;

  String playerName(int player) => state.playerName(player);

  String playerPossessiveName(int player) => state.playerPossessiveName(player);

  Map<String, dynamic> captureNetworkUiState() => {
    'selectedTile': selectedTile,
    'selectedWaterCell': selectedWaterCell,
    'selectedCargoIndex': selectedCargoIndex,
    if (selectedModTypeId != null) 'selectedModTypeId': selectedModTypeId,
    if (selectedAirTile != null) 'selectedAirTile': selectedAirTile,
    'toolIndex': tool.index,
    'hint': hint,
    'defenseTiles': defensePreviewTiles.toList()..sort(),
    'defenseWaterCells': defensePreviewWaterCells.toList()..sort(),
    'defenseOpacity': defensePreviewOpacity,
    'artilleryRangePreview': artilleryRangePreview,
    'canUndo': _undoHistory.isNotEmpty,
  };

  void applyNetworkUiState(Map<String, dynamic> json, {bool notify = true}) {
    int? nullableIndex(Object? value, int length) {
      if (value is! num) return null;
      final index = value.toInt();
      return index >= 0 && index < length ? index : null;
    }

    selectedTile = nullableIndex(json['selectedTile'], state.hexes.length);
    final customType = json['selectedModTypeId'];
    selectedModTypeId =
        customType is String &&
            (mod.buildings.containsKey(customType) ||
                mod.units.containsKey(customType))
        ? customType
        : null;
    selectedAirTile = nullableIndex(
      json['selectedAirTile'],
      state.hexes.length,
    );
    selectedWaterCell = nullableIndex(
      json['selectedWaterCell'],
      state.waterCells.length,
    );
    final cargo = json['selectedCargoIndex'];
    selectedCargoIndex = cargo is num && cargo.toInt() >= 0
        ? cargo.toInt()
        : null;
    final toolIndex = (json['toolIndex'] as num?)?.toInt() ?? 0;
    tool = PlayerTool.values[toolIndex.clamp(0, PlayerTool.values.length - 1)];
    hint = (json['hint'] as String? ?? hint);
    defensePreviewTiles = (json['defenseTiles'] as List? ?? const <Object>[])
        .whereType<num>()
        .map((value) => value.toInt())
        .where((index) => index >= 0 && index < state.hexes.length)
        .toSet();
    defensePreviewWaterCells =
        (json['defenseWaterCells'] as List? ?? const <Object>[])
            .whereType<num>()
            .map((value) => value.toInt())
            .where((index) => index >= 0 && index < state.waterCells.length)
            .toSet();
    defensePreviewOpacity = ((json['defenseOpacity'] as num?)?.toDouble() ?? 0)
        .clamp(0, 1);
    artilleryRangePreview = json['artilleryRangePreview'] as bool? ?? false;
    _networkCanUndo = json['canUndo'] as bool? ?? _networkCanUndo;
    if (notify) notifyListeners();
  }

  void replaceStateFromNetwork(
    Map<String, dynamic> json, {
    Map<String, dynamic>? uiState,
  }) {
    final restored = GameState.fromJson(json);
    if (restored.modId != state.modId ||
        jsonEncode(restored.config.toJson()) !=
            jsonEncode(state.config.toJson())) {
      throw StateError('LAN күйінің моды немесе ойын баптауы сәйкес емес.');
    }
    _restoreState(restored);
    if (localPlayer != null) _visibilityPlayer = localPlayer;
    if (uiState != null) applyNetworkUiState(uiState, notify: false);
    boatBattleAnimation = null;
    seaFortDestructionAnimation = null;
    notifyListeners();
  }

  /// Applies a host-authored compact state update without rebuilding every
  /// unchanged hex on the client. Every changed record is still parsed through
  /// the ordinary model factories before it reaches rendering or gameplay UI.
  void applyStatePatchFromNetwork(
    Map<String, dynamic> patch, {
    Map<String, dynamic>? uiState,
  }) {
    final changedHexes = patch['hexes'];
    if (changedHexes is List) {
      for (final raw in changedHexes) {
        if (raw is! Map) throw const FormatException('LAN жер патчы жарамсыз.');
        final tile = HexTile.fromJson(raw.cast<String, dynamic>());
        if (tile.index < 0 || tile.index >= state.hexes.length) {
          throw const FormatException('LAN жер индексі жарамсыз.');
        }
        final previous = state.hexes[tile.index];
        if (tile.q != previous.q ||
            tile.r != previous.r ||
            !listEquals(tile.neighbors, previous.neighbors)) {
          throw const FormatException('LAN карта топологиясы өзгертілді.');
        }
        state.hexes[tile.index] = tile;
      }
    }

    final changedWater = patch['waterCells'];
    if (changedWater is List) {
      for (final raw in changedWater) {
        if (raw is! Map) throw const FormatException('LAN су патчы жарамсыз.');
        final cell = WaterCell.fromJson(raw.cast<String, dynamic>());
        if (cell.index < 0 || cell.index >= state.waterCells.length) {
          throw const FormatException('LAN су индексі жарамсыз.');
        }
        final previous = state.waterCells[cell.index];
        if (!listEquals(cell.tiles, previous.tiles) ||
            !listEquals(cell.neighbors, previous.neighbors) ||
            !listEquals(cell.coastTiles, previous.coastTiles)) {
          throw const FormatException('LAN су топологиясы өзгертілді.');
        }
        state.waterCells[cell.index] = cell;
      }
    }

    final scalars = patch['scalars'];
    if (scalars is Map) {
      final values = scalars.cast<String, dynamic>();
      if (values['turn'] case final num value) state.turn = value.toInt();
      if (values['round'] case final num value) state.round = value.toInt();
      if (values['rngState'] case final num value) {
        state.rngState = value.toInt();
      }
      if (values['nextProvinceId'] case final num value) {
        state.nextProvinceId = value.toInt();
      }
      if (values['nextNavalEntityId'] case final num value) {
        state.nextNavalEntityId = value.toInt();
      }
      if (values['nextWarCampaignId'] case final num value) {
        state.nextWarCampaignId = value.toInt();
      }
      if (values['nextPeaceConferenceId'] case final num value) {
        state.nextPeaceConferenceId = value.toInt();
      }
      if (values.containsKey('winner')) {
        final winner = values['winner'];
        state.winner = winner is num ? winner.toInt() : null;
      }
    }

    final rawSections = patch['sections'];
    if (rawSections is Map) {
      final sections = rawSections.cast<String, dynamic>();
      if (sections['provinces'] case final List values) {
        state.provinces = values
            .whereType<Map>()
            .map((raw) => Province.fromJson(raw.cast<String, dynamic>()))
            .toList();
      }
      _replaceModelList<WarCampaign>(
        sections,
        'campaigns',
        state.campaigns,
        (raw) => WarCampaign.fromJson(raw),
      );
      _replaceModelList<PeaceConference>(
        sections,
        'peaceConferences',
        state.peaceConferences,
        (raw) => PeaceConference.fromJson(raw),
      );
      _replaceDiplomacyStatusMatrix(sections, 'diplomacyRelations');
      if (sections['diplomacySocial'] is Map) {
        state.diplomacySocial = DiplomacySocialState.fromJson(
          (sections['diplomacySocial'] as Map).cast<String, dynamic>(),
          state.config.playerCount,
        );
      }
      _replaceIntMatrix(
        sections,
        'diplomacyAllianceTurns',
        state.diplomacyAllianceTurns,
      );
      _replaceIntMatrix(
        sections,
        'diplomacyWarCooldowns',
        state.diplomacyWarCooldowns,
      );
      _replaceBoolMatrix(
        sections,
        'diplomacyBlackMarks',
        state.diplomacyBlackMarks,
      );
      _replaceIntMatrix(
        sections,
        'diplomacyBlackMarkCooldowns',
        state.diplomacyBlackMarkCooldowns,
      );
      _replaceIntMatrix(sections, 'diplomacyDebts', state.diplomacyDebts);
      if (sections['diplomacyTraitorTurns'] case final List values) {
        state.diplomacyTraitorTurns
          ..clear()
          ..addAll(values.whereType<num>().map((value) => value.toInt()));
      }
      _replaceModelList<DiplomacySubsidy>(
        sections,
        'diplomacySubsidies',
        state.diplomacySubsidies,
        (raw) => DiplomacySubsidy.fromJson(raw),
      );
      _replaceModelList<DiplomacyProposal>(
        sections,
        'diplomacyProposals',
        state.diplomacyProposals,
        (raw) => DiplomacyProposal.fromJson(raw),
      );
      _replaceModelList<DiplomacyMessage>(
        sections,
        'diplomacyMessages',
        state.diplomacyMessages,
        (raw) => DiplomacyMessage.fromJson(raw),
      );
      if (sections['diplomacyLog'] case final List values) {
        state.diplomacyLog
          ..clear()
          ..addAll(values.whereType<String>());
      }
    }

    if (localPlayer != null) _visibilityPlayer = localPlayer;
    if (uiState != null) applyNetworkUiState(uiState, notify: false);
    boatBattleAnimation = null;
    seaFortDestructionAnimation = null;
    notifyListeners();
  }

  void _replaceModelList<T>(
    Map<String, dynamic> sections,
    String key,
    List<T> target,
    T Function(Map<String, dynamic>) parse,
  ) {
    final values = sections[key];
    if (values is! List) return;
    target
      ..clear()
      ..addAll(
        values.whereType<Map>().map(
          (raw) => parse(raw.cast<String, dynamic>()),
        ),
      );
  }

  void _replaceDiplomacyStatusMatrix(
    Map<String, dynamic> sections,
    String key,
  ) {
    final values = sections[key];
    if (values is! List) return;
    final parsed = values
        .whereType<List>()
        .map(
          (row) => row
              .map((value) => DiplomacyStatus.values.byName(value.toString()))
              .toList(),
        )
        .toList();
    _validateMatrixSize(parsed.length, parsed.map((row) => row.length));
    state.diplomacyRelations
      ..clear()
      ..addAll(parsed);
  }

  void _replaceIntMatrix(
    Map<String, dynamic> sections,
    String key,
    List<List<int>> target,
  ) {
    final values = sections[key];
    if (values is! List) return;
    final parsed = values
        .whereType<List>()
        .map(
          (row) => row.whereType<num>().map((value) => value.toInt()).toList(),
        )
        .toList();
    _validateMatrixSize(parsed.length, parsed.map((row) => row.length));
    target
      ..clear()
      ..addAll(parsed);
  }

  void _replaceBoolMatrix(
    Map<String, dynamic> sections,
    String key,
    List<List<bool>> target,
  ) {
    final values = sections[key];
    if (values is! List) return;
    final parsed = values
        .whereType<List>()
        .map((row) => row.whereType<bool>().toList())
        .toList();
    _validateMatrixSize(parsed.length, parsed.map((row) => row.length));
    target
      ..clear()
      ..addAll(parsed);
  }

  void _validateMatrixSize(int rows, Iterable<int> columns) {
    final expected = state.config.playerCount;
    if (rows != expected || columns.any((count) => count != expected)) {
      throw const FormatException('LAN дипломатия патчы жарамсыз.');
    }
  }

  void updateNetworkTurnClock({
    required bool enabled,
    required int durationSeconds,
    int? deadlineEpochMs,
  }) {
    networkTurnTimerEnabled = enabled;
    networkTurnDurationSeconds = durationSeconds;
    networkTurnDeadline = enabled && deadlineEpochMs != null
        ? DateTime.fromMillisecondsSinceEpoch(deadlineEpochMs)
        : null;
    _networkTurnTicker?.cancel();
    if (enabled && networkTurnDeadline != null) {
      _networkTurnTicker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!_active) return;
        notifyListeners();
        if (networkTurnRemainingSeconds == 0) {
          _networkTurnTicker?.cancel();
        }
      });
    }
    if (_active) notifyListeners();
  }

  Future<T> runAsNetworkPlayer<T>(
    int player,
    FutureOr<T> Function() action,
  ) async {
    if (player != state.turn || !state.isHuman(player)) {
      throw StateError('Бұл ойыншының жүрісі емес.');
    }
    final previousActor = _networkActor;
    final previousVisibility = _visibilityPlayer;
    _networkActor = player;
    _visibilityPlayer = player;
    try {
      return await action();
    } finally {
      _networkActor = previousActor;
      _visibilityPlayer = previousVisibility;
    }
  }

  bool _forwardNetworkCommand(
    String action, [
    Map<String, dynamic> arguments = const <String, dynamic>{},
  ]) {
    final delegate = networkDelegate;
    if (delegate == null) return false;
    if (!isLocalHumanTurn || interactionsLocked) return true;
    if (delegate.busy) {
      hint = 'Алдыңғы әрекет хостта орындалып жатыр';
      notifyListeners();
      return true;
    }
    if (!delegate.sendCommand(action, arguments, captureNetworkUiState())) {
      hint = 'LAN әрекетін жіберу мүмкін болмады';
      notifyListeners();
    }
    return true;
  }

  Future<bool> _forwardNetworkCommandAsync(
    String action, [
    Map<String, dynamic> arguments = const <String, dynamic>{},
  ]) async {
    final delegate = networkDelegate;
    if (delegate == null) return false;
    if (!isLocalHumanTurn || interactionsLocked) return true;
    if (delegate.busy) {
      hint = 'Алдыңғы әрекет хостта орындалып жатыр';
      notifyListeners();
      return true;
    }
    await delegate.sendCommandAsync(action, arguments, captureNetworkUiState());
    return true;
  }

  bool get fogActive {
    if (!state.config.fogOfWar || state.config.humanCount == 0) return false;
    final viewer = visibilityPlayer;
    return viewState.provinces.any((province) => province.owner == viewer) ||
        viewState.waterCells.any(
          (cell) => cell.boat?.owner == viewer || cell.seaFort?.owner == viewer,
        );
  }

  /// Decorative full-board animation detail follows the camera, not map size.
  /// A [HexBoard] enables this only at its far overview zoom where individual
  /// pieces are too small to read and full-map repaints would waste frames.
  bool get overviewAnimationsSuppressed => _overviewAnimationsSuppressed;

  void setOverviewAnimationsSuppressed(bool value) {
    _overviewAnimationsSuppressed = value;
  }

  Set<int> get visibleTileIndices {
    final state = viewState;
    if (!fogActive) {
      return state.hexes.where((t) => t.active).map((t) => t.index).toSet();
    }
    return landVisionTiles(
      state,
      mod,
      (other) => _viewAreAllies(visibilityPlayer, other),
    );
  }

  Set<int> get visibleWaterCellIndices {
    final state = viewState;
    if (!fogActive) {
      return state.waterCells
          .where((c) => c.navigable)
          .map((c) => c.index)
          .toSet();
    }
    return waterVisionCells(
      state,
      mod,
      (other) => _viewAreAllies(visibilityPlayer, other),
    );
  }

  Set<int> get visiblePlayerIndices {
    final visibleState = viewState;
    if (!fogActive) {
      return {
        for (var player = 0; player < visibleState.config.playerCount; player++)
          player,
      };
    }
    final players = <int>{visibilityPlayer};
    final land = visibleTileIndices;
    for (final tile in visibleState.hexes) {
      if (land.contains(tile.index) && tile.owner >= 0) {
        players.add(tile.owner);
      }
    }
    final water = visibleWaterCellIndices;
    for (final cell in visibleState.waterCells) {
      if (!water.contains(cell.index)) continue;
      final boatOwner = cell.boat?.owner;
      final fortOwner = cell.seaFort?.owner;
      if (boatOwner != null && boatOwner >= 0) players.add(boatOwner);
      if (fortOwner != null && fortOwner >= 0) players.add(fortOwner);
    }
    return players;
  }

  bool isPlayerVisible(int player) => visiblePlayerIndices.contains(player);

  bool _viewAreAllies(int first, int second) {
    if (first == second) return true;
    final visibleState = viewState;
    if (!visibleState.config.diplomacy ||
        first < 0 ||
        second < 0 ||
        first >= visibleState.config.playerCount ||
        second >= visibleState.config.playerCount) {
      return false;
    }
    final direct = visibleState.diplomacyRelations[first][second];
    if (direct == DiplomacyStatus.alliance ||
        direct == DiplomacyStatus.coalition) {
      return true;
    }
    final reached = <int>{first};
    final queue = <int>[first];
    for (var cursor = 0; cursor < queue.length; cursor++) {
      final current = queue[cursor];
      for (var player = 0; player < visibleState.config.playerCount; player++) {
        if (reached.contains(player) ||
            visibleState.diplomacyRelations[current][player] !=
                DiplomacyStatus.coalition) {
          continue;
        }
        if (player == second) return true;
        reached.add(player);
        queue.add(player);
      }
    }
    return false;
  }

  bool isTileVisible(int index) =>
      !fogActive || visibleTileIndices.contains(index);

  /// Diplomacy land offers must never reveal or accept a cell that the active
  /// human cannot currently see through fog of war.
  bool canSelectDiplomacyLandTile({required int giver, required int index}) {
    final visibleState = viewState;
    if (index < 0 || index >= visibleState.hexes.length) return false;
    final tile = visibleState.hexes[index];
    return tile.active &&
        tile.owner == giver &&
        isTileVisible(index) &&
        engine.provinceAt(index) != null;
  }

  bool canSelectDiplomacyNavalAsset({
    required int giver,
    required int waterCell,
    required NavalAssetRef reference,
  }) {
    if (!isWaterCellVisible(waterCell) ||
        waterCell < 0 ||
        waterCell >= viewState.waterCells.length) {
      return false;
    }
    final cell = viewState.waterCells[waterCell];
    return switch (reference.kind) {
      NavalAssetKind.boat =>
        cell.boat?.id == reference.id && cell.boat?.owner == giver,
      NavalAssetKind.seaFort =>
        cell.seaFort?.id == reference.id && cell.seaFort?.owner == giver,
    };
  }

  /// Returns the visible foreign player that should be opened directly in the
  /// diplomacy panel. Active move, cargo and construction selections keep
  /// ownership of the tap so a diplomatic shortcut can never steal a move.
  int? diplomacyPlayerForTile(int index) {
    if (!state.config.diplomacy ||
        !isLocalHumanTurn ||
        state.winner != null ||
        interactionsLocked ||
        tool != PlayerTool.select ||
        selectedTile != null ||
        selectedWaterCell != null ||
        selectedCargoIndex != null) {
      return null;
    }
    final visibleState = viewState;
    if (index < 0 || index >= visibleState.hexes.length) return null;
    final tile = visibleState.hexes[index];
    final owner = tile.owner;
    if (!tile.active ||
        !isTileVisible(index) ||
        owner < 0 ||
        owner == state.turn ||
        owner >= state.config.playerCount) {
      return null;
    }
    final province = engine.provinceAt(index);
    if (province == null || province.owner != owner) return null;
    return owner;
  }

  bool isWaterCellVisible(int index) =>
      !fogActive || visibleWaterCellIndices.contains(index);

  void requestBetterDiplomacy(int other) {
    if (!state.config.diplomacy ||
        !canControlCurrentTurn ||
        interactionsLocked ||
        other == state.turn) {
      return;
    }
    if (_forwardNetworkCommand('requestBetterDiplomacy', {'other': other})) {
      return;
    }
    final current = engine.diplomacyBetween(state.turn, other);
    if (current == DiplomacyStatus.coalition) return;
    final type = switch (current) {
      DiplomacyStatus.war => DiplomacyProposalType.peace,
      DiplomacyStatus.peace => DiplomacyProposalType.friendship,
      DiplomacyStatus.alliance => DiplomacyProposalType.militaryAlliance,
      DiplomacyStatus.coalition => DiplomacyProposalType.militaryAlliance,
    };
    final snapshot = _takeSnapshot();
    final changed = engine.proposeDiplomacy(state.turn, other, type);
    if (changed) _rememberSnapshot(snapshot);
    if (!changed) {
      final cooldown = engine.diplomacyCooldown(state.turn, other);
      hint = cooldown > 0
          ? 'Бітімге әлі $cooldown ход қалды'
          : 'Ұсыныс бұрын жіберілген';
    } else {
      hint = switch (type) {
        DiplomacyProposalType.friendship =>
          '${playerName(other)}: достық ұсынылды',
        DiplomacyProposalType.militaryAlliance =>
          '${playerName(other)}: әскери одақ ұсынылды',
        DiplomacyProposalType.peace => '${playerName(other)}: бітім ұсынылды',
        DiplomacyProposalType.exchange => 'Келісім ұсынылды',
      };
    }
    clearSelection();
  }

  void worsenDiplomacy(int other) {
    if (!state.config.diplomacy ||
        !canControlCurrentTurn ||
        interactionsLocked ||
        other == state.turn) {
      return;
    }
    if (_forwardNetworkCommand('worsenDiplomacy', {'other': other})) return;
    final previous = engine.diplomacyBetween(state.turn, other);
    if (!engine.worsenDiplomacy(state.turn, other)) return;
    hint = switch (previous) {
      DiplomacyStatus.coalition =>
        '${playerName(other)}: әскери одақ тоқтатылды',
      DiplomacyStatus.alliance => '${playerName(other)}: достық тоқтатылды',
      _ => '${playerName(other)}: соғыс жарияланды',
    };
    clearSelection();
  }

  bool resolveDiplomacyProposal(
    DiplomacyProposal proposal, {
    required bool accept,
  }) {
    if (!canControlCurrentTurn ||
        proposal.to != state.turn ||
        interactionsLocked) {
      return false;
    }
    if (_forwardNetworkCommand('resolveDiplomacyProposal', {
      'proposal': proposal.toJson(),
      'accept': accept,
    })) {
      return true;
    }
    final resolved = engine.resolveDiplomacyProposal(proposal, accept: accept);
    hint = resolved
        ? accept
              ? 'Ұсыныс қабылданды'
              : 'Ұсыныс қабылданбады'
        : 'Ұсыныс шарттары енді жарамсыз';
    notifyListeners();
    return resolved;
  }

  bool canSelectPeaceConferenceTile({
    required int conferenceId,
    required int index,
  }) {
    final conference = engine.peaceConferenceById(conferenceId);
    final visibleState = viewState;
    if (conference == null ||
        !conference.participants.contains(state.turn) ||
        index < 0 ||
        index >= visibleState.hexes.length ||
        !isTileVisible(index)) {
      return false;
    }
    final tile = visibleState.hexes[index];
    return tile.active &&
        conference.claimTiles.contains(index) &&
        tile.coalitionClaim?.conferenceId == conferenceId;
  }

  bool submitPeaceConferenceProposal({
    required int conferenceId,
    required Map<int, List<int>> allocations,
  }) {
    if (!canControlCurrentTurn || interactionsLocked) return false;
    if (_forwardNetworkCommand('submitPeaceConferenceProposal', {
      'conferenceId': conferenceId,
      'allocations': allocations.map(
        (owner, tiles) => MapEntry(owner.toString(), tiles),
      ),
    })) {
      return true;
    }
    final snapshot = _takeSnapshot();
    final submitted = engine.submitPeaceConferenceProposal(
      conferenceId,
      state.turn,
      allocations,
    );
    hint = submitted
        ? 'Жер бөлу ұсынысы жіберілді'
        : 'Бұл жер бөлу ұсынысы жарамсыз';
    if (submitted) _rememberSnapshot(snapshot);
    notifyListeners();
    return submitted;
  }

  bool acceptPeaceConference(int conferenceId) {
    if (!canControlCurrentTurn || interactionsLocked) return false;
    if (_forwardNetworkCommand('acceptPeaceConference', {
      'conferenceId': conferenceId,
    })) {
      return true;
    }
    final conference = engine.peaceConferenceById(conferenceId);
    if (conference == null || conference.acceptedBy.contains(state.turn)) {
      return false;
    }
    final snapshot = _takeSnapshot();
    final accepted = engine.acceptPeaceConference(conferenceId, state.turn);
    hint = accepted
        ? engine.peaceConferenceById(conferenceId) == null
              ? 'Соғыстан кейінгі жер бөлісі бекітілді'
              : 'Жер бөлу ұсынысы қабылданды'
        : 'Бұл ұсынысты қазір қабылдауға болмайды';
    if (accepted) _rememberSnapshot(snapshot);
    notifyListeners();
    return accepted;
  }

  bool sendDiplomacyExchange({
    required int other,
    DiplomacyOffer fromOffer = const DiplomacyOffer(),
    DiplomacyOffer toOffer = const DiplomacyOffer(),
    List<DiplomacyTerm>? terms,
  }) {
    if (!canControlCurrentTurn || interactionsLocked) return false;
    if (_forwardNetworkCommand('sendDiplomacyExchange', {
      'other': other,
      'fromOffer': fromOffer.toJson(),
      'toOffer': toOffer.toJson(),
      if (terms != null) 'terms': terms.map((term) => term.toJson()).toList(),
    })) {
      return true;
    }
    final snapshot = _takeSnapshot();
    final sent = engine.proposeExchange(
      from: state.turn,
      to: other,
      fromOffer: fromOffer,
      toOffer: toOffer,
      terms: terms,
    );
    if (sent) {
      _rememberSnapshot(snapshot);
      hint = '${playerName(other)}: келісім жіберілді';
      notifyListeners();
    }
    return sent;
  }

  bool sendDiplomacyMessage({required int other, required String text}) {
    if (!canControlCurrentTurn || interactionsLocked) return false;
    if (_forwardNetworkCommand('sendDiplomacyMessage', {
      'other': other,
      'text': text,
    })) {
      return true;
    }
    final snapshot = _takeSnapshot();
    final sent = engine.sendDiplomacyMessage(
      from: state.turn,
      to: other,
      text: text,
    );
    if (sent) {
      _rememberSnapshot(snapshot);
      hint = '${playerName(other)}: хат жіберілді';
      notifyListeners();
    }
    return sent;
  }

  bool influenceDiplomacyOpinion(int other, {required bool improve}) {
    if (!canControlCurrentTurn || interactionsLocked) return false;
    if (_forwardNetworkCommand('influenceDiplomacyOpinion', {
      'other': other,
      'improve': improve,
    })) {
      return true;
    }
    final snapshot = _takeSnapshot();
    final changed = engine.influenceOpinion(
      state.turn,
      other,
      improve: improve,
    );
    if (changed) {
      _rememberSnapshot(snapshot);
      hint = 'Хат жіберілді';
      notifyListeners();
    }
    return changed;
  }

  bool dismissDiplomacyMessage(DiplomacyMessage message) {
    if (!canControlCurrentTurn ||
        interactionsLocked ||
        message.to != state.turn) {
      return false;
    }
    if (_forwardNetworkCommand('dismissDiplomacyMessage', {
      'message': message.toJson(),
    })) {
      return true;
    }
    final snapshot = _takeSnapshot();
    final dismissed = engine.dismissDiplomacyMessage(message);
    if (dismissed) {
      _rememberSnapshot(snapshot);
      notifyListeners();
    }
    return dismissed;
  }

  bool clearDiplomacyInbox() {
    if (!canControlCurrentTurn || interactionsLocked) return false;
    if (_forwardNetworkCommand('clearDiplomacyInbox')) return true;
    final snapshot = _takeSnapshot();
    final changed = engine.clearDiplomacyInbox(state.turn);
    if (changed) {
      _rememberSnapshot(snapshot);
      hint = 'Кіріс хаттар тазартылды';
      notifyListeners();
    }
    return changed;
  }

  bool toggleBlackMark(int other) {
    if (!canControlCurrentTurn || interactionsLocked) return false;
    if (_forwardNetworkCommand('toggleBlackMark', {'other': other})) {
      return true;
    }
    final snapshot = _takeSnapshot();
    final changed = engine.hasBlackMark(state.turn, other)
        ? engine.removeBlackMark(state.turn, other)
        : engine.placeBlackMark(state.turn, other);
    if (changed) {
      _rememberSnapshot(snapshot);
      hint = engine.hasBlackMark(state.turn, other)
          ? 'Қара белгі қойылды'
          : 'Қара белгі алынды';
      notifyListeners();
    }
    return changed;
  }

  Set<int> get moveTargets =>
      selectedTile == null ? const {} : engine.moveTargets(selectedTile!);

  Set<int> get targetTiles {
    if (selectedModTypeId != null) {
      final province = selectedOwnProvince;
      return province == null
          ? {}
          : engine.modBuildTargets(province.id, selectedModTypeId!);
    }
    if (selectedAirTile != null) {
      return {
        ...engine.airMoveTargets(selectedAirTile!),
        ...engine.airAttackTargets(selectedAirTile!),
      };
    }
    if (tool == PlayerTool.select) {
      if (selectedWaterCell != null) {
        final cargoIndex = selectedCargoIndex;
        return cargoIndex == null
            ? const {}
            : engine.boatDisembarkTargets(selectedWaterCell!, cargoIndex);
      }
      return moveTargets;
    }
    final province = selectedProvince;
    if (province == null || province.owner != state.turn) return const {};
    if (tool.index >= PlayerTool.unit1.index &&
        tool.index <= PlayerTool.unit4.index) {
      final strength = tool.index - PlayerTool.unit1.index + 1;
      return engine.unitBuildTargets(province.id, strength);
    }
    final object = switch (tool) {
      PlayerTool.farm => TileObject.farm,
      PlayerTool.tower => TileObject.tower,
      PlayerTool.strongTower => TileObject.strongTower,
      PlayerTool.port1 => TileObject.port1,
      PlayerTool.port2 => TileObject.port2,
      PlayerTool.artillery => TileObject.artillery1,
      _ => TileObject.none,
    };
    return engine.buildTargets(province.id, object);
  }

  Set<int> get targetWaterCells {
    if (selectedAirTile != null || selectedModTypeId != null) return {};
    if (tool == PlayerTool.boat1 || tool == PlayerTool.boat2) {
      final province = selectedOwnProvince;
      final portTile = selectedTile;
      if (province == null || portTile == null) return const {};
      final level = tool == PlayerTool.boat1 ? 1 : 2;
      return engine.boatBuildTargets(province.id, portTile, level);
    }
    if (tool.index >= PlayerTool.unit1.index &&
        tool.index <= PlayerTool.unit4.index) {
      final province = selectedOwnProvince;
      if (province == null) return const {};
      return engine.unitBoatBuildTargets(
        province.id,
        tool.index - PlayerTool.unit1.index + 1,
      );
    }
    if (tool == PlayerTool.seaFort) {
      return selectedWaterCell == null
          ? const {}
          : engine.seaFortBuildTargets(selectedWaterCell!);
    }
    if (tool != PlayerTool.select) return const {};
    if (selectedWaterCell != null && selectedBoat != null) {
      return engine.boatMoveTargets(selectedWaterCell!);
    }
    if (selectedTile != null) return engine.unitBoardingTargets(selectedTile!);
    return const {};
  }

  Province? get selectedProvince {
    final air = selectedAirUnit;
    if (air != null) {
      return state.provinces
          .where((p) => p.id == air.homeProvinceId && p.owner == air.owner)
          .firstOrNull;
    }
    return selectedTile == null ? null : engine.provinceAt(selectedTile!);
  }

  GameUnit? get selectedAirUnit =>
      selectedAirTile == null || selectedAirTile! >= state.hexes.length
      ? null
      : state.hexes[selectedAirTile!].airUnit;

  void selectModType(String id) {
    if (!isLocalHumanTurn ||
        interactionsLocked ||
        state.winner != null ||
        selectedOwnProvince == null ||
        (!mod.buildings.containsKey(id) && !mod.units.containsKey(id))) {
      return;
    }
    selectedTile = selectedOwnProvince!.capital;
    selectedAirTile = null;
    selectedWaterCell = null;
    selectedCargoIndex = null;
    tool = PlayerTool.select;
    selectedModTypeId = id;
    _cancelSelectionFade();
    hint = 'Орнын таңдаңыз';
    notifyListeners();
  }

  bool isBoardTileVisible(int index) {
    if (index < 0 || index >= state.hexes.length) return false;
    if (!fogActive) return true;
    if (state.hexes[index].active) return isTileVisible(index);
    final visibleWater = visibleWaterCellIndices;
    return state.waterCells.any(
      (cell) => visibleWater.contains(cell.index) && cell.tiles.contains(index),
    );
  }

  /// Return true when the mod layer consumed a board tap; ordinary land and
  /// sea input remains available below an aircraft on the next tap.
  bool tapModTile(int index) {
    if (!canControlCurrentTurn ||
        state.winner != null ||
        interactionsLocked ||
        index < 0 ||
        index >= state.hexes.length ||
        !state.hexes[index].inWorld) {
      return false;
    }
    final tile = state.hexes[index];
    if (selectedModTypeId != null) {
      final province = selectedOwnProvince;
      if (province == null || !isBoardTileVisible(index)) return true;
      if (_forwardNetworkCommand('tapModTile', {'index': index})) return true;
      final snapshot = _takeSnapshot();
      final changed = engine.buildModType(
        province.id,
        index,
        selectedModTypeId!,
      );
      if (changed) {
        selectedModTypeId = null;
        if (tile.airUnit?.owner == state.turn) {
          selectedAirTile = index;
          selectedTile = null;
        }
        hint = 'Дайын';
        _rememberSnapshot(snapshot);
      } else {
        hint = 'Ақша аз немесе орын бос емес';
      }
      notifyListeners();
      return true;
    }
    if (selectedAirTile != null) {
      final from = selectedAirTile!;
      if (from == index) {
        selectedAirTile = null;
        notifyListeners();
        return false;
      }
      final attack =
          isBoardTileVisible(index) &&
          engine.airAttackTargets(from).contains(index);
      final move = engine.airMoveTargets(from).contains(index);
      if (attack || move) {
        if (_forwardNetworkCommand('tapModTile', {'index': index})) return true;
        final snapshot = _takeSnapshot();
        final changed = attack
            ? engine.attackWithAirUnit(from, index)
            : engine.moveAirUnit(from, index);
        if (changed) {
          if (!attack) selectedAirTile = index;
          hint = attack ? 'Шабуыл жасалды' : 'Жүріс жасалды';
          _rememberSnapshot(snapshot);
        }
        notifyListeners();
        return true;
      }
      selectedAirTile = null;
    }
    if (tool == PlayerTool.select &&
        tile.airUnit?.owner == state.turn &&
        isBoardTileVisible(index)) {
      _cancelSelectionFade();
      selectedAirTile = index;
      selectedTile = selectedWaterCell = selectedCargoIndex = null;
      hint = tile.airUnit!.ready
          ? 'Жасыл ұяшықтардың бірін таңдаңыз'
          : 'Осы ходта жүріп болды';
      notifyListeners();
      return true;
    }
    return false;
  }

  Province? get selectedOwnProvince {
    final province = selectedProvince;
    return province?.owner == state.turn ? province : null;
  }

  GameBoat? get selectedBoat {
    final waterCell = selectedWaterCell;
    return waterCell == null ? null : engine.waterCellById(waterCell)?.boat;
  }

  SeaFort? get selectedSeaFort {
    final waterCell = selectedWaterCell;
    return waterCell == null ? null : engine.waterCellById(waterCell)?.seaFort;
  }

  int get selectedPortLevel {
    if (selectedTile == null) return 0;
    if (state.hexes[selectedTile!].owner != state.turn) return 0;
    return switch (state.hexes[selectedTile!].object) {
      TileObject.port1 => 1,
      TileObject.port2 => 2,
      _ => 0,
    };
  }

  int get selectedArtilleryLevel {
    final tileIndex = selectedTile;
    if (tileIndex == null || state.hexes[tileIndex].owner != state.turn) {
      return 0;
    }
    return engine.artilleryLevelAt(tileIndex);
  }

  int get selectedArtilleryAmmo {
    final tileIndex = selectedTile;
    return selectedArtilleryLevel == 0 || tileIndex == null
        ? 0
        : state.hexes[tileIndex].artilleryAmmo;
  }

  int get selectedArtilleryAmmoCapacity {
    final tileIndex = selectedTile;
    return tileIndex == null ? 0 : engine.artilleryAmmoCapacityAt(tileIndex);
  }

  void upgradeSelectedPort() {
    final tileIndex = selectedTile;
    if (tileIndex == null || selectedPortLevel == 0) return;
    if (_forwardNetworkCommand('upgradeSelectedPort')) return;
    final snapshot = _takeSnapshot();
    final upgraded = engine.upgradePort(tileIndex);
    tool = PlayerTool.select;
    hint = upgraded
        ? 'Порт 2-деңгейге дамытылды'
        : selectedPortLevel >= 2
        ? 'Порт ең жоғарғы деңгейде'
        : 'Портты дамытуға ақша жетпейді';
    if (upgraded) {
      _rememberSnapshot(snapshot);
    }
    notifyListeners();
  }

  void upgradeSelectedArtillery() {
    final tileIndex = selectedTile;
    final level = selectedArtilleryLevel;
    if (tileIndex == null || level == 0) return;
    if (_forwardNetworkCommand('upgradeSelectedArtillery')) return;
    final snapshot = _takeSnapshot();
    final upgraded = engine.upgradeArtillery(tileIndex);
    tool = PlayerTool.select;
    hint = upgraded
        ? 'Артиллерия ${level + 1}-деңгейге дамытылды'
        : level >= 3
        ? 'Артиллерия ең жоғарғы деңгейде'
        : 'Артиллерияны дамытуға ақша жетпейді';
    if (upgraded) {
      _rememberSnapshot(snapshot);
    }
    notifyListeners();
  }

  void setTool(PlayerTool value) {
    if (!isLocalHumanTurn || state.winner != null || interactionsLocked) {
      return;
    }
    _cancelSelectionFade();
    selectedModTypeId = null;
    selectedAirTile = null;
    if (value == PlayerTool.port2) {
      tool = PlayerTool.select;
      hint = '2-деңгейлі порт тек порттың өз панелінен дамытылады';
      notifyListeners();
      return;
    }
    final boatTool = value == PlayerTool.boat1 || value == PlayerTool.boat2;
    final seaFortTool = value == PlayerTool.seaFort;
    if (boatTool &&
        (selectedProvince?.owner != state.turn ||
            selectedPortLevel < (value == PlayerTool.boat1 ? 1 : 2))) {
      tool = PlayerTool.select;
      hint = 'Алдымен өз портыңызды таңдаңыз';
      notifyListeners();
      return;
    }
    if (seaFortTool &&
        (selectedBoat == null || selectedBoat!.owner != state.turn)) {
      tool = PlayerTool.select;
      hint = 'Алдымен жүрісі бар өз кемеңізді таңдаңыз';
      notifyListeners();
      return;
    }
    if (!boatTool &&
        !seaFortTool &&
        value != PlayerTool.select &&
        selectedProvince?.owner != state.turn) {
      tool = PlayerTool.select;
      hint = 'Алдымен өз аймағыңызды таңдаңыз';
      notifyListeners();
      return;
    }
    tool = value;
    selectedCargoIndex = null;
    hint = switch (value) {
      PlayerTool.select => 'Әскерді таңдаңыз',
      PlayerTool.unit1 =>
        '${mod.rules.unitPricePerLevel} теңге: сарбаз қоятын жерді таңдаңыз',
      PlayerTool.unit2 =>
        '${mod.rules.unitPricePerLevel * 2} теңге: найзагер қоятын жерді таңдаңыз',
      PlayerTool.unit3 =>
        '${mod.rules.unitPricePerLevel * 3} теңге: рыцарь қоятын жерді таңдаңыз',
      PlayerTool.unit4 =>
        '${mod.rules.unitPricePerLevel * 4} теңге: батыр қоятын жерді таңдаңыз',
      PlayerTool.farm => 'Шаруашылық орнын таңдаңыз',
      PlayerTool.tower => 'Мұнара орнын таңдаңыз',
      PlayerTool.strongTower => 'Қамал орнын таңдаңыз',
      PlayerTool.port1 => 'Жағалаудан 1-деңгейлі порт орнын таңдаңыз',
      PlayerTool.port2 => 'Жаңартылатын портты таңдаңыз',
      PlayerTool.boat1 => 'Жаға маңынан шағын қайық орнын таңдаңыз',
      PlayerTool.boat2 => 'Жаға маңынан үлкен қайық орнын таңдаңыз',
      PlayerTool.artillery => 'Жағалаудан артиллерия орнын таңдаңыз',
      PlayerTool.seaFort => 'Кеме жанынан теңіз бекінісінің орнын таңдаңыз',
    };
    notifyListeners();
  }

  void clearSelection() {
    _cancelSelectionFade();
    selectedModTypeId = null;
    selectedAirTile = null;
    selectedTile = null;
    selectedWaterCell = null;
    selectedCargoIndex = null;
    tool = PlayerTool.select;
    hint = '';
    notifyListeners();
  }

  void explainSeaFortBuildBlock() {
    final waterCell = selectedWaterCell;
    final block = waterCell == null
        ? SeaFortBuildBlock.noBoat
        : engine.seaFortBuildBlock(waterCell);
    hint = switch (block) {
      null => 'Кеме жанынан теңіз бекінісінің орнын таңдаңыз',
      SeaFortBuildBlock.noBoat => 'Алдымен өз кемеңізді таңдаңыз',
      SeaFortBuildBlock.enemyBoat =>
        'Теңіз бекінісін тек өз кемеңіз сала алады',
      SeaFortBuildBlock.levelTwoRequired =>
        'Теңіз бекінісін тек 2-деңгейлі кеме салады',
      SeaFortBuildBlock.boatAlreadyActed =>
        'Бұл кеме осы жүрісте әрекет жасап қойды',
      SeaFortBuildBlock.missingHomeProvince =>
        'Кеменің негізгі провинциясы табылмады',
      SeaFortBuildBlock.insufficientFunds =>
        'Теңіз бекінісіне ${mod.rules.seaFortPrice} теңге керек',
      SeaFortBuildBlock.noOpenNeighbor =>
        'Кеме жанында бос жүзуге болатын су ұяшығы жоқ',
    };
    notifyListeners();
  }

  void longPressTile(int index) {
    if (!canControlCurrentTurn || state.winner != null || interactionsLocked) {
      return;
    }
    final tile = state.hexes[index];
    if (!tile.active || !isTileVisible(index)) return;
    if (tool != PlayerTool.select) {
      _cancelSelectionFade();
      tool = PlayerTool.select;
      hint = 'Әрекет отмена жасалды';
      notifyListeners();
      return;
    }
    final province = engine.provinceAt(index);
    if (province == null || province.owner != state.turn) return;
    if (engine.artilleryLevelAt(index) > 0) {
      _startArtilleryRangePreview(index);
      hint = 'Артиллерияның қорғаныс және теңіздегі ату аумағы көрсетілді';
      notifyListeners();
      return;
    }
    if (_isDefensiveObject(tile.object)) {
      _startDefensePreview(index);
      hint = 'Қорғалған аймақтар көрсетілді';
      notifyListeners();
      return;
    }

    if (_forwardNetworkCommand('longPressTile', {'index': index})) return;

    final snapshot = _takeSnapshot();
    final moved = engine.massMarch(province.id, index);
    _cancelSelectionFade();
    selectedTile = index;
    selectedWaterCell = null;
    hint = moved == 0
        ? 'Бұл провинцияда жүретін әскер жоқ'
        : '$moved әскер осы жерге бағытталды';
    notifyListeners();
    if (moved > 0) {
      _rememberSnapshot(snapshot);
    }
  }

  void tapTile(int index) {
    if (index < 0 || index >= state.hexes.length) return;
    if (!canControlCurrentTurn || state.winner != null || interactionsLocked) {
      return;
    }
    final tile = state.hexes[index];
    if (!tile.active || !isTileVisible(index)) return;
    selectedModTypeId = null;
    selectedAirTile = null;
    final mutatesState =
        tool != PlayerTool.select ||
        (selectedWaterCell != null && targetTiles.contains(index)) ||
        (selectedTile != null && moveTargets.contains(index));
    if (mutatesState && _forwardNetworkCommand('tapTile', {'index': index})) {
      return;
    }
    final snapshot = mutatesState ? _takeSnapshot() : null;
    var changed = false;
    if (tool == PlayerTool.select) {
      if (selectedWaterCell != null && targetTiles.contains(index)) {
        final waterCell = selectedWaterCell!;
        final cargoIndex = selectedCargoIndex!;
        changed = engine.disembarkUnit(waterCell, cargoIndex, index);
        if (changed) {
          selectedCargoIndex = null;
          final boat = engine.waterCellById(waterCell)?.boat;
          if (boat != null && boat.cargo.isNotEmpty) {
            selectedTile = null;
            selectedWaterCell = waterCell;
            hint = 'Келесі түсірілетін әскерді таңдаңыз';
          } else {
            _settleOnProvinceAt(index);
            hint = 'Әскер жағаға түсті';
          }
        }
      } else {
        final tappedSelectedTile = selectedTile == index;
        if (tappedSelectedTile) {
          _cancelSelectionFade();
          selectedTile = null;
          selectedWaterCell = null;
          selectedCargoIndex = null;
          hint = 'Таңдау алынды';
        } else if (selectedTile != null && moveTargets.contains(index)) {
          _cancelSelectionFade();
          changed = engine.moveUnit(selectedTile!, index);
          if (changed) _settleOnProvinceAt(index);
          hint = changed ? 'Жүріс жасалды' : 'Бұл жүріс мүмкін емес';
        } else {
          _cancelSelectionFade();
          selectedTile = index;
          selectedWaterCell = null;
          selectedCargoIndex = null;
          hint =
              tile.unit?.ready == true &&
                  engine.unitOwnerAt(index) == state.turn
              ? 'Жасыл ұяшықтардың бірін таңдаңыз'
              : 'Аймақ таңдалды';
          if (tile.owner != state.turn &&
              engine.unitOwnerAt(index) != state.turn) {
            _startForeignSelectionFade(index);
          }
        }
      }
    } else {
      final isUnitTool =
          tool.index >= PlayerTool.unit1.index &&
          tool.index <= PlayerTool.unit4.index;
      final province = selectedProvince;
      if (province == null || province.owner != state.turn) {
        hint = 'Өз аймағыңызды таңдаңыз';
      } else if (isUnitTool) {
        final strength = tool.index - PlayerTool.unit1.index + 1;
        final wasAttack = tile.owner != state.turn;
        changed = engine.buyUnit(province.id, index, strength);
        hint = changed
            ? wasAttack
                  ? 'Шекара бірден алынды'
                  : 'Әскер қойылды'
            : 'Бұл ұяшыққа әскер қою мүмкін емес';
      } else {
        final object = switch (tool) {
          PlayerTool.farm => TileObject.farm,
          PlayerTool.tower => TileObject.tower,
          PlayerTool.strongTower => TileObject.strongTower,
          PlayerTool.port1 => TileObject.port1,
          PlayerTool.port2 => TileObject.port2,
          PlayerTool.artillery => TileObject.artillery1,
          _ => TileObject.none,
        };
        changed = engine.build(province.id, index, object);
        hint = changed ? 'Құрылыс салынды' : 'Ақша аз немесе орын бос емес';
      }
      _cancelSelectionFade();
      if (changed) _settleOnProvinceAt(index);
      tool = PlayerTool.select;
    }
    notifyListeners();
    if (changed && snapshot != null) {
      _rememberSnapshot(snapshot);
    }
  }

  void tapWaterCell(int index) {
    if (!canControlCurrentTurn || state.winner != null || interactionsLocked) {
      return;
    }
    final cell = engine.waterCellById(index);
    if (cell == null || !isWaterCellVisible(index)) return;
    selectedModTypeId = null;
    selectedAirTile = null;
    final mutatesState =
        tool != PlayerTool.select ||
        (selectedTile != null && targetWaterCells.contains(index)) ||
        (selectedWaterCell != null &&
            selectedBoat != null &&
            targetWaterCells.contains(index));
    if (mutatesState &&
        _forwardNetworkCommand('tapWaterCell', {'index': index})) {
      return;
    }
    final snapshot = mutatesState ? _takeSnapshot() : null;
    var changed = false;
    if (tool == PlayerTool.boat1 || tool == PlayerTool.boat2) {
      final province = selectedOwnProvince;
      final portTile = selectedTile;
      if (province != null && portTile != null) {
        final level = tool == PlayerTool.boat1 ? 1 : 2;
        final clearedSeaMint = cell.seaMint;
        changed = engine.buildBoat(province.id, portTile, index, level);
        if (changed) {
          _cancelSelectionFade();
          selectedWaterCell = null;
          selectedTile = portTile;
          hint = clearedSeaMint
              ? 'Қайық жалбызды тазартты: +\$7, осы ходтағы жүрісі бітті'
              : 'Қайық суға шығарылды';
        }
      }
      tool = PlayerTool.select;
      if (!changed) hint = 'Бұл жерге қайық шығаруға болмайды';
    } else if (tool == PlayerTool.seaFort) {
      final fromWaterCell = selectedWaterCell;
      if (fromWaterCell != null) {
        changed = engine.buildSeaFort(fromWaterCell, index);
      }
      tool = PlayerTool.select;
      if (changed) {
        selectedTile = null;
        selectedWaterCell = null;
        hint = 'Теңіз бекінісі салынды';
      } else {
        hint = 'Бекіністі тек өз кемеңіздің қасына салуға болады';
      }
    } else if (tool.index >= PlayerTool.unit1.index &&
        tool.index <= PlayerTool.unit4.index) {
      final province = selectedOwnProvince;
      if (province != null) {
        changed = engine.buyUnitIntoBoat(
          province.id,
          index,
          tool.index - PlayerTool.unit1.index + 1,
        );
      }
      tool = PlayerTool.select;
      hint = changed
          ? 'Әскер кемеге отырды, осы ходтағы жүрісі бітті'
          : 'Бұл кемеде орын жоқ немесе ақша жетпейді';
    } else if (tool != PlayerTool.select) {
      _cancelSelectionFade();
      tool = PlayerTool.select;
      hint = 'Бұл жерде құрылыс жасауға болмайды';
    } else if (tool == PlayerTool.select) {
      if (selectedTile != null && targetWaterCells.contains(index)) {
        changed = engine.boardUnit(selectedTile!, index);
        if (changed) {
          _cancelSelectionFade();
          selectedTile = null;
          selectedWaterCell = null;
          selectedCargoIndex = null;
          hint = 'Әскер қайыққа отырды';
        }
      } else if (selectedWaterCell != null &&
          selectedBoat != null &&
          targetWaterCells.contains(index)) {
        final fromWaterCell = selectedWaterCell!;
        final attacker = engine.waterCellById(fromWaterCell)!.boat!;
        final defender = cell.boat;
        final defenderFort = cell.seaFort;
        final attackerPower = engine.boatCombatPower(attacker);
        final defenderPower = defender == null
            ? 0
            : engine.boatCombatPower(defender);
        final attackerOwner = attacker.owner;
        final attackerLevel = attacker.level;
        final defenderOwner = defender?.owner;
        final defenderLevel = defender?.level;
        final clearedSeaMint = cell.seaMint;
        changed = engine.moveBoat(fromWaterCell, index);
        if (changed) {
          if (defenderOwner != null && defenderLevel != null) {
            boatBattleAnimation = BoatBattleAnimation(
              serial: ++_battleSerial,
              fromWaterCell: fromWaterCell,
              toWaterCell: index,
              attackerOwner: attackerOwner,
              attackerLevel: attackerLevel,
              defenderOwner: defenderOwner,
              defenderLevel: defenderLevel,
              bothSunk: attackerPower == defenderPower,
            );
          } else if (defenderFort != null) {
            seaFortDestructionAnimation = SeaFortDestructionAnimation(
              serial: ++_seaDestructionSerial,
              fromWaterCell: fromWaterCell,
              toWaterCell: index,
              attackerOwner: attackerOwner,
              attackerLevel: attackerLevel,
              fortOwner: defenderFort.owner,
            );
          }
          selectedWaterCell = null;
          selectedCargoIndex = null;
          hint = clearedSeaMint
              ? 'Судағы жалбыз тазартылды: +\$7'
              : cell.boat == null
              ? 'Теңіз шайқасы аяқталды'
              : 'Қайық жүзді';
        }
      } else if (cell.seaFort != null) {
        if (selectedWaterCell == index) {
          selectedWaterCell = null;
          hint = 'Теңіз бекінісі таңдаудан алынды';
        } else {
          selectedWaterCell = index;
          selectedTile = null;
          selectedCargoIndex = null;
          hint = cell.seaFort!.owner == state.turn
              ? 'Қорғанысын көру үшін бекіністі басып тұрыңыз'
              : 'Жау теңіз бекінісі';
        }
      } else if (cell.boat?.owner == state.turn) {
        if (selectedWaterCell == index) {
          selectedWaterCell = null;
          selectedCargoIndex = null;
          hint = 'Қайық таңдаудан алынды';
        } else {
          selectedWaterCell = index;
          selectedTile = null;
          selectedCargoIndex = null;
          hint = cell.boat!.cargo.isEmpty
              ? 'Қайық таңдалды'
              : 'Түсіретін әскерді төменнен таңдаңыз';
        }
      } else if (cell.boat == null && cell.seaFort == null) {
        if (selectedWaterCell == index) {
          selectedWaterCell = null;
          hint = 'Теңіз аумағы таңдаудан алынды';
        } else {
          selectedTile = null;
          selectedWaterCell = index;
          selectedCargoIndex = null;
          hint = 'Теңіз аумағы таңдалды; кемелерді шақыру үшін басып тұрыңыз';
        }
      }
    }
    notifyListeners();
    if (changed && snapshot != null) {
      _rememberSnapshot(snapshot);
    }
  }

  void selectBoatCargo(int index) {
    final boat = selectedBoat;
    if (boat == null ||
        boat.owner != state.turn ||
        index < 0 ||
        index >= boat.cargo.length) {
      return;
    }
    if (!boat.cargo[index].ready) {
      selectedCargoIndex = null;
      hint = 'Бұл әскер осы ходта мінді, келесі ходта түседі';
      notifyListeners();
      return;
    }
    selectedCargoIndex = selectedCargoIndex == index ? null : index;
    hint = selectedCargoIndex == null
        ? 'Әскер таңдаудан алынды'
        : 'Жасыл жағалаудан түсетін жерді таңдаңыз';
    notifyListeners();
  }

  void longPressWaterCell(int index) {
    if (!canControlCurrentTurn || state.winner != null || interactionsLocked) {
      return;
    }
    if (!isWaterCellVisible(index)) return;
    final fort = engine.waterCellById(index)?.seaFort;
    if (tool != PlayerTool.select) return;
    if (fort?.owner == state.turn) {
      _startSeaDefensePreview(index);
      hint = 'Теңіз бекіністерінің қорғайтын аймағы көрсетілді';
      notifyListeners();
      return;
    }
    if (_forwardNetworkCommand('longPressWaterCell', {'index': index})) {
      return;
    }
    final snapshot = _takeSnapshot();
    final moved = engine.massSail(index);
    selectedTile = null;
    selectedWaterCell = index;
    selectedCargoIndex = null;
    hint = moved == 0
        ? 'Бұл жүрісте бағытталатын кеме жоқ'
        : '$moved кеме осы теңіз аумағына бағытталды';
    notifyListeners();
    if (moved > 0) {
      _rememberSnapshot(snapshot);
    }
  }

  void endLongPress() {
    if (defensePreviewTiles.isEmpty && defensePreviewWaterCells.isEmpty) {
      return;
    }
    _fadeDefensePreview();
  }

  void _restoreState(GameState restored) {
    state
      ..width = restored.width
      ..height = restored.height
      ..turn = restored.turn
      ..round = restored.round
      ..rngState = restored.rngState
      ..nextProvinceId = restored.nextProvinceId
      ..nextNavalEntityId = restored.nextNavalEntityId
      ..nextWarCampaignId = restored.nextWarCampaignId
      ..nextPeaceConferenceId = restored.nextPeaceConferenceId
      ..winner = restored.winner;
    state.hexes
      ..clear()
      ..addAll(restored.hexes);
    state.waterCells
      ..clear()
      ..addAll(restored.waterCells);
    state.provinces = restored.provinces;
    state.diplomacySocial = restored.diplomacySocial;
    state.campaigns
      ..clear()
      ..addAll(restored.campaigns);
    state.peaceConferences
      ..clear()
      ..addAll(restored.peaceConferences);
    state.diplomacyRelations
      ..clear()
      ..addAll(
        restored.diplomacyRelations.map(
          (row) => List<DiplomacyStatus>.from(row),
        ),
      );
    state.diplomacyAllianceTurns
      ..clear()
      ..addAll(
        restored.diplomacyAllianceTurns.map((row) => List<int>.from(row)),
      );
    state.diplomacyWarCooldowns
      ..clear()
      ..addAll(
        restored.diplomacyWarCooldowns.map((row) => List<int>.from(row)),
      );
    state.diplomacyBlackMarks
      ..clear()
      ..addAll(restored.diplomacyBlackMarks.map((row) => List<bool>.from(row)));
    state.diplomacyBlackMarkCooldowns
      ..clear()
      ..addAll(
        restored.diplomacyBlackMarkCooldowns.map((row) => List<int>.from(row)),
      );
    state.diplomacyDebts
      ..clear()
      ..addAll(restored.diplomacyDebts.map((row) => List<int>.from(row)));
    state.diplomacyTraitorTurns
      ..clear()
      ..addAll(restored.diplomacyTraitorTurns);
    state.diplomacySubsidies
      ..clear()
      ..addAll(restored.diplomacySubsidies);
    state.diplomacyProposals
      ..clear()
      ..addAll(restored.diplomacyProposals);
    state.diplomacyMessages
      ..clear()
      ..addAll(restored.diplomacyMessages);
    state.diplomacyLog
      ..clear()
      ..addAll(restored.diplomacyLog);
  }

  void undo() {
    if (!canControlCurrentTurn || interactionsLocked || !canUndo) {
      return;
    }
    if (_forwardNetworkCommand('undo')) return;
    final snapshot =
        jsonDecode(_undoHistory.removeLast()) as Map<String, dynamic>;
    final restored = GameState.fromJson(
      snapshot['state'] as Map<String, dynamic>,
    );
    state.hexes
      ..clear()
      ..addAll(restored.hexes);
    state.waterCells
      ..clear()
      ..addAll(restored.waterCells);
    state.provinces = restored.provinces;
    state.diplomacySocial = restored.diplomacySocial;
    state.turn = restored.turn;
    state.round = restored.round;
    state.rngState = restored.rngState;
    state.nextProvinceId = restored.nextProvinceId;
    state.nextNavalEntityId = restored.nextNavalEntityId;
    state.nextWarCampaignId = restored.nextWarCampaignId;
    state.nextPeaceConferenceId = restored.nextPeaceConferenceId;
    state.winner = restored.winner;
    state.campaigns
      ..clear()
      ..addAll(restored.campaigns);
    state.peaceConferences
      ..clear()
      ..addAll(restored.peaceConferences);
    state.diplomacyRelations
      ..clear()
      ..addAll(
        restored.diplomacyRelations.map(
          (row) => List<DiplomacyStatus>.from(row),
        ),
      );
    state.diplomacyAllianceTurns
      ..clear()
      ..addAll(
        restored.diplomacyAllianceTurns.map((row) => List<int>.from(row)),
      );
    state.diplomacyWarCooldowns
      ..clear()
      ..addAll(
        restored.diplomacyWarCooldowns.map((row) => List<int>.from(row)),
      );
    state.diplomacyBlackMarks
      ..clear()
      ..addAll(restored.diplomacyBlackMarks.map((row) => List<bool>.from(row)));
    state.diplomacyBlackMarkCooldowns
      ..clear()
      ..addAll(
        restored.diplomacyBlackMarkCooldowns.map((row) => List<int>.from(row)),
      );
    state.diplomacyDebts
      ..clear()
      ..addAll(restored.diplomacyDebts.map((row) => List<int>.from(row)));
    state.diplomacyTraitorTurns
      ..clear()
      ..addAll(restored.diplomacyTraitorTurns);
    state.diplomacySubsidies
      ..clear()
      ..addAll(restored.diplomacySubsidies);
    state.diplomacyProposals
      ..clear()
      ..addAll(restored.diplomacyProposals);
    state.diplomacyMessages
      ..clear()
      ..addAll(restored.diplomacyMessages);
    state.diplomacyLog
      ..clear()
      ..addAll(restored.diplomacyLog);
    selectedTile = snapshot['selectedTile'] as int?;
    selectedWaterCell = snapshot['selectedWaterCell'] as int?;
    selectedCargoIndex = snapshot['selectedCargoIndex'] as int?;
    selectedAirTile = snapshot['selectedAirTile'] as int?;
    selectedModTypeId = null;
    boatBattleAnimation = null;
    seaFortDestructionAnimation = null;
    _cancelSelectionFade();
    tool = PlayerTool.select;
    hint = 'Соңғы әрекет қайтарылды';
    notifyListeners();
  }

  String _takeSnapshot() => jsonEncode({
    'state': state.toJson(),
    'selectedTile': selectedTile,
    'selectedWaterCell': selectedWaterCell,
    'selectedCargoIndex': selectedCargoIndex,
    if (selectedAirTile != null) 'selectedAirTile': selectedAirTile,
  });

  void _rememberSnapshot(String snapshot) {
    _undoHistory.add(snapshot);
    if (_undoHistory.length > 30) _undoHistory.removeAt(0);
  }

  bool neutralizeDepartedLanPlayer(int player) {
    if (!isLanHost) return false;
    final changed = engine.neutralizeDepartedPlayer(player);
    if (!changed) return false;
    if (selectedTile != null && state.hexes[selectedTile!].owner < 0) {
      selectedTile = null;
    }
    if (selectedWaterCell != null) {
      final cell = state.waterCells[selectedWaterCell!];
      if ((cell.boat?.owner ?? cell.seaFort?.owner ?? -1) < 0) {
        selectedWaterCell = null;
        selectedCargoIndex = null;
      }
    }
    _undoHistory.clear();
    hint = '${playerName(player)} шықты: жері бейтарап болды';
    notifyListeners();
    return true;
  }

  Future<void> finishTurn() async {
    if (!canControlCurrentTurn || state.winner != null || interactionsLocked) {
      return;
    }
    if (await _forwardNetworkCommandAsync('finishTurn')) return;
    turnTransitionActive = true;
    try {
      _visibilityPlayer = state.turn;
      engine.endTurn();
      turnCompleted.notifyListeners();
      final visibleStrikes = _humanRelevantArtilleryStrikes(
        engine.lastArtilleryStrikes,
      );
      _cancelSelectionFade();
      _undoHistory.clear();
      selectedTile = null;
      selectedModTypeId = null;
      selectedAirTile = null;
      selectedWaterCell = null;
      selectedCargoIndex = null;
      tool = PlayerTool.select;
      artilleryCinematicActive = visibleStrikes.isNotEmpty;
      hint = visibleStrikes.isEmpty
          ? 'Келесі ойыншының жүрісі'
          : 'Жағалау артиллериясы оқ атып жатыр';
      notifyListeners();
      if (visibleStrikes.isNotEmpty) {
        await _playArtilleryFireAnimation(visibleStrikes);
        artilleryCinematicActive = false;
        if (_active) notifyListeners();
      }
      await runAiTurns();
      if (localPlayer == null && state.currentPlayerIsHuman) {
        _visibilityPlayer = state.turn;
      }
      if (autosaveEnabled) await saves.save(state);
    } finally {
      turnTransitionActive = false;
      if (_active) notifyListeners();
    }
  }

  Future<void> runAiTurns() async {
    if (!authoritativeSimulation ||
        aiThinking ||
        state.currentPlayerIsHuman ||
        state.winner != null) {
      return;
    }
    final concealTurns = state.config.fogOfWar && state.config.humanCount > 0;
    if (concealTurns) {
      _concealedState = GameState.fromJson(
        (jsonDecode(jsonEncode(state.toJson())) as Map).cast<String, dynamic>(),
      );
    }
    aiThinking = true;
    final fastAiBatch =
        state.config.playerCount >= 8 || state.hexes.length > 2000;
    final progressSteps = fastAiBatch ? 2 : 10;
    final minimumVisibleTurn = fastAiBatch
        ? Duration.zero
        : const Duration(milliseconds: 90);
    aiPlayer = concealTurns ? null : state.turn;
    aiProgress = 0;
    hint = concealTurns ? 'Қарсыластар жүріп жатыр' : hint;
    if (_active) notifyListeners();
    var firstAiInBatch = true;
    while (_active && !state.currentPlayerIsHuman && state.winner == null) {
      final player = state.turn;
      aiPlayer = concealTurns ? null : player;
      aiProgress = 0;
      if (!concealTurns) {
        hint = 'AI ${playerName(player)} жүріп жатыр';
        if (_active) notifyListeners();
      }
      final visibleFor = Stopwatch()..start();
      var lastProgressBucket = -1;
      await GameAi(mod: mod, engine: engine).takeTurnAsync(
        yieldBeforeWork: !fastAiBatch || firstAiInBatch,
        onProgress: (progress) {
          if (!_active) return;
          if (concealTurns) return;
          final bucket = (progress * progressSteps).floor();
          if (bucket == lastProgressBucket) return;
          lastProgressBucket = bucket;
          aiProgress = progress;
          notifyListeners();
        },
      );
      if (_active) turnCompleted.notifyListeners();
      firstAiInBatch = false;
      if (state.config.humanCount == 0 &&
          autosaveEnabled &&
          (state.turn <= player || state.winner != null)) {
        await saves.save(state);
      }
      final visibleStrikes = concealTurns
          ? const <ArtilleryStrike>[]
          : _humanRelevantArtilleryStrikes(engine.lastArtilleryStrikes);
      if (visibleStrikes.isNotEmpty) {
        artilleryCinematicActive = true;
        hint = 'Жағалау артиллериясы оқ атып жатыр';
        if (_active) notifyListeners();
        await _playArtilleryFireAnimation(visibleStrikes);
        artilleryCinematicActive = false;
      }
      if (!concealTurns) {
        final remaining = minimumVisibleTurn - visibleFor.elapsed;
        if (remaining > Duration.zero) await Future<void>.delayed(remaining);
        if (_active) notifyListeners();
      }
    }
    _undoHistory.clear();
    _concealedState = null;
    if (localPlayer == null && state.currentPlayerIsHuman) {
      _visibilityPlayer = state.turn;
    }
    aiThinking = false;
    aiPlayer = null;
    aiProgress = 0;
    hint = state.winner == null ? 'Сіздің жүрісіңіз' : 'Ойын аяқталды';
    if (_active) notifyListeners();
  }

  @override
  void dispose() {
    _active = false;
    turnCompleted.dispose();
    _selectionFadeTimer?.cancel();
    _defensePreviewTimer?.cancel();
    _artilleryFireTimer?.cancel();
    _networkTurnTicker?.cancel();
    if (!(_artilleryAnimationCompleter?.isCompleted ?? true)) {
      _artilleryAnimationCompleter!.complete();
    }
    super.dispose();
  }

  void _settleOnProvinceAt(int tileIndex) {
    final province = engine.provinceAt(tileIndex);
    selectedTile = province?.capital;
    selectedWaterCell = null;
    selectedCargoIndex = null;
    selectionOpacity = 1;
  }

  void _startDefensePreview(int tileIndex) {
    _defensePreviewTimer?.cancel();
    final tile = state.hexes[tileIndex];
    final province = engine.provinceAt(tileIndex);
    if (province == null ||
        province.owner != state.turn ||
        !_isDefensiveObject(tile.object)) {
      return;
    }
    defensePreviewTiles = _provinceDefenseTiles(province, tile.owner);
    defensePreviewWaterCells = const {};
    artilleryRangePreview = false;
    _animateDefensePreviewIn();
  }

  bool _isDefensiveObject(TileObject object) => switch (object) {
    TileObject.town ||
    TileObject.tower ||
    TileObject.strongTower ||
    TileObject.port1 ||
    TileObject.port2 ||
    TileObject.artillery1 ||
    TileObject.artillery2 ||
    TileObject.artillery3 => true,
    _ => false,
  };

  Set<int> _provinceDefenseTiles(Province province, int owner) {
    final result = <int>{};
    for (final defenseTileIndex in province.tiles) {
      final defenseTile = state.hexes[defenseTileIndex];
      if (!_isDefensiveObject(defenseTile.object)) continue;
      result.add(defenseTileIndex);
      result.addAll(
        defenseTile.neighbors.where(
          (neighbor) =>
              state.hexes[neighbor].active &&
              state.hexes[neighbor].owner == owner,
        ),
      );
    }
    return result;
  }

  void _startSeaDefensePreview(int waterCellIndex) {
    _defensePreviewTimer?.cancel();
    final fort = engine.waterCellById(waterCellIndex)?.seaFort;
    if (fort?.owner != state.turn) return;
    defensePreviewTiles = const {};
    defensePreviewWaterCells = engine.seaFortNetworkProtectedCells(
      waterCellIndex,
    );
    artilleryRangePreview = false;
    _animateDefensePreviewIn();
  }

  void _startArtilleryRangePreview(int tileIndex) {
    _defensePreviewTimer?.cancel();
    final tile = state.hexes[tileIndex];
    if (tile.owner != state.turn || engine.artilleryLevelAt(tileIndex) <= 0) {
      return;
    }
    final province = engine.provinceAt(tileIndex);
    defensePreviewTiles = province == null
        ? const {}
        : _provinceDefenseTiles(province, tile.owner);
    defensePreviewWaterCells = engine.artilleryTargetWaterCells(tileIndex);
    artilleryRangePreview = true;
    _animateDefensePreviewIn();
  }

  void _animateDefensePreviewIn() {
    _defensePreviewTimer?.cancel();
    if (overviewAnimationsSuppressed) {
      defensePreviewOpacity = 1;
      notifyListeners();
      return;
    }
    defensePreviewOpacity = 0;
    var step = 0;
    _defensePreviewTimer = Timer.periodic(const Duration(milliseconds: 38), (
      timer,
    ) {
      if (!_active) {
        timer.cancel();
        return;
      }
      step++;
      final progress = (step / 8).clamp(0.0, 1.0);
      defensePreviewOpacity = progress * (2 - progress);
      if (step >= 8) {
        defensePreviewOpacity = 1;
        timer.cancel();
        _defensePreviewTimer = null;
      }
      notifyListeners();
    });
  }

  void _fadeDefensePreview() {
    _defensePreviewTimer?.cancel();
    if (overviewAnimationsSuppressed) {
      defensePreviewTiles = const {};
      defensePreviewWaterCells = const {};
      artilleryRangePreview = false;
      defensePreviewOpacity = 0;
      notifyListeners();
      return;
    }
    final startOpacity = defensePreviewOpacity.clamp(0.0, 1.0);
    var step = 0;
    _defensePreviewTimer = Timer.periodic(const Duration(milliseconds: 55), (
      timer,
    ) {
      if (!_active) {
        timer.cancel();
        return;
      }
      step++;
      defensePreviewOpacity = startOpacity * (1 - step / 10).clamp(0, 1);
      if (step >= 10) {
        defensePreviewTiles = const {};
        defensePreviewWaterCells = const {};
        artilleryRangePreview = false;
        defensePreviewOpacity = 0;
        timer.cancel();
        _defensePreviewTimer = null;
      }
      notifyListeners();
    });
  }

  List<ArtilleryStrike> _humanRelevantArtilleryStrikes(
    List<ArtilleryStrike> strikes,
  ) => strikes
      .where(
        (strike) =>
            state.isHuman(strike.sourceOwner) ||
            state.isHuman(strike.targetOwner),
      )
      .toList(growable: false);

  Future<void> _playArtilleryFireAnimation(List<ArtilleryStrike> strikes) {
    _artilleryFireTimer?.cancel();
    if (!(_artilleryAnimationCompleter?.isCompleted ?? true)) {
      _artilleryAnimationCompleter!.complete();
    }
    if (strikes.isEmpty) {
      artilleryFireAnimation = const [];
      artilleryFireOpacity = 0;
      return Future<void>.value();
    }
    final completer = Completer<void>();
    _artilleryAnimationCompleter = completer;
    artilleryFireAnimation = List.unmodifiable(strikes);
    artilleryFireOpacity = 1;
    artilleryAnimationSerial++;
    var step = 0;
    final volleyCount = artilleryStrikeVolleys(strikes).length;
    final stepsPerVolley = overviewAnimationsSuppressed ? 7 : 13;
    final frameDuration = overviewAnimationsSuppressed
        ? const Duration(milliseconds: 75)
        : const Duration(milliseconds: 40);
    final totalSteps = stepsPerVolley * volleyCount;
    _artilleryFireTimer = Timer.periodic(frameDuration, (timer) {
      if (!_active) {
        timer.cancel();
        if (!completer.isCompleted) completer.complete();
        return;
      }
      step++;
      artilleryFireOpacity = (1 - step / totalSteps).clamp(0, 1);
      if (step >= totalSteps) {
        artilleryFireAnimation = const [];
        artilleryFireOpacity = 0;
        timer.cancel();
        _artilleryFireTimer = null;
        if (!completer.isCompleted) completer.complete();
      }
      notifyListeners();
    });
    notifyListeners();
    return completer.future;
  }

  void _cancelSelectionFade() {
    _selectionFadeTimer?.cancel();
    _selectionFadeTimer = null;
    selectionOpacity = 1;
  }

  void _startForeignSelectionFade(int tileIndex) {
    _selectionFadeTimer?.cancel();
    selectionOpacity = 1;
    if (overviewAnimationsSuppressed) {
      _selectionFadeTimer = Timer(const Duration(milliseconds: 360), () {
        if (!_active || selectedTile != tileIndex) return;
        selectedTile = null;
        selectionOpacity = 1;
        hint = '';
        _selectionFadeTimer = null;
        notifyListeners();
      });
      return;
    }
    var step = 0;
    _selectionFadeTimer = Timer.periodic(const Duration(milliseconds: 45), (
      timer,
    ) {
      if (!_active || selectedTile != tileIndex) {
        timer.cancel();
        return;
      }
      step++;
      selectionOpacity = (1 - step / 8).clamp(0, 1);
      if (step >= 8) {
        selectedTile = null;
        selectionOpacity = 1;
        hint = '';
        timer.cancel();
        _selectionFadeTimer = null;
      }
      if (_active) notifyListeners();
    });
  }
}
