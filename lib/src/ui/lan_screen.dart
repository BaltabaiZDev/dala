import 'dala_theme.dart';
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../game/game_controller.dart';
import '../game/map_generator.dart';
import '../game/models.dart';
import '../lan/lan_protocol.dart';
import '../lan/lan_room_client.dart';
import '../lan/lan_room_host.dart';
import '../lan/lan_server_factory.dart';
import '../modding/game_mod.dart';
import '../modding/content_library.dart';
import '../persistence/save_repository.dart';
import '../persistence/settings_repository.dart';
import 'antiyoy_background.dart';
import 'antiyoy_loading.dart';
import 'game_screen.dart';
import 'top_snack_bar.dart';

typedef LanConfigPicker = Future<GameConfig?> Function(BuildContext context);

class LanScreen extends StatefulWidget {
  const LanScreen({
    required this.mod,
    required this.saves,
    required this.pickConfig,
    this.defaultMod,
    this.library,
    super.key,
  });

  final GameMod mod;
  final GameMod? defaultMod;
  final ContentLibrary? library;
  final SaveRepository saves;
  final LanConfigPicker pickConfig;

  @override
  State<LanScreen> createState() => _LanScreenState();
}

class _LanScreenState extends State<LanScreen> {
  final TextEditingController _name = TextEditingController(text: 'Ойыншы');
  final TextEditingController _address = TextEditingController();
  final TextEditingController _roomCode = TextEditingController();
  bool _working = false;
  late bool _useMod;
  GameMod? _selectedMod;
  InstalledMap? _selectedMap;
  GameMod get _roomMod =>
      _useMod ? _selectedMod ?? widget.mod : widget.defaultMod ?? widget.mod;

  @override
  void initState() {
    super.initState();
    _useMod = widget.mod.id != 'classic_steppe';
    final browserHost = Uri.base.host;
    _address.text = browserHost.isNotEmpty && browserHost != 'localhost'
        ? '$browserHost:$lanDefaultPort'
        : '127.0.0.1:$lanDefaultPort';
  }

  @override
  void dispose() {
    _name.dispose();
    _address.dispose();
    _roomCode.dispose();
    super.dispose();
  }

