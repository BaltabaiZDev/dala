import 'package:antiyoy_self/src/game/models.dart';
import 'package:antiyoy_self/src/lan/lan_protocol.dart';
import 'package:antiyoy_self/src/lan/lan_state_patch.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('LAN names and room codes are normalized deterministically', () {
    expect(sanitizeLanPlayerName('  A\n   B  '), 'A B');
    expect(sanitizeLanPlayerName(''), 'Ойыншы');
    expect(normalizeRoomCode('room 42'), '000042');
    expect(normalizeRoomCode('12345678'), '345678');
  });

  test('lobby is ready only when every human seat is connected', () {
    const config = GameConfig(playerCount: 3, humanCount: 3);
    final waiting = LanLobbyState(
      roomCode: '123456',
      config: config,
      participants: const [
        LanParticipant(
          id: 'host',
          name: 'Host',
          seat: 0,
          connected: true,
          isHost: true,
        ),
        LanParticipant(
          id: 'two',
          name: 'Two',
          seat: 1,
          connected: true,
          isHost: false,
        ),
      ],
      started: false,
    );
    expect(waiting.readyToStart, isFalse);

    final ready = LanLobbyState(
      roomCode: waiting.roomCode,
      config: config,
      participants: [
        ...waiting.participants,
        const LanParticipant(
          id: 'three',
          name: 'Three',
          seat: 2,
          connected: true,
          isHost: false,
        ),
      ],
      started: false,
    );
    expect(ready.readyToStart, isTrue);
    expect(
      LanLobbyState.fromJson(ready.toJson()).participants.length,
      ready.participants.length,
    );
  });

  test('network commands preserve revision, arguments and UI context', () {
    const ui = LanUiState(
      selectedTile: 7,
      selectedWaterCell: 4,
      selectedCargoIndex: 1,
      toolIndex: 8,
      hint: 'test',
      canUndo: true,
    );
    const command = LanGameCommand(
      id: 11,
      baseRevision: 9,
      action: 'tapWaterCell',
      arguments: {'index': 4},
      ui: ui,
    );
    final restored = LanGameCommand.fromJson(command.toJson());
    expect(restored.id, 11);
    expect(restored.baseRevision, 9);
    expect(restored.action, 'tapWaterCell');
    expect(restored.arguments['index'], 4);
    expect(restored.ui.toolIndex, 8);
  });

  test('turn timer minimums scale from one to five minutes by map size', () {
    expect(MapSize.values.map(lanMinimumTurnSeconds), const [
      60,
      120,
      180,
      240,
      300,
    ]);
    expect(lanTurnDurationOptions(MapSize.giant), const [
      300,
      360,
      420,
      480,
      540,
      600,
    ]);
  });

  test('compact state patch changes only dirty cells and scalar fields', () {
    final state = GameState(
      config: const GameConfig(playerCount: 2, humanCount: 2),
      modId: 'classic',
      width: 2,
      height: 1,
      hexes: [
        HexTile(
          index: 0,
          q: 0,
          r: 0,
          active: true,
          owner: 0,
          neighbors: const [1],
        ),
        HexTile(
          index: 1,
          q: 1,
          r: 0,
          active: true,
          owner: 1,
          neighbors: const [0],
        ),
      ],
      provinces: [
        Province(id: 1, owner: 0, tiles: const [0], money: 10, capital: 0),
        Province(id: 2, owner: 1, tiles: const [1], money: 10, capital: 1),
      ],
      turn: 0,
      round: 0,
      rngState: 1,
      nextProvinceId: 3,
    );
    final retained = state.toJson();
    final builder = LanStatePatchBuilder()..prime(state);
    state.hexes[1].owner = 0;
    state.turn = 1;
    final patch = builder.build(state)!;

    expect((patch['hexes'] as List), hasLength(1));
    expect((patch['hexes'] as List).single['index'], 1);
    expect((patch['scalars'] as Map)['turn'], 1);
    applyLanPatchToJson(retained, patch);
    expect((retained['hexes'] as List)[1]['owner'], 0);
    expect(retained['turn'], 1);
  });
}
