import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/status.dart' as ws_status;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../game/game_controller.dart';
import '../game/models.dart';
import 'lan_protocol.dart';
import 'lan_state_patch.dart';

class LanRoomClient extends ChangeNotifier implements GameNetworkDelegate {
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Timer? _reconnectTimer;
  final Map<int, Completer<bool>> _pending = {};
  String _address = '';
  String _roomCode = '';
  String _name = '';
  String? _token;
  bool _closing = false;
  int _nextCommandId = 1;
  int _reconnectAttempt = 0;
  GameController? _boundController;

  LanConnectionStatus status = LanConnectionStatus.idle;
  LanLobbyState? lobby;
  Map<String, dynamic>? stateJson;
  Map<String, dynamic>? latestUi;
  int revision = 0;
  int seat = -1;
  String? participantId;
  String? error;
  bool closedByHost = false;
  bool removedByHost = false;
  LanTurnClock turnClock = const LanTurnClock(
    enabled: false,
    durationSeconds: 0,
  );

  @override
  bool get isConnected =>
      status == LanConnectionStatus.lobby ||
      status == LanConnectionStatus.playing;

  @override
  bool get busy => _pending.isNotEmpty;

  bool get hasStarted => stateJson != null && seat >= 0;

  Future<void> connect({
    required String address,
    required String roomCode,
    required String name,
  }) async {
    _address = address.trim();
    _roomCode = roomCode.replaceAll(RegExp('[^0-9]'), '');
    _name = sanitizeLanPlayerName(name);
    _closing = false;
    closedByHost = false;
    removedByHost = false;
    _reconnectAttempt = 0;
    await _open(reconnecting: false);
  }

  Future<void> _open({required bool reconnecting}) async {
    await _subscription?.cancel();
    await _channel?.sink.close();
    status = reconnecting
        ? LanConnectionStatus.reconnecting
        : LanConnectionStatus.connecting;
    error = null;
    _refresh();
    try {
      final uri = _normalizeAddress(_address);
      final channel = WebSocketChannel.connect(uri);
      _channel = channel;
      await channel.ready.timeout(const Duration(seconds: 6));
      _subscription = channel.stream.listen(
        _handleData,
        onDone: _connectionLost,
        onError: (_) => _connectionLost(),
        cancelOnError: true,
      );
      channel.sink.add(
        jsonEncode({
          'type': 'join',
          'protocol': lanProtocolVersion,
          'roomCode': _roomCode,
          'name': _name,
          if (_token != null) 'token': _token,
        }),
      );
    } catch (exception) {
      error = 'LAN бөлмесіне қосылу мүмкін болмады: ${_safeError(exception)}';
      _scheduleReconnect();
    }
  }

  void _handleData(dynamic data) {
    if (data is! String) return;
    try {
      final decoded = jsonDecode(data);
      if (decoded is! Map) return;
      final message = decoded.cast<String, dynamic>();
      switch (message['type']) {
        case 'welcome':
          _token = message['token'] as String?;
          participantId = message['participantId'] as String?;
          seat = (message['seat'] as num?)?.toInt() ?? -1;
          revision = (message['revision'] as num?)?.toInt() ?? revision;
          lobby = _readLobby(message['lobby']);
          _updateSeatFromLobby();
          _readState(message['state']);
          _readTurnClock(message['turnClock']);
          status = stateJson == null
              ? LanConnectionStatus.lobby
              : LanConnectionStatus.playing;
          _reconnectAttempt = 0;
          error = null;
          break;
        case 'lobby':
          lobby = _readLobby(message['lobby']);
          _updateSeatFromLobby();
          revision = (message['revision'] as num?)?.toInt() ?? revision;
          if (stateJson == null) status = LanConnectionStatus.lobby;
          break;
        case 'gameStarted':
          lobby = _readLobby(message['lobby']) ?? lobby;
          _updateSeatFromLobby();
          revision = (message['revision'] as num?)?.toInt() ?? revision;
          _readState(message['state']);
          _readTurnClock(message['turnClock']);
          status = LanConnectionStatus.playing;
          break;
        case 'snapshot':
          final incoming = (message['revision'] as num?)?.toInt() ?? -1;
          if (incoming >= revision) {
            revision = incoming;
            _readState(message['state']);
            _readTurnClock(message['turnClock']);
          }
          break;
        case 'statePatch':
          final incoming = (message['revision'] as num?)?.toInt() ?? -1;
          final rawPatch = message['patch'];
          if (incoming >= revision && rawPatch is Map) {
            revision = incoming;
            _readStatePatch(rawPatch.cast<String, dynamic>());
            _readTurnClock(message['turnClock']);
          }
          break;
        case 'turnClock':
          _readTurnClock(message['turnClock']);
          break;
        case 'commandResult':
          final id = (message['id'] as num?)?.toInt() ?? -1;
          final accepted = message['accepted'] as bool? ?? false;
          final completer = _pending.remove(id);
          revision = (message['revision'] as num?)?.toInt() ?? revision;
          final rawUi = message['ui'];
          if (rawUi is Map) {
            latestUi = rawUi.cast<String, dynamic>();
            _boundController?.applyNetworkUiState(latestUi!);
          }
          if (!accepted) {
            error =
                message['message'] as String? ?? 'LAN әрекеті қабылданбады.';
            _setControllerHint(error!);
          }
          if (completer != null && !completer.isCompleted) {
            completer.complete(accepted);
          }
          break;
        case 'error':
          error = message['message'] as String? ?? 'LAN қатесі.';
          _setControllerHint(error!);
          break;
        case 'roomClosed':
          _terminalClose(
            message['message'] as String? ?? 'Хост бөлмені жапты',
            byHost: true,
          );
          return;
        case 'participantRemoved':
          removedByHost = true;
          _terminalClose(
            message['message'] as String? ?? 'Хост сізді бөлмеден шығарды',
            byHost: true,
          );
          return;
        case 'pong':
          break;
      }
      _refresh();
    } on FormatException {
      error = 'Хост жарамсыз LAN жауабын жіберді.';
      _refresh();
    }
  }

