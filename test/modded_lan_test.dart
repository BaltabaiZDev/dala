import 'package:flutter_test/flutter_test.dart';
import 'package:antiyoy_self/src/game/game_controller.dart';
import 'package:antiyoy_self/src/game/map_generator.dart';
import 'package:antiyoy_self/src/game/models.dart';
import 'package:antiyoy_self/src/modding/game_mod.dart';
import 'package:antiyoy_self/src/lan/lan_room_host.dart';
import 'package:antiyoy_self/src/lan/lan_room_client.dart';
import 'package:antiyoy_self/src/persistence/save_repository.dart';
import 'package:antiyoy_self/src/modding/mod_stack.dart';
import 'package:antiyoy_self/src/lan/lan_protocol.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'LAN refuses missing and edited mods before assigning a seat; accepts the whole stack',
    () async {
      final base = await GameMod.loadDefault();
      final a = GameMod.fromJson(
        base.toJson()
          ..['id'] = 'first'
          ..['name'] = 'First',
      );
      final b = GameMod.fromJson(
        base.toJson()
          ..['id'] = 'second'
          ..['name'] = 'Second',
      );
      final wrong = GameMod.fromJson(
        b.toJson()..['description'] = 'Edited same version',
      );
      final stack = ModStack.compose(base, [b, a]).mod;
      const config = GameConfig(
        mapSize: MapSize.small,
        playerCount: 2,
        humanCount: 2,
        seed: 103,
      );
      final host = LanRoomHost(config: config, hostName: 'Host', mod: stack);
      final clients = <LanRoomClient>[];
      final controller = GameController(
        mod: stack,
        state: MapGenerator(stack).generate(config),
        saves: SaveRepository(),
        autosaveEnabled: false,
        authoritativeSimulation: false,
      );
      addTearDown(() async {
        for (final client in clients) {
          await client.close();
          client.dispose();
        }
        await host.close();
        host.dispose();
        controller.dispose();
      });
      await host.start(port: 0);
      Future<void> until(bool Function() predicate) async {
        final watch = Stopwatch()..start();
        while (!predicate()) {
          if (watch.elapsedMilliseconds > 5000) fail('LAN handshake timeout');
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      }

      for (final installed in [
        <GameMod>[],
        [a],
        [a, wrong],
      ]) {
        final client = LanRoomClient(
          defaultMod: base,
          installedMods: installed,
        );
        clients.add(client);
        await client.connect(
          address: '127.0.0.1:${host.binding!.port}',
          roomCode: host.roomCode,
          name: 'Guest',
        );
        await until(() => client.status == LanConnectionStatus.closed);
        expect(client.seat, -1);
        expect(client.missingContent, isNotEmpty);
        expect(client.hasStarted, isFalse);
        expect(host.participants, hasLength(1));
      }
      // Installed order is irrelevant: the host's declared order is applied.
      final client = LanRoomClient(defaultMod: base, installedMods: [a, b]);
      clients.add(client);
      await client.connect(
        address: '127.0.0.1:${host.binding!.port}',
        roomCode: host.roomCode,
        name: 'Guest',
      );
      await until(() => host.readyToStart && client.lobby != null);
      expect(client.lobby!.requiredMods.map((ref) => ref.id), [
        'second',
        'first',
      ]);
      host.startGame(controller);
      await until(() => client.hasStarted);
      expect(client.sessionMod!.fingerprint, stack.fingerprint);
    },
  );
  test('LAN uses installed mod; local mismatching rules cannot bind', () async {
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
    final client = LanRoomClient(defaultMod: base, installedMods: [mod]);
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
