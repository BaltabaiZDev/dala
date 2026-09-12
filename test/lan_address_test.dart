import 'package:antiyoy_self/src/lan/lan_address.dart';
import 'package:antiyoy_self/src/lan/lan_room_client.dart';
import 'package:antiyoy_self/src/lan/lan_room_host.dart';
import 'package:antiyoy_self/src/lan/lan_server_api.dart';
import 'package:antiyoy_self/src/persistence/lan_settings_repository.dart';
import 'package:antiyoy_self/src/game/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('bare hosts use 7777; explicit and saved ports are preserved', () {
    for (final source in [
      '192.168.1.20',
      ' ws://192.168.1.20 ',
      'http://192.168.1.20/ws',
    ]) {
      expect(lanAddressUri(source).toString(), 'ws://192.168.1.20:7777/ws');
    }
    expect(lanAddressUri('192.168.1.20', defaultPort: 8888).port, 8888);
    expect(lanAddressUri('192.168.1.20:9999', defaultPort: 8888).port, 9999);
    expect(lanAddressUri('http://localhost:80').port, 80);
    expect(lanAddressUri('https://localhost:443').port, 443);
    expect(lanAddressUri('https://localhost').scheme, 'wss');
    expect(lanAddressUri('::1').host, '::1');
    expect(lanAddressUri('[::1]:8888').port, 8888);
    for (final invalid in [
      '',
      'some host',
      'ftp://host',
      'ws://host/other',
      'host:0',
      'host:65536',
      'host:abc',
      'ws://me@host',
    ]) {
      expect(
        () => lanAddressUri(invalid),
        throwsFormatException,
        reason: invalid,
      );
    }
  });

  test('Wi-Fi is primary, virtual interfaces and loopback are secondary', () {
    expect(
      rankedLanAddresses(const [
        LanInterfaceAddress('172.17.0.1', 'vEthernet (WSL)'),
        LanInterfaceAddress('127.0.0.1', 'loopback'),
        LanInterfaceAddress('10.0.0.5', 'tun0'),
        LanInterfaceAddress('192.168.0.8', 'Ethernet'),
        LanInterfaceAddress('192.168.1.20', 'wlan0'),
        LanInterfaceAddress('192.168.1.20', 'Wi-Fi'),
      ]),
      ['192.168.1.20', '192.168.0.8', '10.0.0.5', '172.17.0.1', '127.0.0.1'],
    );
    expect(rankedLanAddresses([]), ['127.0.0.1']);
  });

  test('port preference persists and invalid stored values recover', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = LanSettingsRepository();
    expect(await settings.loadPort(), 7777);
    await settings.savePort(8888);
    expect(await LanSettingsRepository().loadPort(), 8888);
    expect(() => settings.savePort(0), throwsArgumentError);
    SharedPreferences.setMockInitialValues({'dala.lan.port': 99999});
    expect(await settings.loadPort(), 7777);
  });

  test(
    'native host binds 7777, accepts bare IP, and never changes a busy port',
    () async {
      final host = LanRoomHost(
        config: const GameConfig(playerCount: 2, humanCount: 2),
        hostName: 'Host',
      );
      final second = LanRoomHost(config: host.config, hostName: 'Second');
      final client = LanRoomClient();
      addTearDown(() async {
        await client.close();
        await second.close();
        await host.close();
        client.dispose();
        second.dispose();
        host.dispose();
      });
      await host.start();
      expect(host.binding!.port, 7777);
      await expectLater(second.start(), throwsA(isA<LanPortUnavailable>()));
      await client.connect(
        address: '127.0.0.1',
        roomCode: host.roomCode,
        name: 'Guest',
      );
      final deadline = DateTime.now().add(const Duration(seconds: 4));
      while (client.seat < 0 && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(client.seat, 1, reason: client.error);
      expect(host.readyToStart, isTrue);
    },
  );
}
