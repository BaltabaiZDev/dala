import 'package:flutter_test/flutter_test.dart';
import 'package:antiyoy_self/src/game/game_controller.dart';
import 'package:antiyoy_self/src/game/map_generator.dart';
import 'package:antiyoy_self/src/game/models.dart';
import 'package:antiyoy_self/src/modding/game_mod.dart';
import 'package:antiyoy_self/src/lan/lan_room_host.dart';
import 'package:antiyoy_self/src/lan/lan_room_client.dart';
import 'package:antiyoy_self/src/persistence/save_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('LAN transfers host mod; local mismatching rules cannot bind', () async {
    final base = await GameMod.loadDefault();
    final raw = base.toJson()
      ..['id'] = 'lan_mod'
      ..['name'] = 'LAN мод';
    (raw['rules'] as Map)['unitPricePerLevel'] = 25;
    final mod = GameMod.fromJson(raw);
    const config = GameConfig(
      mapSize: MapSize.small,
      playerCount: 2,
      humanCount: 2,
      seed: 102,
    );
    final host = LanRoomHost(
      config: config,
      hostName: 'Host',
      mod: mod,
      mapName: 'Тест карта',
    );
    final client = LanRoomClient();
    final controller = GameController(
      mod: mod,
      state: MapGenerator(mod).generate(config),
      saves: SaveRepository(),
      autosaveEnabled: false,
      authoritativeSimulation: false,
    );
    addTearDown(() async {
      await client.close();
      await host.close();
      controller.dispose();
      client.dispose();
      host.dispose();
    });
    await host.start(port: 0);
    await client.connect(
      address: '127.0.0.1:${host.binding!.port}',
      roomCode: host.roomCode,
      name: 'Guest',
    );
    Future<void> until(bool Function() ready) async {
      final watch = Stopwatch()..start();
      while (!ready()) {
        if (watch.elapsedMilliseconds > 5000) {
          fail('LAN timeout: ${client.error}');
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }

    await until(() => host.readyToStart && client.lobby != null);
    expect(client.lobby!.modded, isTrue);
    expect(client.lobby!.mapName, 'Тест карта');
    host.startGame(controller);
    await until(() => client.hasStarted);
    expect(client.sessionMod!.fingerprint, mod.fingerprint);
    expect(client.sessionMod!.rules.unitPricePerLevel, 25);
    final wrong = GameController(
      mod: base,
      state: GameState.fromJson(client.stateJson!),
      saves: SaveRepository(),
      autosaveEnabled: false,
      authoritativeSimulation: false,
    );
    expect(() => client.bindController(wrong), throwsStateError);
    wrong.dispose();
    final guest = GameController(
      mod: client.sessionMod!,
      state: GameState.fromJson(client.stateJson!),
      saves: SaveRepository(),
      autosaveEnabled: false,
      authoritativeSimulation: false,
    );
    client.bindController(guest);
    expect(
      guest.mod.rules.unitPricePerLevel,
      controller.mod.rules.unitPricePerLevel,
    );
    client.unbindController(guest);
    guest.dispose();
  });
}