  LanLobbyState? _readLobby(Object? raw) =>
      raw is Map ? LanLobbyState.fromJson(raw.cast<String, dynamic>()) : null;

  void _updateSeatFromLobby() {
    final id = participantId;
    final currentLobby = lobby;
    if (id == null || currentLobby == null) return;
    final participant = currentLobby.participants
        .where((candidate) => candidate.id == id)
        .firstOrNull;
    if (participant != null) seat = participant.seat;
  }

  void _readState(Object? raw) {
    if (raw is! Map) return;
    final next = raw.cast<String, dynamic>();
    // Parsing here fails closed before the snapshot reaches the renderer.
    GameState.fromJson(next);
    stateJson = next;
    final controller = _boundController;
    if (controller != null) {
      controller.replaceStateFromNetwork(next, uiState: latestUi);
    }
  }

  void _readStatePatch(Map<String, dynamic> patch) {
    final snapshot = stateJson;
    if (snapshot == null) {
      throw const FormatException('LAN толық күйі жоқ.');
    }
    applyLanPatchToJson(snapshot, patch);
    _boundController?.applyStatePatchFromNetwork(patch, uiState: latestUi);
  }

  void _readTurnClock(Object? raw) {
    if (raw is! Map) return;
    turnClock = LanTurnClock.fromJson(raw.cast<String, dynamic>());
    _boundController?.updateNetworkTurnClock(
      enabled: turnClock.enabled,
      durationSeconds: turnClock.durationSeconds,
      deadlineEpochMs: turnClock.deadlineEpochMs,
    );
  }

  void bindController(GameController controller) {
    _boundController = controller;
    controller.networkDelegate = this;
    final snapshot = stateJson;
    if (snapshot != null) {
      controller.replaceStateFromNetwork(snapshot, uiState: latestUi);
    }
    controller.updateNetworkTurnClock(
      enabled: turnClock.enabled,
      durationSeconds: turnClock.durationSeconds,
      deadlineEpochMs: turnClock.deadlineEpochMs,
    );
  }

  void unbindController(GameController controller) {
    if (identical(_boundController, controller)) {
      controller.networkDelegate = null;
      _boundController = null;
    }
  }

  @override
  bool sendCommand(
    String action,
    Map<String, dynamic> arguments,
    Map<String, dynamic> uiState,
  ) {
    if (!isConnected || status != LanConnectionStatus.playing || busy) {
      return false;
    }
    final id = _nextCommandId++;
    final completer = Completer<bool>();
    _pending[id] = completer;
    _send(
      LanGameCommand(
        id: id,
        baseRevision: revision,
        action: action,
        arguments: arguments,
        ui: LanUiState.fromJson(uiState),
      ).toJson(),
    );
    _armCommandTimeout(id, completer);
    _refresh();
    return true;
  }

