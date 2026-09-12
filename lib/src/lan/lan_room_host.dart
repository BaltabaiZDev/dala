import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../game/game_controller.dart';
import '../game/models.dart';
import 'lan_command_dispatcher.dart';
import 'lan_protocol.dart';
import 'lan_server_api.dart';
import 'lan_server_factory.dart';
import 'lan_state_patch.dart';

class LanRoomHost extends ChangeNotifier {
  LanRoomHost({
    required this.config,
    required String hostName,
    String? roomCode,
    LanServerBackend? backend,
    this.turnTimerEnabled = false,
    int? turnDurationSeconds,
  }) : roomCode = roomCode ?? _newRoomCode(),
       _backend = backend ?? createLanServerBackend(),
       _participants = <String, LanParticipant>{
         'host': LanParticipant(
           id: 'host',
           name: sanitizeLanPlayerName(hostName),
           seat: 0,
           connected: true,
           isHost: true,
         ),
       } {
    this.turnDurationSeconds = math.max(
      lanMinimumTurnSeconds(config.mapSize),
      turnDurationSeconds ?? lanMinimumTurnSeconds(config.mapSize),
    );
  }

  final GameConfig config;
  final String roomCode;
  final LanServerBackend _backend;
  final Map<String, LanParticipant> _participants;
  final Map<String, LanServerConnection> _connections = {};
  final Map<String, String> _connectionTokens = {};
  final Map<String, String> _tokenParticipantIds = {};
  final Map<String, Timer> _disconnectGraceTimers = {};
  final LanCommandDispatcher _dispatcher = const LanCommandDispatcher();
  StreamSubscription<LanServerConnection>? _connectionSubscription;
  LanServerBinding? binding;
  GameController? controller;
  String? error;
  bool started = false;
  bool _closed = false;
  bool _applyingRemote = false;
  bool turnTimerEnabled;
  late int turnDurationSeconds;
  int revision = 0;
  int _nextParticipantId = 1;
  final LanStatePatchBuilder _patchBuilder = LanStatePatchBuilder();
  Timer? _syncTimer;
  Timer? _turnTimer;
  int? _turnDeadlineEpochMs;
  String? _turnClockKey;
  Future<void> _commandSerial = Future<void>.value();

  List<LanParticipant> get participants =>
      _participants.values.toList()
        ..sort((first, second) => first.seat.compareTo(second.seat));

  LanLobbyState get lobby => LanLobbyState(
    roomCode: roomCode,
    config: config,
    participants: participants,
    started: started,
    turnTimerEnabled: turnTimerEnabled,
    turnDurationSeconds: turnDurationSeconds,
  );

  bool get readyToStart => !started && lobby.readyToStart;

  List<String> get joinAddresses => binding == null
      ? const <String>[]
      : [for (final address in binding!.addresses) '$address:${binding!.port}'];

  int get minimumTurnDurationSeconds => lanMinimumTurnSeconds(config.mapSize);

  int? get turnDeadlineEpochMs => _turnDeadlineEpochMs;

  void setTurnTimerEnabled(bool value) {
    if (turnTimerEnabled == value) return;
    turnTimerEnabled = value;
    _turnClockKey = null;
    if (started) _refreshTurnClock(force: true);
    _broadcastLobby();
    notifyListeners();
  }

  void setTurnDurationSeconds(int seconds) {
    final allowed = lanTurnDurationOptions(config.mapSize);
    final value = allowed.reduce(
      (best, item) =>
          (item - seconds).abs() < (best - seconds).abs() ? item : best,
    );
    if (turnDurationSeconds == value) return;
    turnDurationSeconds = value;
    _turnClockKey = null;
    if (started && turnTimerEnabled) _refreshTurnClock(force: true);
    _broadcastLobby();
    notifyListeners();
  }

  Future<void> start({int port = lanDefaultPort}) async {
    if (_closed) throw StateError('LAN бөлмесі жабылған.');
    try {
      binding = await _backend.start(port: port);
      _connectionSubscription = _backend.connections.listen(_acceptConnection);
      error = null;
      notifyListeners();
    } catch (exception) {
      error = exception.toString();
      notifyListeners();
      rethrow;
    }
  }

