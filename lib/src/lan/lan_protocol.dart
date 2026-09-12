export 'lan_address.dart' show lanDefaultPort;
import '../game/models.dart';
import '../modding/game_mod.dart';

// Isolated-cell conquest and treaty evacuation must agree on every device.
const int lanProtocolVersion = 7;

const int lanMaxPlayerNameLength = 20;
const int lanMaxMessageLength = 512;

int lanMinimumTurnSeconds(MapSize size) => switch (size) {
  MapSize.small => 60,
  MapSize.medium => 120,
  MapSize.large => 180,
  MapSize.huge => 240,
  MapSize.giant => 300,
};

List<int> lanTurnDurationOptions(MapSize size) {
  final minimum = lanMinimumTurnSeconds(size);
  return List<int>.generate(6, (index) => minimum + index * 60);
}

enum LanConnectionStatus {
  idle,
  connecting,
  lobby,
  playing,
  reconnecting,
  closed,
}

String sanitizeLanPlayerName(String value) {
  final compact = value
      .replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '')
      .trim()
      .replaceAll(RegExp(r'\s+'), ' ');
  if (compact.isEmpty) return 'Ойыншы';
  return compact.length <= lanMaxPlayerNameLength
      ? compact
      : compact.substring(0, lanMaxPlayerNameLength);
}

String normalizeRoomCode(String value) {
  final digits = value.replaceAll(RegExp('[^0-9]'), '');
  if (digits.length >= 6) return digits.substring(digits.length - 6);
  return digits.padLeft(6, '0');
}

class LanParticipant {
  const LanParticipant({
    required this.id,
    required this.name,
    required this.seat,
    required this.connected,
    required this.isHost,
  });

  final String id;
  final String name;
  final int seat;
  final bool connected;
  final bool isHost;

  LanParticipant copyWith({int? seat, bool? connected}) => LanParticipant(
    id: id,
    name: name,
    seat: seat ?? this.seat,
    connected: connected ?? this.connected,
    isHost: isHost,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'seat': seat,
    'connected': connected,
    'isHost': isHost,
  };

  factory LanParticipant.fromJson(Map<String, dynamic> json) => LanParticipant(
    id: json['id'] as String? ?? '',
    name: sanitizeLanPlayerName(json['name'] as String? ?? ''),
    seat: (json['seat'] as num?)?.toInt() ?? -1,
    connected: json['connected'] as bool? ?? false,
    isHost: json['isHost'] as bool? ?? false,
  );
}

class LanLobbyState {
  const LanLobbyState({
    required this.roomCode,
    required this.config,
    required this.participants,
    required this.started,
    this.turnTimerEnabled = false,
    this.turnDurationSeconds = 0,
    this.modName = 'DALA',
    this.modHash,
    this.modded = false,
    this.mapName,
    this.requiredMods = const [],
  });

  final String roomCode;
  final GameConfig config;
  final List<LanParticipant> participants;
  final bool started;
  final bool turnTimerEnabled;
  final int turnDurationSeconds;
  final String modName;
  final String? modHash;
  final bool modded;
  final String? mapName;
  final List<ModReference> requiredMods;

  bool get readyToStart {
    final occupied = participants
        .where((participant) => participant.connected)
        .map((participant) => participant.seat)
        .toSet();
    return List<int>.generate(
      config.humanCount,
      (index) => index,
    ).every(occupied.contains);
  }

  Map<String, dynamic> toJson() => {
    'roomCode': roomCode,
    'config': config.toJson(),
    'participants': participants
        .map((participant) => participant.toJson())
        .toList(),
    'started': started,
    'turnTimerEnabled': turnTimerEnabled,
    'turnDurationSeconds': turnDurationSeconds,
    'modName': modName,
    'modHash': modHash,
    'modded': modded,
    'mapName': mapName,
    'requiredMods': requiredMods.map((m) => m.toJson()).toList(),
  };

  factory LanLobbyState.fromJson(Map<String, dynamic> json) => LanLobbyState(
    roomCode: json['roomCode'] as String? ?? '',
    config: GameConfig.fromJson(
      (json['config'] as Map? ?? const <String, dynamic>{})
          .cast<String, dynamic>(),
    ),
    participants: (json['participants'] as List? ?? const <Object>[])
        .whereType<Map>()
        .map((item) => LanParticipant.fromJson(item.cast<String, dynamic>()))
        .toList(),
    started: json['started'] as bool? ?? false,
    turnTimerEnabled: json['turnTimerEnabled'] as bool? ?? false,
    turnDurationSeconds: (json['turnDurationSeconds'] as num?)?.toInt() ?? 0,
    modName: json['modName'] as String? ?? 'DALA',
    modHash: json['modHash'] as String?,
    modded: json['modded'] as bool? ?? false,
    mapName: json['mapName'] as String?,
    requiredMods: ModReference.readList(json['requiredMods']),
  );
}