  @override
  Future<bool> sendCommandAsync(
    String action,
    Map<String, dynamic> arguments,
    Map<String, dynamic> uiState,
  ) async {
    if (!isConnected || status != LanConnectionStatus.playing || busy) {
      return false;
    }
    final id = _nextCommandId++;
    final completer = Completer<bool>();
    _pending[id] = completer;
    _send(
      LanGameCommand(
        id: id,
        baseRevision: revision,
        action: action,
        arguments: arguments,
        ui: LanUiState.fromJson(uiState),
      ).toJson(),
    );
    _armCommandTimeout(id, completer);
    _refresh();
    return completer.future;
  }

  void _armCommandTimeout(int id, Completer<bool> completer) {
    Timer(const Duration(seconds: 10), () {
      if (_pending.remove(id) == null || completer.isCompleted) return;
      error = 'Хост әрекетке уақытында жауап бермеді.';
      completer.complete(false);
      _setControllerHint(error!);
      _refresh();
    });
  }

  void _send(Map<String, dynamic> message) {
    _channel?.sink.add(jsonEncode(message));
  }

  void _connectionLost() {
    if (_closing || status == LanConnectionStatus.closed) return;
    status = LanConnectionStatus.reconnecting;
    error = 'Хостпен байланыс үзілді. Қайта қосылуда…';
    for (final completer in _pending.values) {
      if (!completer.isCompleted) completer.complete(false);
    }
    _pending.clear();
    _setControllerHint(error!);
    _refresh();
    _scheduleReconnect();
  }

  void _terminalClose(String message, {required bool byHost}) {
    if (_closing && status == LanConnectionStatus.closed) return;
    _closing = true;
    closedByHost = byHost;
    _reconnectTimer?.cancel();
    unawaited(_subscription?.cancel());
    unawaited(_channel?.sink.close());
    for (final completer in _pending.values) {
      if (!completer.isCompleted) completer.complete(false);
    }
    _pending.clear();
    status = LanConnectionStatus.closed;
    error = message;
    _setControllerHint(message);
    _refresh();
  }

  void _scheduleReconnect() {
    if (_closing) return;
    _reconnectTimer?.cancel();
    if (_reconnectAttempt >= 4) {
      status = LanConnectionStatus.closed;
      error = 'Хост табылмады. Бөлмеге қайта кіріп көріңіз.';
      _refresh();
      return;
    }
    final seconds = 1 << _reconnectAttempt;
    _reconnectAttempt++;
    status = LanConnectionStatus.reconnecting;
    _refresh();
    _reconnectTimer = Timer(
      Duration(seconds: seconds),
      () => unawaited(_open(reconnecting: true)),
    );
  }

  void _setControllerHint(String message) {
    final controller = _boundController;
    if (controller == null) return;
    final ui = controller.captureNetworkUiState()..['hint'] = message;
    controller.applyNetworkUiState(ui);
  }

  void _refresh() {
    notifyListeners();
    final controller = _boundController;
    if (controller != null) {
      controller.applyNetworkUiState(controller.captureNetworkUiState());
    }
  }

  Future<void> close({bool notifyHost = true}) async {
    if (_closing) return;
    _closing = true;
    _reconnectTimer?.cancel();
    if (notifyHost && isConnected) {
      _send({'type': 'leave'});
      await Future<void>.delayed(Duration.zero);
    }
    await _subscription?.cancel();
    await _channel?.sink.close(
      ws_status.normalClosure,
      'Ойыншы бөлмеден шықты',
    );
    for (final completer in _pending.values) {
      if (!completer.isCompleted) completer.complete(false);
    }
    _pending.clear();
    status = LanConnectionStatus.closed;
    _refresh();
  }

  @override
  void dispose() {
    unawaited(close());
    super.dispose();
  }

  static Uri _normalizeAddress(String raw) {
    var value = raw.trim();
    if (value.isEmpty) throw const FormatException('Хост IP бос.');
    if (!value.contains('://')) value = 'ws://$value';
    final uri = Uri.parse(value);
    final port = uri.hasPort ? uri.port : lanDefaultPort;
    if (uri.host.isEmpty) throw const FormatException('Хост IP жарамсыз.');
    return uri.replace(
      scheme: uri.scheme == 'wss' ? 'wss' : 'ws',
      port: port,
      path: '/ws',
      query: null,
      fragment: null,
    );
  }

  static String _safeError(Object exception) => exception
      .toString()
      .replaceFirst(RegExp(r'^[^:]+:\s*'), '')
      .replaceAll('\n', ' ');
}