  void _acceptConnection(LanServerConnection connection) {
    if (_closed) {
      unawaited(connection.close(reason: 'Бөлме жабық'));
      return;
    }
    _connections[connection.id] = connection;
    connection.messages.listen(
      (message) {
        final type = message['type'];
        if (type == 'command' || type == 'leave') {
          _commandSerial = _commandSerial
              .then((_) => _handleMessage(connection, message))
              .catchError((Object exception, StackTrace stackTrace) {
                if (!_closed) {
                  _sendError(connection, 'LAN әрекеті орындалмады.');
                }
              });
        } else {
          unawaited(_handleMessage(connection, message));
        }
      },
      onDone: () => _disconnect(connection.id),
      onError: (_) => _disconnect(connection.id),
      cancelOnError: true,
    );
  }

  Future<void> _handleMessage(
    LanServerConnection connection,
    Map<String, dynamic> message,
  ) async {
    final type = message['type'];
    if (!_connectionTokens.containsKey(connection.id)) {
      if (type != 'join') {
        _sendError(connection, 'Алдымен бөлмеге кіріңіз.');
        return;
      }
      _join(connection, message);
      return;
    }
    if (type == 'ping') {
      connection.send({'type': 'pong'});
      return;
    }
    if (type == 'leave') {
      await _leaveConnection(connection, reason: 'Ойыншы бөлмеден шықты');
      return;
    }
    if (type != 'command' || !started || controller == null) {
      _sendError(connection, 'Ойын командасы қазір қабылданбайды.');
      return;
    }
    final token = _connectionTokens[connection.id]!;
    final participantId = _tokenParticipantIds[token];
    final participant = participantId == null
        ? null
        : _participants[participantId];
    if (participant == null || !participant.connected) {
      _sendError(connection, 'Ойыншы бөлмеде жоқ.');
      return;
    }
    final command = LanGameCommand.fromJson(message);
    if (command.id < 0 || command.baseRevision != revision) {
      _sendSnapshot(connection);
      _sendCommandResult(
        connection,
        command.id,
        accepted: false,
        message: 'Күй жаңарды, әрекетті қайталаңыз.',
      );
      return;
    }
    if (participant.seat != controller!.state.turn) {
      _sendCommandResult(
        connection,
        command.id,
        accepted: false,
        message: 'Қазір сіздің жүрісіңіз емес.',
      );
      return;
    }

    _applyingRemote = true;
    try {
      final ui = await _dispatcher.dispatch(
        controller: controller!,
        player: participant.seat,
        command: command,
      );
      _syncControllerState(force: false);
      _sendCommandResult(connection, command.id, accepted: true, ui: ui);
    } catch (exception) {
      _sendCommandResult(
        connection,
        command.id,
        accepted: false,
        message: _safeError(exception),
      );
      _sendSnapshot(connection);
    } finally {
      _applyingRemote = false;
    }
  }

  void _join(LanServerConnection connection, Map<String, dynamic> message) {
    if ((message['protocol'] as num?)?.toInt() != lanProtocolVersion) {
      _sendError(connection, 'LAN нұсқасы сәйкес емес.');
      return;
    }
    if (message['roomCode']?.toString() != roomCode) {
      _sendError(connection, 'Бөлме коды қате.');
      return;
    }
    final requestedToken = message['token'] as String?;
    if (requestedToken != null) {
      final existingId = _tokenParticipantIds[requestedToken];
      final existing = existingId == null ? null : _participants[existingId];
      if (existing != null && !existing.isHost) {
        _bindConnection(
          connection,
          requestedToken,
          existing.copyWith(connected: true),
        );
        return;
      }
    }
    if (started) {
      _sendError(connection, 'Ойын басталып кетті. Қайта кіру кілті қажет.');
      return;
    }
    final seat = _firstFreeSeat();
    if (seat == null) {
      _sendError(connection, 'Бөлмеде бос орын жоқ.');
      return;
    }
    final id = 'player-${_nextParticipantId++}';
    final token = _newToken();
    _tokenParticipantIds[token] = id;
    _bindConnection(
      connection,
      token,
      LanParticipant(
        id: id,
        name: sanitizeLanPlayerName(message['name'] as String? ?? ''),
        seat: seat,
        connected: true,
        isHost: false,
      ),
    );
  }

