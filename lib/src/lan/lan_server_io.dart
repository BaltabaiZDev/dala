import 'lan_address.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'lan_server_api.dart';

const bool hostingSupported = true;

LanServerBackend createLanServerBackend() => _IoLanServer();

class _IoLanServer implements LanServerBackend {
  final StreamController<LanServerConnection> _connections =
      StreamController<LanServerConnection>.broadcast();
  final Set<_IoLanConnection> _openConnections = {};
  HttpServer? _server;
  int _nextConnectionId = 1;

  @override
  Stream<LanServerConnection> get connections => _connections.stream;

  @override
  Future<LanServerBinding> start({int port = lanDefaultPort}) async {
    if (_server != null) {
      throw StateError('LAN сервері әлдеқашан ашық.');
    }
    late final HttpServer server;
    try {
      server = await HttpServer.bind(
        InternetAddress.anyIPv4,
        port,
        shared: false,
      );
    } on SocketException {
      throw LanPortUnavailable(port);
    }
    _server = server;
    server.listen(_handleRequest, onError: (_) {});

    final addresses = <LanInterfaceAddress>[];
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          if (!address.isLoopback && address.address.isNotEmpty) {
            addresses.add(LanInterfaceAddress(address.address, interface.name));
          }
        }
      }
    } on SocketException {
      // Loopback remains available for tests and same-device play.
    }
    return LanServerBinding(
      addresses: rankedLanAddresses(addresses),
      port: server.port,
    );
  }

  Future<void> _handleRequest(HttpRequest request) async {
    if (request.uri.path != '/ws' ||
        !WebSocketTransformer.isUpgradeRequest(request)) {
      request.response
        ..statusCode = HttpStatus.notFound
        ..headers.contentType = ContentType.text
        ..write('Antiyoy LAN WebSocket: /ws')
        ..close();
      return;
    }
    try {
      final socket = await WebSocketTransformer.upgrade(request);
      socket.pingInterval = const Duration(seconds: 12);
      final connection = _IoLanConnection(
        'lan-${_nextConnectionId++}',
        socket,
        onClosed: (closed) => _openConnections.remove(closed),
      );
      _openConnections.add(connection);
      _connections.add(connection);
    } on WebSocketException {
      await request.response.close();
    }
  }

  @override
  Future<void> close() async {
    final connections = _openConnections.toList();
    _openConnections.clear();
    for (final connection in connections) {
      await connection.close(
        code: WebSocketStatus.goingAway,
        reason: 'Хост бөлмені жапты',
      );
    }
    await _server?.close(force: true);
    _server = null;
    await _connections.close();
  }
}

class _IoLanConnection implements LanServerConnection {
  _IoLanConnection(this.id, this._socket, {required this.onClosed}) {
    _subscription = _socket.listen(
      _handleData,
      onDone: _finish,
      onError: (_) => _finish(),
      cancelOnError: true,
    );
  }

  @override
  final String id;
  final WebSocket _socket;
  final void Function(_IoLanConnection connection) onClosed;
  final StreamController<Map<String, dynamic>> _messages =
      StreamController<Map<String, dynamic>>();
  late final StreamSubscription<dynamic> _subscription;
  bool _closed = false;

  @override
  Stream<Map<String, dynamic>> get messages => _messages.stream;

  void _handleData(dynamic data) {
    if (data is! String) return;
    try {
      final decoded = jsonDecode(data);
      if (decoded is Map) {
        _messages.add(decoded.cast<String, dynamic>());
      }
    } on FormatException {
      send({'type': 'error', 'message': 'Жарамсыз LAN хабарламасы'});
    }
  }

  void _finish() {
    if (_closed) return;
    _closed = true;
    onClosed(this);
    unawaited(_messages.close());
  }

  @override
  void send(Map<String, dynamic> message) {
    if (_closed || _socket.readyState != WebSocket.open) return;
    _socket.add(jsonEncode(message));
  }

  @override
  Future<void> close({int? code, String? reason}) async {
    if (_closed) return;
    _closed = true;
    await _subscription.cancel();
    await _socket.close(code, reason);
    onClosed(this);
    await _messages.close();
  }
}
