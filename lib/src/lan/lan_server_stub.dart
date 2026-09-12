import 'dart:async';

import 'lan_server_api.dart';

const bool hostingSupported = false;

LanServerBackend createLanServerBackend() => _UnsupportedLanServer();

class _UnsupportedLanServer implements LanServerBackend {
  @override
  Stream<LanServerConnection> get connections => const Stream.empty();

  @override
  Future<LanServerBinding> start({int port = 7358}) => Future.error(
    UnsupportedError(
      'Браузер LAN портын аша алмайды. Бөлмені Windows/Android қолданбасынан ашыңыз.',
    ),
  );

  @override
  Future<void> close() async {}
}