  void _bindConnection(
    LanServerConnection connection,
    String token,
    LanParticipant participant,
  ) {
    _disconnectGraceTimers.remove(participant.id)?.cancel();
    final oldConnectionId = _connectionTokens.entries
        .where((entry) => entry.value == token)
        .map((entry) => entry.key)
        .firstOrNull;
    if (oldConnectionId != null && oldConnectionId != connection.id) {
      _connectionTokens.remove(oldConnectionId);
      final oldConnection = _connections.remove(oldConnectionId);
      if (oldConnection != null) {
        unawaited(oldConnection.close(reason: 'Жаңа қосылым ашылды'));
      }
    }
    _participants[participant.id] = participant;
    _connectionTokens[connection.id] = token;
    connection.send({
      'type': 'welcome',
      'protocol': lanProtocolVersion,
      'token': token,
      'participantId': participant.id,
      'seat': participant.seat,
      'revision': revision,
      'lobby': lobby.toJson(),
      if (started && controller != null) 'state': controller!.state.toJson(),
      if (started && controller != null) 'turnClock': _turnClockJson(),
    });
    _broadcastLobby();
    notifyListeners();
  }

  int? _firstFreeSeat() {
    final used = _participants.values
        .where((participant) => participant.connected)
        .map((participant) => participant.seat)
        .toSet();
    for (var seat = 1; seat < config.humanCount; seat++) {
      if (!used.contains(seat)) return seat;
    }
    return null;
  }

  void moveParticipant(String participantId, int seat) {
    if (started || seat <= 0 || seat >= config.humanCount) return;
    final participant = _participants[participantId];
    if (participant == null || participant.isHost) return;
    final occupant = _participants.values
        .where((candidate) => candidate.seat == seat)
        .firstOrNull;
    if (occupant != null && occupant.id != participantId) {
      _participants[occupant.id] = occupant.copyWith(seat: participant.seat);
    }
    _participants[participantId] = participant.copyWith(seat: seat);
    _broadcastLobby();
    notifyListeners();
  }

  Future<void> kick(String participantId) async {
    final participant = _participants[participantId];
    if (participant == null || participant.isHost) return;
    await _removeParticipant(
      participant,
      reason: 'Хост ойыншыны шығарды',
      notifyConnection: true,
    );
  }

  Future<void> _leaveConnection(
    LanServerConnection connection, {
    required String reason,
  }) async {
    final token = _connectionTokens[connection.id];
    final participantId = token == null ? null : _tokenParticipantIds[token];
    final participant = participantId == null
        ? null
        : _participants[participantId];
    if (participant == null || participant.isHost) return;
    await _removeParticipant(
      participant,
      reason: reason,
      notifyConnection: false,
    );
  }

  Future<void> _removeParticipant(
    LanParticipant participant, {
    required String reason,
    required bool notifyConnection,
  }) async {
    _disconnectGraceTimers.remove(participant.id)?.cancel();
    final token = _tokenParticipantIds.entries
        .where((entry) => entry.value == participant.id)
        .map((entry) => entry.key)
        .firstOrNull;
    final connectionId = token == null
        ? null
        : _connectionTokens.entries
              .where((entry) => entry.value == token)
              .map((entry) => entry.key)
              .firstOrNull;
    final connection = connectionId == null ? null : _connections[connectionId];
    if (notifyConnection && connection != null) {
      connection.send({'type': 'participantRemoved', 'message': reason});
    }

    _participants.remove(participant.id);
    if (token != null) _tokenParticipantIds.remove(token);
    if (connectionId != null) {
      _connectionTokens.remove(connectionId);
      _connections.remove(connectionId);
    }

    final gameController = controller;
    if (started && gameController != null) {
      final wasCurrentTurn = gameController.state.turn == participant.seat;
      gameController.neutralizeDepartedLanPlayer(participant.seat);
      if (wasCurrentTurn && gameController.state.winner == null) {
        await gameController.runAsNetworkPlayer(
          participant.seat,
          gameController.finishTurn,
        );
      }
      _syncControllerState(force: false);
    }
    _broadcastLobby();
    notifyListeners();
    if (connection != null) {
      await connection.close(reason: reason);
    }
  }

