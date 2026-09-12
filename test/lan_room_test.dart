import 'dart:async';

import 'package:antiyoy_self/src/game/game_controller.dart';
import 'package:antiyoy_self/src/game/game_engine.dart';
import 'package:antiyoy_self/src/game/models.dart';
import 'package:antiyoy_self/src/lan/lan_room_client.dart';
import 'package:antiyoy_self/src/lan/lan_room_host.dart';
import 'package:antiyoy_self/src/lan/lan_protocol.dart';
import 'package:antiyoy_self/src/modding/game_mod.dart';
import 'package:antiyoy_self/src/persistence/save_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late GameMod mod;

  setUpAll(() async {
    mod = await GameMod.loadDefault();
  });

  test(
    'native LAN host owns state and accepts only current player commands',
    () async {
      const config = GameConfig(
        mapSize: MapSize.small,
        playerCount: 2,
        humanCount: 2,
        seed: 7358,
        diplomacy: true,
      );
      final host = LanRoomHost(
        config: config,
        hostName: 'Host',
        roomCode: '735800',
      );
      final client = LanRoomClient();
      GameController? hostController;
      GameController? clientController;
      addTearDown(() async {
        if (clientController != null) {
          client.unbindController(clientController);
        }
        await client.close();
        await host.close();
        clientController?.dispose();
        hostController?.dispose();
        client.dispose();
        host.dispose();
      });

      await host.start(port: 0);
      final port = host.binding!.port;
      await client.connect(
        address: '127.0.0.1:$port',
        roomCode: host.roomCode,
        name: 'Guest',
      );
      await _waitFor(
        'client lobby join',
        () => client.seat == 1 && host.readyToStart,
      );

      hostController = GameController(
        mod: mod,
        state: _twoPlayerState(config),
        saves: SaveRepository(),
        autosaveEnabled: false,
        localPlayer: 0,
        networkRole: GameNetworkRole.host,
      );
      host.startGame(hostController);
      await _waitFor(
        'initial game snapshot',
        () => client.hasStarted && client.stateJson != null,
      );
      expect(hostController.state.playerNames, ['Host', 'Guest']);
      final namedClientState = GameState.fromJson(client.stateJson!);
      expect(namedClientState.playerName(0), 'Host');
      expect(namedClientState.playerName(1), 'Guest');

      clientController = GameController(
        mod: mod,
        state: namedClientState,
        saves: SaveRepository(),
        autosaveEnabled: false,
        localPlayer: client.seat,
        networkRole: GameNetworkRole.client,
        authoritativeSimulation: false,
      );
      client.bindController(clientController);

      expect(
        clientController.sendDiplomacyMessage(other: 0, text: 'early'),
        isFalse,
      );
      expect(hostController.state.diplomacyMessages, isEmpty);
      expect(hostController.state.winner, isNull);
      expect(hostController.canControlCurrentTurn, isTrue);
      expect(hostController.interactionsLocked, isFalse);

      await hostController.finishTurn();
      expect(hostController.state.turn, 1);
      await _waitFor(
        'host turn reaches client (host=${hostController.state.turn}, revision=${host.revision}, clientRevision=${client.revision}, clientError=${client.error})',
        () => clientController!.state.turn == 1,
      );
      expect(clientController.isLocalHumanTurn, isTrue);

      final revisionBeforeSelection = host.revision;
      clientController.tapTile(2);
      expect(clientController.selectedTile, 2);
      expect(client.busy, isFalse);
      expect(host.revision, revisionBeforeSelection);

      expect(
        clientController.sendDiplomacyMessage(other: 0, text: 'LAN'),
        isTrue,
      );
      await _waitFor(
        'client diplomacy command reaches host',
        () => hostController!.state.diplomacyMessages.any(
          (message) =>
              message.from == 1 && message.to == 0 && message.text == 'LAN',
        ),
      );
      // Host execution precedes delivery of its acknowledgement. Wait for
      // that delivery before issuing another command, as the client UI does.
      await _waitFor(
        'client receives diplomacy acknowledgement',
        () =>
            !client.busy &&
            clientController!.state.diplomacyMessages.any(
              (message) =>
                  message.from == 1 && message.to == 0 && message.text == 'LAN',
            ),
      );

      expect(
        clientController.canUndo,
        isTrue,
        reason: 'Refreshing LAN status must retain the host undo permission',
      );
      expect(
        hostController.canUndo,
        isFalse,
        reason: 'The host cannot undo the guest turn from its own controls',
      );
      clientController.undo();
      expect(client.busy, isTrue);
      expect(clientController.canUndo, isFalse);
      await _waitFor(
        'guest undoes diplomacy message',
        () => !client.busy && clientController!.state.diplomacyMessages.isEmpty,
      );
      expect(clientController.canUndo, isFalse);

      final money = clientController.state.provinces.last.money;
      for (var strength = 1; strength <= 2; strength++) {
        clientController.clearSelection();
        clientController.tapTile(2);
        clientController.setTool(PlayerTool.unit1);
        clientController.tapTile(3);
        await _waitFor(
          'guest recruits strength $strength',
          () =>
              !client.busy &&
              clientController!.state.hexes[3].unit?.strength == strength,
        );
        expect(clientController.canUndo, isTrue);
      }

      // A rejected stale command forces a full host snapshot. The availability
      // comes from that snapshot even if the previous local UI cache was lost.
      client.latestUi = {'canUndo': false};
      client.revision--;
      expect(
        await client.sendCommandAsync(
          'undo',
          {},
          clientController.captureNetworkUiState(),
        ),
        isFalse,
      );
      expect(clientController.state.hexes[3].unit!.strength, 2);
      expect(clientController.canUndo, isTrue);

      clientController.undo();
      clientController.undo(); // Ignore an extra tap while awaiting the host.
      await _waitFor(
        'first recruitment undo acknowledged',
        () =>
            !client.busy &&
            clientController!.state.hexes[3].unit?.strength == 1,
      );
      expect(clientController.canUndo, isTrue);
      expect(
        clientController.state.provinces.last.money,
        money - mod.rules.unitPricePerLevel,
      );
      clientController.undo();
      await _waitFor(
        'second recruitment undo acknowledged',
        () => !client.busy && clientController!.state.hexes[3].unit == null,
      );
      expect(clientController.state.provinces.last.money, money);
      expect(clientController.canUndo, isFalse);
      expect(hostController.state.toJson(), clientController.state.toJson());

      // Leave history behind, then verify that another round cannot reuse it.
      clientController.clearSelection();
      clientController.tapTile(2);
      clientController.setTool(PlayerTool.unit1);
      clientController.tapTile(3);
      await _waitFor(
        'guest has one new undo entry',
        () => !client.busy && clientController!.state.hexes[3].unit != null,
      );
      expect(clientController.canUndo, isTrue);

      await clientController.finishTurn();
      await _waitFor(
        'client end turn reaches host',
        () => hostController!.state.turn == 0,
      );
      await _waitFor(
        'final host snapshot reaches client',
        () => clientController!.state.turn == 0,
      );
      expect(hostController.state.toJson(), clientController.state.toJson());
      expect(clientController.canUndo, isFalse);
      hostController.clearSelection();
      hostController.tapTile(0);
      hostController.setTool(PlayerTool.unit1);
      hostController.tapTile(1);
      await _waitFor(
        'host purchase reaches guest',
        () => clientController!.state.hexes[1].unit != null,
      );
      expect(hostController.canUndo, isTrue);
      expect(clientController.canUndo, isFalse);
      expect(
        await client.sendCommandAsync('undo', {}, {'canUndo': true}),
        isFalse,
      );
      expect(hostController.state.hexes[1].unit, isNotNull);
      hostController.undo();
      await _waitFor(
        'host undo reaches guest',
        () => clientController!.state.hexes[1].unit == null,
      );
      await hostController.finishTurn();
      await _waitFor(
        'next guest turn',
        () => clientController!.state.turn == 1,
      );
      expect(clientController.canUndo, isFalse);
      expect(clientController.captureNetworkUiState()['canUndo'], isFalse);
      await client.close(notifyHost: false);
      await _waitFor(
        'disconnected turn skipped',
        () => hostController!.state.turn == 0,
      );
      await client.connect(
        address: '127.0.0.1:$port',
        roomCode: host.roomCode,
        name: 'Guest',
      );
      await _waitFor(
        'guest reconnects to snapshot',
        () => client.status == LanConnectionStatus.playing,
      );
      expect(clientController.canUndo, isFalse);
      expect(hostController.state.toJson(), clientController.state.toJson());
    },
  );

  test('departed faction keeps abandoned land and naval objects', () {
    const config = GameConfig(playerCount: 2, humanCount: 2, seed: 7362);
    final state = _twoPlayerState(config);
    state.hexes[3].unit = GameUnit(strength: 2, owner: 1, homeProvinceId: 2);
    state.waterCells.addAll([
      WaterCell(
        index: 0,
        tiles: const [],
        boat: GameBoat(
          id: 1,
          owner: 1,
          level: 2,
          homeProvinceId: 2,
          cargo: [GameUnit(strength: 1, owner: 1, homeProvinceId: 2)],
        ),
      ),
      WaterCell(
        index: 1,
        tiles: const [],
        seaFort: SeaFort(id: 2, owner: 1, homeProvinceId: 2),
      ),
    ]);
    final engine = GameEngine(mod: mod, state: state);

    expect(engine.neutralizeDepartedPlayer(1), isTrue);
    expect(state.hexes[2].object, TileObject.town);
    expect(state.hexes[3].unit, isNotNull);
    expect(state.hexes[3].unit!.owner, -1);
    expect(state.waterCells[0].boat, isNotNull);
    expect(state.waterCells[0].boat!.owner, -1);
    expect(state.waterCells[0].boat!.cargo.single.owner, -1);
    expect(state.waterCells[1].seaFort, isNotNull);
    expect(state.waterCells[1].seaFort!.owner, -1);
  });

  test('host close is terminal and never enters the reconnect loop', () async {
    const config = GameConfig(
      mapSize: MapSize.small,
      playerCount: 2,
      humanCount: 2,
      seed: 7359,
    );
    final host = LanRoomHost(
      config: config,
      hostName: 'Host',
      roomCode: '735900',
    );
    final client = LanRoomClient();
    addTearDown(() async {
      await client.close(notifyHost: false);
      await host.close();
      client.dispose();
      host.dispose();
    });

    await host.start(port: 0);
    await client.connect(
      address: '127.0.0.1:${host.binding!.port}',
      roomCode: host.roomCode,
      name: 'Guest',
    );
    await _waitFor('client joined before close', () => client.seat == 1);
    await host.close();
    await _waitFor(
      'client receives terminal room close',
      () => client.closedByHost && client.status == LanConnectionStatus.closed,
    );
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    expect(client.status, LanConnectionStatus.closed);
    expect(client.error, contains('Хост'));
  });

  test(
    'intentional leave neutralizes land but keeps its board objects',
    () async {
      const config = GameConfig(
        mapSize: MapSize.small,
        playerCount: 2,
        humanCount: 2,
        seed: 7360,
      );
      final host = LanRoomHost(
        config: config,
        hostName: 'Host',
        roomCode: '736000',
      );
      final client = LanRoomClient();
      late final GameController hostController;
      addTearDown(() async {
        await client.close(notifyHost: false);
        await host.close();
        hostController.dispose();
        client.dispose();
        host.dispose();
      });

      await host.start(port: 0);
      await client.connect(
        address: '127.0.0.1:${host.binding!.port}',
        roomCode: host.roomCode,
        name: 'Guest',
      );
      await _waitFor('guest joins neutralize room', () => host.readyToStart);
      final state = _twoPlayerState(config);
      state.hexes[3].unit = GameUnit(strength: 2);
      hostController = GameController(
        mod: mod,
        state: state,
        saves: SaveRepository(),
        autosaveEnabled: false,
        localPlayer: 0,
        networkRole: GameNetworkRole.host,
      );
      host.startGame(hostController);
      await _waitFor('leave game started', () => client.hasStarted);

      await client.close();
      await _waitFor(
        'departed faction becomes neutral',
        () => hostController.state.provinces.every((item) => item.owner != 1),
      );
      expect(hostController.state.hexes[2].owner, -1);
      expect(hostController.state.hexes[2].object, TileObject.town);
      expect(hostController.state.hexes[3].owner, -1);
      expect(hostController.state.hexes[3].unit, isNotNull);
      expect(hostController.state.hexes[3].unit!.owner, -1);
      expect(host.participants.where((item) => item.seat == 1), isEmpty);
    },
  );

  test(
    'host timer publishes the balanced minimum and expires authoritatively',
    () async {
      const config = GameConfig(
        mapSize: MapSize.small,
        playerCount: 2,
        humanCount: 2,
        seed: 7361,
      );
      final host = LanRoomHost(
        config: config,
        hostName: 'Host',
        roomCode: '736100',
        turnTimerEnabled: true,
      );
      final client = LanRoomClient();
      late final GameController hostController;
      addTearDown(() async {
        await client.close(notifyHost: false);
        await host.close();
        hostController.dispose();
        client.dispose();
        host.dispose();
      });

      await host.start(port: 0);
      await client.connect(
        address: '127.0.0.1:${host.binding!.port}',
        roomCode: host.roomCode,
        name: 'Guest',
      );
      await _waitFor('timer guest joins', () => host.readyToStart);
      hostController = GameController(
        mod: mod,
        state: _twoPlayerState(config),
        saves: SaveRepository(),
        autosaveEnabled: false,
        localPlayer: 0,
        networkRole: GameNetworkRole.host,
      );
      host.startGame(hostController);
      await _waitFor(
        'client receives clock',
        () =>
            client.turnClock.enabled &&
            client.turnClock.deadlineEpochMs != null,
      );
      expect(host.turnDurationSeconds, 60);
      expect(client.turnClock.durationSeconds, 60);

      await host.expireCurrentTurnForTesting();
      await _waitFor(
        'expired host turn reaches guest',
        () => hostController.state.turn == 1,
      );
      expect(hostController.state.turn, 1);
    },
  );
}

GameState _twoPlayerState(GameConfig config) => GameState(
  config: config,
  modId: 'classic_steppe',
  width: 4,
  height: 1,
  hexes: [
    HexTile(
      index: 0,
      q: 0,
      r: 0,
      active: true,
      owner: 0,
      neighbors: const [1],
      object: TileObject.town,
    ),
    HexTile(
      index: 1,
      q: 1,
      r: 0,
      active: true,
      owner: 0,
      neighbors: const [0, 2],
    ),
    HexTile(
      index: 2,
      q: 2,
      r: 0,
      active: true,
      owner: 1,
      neighbors: const [1, 3],
      object: TileObject.town,
    ),
    HexTile(index: 3, q: 3, r: 0, active: true, owner: 1, neighbors: const [2]),
  ],
  provinces: [
    Province(id: 1, owner: 0, tiles: const [0, 1], money: 50, capital: 0),
    Province(id: 2, owner: 1, tiles: const [2, 3], money: 50, capital: 2),
  ],
  turn: 0,
  round: 0,
  rngState: 7358,
  nextProvinceId: 3,
);

Future<void> _waitFor(String label, bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 8));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('LAN test condition timed out: $label');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}
