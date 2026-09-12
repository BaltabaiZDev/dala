import 'dart:async';

class LanServerBinding {
  const LanServerBinding({required this.addresses, required this.port});

  final List<String> addresses;
  final int port;
}

abstract interface class LanServerConnection {
  String get id;

  Stream<Map<String, dynamic>> get messages;

  void send(Map<String, dynamic> message);

  Future<void> close({int? code, String? reason});
}

abstract interface class LanServerBackend {
  Stream<LanServerConnection> get connections;

  Future<LanServerBinding> start({int port = 7358});

  Future<void> close();
}
