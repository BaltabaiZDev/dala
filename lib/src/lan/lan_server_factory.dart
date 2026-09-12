import 'lan_server_api.dart';
import 'lan_server_stub.dart'
    if (dart.library.io) 'lan_server_io.dart'
    as platform;

bool get lanHostingSupported => platform.hostingSupported;

LanServerBackend createLanServerBackend() => platform.createLanServerBackend();