  void startGame(GameController gameController) {
    if (!readyToStart) throw StateError('Барлық LAN орындары толмады.');
    _applyParticipantNames(gameController.state);
    controller = gameController;
    started = true;
    revision = 1;
    _patchBuilder.prime(gameController.state);
    gameController.addListener(_controllerChanged);
    _refreshTurnClock(force: true);
    _broadcast({
      'type': 'gameStarted',
      'revision': revision,
      'lobby': lobby.toJson(),
      'state': gameController.state.toJson(),
      'turnClock': _turnClockJson(),
    });
    notifyListeners();
  }

  void restartGame(GameController gameController) {
    final old = controller;
    if (old != null) old.removeListener(_controllerChanged);
    _applyParticipantNames(gameController.state);
    controller = gameController;
    started = true;
    revision++;
    _patchBuilder.prime(gameController.state);
    gameController.addListener(_controllerChanged);
    _turnClockKey = null;
    _refreshTurnClock(force: true);
    _broadcast({
      'type': 'gameStarted',
      'revision': revision,
      'lobby': lobby.toJson(),
      'state': gameController.state.toJson(),
      'turnClock': _turnClockJson(),
    });
    notifyListeners();
  }

  void _applyParticipantNames(GameState state) {
    for (final participant in participants) {
      state.setPlayerName(participant.seat, participant.name);
    }
  }

  void detachGameController(GameController gameController) {
    if (!identical(controller, gameController)) return;
    gameController.removeListener(_controllerChanged);
    controller = null;
  }

  void _controllerChanged() {
    if (_applyingRemote || controller == null) return;
    _syncTimer?.cancel();
    _syncTimer = Timer(
      const Duration(milliseconds: 35),
      () => _syncControllerState(force: false),
    );
  }

  void _syncControllerState({required bool force}) {
    final gameController = controller;
    if (gameController == null) return;
    final patch = _patchBuilder.build(gameController.state);
    if (!force && patch == null) return;
    revision++;
    if (force || patch?['fullStateRequired'] == true) {
      _patchBuilder.prime(gameController.state);
      _broadcast({
        'type': 'snapshot',
        'revision': revision,
        'state': gameController.state.toJson(),
        'turnClock': _turnClockJson(),
      });
    } else {
      _broadcast({
        'type': 'statePatch',
        'revision': revision,
        'patch': patch,
        'turnClock': _turnClockJson(),
      });
    }
    _refreshTurnClock();
  }

  void _disconnect(String connectionId) {
    _connections.remove(connectionId);
    final token = _connectionTokens.remove(connectionId);
    if (token == null) return;
    final participantId = _tokenParticipantIds[token];
    final participant = participantId == null
        ? null
        : _participants[participantId];
    if (participant == null) return;
    if (started) {
      _participants[participant.id] = participant.copyWith(connected: false);
      _disconnectGraceTimers.remove(participant.id)?.cancel();
      _disconnectGraceTimers[participant.id] = Timer(
        const Duration(seconds: 18),
        () {
          _commandSerial = _commandSerial.then((_) async {
            final current = _participants[participant.id];
            if (current == null || current.connected) return;
            await _removeParticipant(
              current,
              reason: 'Ойыншы желіден шығып кетті',
              notifyConnection: false,
            );
          });
        },
      );
    } else {
      _participants.remove(participant.id);
      _tokenParticipantIds.remove(token);
    }
    _broadcastLobby();
    notifyListeners();
    if (started && controller?.state.turn == participant.seat) {
      _commandSerial = _commandSerial.then(
        (_) => _skipDisconnectedTurn(participant.id, participant.seat),
      );
    }
  }

  void _broadcastLobby() => _broadcast({
    'type': 'lobby',
    'revision': revision,
    'lobby': lobby.toJson(),
  });

  void _sendSnapshot(LanServerConnection connection) {
    if (controller == null) return;
    connection.send({
      'type': 'snapshot',
      'revision': revision,
      'state': controller!.state.toJson(),
      'turnClock': _turnClockJson(),
    });
  }

  Map<String, dynamic> _turnClockJson() => LanTurnClock(
    enabled: turnTimerEnabled,
    durationSeconds: turnDurationSeconds,
    deadlineEpochMs: _turnDeadlineEpochMs,
  ).toJson();