  Future<void> _host() async {
    if (_working) return;
    if (!lanHostingSupported) {
      showTopSnackBar(
        context,
        'Браузер бөлме аша алмайды. Хостты Windows немесе Android қолданбасынан ашыңыз.',
      );
      return;
    }
    final roomMod = _roomMod;
    GameState? mapState;
    try {
      mapState = _selectedMap?.map.createState(roomMod, multiplayer: true);
    } on Object catch (error) {
      showTopSnackBar(context, 'Карта ашылмады: $error');
      return;
    }
    final selected = mapState?.config ?? await widget.pickConfig(context);
    if (!mounted || selected == null) return;
    final configJson = selected.toJson();
    configJson['humanCount'] = math.max(2, selected.humanCount);
    final config = GameConfig.fromJson(configJson);
    final host = LanRoomHost(
      config: config,
      hostName: _name.text,
      mod: roomMod,
      mapName: _selectedMap?.map.name,
    );
    setState(() => _working = true);
    try {
      await runWithAntiyoyLoader(
        context,
        semanticsLabel: 'LAN бөлмесі ашылуда',
        task: host.start,
      );
      if (!mounted) {
        await host.close();
        return;
      }
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => _LanHostLobby(
            host: host,
            mod: roomMod,
            saves: widget.saves,
            initialState: mapState,
          ),
        ),
      );
    } catch (exception) {
      if (mounted) {
        showTopSnackBar(context, 'LAN бөлмесі ашылмады: $exception');
      }
      await host.close();
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _join() async {
    if (_working) return;
    final code = _roomCode.text.replaceAll(RegExp('[^0-9]'), '');
    if (code.length != 6) {
      showTopSnackBar(context, '6 саннан тұратын бөлме кодын жазыңыз.');
      return;
    }
    final client = LanRoomClient();
    setState(() => _working = true);
    try {
      await client.connect(
        address: _address.text,
        roomCode: code,
        name: _name.text,
      );
      if (!mounted) {
        await client.close();
        return;
      }
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => _LanClientLobby(
            client: client,
            mod: widget.mod,
            saves: widget.saves,
          ),
        ),
      );
      if (mounted && client.closedByHost && client.error != null) {
        showTopSnackBar(context, client.error!);
      }
    } finally {
      await client.close();
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) => _LanScaffold(
    title: 'LAN ойыны',
    onBack: () => Navigator.pop(context),
    child: Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(28, 96, 28, 30),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 430),
          child: _LanPanel(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _LanField(
                  key: const ValueKey('lan-player-name'),
                  controller: _name,
                  label: 'Атыңыз',
                ),
                const SizedBox(height: 18),
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: false, label: Text('Кәдімгі')),
                    ButtonSegment(value: true, label: Text('Модпен')),
                  ],
                  selected: {_useMod},
                  onSelectionChanged: _working
                      ? null
                      : (value) => setState(() {
                          _useMod = value.single;
                          _selectedMap = null;
                        }),
                ),
                if (_useMod) ...[
                  const SizedBox(height: 10),
                  if (widget.library?.mods.isNotEmpty ?? false)
                    DropdownButtonFormField<GameMod>(
                      initialValue: _roomMod.id == 'classic_steppe'
                          ? null
                          : _roomMod,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Бөлме моды',
                      ),
                      items: [
                        for (final entry in widget.library!.mods)
                          DropdownMenuItem(
                            value: entry.mod,
                            child: Text(
                              entry.mod.name,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: _working
                          ? null
                          : (value) => setState(() {
                              _selectedMod = value;
                              _selectedMap = null;
                            }),
                    )
                  else
                    const Text(
                      'Алдымен «Модтар мен карталар» бөлімінде мод орнатыңыз.',
                    ),
                ],
                const SizedBox(height: 10),
                DropdownButtonFormField<InstalledMap?>(
                  key: ValueKey((_roomMod.fingerprint, _useMod)),
                  initialValue: _selectedMap,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Карта'),
                  items: [
                    const DropdownMenuItem(
                      value: null,
                      child: Text('Кездейсоқ карта'),
                    ),
                    for (final entry
                        in widget.library?.maps ?? <InstalledMap>[])
                      if (widget.library!.modForMap(entry)?.fingerprint ==
                          _roomMod.fingerprint)
                        DropdownMenuItem(
                          value: entry,
                          child: Text(
                            entry.map.name,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                  ],
                  onChanged: _working
                      ? null
                      : (value) => setState(() => _selectedMap = value),
                ),
                const SizedBox(height: 18),
                _LanActionBand(
                  key: const ValueKey('lan-host-button'),
                  label: 'Бөлме ашу',
                  color: DalaTheme.green,
                  enabled:
                      !_working &&
                      (!_useMod || _roomMod.id != 'classic_steppe'),
                  onTap: _host,
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 18),
                  child: Text(
                    'немесе бөлмеге кіріңіз',
                    style: TextStyle(fontSize: 15, color: Colors.black54),
                  ),
                ),
                _LanField(
                  key: const ValueKey('lan-address'),
                  controller: _address,
                  label: 'Хост IP · мысалы 192.168.1.20:7358',
                  keyboardType: TextInputType.url,
                ),
                const SizedBox(height: 10),
                _LanField(
                  key: const ValueKey('lan-room-code'),
                  controller: _roomCode,
                  label: '6 сандық бөлме коды',
                  keyboardType: TextInputType.number,
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(6),
                  ],
                ),
                const SizedBox(height: 16),
                _LanActionBand(
                  key: const ValueKey('lan-join-button'),
                  label: _working ? 'Қосылуда…' : 'Бөлмеге кіру',
                  color: DalaTheme.blue,
                  enabled: !_working,
                  onTap: _join,
                ),
                const SizedBox(height: 16),
                const Text(
                  'Барлық құрылғы бір Wi‑Fi немесе жергілікті желіде болуы керек. '
                  'Хост ойын күйін, AI жүрістерін, сақтауды және бөлме орындарын басқарады.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, height: 1.25),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class _LanHostLobby extends StatefulWidget {
  const _LanHostLobby({
    required this.host,
    required this.mod,
    required this.saves,
    this.initialState,
  });

  final LanRoomHost host;
  final GameMod mod;
  final SaveRepository saves;
  final GameState? initialState;

  @override
  State<_LanHostLobby> createState() => _LanHostLobbyState();
}

class _LanHostLobbyState extends State<_LanHostLobby> {
  bool _starting = false;

  @override
  void dispose() {
    unawaited(widget.host.close());
    super.dispose();
  }

  Future<void> _startGame() async {
    if (_starting || !widget.host.readyToStart) return;
    setState(() => _starting = true);
    final settings = await const SettingsRepository().load();
    if (!mounted) return;
    final initialState = await runWithAntiyoyLoader(
      context,
      semanticsLabel: 'LAN картасы жасалуда',
      task: () async => widget.initialState == null
          ? await generateMapAsync(widget.mod, widget.host.config)
          : GameState.fromJson(widget.initialState!.toJson()),
    );
    if (!mounted) return;
    final entrySnapshot = GameState.fromJson(initialState.toJson());
    var activeState = initialState;
    var first = true;
    while (mounted) {
      final controller = GameController(
        mod: widget.mod,
        state: activeState,
        saves: widget.saves,
        autosaveEnabled: settings.autosave,
        confirmEndTurn: true,
        leftHanded: settings.leftHanded,
        sensitivity: settings.sensitivity,
        localPlayer: 0,
        networkRole: GameNetworkRole.host,
      );
      if (first) {
        widget.host.startGame(controller);
        first = false;
      } else {
        widget.host.restartGame(controller);
      }
      final result = await Navigator.of(context).push<GameScreenExit>(
        MaterialPageRoute<GameScreenExit>(
          builder: (_) =>
              GameScreen(controller: controller, disposeController: false),
        ),
      );
      if (result != GameScreenExit.restart) {
        await widget.host.close();
        controller.dispose();
        if (mounted) Navigator.pop(context);
        return;
      }
      activeState = GameState.fromJson(entrySnapshot.toJson());
      widget.host.detachGameController(controller);
      controller.dispose();
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.host,
    builder: (context, _) {
      final host = widget.host;
      return _LanScaffold(
        title: 'LAN · Хост',
        onBack: () => Navigator.pop(context),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 92, 24, 28),
          children: [
            _LanPanel(
              child: Column(
                children: [
                  Text(
                    '${host.lobby.modded ? 'Модпен' : 'Кәдімгі'} · ${host.lobby.modName}',
                  ),
                  if (host.mapName != null) Text('Карта: ${host.mapName}'),
                  const Text('Бөлме коды', style: TextStyle(fontSize: 15)),
                  SelectableText(
                    host.roomCode,
                    key: const ValueKey('lan-host-room-code'),
                    style: const TextStyle(
                      fontSize: 42,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 6,
                    ),
                  ),
                  const SizedBox(height: 10),
                  for (final address in host.joinAddresses)
                    InkWell(
                      onTap: () {
                        Clipboard.setData(ClipboardData(text: address));
                        showTopSnackBar(context, 'IP көшірілді: $address');
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 5),
                        child: Text(
                          address,
                          style: const TextStyle(
                            fontSize: 18,
                            decoration: TextDecoration.underline,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            _LanPanel(
              child: Column(
                children: [
                  const Text(
                    'Ойыншылар',
                    style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 8),
                  for (var seat = 0; seat < host.config.humanCount; seat++)
                    _HostSeatRow(
                      seat: seat,
                      color:
                          widget.mod.palette[seat % widget.mod.palette.length],
                      participant: host.participants
                          .where((participant) => participant.seat == seat)
                          .firstOrNull,
                      maxSeats: host.config.humanCount,
                      onMove: host.moveParticipant,
                      onKick: host.kick,
                    ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            _LanPanel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Ход таймері',
                          style: TextStyle(
                            fontSize: 21,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      Switch(
                        key: const ValueKey('lan-turn-timer-toggle'),
                        value: host.turnTimerEnabled,
                        activeTrackColor: DalaTheme.green,
                        onChanged: host.setTurnTimerEnabled,
                      ),
                    ],
                  ),
                  Text(
                    'Бұл карта үшін минимум: '
                    '${host.minimumTurnDurationSeconds ~/ 60} мин',
                    style: const TextStyle(fontSize: 14, color: Colors.black54),
                  ),
                  if (host.turnTimerEnabled) ...[
                    const SizedBox(height: 10),
                    DropdownButtonFormField<int>(
                      key: const ValueKey('lan-turn-duration'),
                      initialValue: host.turnDurationSeconds,
                      decoration: const InputDecoration(
                        labelText: 'Әр ойыншыға берілетін уақыт',
                        filled: true,
                        fillColor: Colors.white70,
                        border: OutlineInputBorder(),
                      ),
                      items: [
                        for (final seconds in lanTurnDurationOptions(
                          host.config.mapSize,
                        ))
                          DropdownMenuItem<int>(
                            value: seconds,
                            child: Text('${seconds ~/ 60} минут'),
                          ),
                      ],
                      onChanged: (value) {
                        if (value != null) {
                          host.setTurnDurationSeconds(value);
                        }
                      },
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 16),
            _LanActionBand(
              key: const ValueKey('lan-start-game'),
              label: _starting
                  ? 'Карта жасалуда…'
                  : host.readyToStart
                  ? 'Ойынды бастау'
                  : 'Барлық орынның толуын күтіңіз',
              color: DalaTheme.green,
              enabled: !_starting && host.readyToStart,
              onTap: _startGame,
            ),
          ],
        ),
      );
    },
  );
}

class _LanClientLobby extends StatefulWidget {
  const _LanClientLobby({
    required this.client,
    required this.mod,
    required this.saves,
  });

  final LanRoomClient client;
  final GameMod mod;
  final SaveRepository saves;

  @override
  State<_LanClientLobby> createState() => _LanClientLobbyState();
}

class _LanClientLobbyState extends State<_LanClientLobby> {
  bool _openingGame = false;
  bool _roomClosureHandled = false;

  @override
  void initState() {
    super.initState();
    widget.client.addListener(_changed);
    _changed();
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    if (widget.client.closedByHost && !_roomClosureHandled) {
      _roomClosureHandled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_openingGame) {
          Navigator.of(context).pop(GameScreenExit.mainMenu);
        } else {
          Navigator.of(context).pop();
        }
      });
      return;
    }
    if (!_openingGame && widget.client.hasStarted) {
      _openingGame = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _openGame());
    }
  }

  Future<void> _openGame() async {
    final stateJson = widget.client.stateJson;
    if (!mounted || stateJson == null || widget.client.seat < 0) return;
    final settings = await const SettingsRepository().load();
    if (!mounted) return;
    try {
      await ContentLibrary.validateImages(widget.client.sessionMod!);
    } on Object {
      if (mounted) {
        showTopSnackBar(context, 'Хост модының суреттері жарамсыз.');
        Navigator.pop(context);
      }
      return;
    }
    if (!mounted) return;
    final controller = GameController(
      mod: widget.client.sessionMod!,
      state: GameState.fromJson(stateJson),
      saves: widget.saves,
      autosaveEnabled: false,
      confirmEndTurn: true,
      leftHanded: settings.leftHanded,
      sensitivity: settings.sensitivity,
      localPlayer: widget.client.seat,
      networkRole: GameNetworkRole.client,
      authoritativeSimulation: false,
    );
    widget.client.bindController(controller);
    await Navigator.of(context).push<GameScreenExit>(
      MaterialPageRoute<GameScreenExit>(
        builder: (_) =>
            GameScreen(controller: controller, disposeController: false),
      ),
    );
    widget.client.unbindController(controller);
    controller.dispose();
    if (!widget.client.closedByHost) await widget.client.close();
    if (mounted) Navigator.pop(context);
  }

  @override
  void dispose() {
    widget.client.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final client = widget.client;
    final lobby = client.lobby;
    return _LanScaffold(
      title: 'LAN · Ойыншы',
      onBack: () async {
        await client.close();
        if (context.mounted) Navigator.pop(context);
      },
      child: ListView(
        padding: const EdgeInsets.fromLTRB(24, 100, 24, 28),
        children: [
          _LanPanel(
            child: Column(
              children: [
                Text(
                  client.status == LanConnectionStatus.reconnecting
                      ? 'Қайта қосылуда…'
                      : lobby == null
                      ? 'Хост жауабы күтілуде…'
                      : 'Бөлме ${lobby.roomCode}',
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                if (client.error != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    client.error!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Color(0xff9a3129)),
                  ),
                ],
                if (lobby != null) ...[
                  Text(
                    "${lobby.modded ? 'Модпен' : 'Кәдімгі'} · ${lobby.modName}",
                  ),
                  if (lobby.mapName != null) Text('Карта: ${lobby.mapName}'),
                  const SizedBox(height: 14),
                  for (var seat = 0; seat < lobby.config.humanCount; seat++)
                    _ClientSeatRow(
                      seat: seat,
                      color:
                          (widget.client.sessionMod ?? widget.mod)
                              .palette[seat %
                              (widget.client.sessionMod ?? widget.mod)
                                  .palette
                                  .length],
                      participant: lobby.participants
                          .where((participant) => participant.seat == seat)
                          .firstOrNull,
                      isMe: seat == client.seat,
                    ),
                  const SizedBox(height: 14),
                  Text(
                    lobby.turnTimerEnabled
                        ? 'Ход уақыты: ${lobby.turnDurationSeconds ~/ 60} минут'
                        : 'Ход таймері өшірулі',
                    key: const ValueKey('lan-client-timer-setting'),
                    style: const TextStyle(fontSize: 15),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Картаны және ойынды хост бастайды',
                    style: TextStyle(fontSize: 16),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _HostSeatRow extends StatelessWidget {
  const _HostSeatRow({
    required this.seat,
    required this.color,
    required this.participant,
    required this.maxSeats,
    required this.onMove,
    required this.onKick,
  });

  final int seat;
  final Color color;
  final LanParticipant? participant;
  final int maxSeats;
  final void Function(String participantId, int seat) onMove;
  final Future<void> Function(String participantId) onKick;

  @override
  Widget build(BuildContext context) {
    final player = participant;
    return Container(
      key: ValueKey('lan-host-seat-$seat'),
      margin: const EdgeInsets.only(top: 7),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .72),
        border: Border.all(color: Colors.black45),
      ),
      child: Row(
        children: [
          Text(
            '${seat + 1}',
            style: const TextStyle(fontWeight: FontWeight.w900),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              player == null
                  ? 'Бос орын'
                  : '${player.name}${player.isHost ? ' · хост' : ''}${player.connected ? '' : ' · байланыс жоқ'}',
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 17),
            ),
          ),
          if (player != null && !player.isHost) ...[
            IconButton(
              tooltip: 'Алдыңғы түс',
              onPressed: seat > 1 ? () => onMove(player.id, seat - 1) : null,
              icon: const Icon(Icons.chevron_left),
            ),
            IconButton(
              tooltip: 'Келесі түс',
              onPressed: seat < maxSeats - 1
                  ? () => onMove(player.id, seat + 1)
                  : null,
              icon: const Icon(Icons.chevron_right),
            ),
            IconButton(
              tooltip: 'Бөлмеден шығару',
              onPressed: () => onKick(player.id),
              icon: const Icon(Icons.close, color: Color(0xff8d241e)),
            ),
          ],
        ],
      ),
    );
  }
}

class _ClientSeatRow extends StatelessWidget {
  const _ClientSeatRow({
    required this.seat,
    required this.color,
    required this.participant,
    required this.isMe,
  });

  final int seat;
  final Color color;
  final LanParticipant? participant;
  final bool isMe;

  @override
  Widget build(BuildContext context) => Container(
    key: ValueKey('lan-client-seat-$seat'),
    margin: const EdgeInsets.only(top: 7),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .72),
      border: Border.all(
        color: isMe ? Colors.white : Colors.black45,
        width: isMe ? 3 : 1,
      ),
    ),
    child: Text(
      '${seat + 1} · ${participant?.name ?? 'Бос орын'}${isMe ? ' · сіз' : ''}',
      style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
    ),
  );
}

class _LanScaffold extends StatelessWidget {
  const _LanScaffold({
    required this.title,
    required this.onBack,
    required this.child,
  });

  final String title;
  final VoidCallback onBack;
  final Widget child;

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: DalaTheme.canvas,
    body: DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [DalaTheme.paper, DalaTheme.canvas],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          const AntiyoyAnimatedParticles(),
          child,
          SafeArea(
            child: Align(
              alignment: Alignment.topCenter,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
                child: Row(
                  children: [
                    Material(
                      color: DalaTheme.gold,
                      borderRadius: BorderRadius.circular(14),
                      elevation: 5,
                      child: InkWell(
                        onTap: onBack,
                        borderRadius: BorderRadius.circular(14),
                        child: const SizedBox(
                          width: 62,
                          height: 52,
                          child: Icon(Icons.arrow_back, size: 32),
                        ),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        title,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 25,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                    const SizedBox(width: 62),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class _LanPanel extends StatelessWidget {
  const _LanPanel({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Material(
    color: DalaTheme.paper,
    elevation: 7,
    borderRadius: BorderRadius.circular(18),
    child: Padding(padding: const EdgeInsets.all(20), child: child),
  );
}

class _LanField extends StatelessWidget {
  const _LanField({
    required this.controller,
    required this.label,
    this.keyboardType,
    this.inputFormatters,
    super.key,
  });

  final TextEditingController controller;
  final String label;
  final TextInputType? keyboardType;
  final List<TextInputFormatter>? inputFormatters;

  @override
  Widget build(BuildContext context) => TextField(
    controller: controller,
    keyboardType: keyboardType,
    inputFormatters: inputFormatters,
    maxLength: keyboardType == TextInputType.number ? 6 : 40,
    decoration: InputDecoration(
      labelText: label,
      counterText: '',
      filled: true,
      fillColor: Colors.white70,
      border: const OutlineInputBorder(),
    ),
  );
}

class _LanActionBand extends StatelessWidget {
  const _LanActionBand({
    required this.label,
    required this.color,
    required this.enabled,
    required this.onTap,
    super.key,
  });

  final String label;
  final Color color;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: enabled ? color : Colors.grey.shade500,
    child: InkWell(
      onTap: enabled ? onTap : null,
      child: SizedBox(
        height: 58,
        child: Center(
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 21,
              fontWeight: FontWeight.w800,
              color: enabled ? Colors.black : Colors.black54,
            ),
          ),
        ),
      ),
    ),
  );
}