class LanTurnClock {
  const LanTurnClock({
    required this.enabled,
    required this.durationSeconds,
    this.deadlineEpochMs,
  });

  final bool enabled;
  final int durationSeconds;
  final int? deadlineEpochMs;

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'durationSeconds': durationSeconds,
    'deadlineEpochMs': deadlineEpochMs,
  };

  factory LanTurnClock.fromJson(Map<String, dynamic> json) => LanTurnClock(
    enabled: json['enabled'] as bool? ?? false,
    durationSeconds: (json['durationSeconds'] as num?)?.toInt() ?? 0,
    deadlineEpochMs: (json['deadlineEpochMs'] as num?)?.toInt(),
  );
}

class LanUiState {
  const LanUiState({
    this.selectedTile,
    this.selectedWaterCell,
    this.selectedCargoIndex,
    this.toolIndex = 0,
    this.hint = '',
    this.defenseTiles = const <int>[],
    this.defenseWaterCells = const <int>[],
    this.defenseOpacity = 0,
    this.artilleryRangePreview = false,
    this.canUndo = false,
  });

  final int? selectedTile;
  final int? selectedWaterCell;
  final int? selectedCargoIndex;
  final int toolIndex;
  final String hint;
  final List<int> defenseTiles;
  final List<int> defenseWaterCells;
  final double defenseOpacity;
  final bool artilleryRangePreview;
  final bool canUndo;

  Map<String, dynamic> toJson() => {
    'selectedTile': selectedTile,
    'selectedWaterCell': selectedWaterCell,
    'selectedCargoIndex': selectedCargoIndex,
    'toolIndex': toolIndex,
    'hint': hint,
    'defenseTiles': defenseTiles,
    'defenseWaterCells': defenseWaterCells,
    'defenseOpacity': defenseOpacity,
    'artilleryRangePreview': artilleryRangePreview,
    'canUndo': canUndo,
  };

  factory LanUiState.fromJson(Map<String, dynamic> json) => LanUiState(
    selectedTile: (json['selectedTile'] as num?)?.toInt(),
    selectedWaterCell: (json['selectedWaterCell'] as num?)?.toInt(),
    selectedCargoIndex: (json['selectedCargoIndex'] as num?)?.toInt(),
    toolIndex: (json['toolIndex'] as num?)?.toInt() ?? 0,
    hint: (json['hint'] as String? ?? '').substring(
      0,
      (json['hint'] as String? ?? '').length.clamp(0, lanMaxMessageLength),
    ),
    defenseTiles: _readIntList(json['defenseTiles']),
    defenseWaterCells: _readIntList(json['defenseWaterCells']),
    defenseOpacity: (json['defenseOpacity'] as num?)?.toDouble() ?? 0,
    artilleryRangePreview: json['artilleryRangePreview'] as bool? ?? false,
    canUndo: json['canUndo'] as bool? ?? false,
  );
}

class LanGameCommand {
  const LanGameCommand({
    required this.id,
    required this.baseRevision,
    required this.action,
    required this.arguments,
    required this.ui,
  });

  final int id;
  final int baseRevision;
  final String action;
  final Map<String, dynamic> arguments;
  final LanUiState ui;

  Map<String, dynamic> toJson() => {
    'type': 'command',
    'protocol': lanProtocolVersion,
    'id': id,
    'baseRevision': baseRevision,
    'action': action,
    'arguments': arguments,
    'ui': ui.toJson(),
  };

  factory LanGameCommand.fromJson(Map<String, dynamic> json) => LanGameCommand(
    id: (json['id'] as num?)?.toInt() ?? -1,
    baseRevision: (json['baseRevision'] as num?)?.toInt() ?? -1,
    action: json['action'] as String? ?? '',
    arguments: (json['arguments'] as Map? ?? const <String, dynamic>{})
        .cast<String, dynamic>(),
    ui: LanUiState.fromJson(
      (json['ui'] as Map? ?? const <String, dynamic>{}).cast<String, dynamic>(),
    ),
  );
}

List<int> _readIntList(Object? raw) => raw is List
    ? raw.whereType<num>().map((value) => value.toInt()).toList()
    : const <int>[];