  void _refreshTurnClock({bool force = false}) {
    final gameController = controller;
    final key = gameController == null
        ? null
        : '${gameController.state.round}:${gameController.state.turn}';
    if (!force && key == _turnClockKey) return;
    _turnClockKey = key;
    _turnTimer?.cancel();
    _turnDeadlineEpochMs = null;

    if (gameController != null &&
        started &&
        gameController.state.currentPlayerIsHuman &&
        gameController.state.winner == null) {
      final player = gameController.state.turn;
      final participant = _participants.values
          .where((item) => item.seat == player)
          .firstOrNull;
      if (participant == null || !participant.connected) {
        _commandSerial = _commandSerial.then(
          (_) => _skipDisconnectedTurn(participant?.id, player),
        );
      } else if (turnTimerEnabled) {
        _turnDeadlineEpochMs = DateTime.now()
            .add(Duration(seconds: turnDurationSeconds))
            .millisecondsSinceEpoch;
        _turnTimer = Timer(Duration(seconds: turnDurationSeconds), () {
          _commandSerial = _commandSerial.then((_) => _expireTurn(player, key));
        });
      }
    }

    gameController?.updateNetworkTurnClock(
      enabled: turnTimerEnabled,
      durationSeconds: turnDurationSeconds,
      deadlineEpochMs: _turnDeadlineEpochMs,
    );
    if (started) {
      _broadcast({'type': 'turnClock', 'turnClock': _turnClockJson()});
    }
  }

  Future<void> _expireTurn(int player, String? key) async {
    final gameController = controller;
    if (_closed ||
        gameController == null ||
        !turnTimerEnabled ||
        key != _turnClockKey ||
        gameController.state.turn != player ||
        gameController.state.winner != null) {
      return;
    }
    await gameController.runAsNetworkPlayer(player, gameController.finishTurn);
    _syncControllerState(force: false);
  }

  @visibleForTesting
  Future<void> expireCurrentTurnForTesting() async {
    final gameController = controller;
    if (gameController == null) return;
    await _expireTurn(gameController.state.turn, _turnClockKey);
  }

  Future<void> _skipDisconnectedTurn(String? participantId, int player) async {
    final gameController = controller;
    if (_closed ||
        gameController == null ||
        gameController.state.turn != player ||
        gameController.state.winner != null) {
      return;
    }
    final participant = participantId == null
        ? null
        : _participants[participantId];
    if (participant?.connected == true) return;
    await gameController.runAsNetworkPlayer(player, gameController.finishTurn);
    _syncControllerState(force: false);
  }

  void _sendCommandResult(
    LanServerConnection connection,
    int commandId, {
    required bool accepted,
    String? message,
    Map<String, dynamic>? ui,
  }) {
    connection.send({
      'type': 'commandResult',
      'id': commandId,
      'accepted': accepted,
      'revision': revision,
      'message': ?message,
      'ui': ?ui,
    });
  }

  void _sendError(LanServerConnection connection, String message) {
    connection.send({'type': 'error', 'message': message});
  }

  void _broadcast(Map<String, dynamic> message) {
    for (final connection in _connections.values) {
      if (_connectionTokens.containsKey(connection.id)) {
        connection.send(message);
      }
    }
  }

  String _safeError(Object exception) {
    if (exception is StateError ||
        exception is FormatException ||
        exception is UnsupportedError) {
      return exception.toString().replaceFirst(RegExp(r'^[^:]+:\s*'), '');
    }
    return 'LAN әрекеті орындалмады.';
  }

  Future<void> close({String reason = 'Хост бөлмені жапты'}) async {
    if (_closed) return;
    _closed = true;
    _syncTimer?.cancel();
    _turnTimer?.cancel();
    for (final timer in _disconnectGraceTimers.values) {
      timer.cancel();
    }
    _disconnectGraceTimers.clear();
    _broadcast({'type': 'roomClosed', 'message': reason});
    await Future<void>.delayed(Duration.zero);
    final gameController = controller;
    if (gameController != null) {
      gameController.removeListener(_controllerChanged);
      gameController.updateNetworkTurnClock(
        enabled: false,
        durationSeconds: turnDurationSeconds,
      );
    }
    await _connectionSubscription?.cancel();
    await _backend.close();
  }

  @override
  void dispose() {
    unawaited(close());
    super.dispose();
  }

  static String _newRoomCode() =>
      (math.Random.secure().nextInt(900000) + 100000).toString();

  static String _newToken() {
    final random = math.Random.secure();
    return List<String>.generate(
      4,
      (_) => random.nextInt(0x7fffffff).toRadixString(36),
    ).join('-');
  }
}
