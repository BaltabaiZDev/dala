import 'package:shared_preferences/shared_preferences.dart';
import '../lan/lan_address.dart';

class LanSettingsRepository {
  Future<int> loadPort() async {
    final prefs = await SharedPreferences.getInstance();
    final port = prefs.getInt('dala.lan.port') ?? lanDefaultPort;
    return port >= 1 && port <= 65535 ? port : lanDefaultPort;
  }

  Future<void> savePort(int port) async {
    if (port < 1 || port > 65535) throw ArgumentError.value(port, 'port');
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('dala.lan.port', port);
  }
}
