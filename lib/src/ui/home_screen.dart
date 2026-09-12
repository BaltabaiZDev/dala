import 'dala_theme.dart';
import 'dala_art.dart';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../game/game_controller.dart';
import '../game/map_generator.dart';
import '../game/models.dart';
import '../game/scenario_catalog.dart';
import '../modding/game_mod.dart';
import '../persistence/editor_repository.dart';
import '../persistence/save_repository.dart';
import '../persistence/settings_repository.dart';
import 'antiyoy_background.dart';
import 'antiyoy_loading.dart';
import 'antiyoy_pressable.dart';
import 'editor_screen.dart';
import 'game_screen.dart';
import 'lan_screen.dart';
import 'top_snack_bar.dart';

const _aqua = DalaTheme.canvas;
const _violet = DalaTheme.blue;
const _paper = DalaTheme.paper;
const _olive = DalaTheme.gold;
const _blue = DalaTheme.blue;
const _green = DalaTheme.green;
const _orange = DalaTheme.gold;

GameMod _withPlayerColor(GameMod mod, int offset) {
  if (mod.palette.isEmpty) return mod;
  final normalized = offset % mod.palette.length;
  if (normalized == 0) return mod;
  return GameMod(
    id: mod.id,
    name: mod.name,
    title: mod.title,
    version: mod.version,
    rules: mod.rules,
    palette: [
      for (var i = 0; i < mod.palette.length; i++)
        mod.palette[(i + normalized) % mod.palette.length],
    ],
    neutralColor: mod.neutralColor,
    waterColor: mod.waterColor,
  );
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({required this.gameMod, required this.saves, super.key});

  final GameMod gameMod;
  final SaveRepository saves;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final SettingsRepository _settings = const SettingsRepository();
  final EditorRepository _editor = const EditorRepository();
  late Future<bool> _hasSave;

  @override
  void initState() {
    super.initState();
    _refreshSave();
  }

  void _refreshSave() => _hasSave = widget.saves.hasSave();

  Future<void> _continueGame() async {
    final state = await runWithAntiyoyLoader(
      context,
      semanticsLabel: 'Ойын жүктелуде',
      task: widget.saves.load,
    );
    if (!mounted || state == null) return;
    await _openGame(state);
  }

  Future<void> _openConfigScreen(Widget screen) async {
    final config = await Navigator.of(
      context,
    ).push<GameConfig>(MaterialPageRoute(builder: (_) => screen));
    if (!mounted || config == null) return;
    await _startConfig(config);
  }

  Future<void> _startConfig(GameConfig config) async {
    final result = await runWithAntiyoyLoader(
      context,
      semanticsLabel: 'Карта жасалуда',
      task: () async {
        final state = await generateMapAsync(widget.gameMod, config);
        final settings = await _settings.load();
        if (settings.autosave) await widget.saves.save(state);
        return (state: state, autosave: settings.autosave);
      },
    );
    if (!mounted) return;
    await _openGame(result.state, autosaveEnabled: result.autosave);
  }

  Future<void> _openPlayerLevels() async {
    final result = await Navigator.of(context).push<Object>(
      MaterialPageRoute<Object>(
        builder: (_) => _CampaignScreen(editor: _editor, mod: widget.gameMod),
      ),
    );
    if (!mounted || result == null) return;
    if (result is _EditorConfigRequest) {
      await _copyPresetToEditor(result.config);
    } else if (result is GameConfig) {
      await _startConfig(result);
    } else if (result is GameState) {
      if (EditorRepository.isValidState(
        result,
        expectedModId: widget.gameMod.id,
        requirePlayable: true,
        rules: widget.gameMod.rules,
      )) {
        await _openGame(result);
      }
    }
  }

  Future<void> _openCampaignLevels() async {
    final result = await Navigator.of(context).push<Object>(
      MaterialPageRoute<Object>(
        builder: (_) => _LevelsScreen(repository: _settings),
      ),
    );
    if (!mounted || result == null) return;
    if (result is _EditorConfigRequest) {
      await _copyPresetToEditor(result.config);
    } else if (result is GameConfig) {
      await _startConfig(result);
    }
  }

  Future<void> _copyPresetToEditor(GameConfig config) async {
    final state = await runWithAntiyoyLoader(
      context,
      semanticsLabel: 'Редактор картасы жасалуда',
      task: () async {
        final editorConfigJson = config.toJson()..remove('campaignLevel');
        final state = await generateMapAsync(
          widget.gameMod,
          GameConfig.fromJson(editorConfigJson),
        );
        await _editor.saveDraft(state);
        return state;
      },
    );
    if (!mounted) return;
    await _openEditor(initialState: state);
  }

  Future<void> _openGame(GameState state, {bool? autosaveEnabled}) async {
    final settings = await _settings.load();
    final shouldAutosave = autosaveEnabled ?? settings.autosave;
    if (!mounted) return;
    final entrySnapshot = GameState.fromJson(state.toJson());
    var activeState = state;
    while (mounted) {
      final result = await Navigator.of(context).push<GameScreenExit>(
        MaterialPageRoute<GameScreenExit>(
          builder: (_) => GameScreen(
            onVictory: activeState.config.campaignLevel == null
                ? null
                : () async {
                    final current = await _settings.unlockedLevels();
                    final next = math.min(
                      50,
                      activeState.config.campaignLevel! + 1,
                    );
                    if (next > current) {
                      await _settings.setUnlockedLevels(next);
                    }
                  },
            controller: GameController(
              mod: _withPlayerColor(
                widget.gameMod,
                activeState.config.playerColorOffset,
              ),
              state: activeState,
              saves: widget.saves,
              autosaveEnabled: shouldAutosave,
              confirmEndTurn: settings.confirmEndTurn,
              leftHanded: settings.leftHanded,
              sensitivity: settings.sensitivity,
            ),
          ),
        ),
      );
      if (!mounted || result != GameScreenExit.restart) break;
      activeState = GameState.fromJson(entrySnapshot.toJson());
    }
    if (mounted) setState(_refreshSave);
  }

  Future<void> _openEditor({GameState? initialState}) async {
    final state = await Navigator.of(context).push<GameState>(
      MaterialPageRoute<GameState>(
        builder: (_) => EditorScreen(
          mod: widget.gameMod,
          repository: _editor,
          initialState: initialState,
        ),
      ),
    );
    if (!mounted || state == null) return;
    if (!EditorRepository.isValidState(
      state,
      expectedModId: widget.gameMod.id,
      requirePlayable: true,
      rules: widget.gameMod.rules,
    )) {
      showTopSnackBar(context, 'Редактор картасы ойнатуға жарамсыз.');
      return;
    }
    final settings = await _settings.load();
    if (!mounted) return;
    await _openGame(state, autosaveEnabled: settings.autosave);
  }

  @override
  Widget build(BuildContext context) {
    return _MenuScaffold(
      background: _violet,
      topLeft: _SquareAssetButton(
        label: 'Баптаулар',
        asset: 'assets/classic/settings_icon.png',
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => _SettingsScreen(
              repository: _settings,
              saves: widget.saves,
              editor: _editor,
              modId: widget.gameMod.id,
              rules: widget.gameMod.rules,
            ),
          ),
        ),
      ),
      topRight: _SquareAssetButton(
        label: 'Шығу',
        asset: 'assets/classic/shut_down.png',
        onTap: SystemNavigator.pop,
      ),
      child: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 88, 16, 24),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: math.max(0, constraints.maxHeight - 112),
            ),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 322),
                child: FutureBuilder<bool>(
                  future: _hasSave,
                  builder: (context, snapshot) => _ClassicPanel(
                    padding: EdgeInsets.zero,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Padding(
                          padding: EdgeInsets.fromLTRB(20, 20, 20, 16),
                          child: Column(
                            children: [
                              DalaAsset('castle', width: 64, height: 64),
                              Text(
                                'DALA',
                                style: TextStyle(
                                  fontSize: 34,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 8,
                                  color: DalaTheme.ink,
                                ),
                              ),
                              Text(
                                'Д А Л А   А Т Л А С Ы',
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                  color: DalaTheme.deepWater,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (snapshot.data == true)
                          _MenuBand(
                            label: 'Жалғастыру',
                            color: _green,
                            onTap: _continueGame,
                          ),
                        _MenuBand(
                          label: 'Шайқас',
                          color: _olive,
                          onTap: () => _openConfigScreen(
                            _NewGameScreen(
                              repository: _settings,
                              palette: widget.gameMod.palette,
                            ),
                          ),
                        ),
                        _MenuBand(
                          label: 'LAN ойыны',
                          color: _orange,
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => LanScreen(
                                mod: widget.gameMod,
                                saves: widget.saves,
                                pickConfig: (lanContext) =>
                                    Navigator.of(lanContext).push<GameConfig>(
                                      MaterialPageRoute<GameConfig>(
                                        builder: (_) => _NewGameScreen(
                                          repository: _settings,
                                          palette: widget.gameMod.palette,
                                        ),
                                      ),
                                    ),
                              ),
                            ),
                          ),
                        ),
                        _MenuBand(
                          label: 'Редактор',
                          color: _green,
                          onTap: _openEditor,
                        ),
                        _MenuBand(
                          label: 'Ойыншы деңгейлері',
                          color: _blue,
                          onTap: _openPlayerLevels,
                        ),
                        _MenuBand(
                          label: 'Кампания',
                          color: _green,
                          onTap: _openCampaignLevels,
                        ),
                        _MenuBand(
                          label: 'Жүктеу',
                          color: _olive,
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => _SaveSlotsScreen(
                                saves: widget.saves,
                                onLoad: _continueGame,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NewGameScreen extends StatefulWidget {
  const _NewGameScreen({required this.repository, required this.palette});

  final SettingsRepository repository;
  final List<Color> palette;

  @override
  State<_NewGameScreen> createState() => _NewGameScreenState();
}

class _NewGameScreenState extends State<_NewGameScreen> {
  AppSettings settings = const AppSettings();

  @override
  void initState() {
    super.initState();
    widget.repository.load().then((loaded) {
      if (mounted) setState(() => settings = _clampPlayers(loaded));
    });
  }

  AppSettings _clampPlayers(AppSettings value) {
    final playerCount = value.playerCount.clamp(2, value.mapSize.maxPlayers);
    return value.copyWith(
      playerCount: playerCount,
      humanCount: value.humanCount.clamp(0, playerCount),
    );
  }

  void _set(AppSettings value) {
    final normalized = _clampPlayers(value);
    setState(() => settings = normalized);
    widget.repository.save(normalized);
  }

  GameConfig _createConfig() {
    final seed = math.Random.secure().nextInt(0x7fffffff);
    final colorOffset = settings.playerColorChoice < 0
        ? seed % widget.palette.length
        : settings.playerColorChoice % widget.palette.length;
    return GameConfig(
      mapSize: settings.mapSize,
      playerCount: settings.playerCount,
      humanCount: math.min(settings.humanCount, settings.playerCount),
      seed: seed,
      difficulty: settings.difficulty,
      treePercent: settings.treePercent,
      startingProvinceCount: settings.startingProvinceCount,
      playerColorOffset: colorOffset,
      slayRules: settings.slayRules,
      fogOfWar: settings.fogOfWar,
      diplomacy: settings.diplomacy,
    );
  }

  Future<void> _openMore() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => _AdvancedGameSettingsScreen(
          initial: settings,
          palette: widget.palette,
          onChanged: _set,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return _MenuScaffold(
      background: _aqua,
      topLeft: _BackButton(onTap: () => Navigator.pop(context)),
      topRight: _TopTextButton(
        label: 'Бастау',
        color: _green,
        onTap: () => Navigator.pop(context, _createConfig()),
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(36, 126, 36, 28),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 318),
            child: Column(
              children: [
                _ClassicPanel(
                  padding: const EdgeInsets.fromLTRB(27, 30, 27, 25),
                  child: Column(
                    children: [
                      _SetupSlider(
                        title: 'Қиындық',
                        value: settings.difficulty.index.toDouble(),
                        min: 0,
                        max: 5,
                        divisions: 5,
                        valueLabel: _difficultyLabel(settings.difficulty),
                        onChanged: (value) => _set(
                          settings.copyWith(
                            difficulty: AiDifficulty.values[value.round()],
                          ),
                        ),
                      ),
                      const SizedBox(height: 18),
                      _SetupSlider(
                        title: 'Карта өлшемі',
                        value: settings.mapSize.index.toDouble(),
                        min: 0,
                        max: (MapSize.values.length - 1).toDouble(),
                        divisions: MapSize.values.length - 1,
                        valueLabel: _mapSizeLabel(settings.mapSize),
                        onChanged: (value) {
                          final mapSize = MapSize.values[value.round()];
                          final playerCount = math.min(
                            settings.playerCount,
                            mapSize.maxPlayers,
                          );
                          _set(
                            settings.copyWith(
                              mapSize: mapSize,
                              playerCount: playerCount,
                              humanCount: math.min(
                                settings.humanCount,
                                playerCount,
                              ),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 38),
                _ClassicPanel(
                  padding: EdgeInsets.zero,
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(27, 30, 27, 2),
                        child: Column(
                          children: [
                            _SetupSlider(
                              title: 'Ойыншылар',
                              value: settings.humanCount.toDouble(),
                              min: 0,
                              max: settings.playerCount.toDouble(),
                              divisions: settings.playerCount,
                              valueLabel: _humanPlayersLabel(
                                settings.humanCount,
                              ),
                              onChanged: (value) => _set(
                                settings.copyWith(humanCount: value.round()),
                              ),
                            ),
                            const SizedBox(height: 18),
                            _SetupSlider(
                              title: 'Түстер',
                              value: settings.playerCount.toDouble(),
                              min: 2,
                              max: settings.mapSize.maxPlayers.toDouble(),
                              divisions: settings.mapSize.maxPlayers - 2,
                              valueLabel: '${settings.playerCount} түс',
                              onChanged: (value) {
                                final players = value.round();
                                _set(
                                  settings.copyWith(
                                    playerCount: players,
                                    humanCount: math.min(
                                      settings.humanCount,
                                      players,
                                    ),
                                  ),
                                );
                              },
                            ),
                          ],
                        ),
                      ),
                      Align(
                        alignment: Alignment.centerRight,
                        child: _InlineMoreButton(onTap: _openMore),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AdvancedGameSettingsScreen extends StatefulWidget {
  const _AdvancedGameSettingsScreen({
    required this.initial,
    required this.palette,
    required this.onChanged,
  });

  final AppSettings initial;
  final List<Color> palette;
  final ValueChanged<AppSettings> onChanged;

  @override
  State<_AdvancedGameSettingsScreen> createState() =>
      _AdvancedGameSettingsScreenState();
}

class _AdvancedGameSettingsScreenState
    extends State<_AdvancedGameSettingsScreen> {
  late AppSettings settings = widget.initial;

  void _set(AppSettings value) {
    setState(() => settings = value);
    widget.onChanged(value);
  }

  Future<void> _openPlayerColorPicker() async {
    final choice = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      useSafeArea: false,
      barrierColor: Colors.transparent,
      backgroundColor: Colors.transparent,
      elevation: 0,
      enableDrag: false,
      shape: const RoundedRectangleBorder(),
      builder: (sheetContext) => _PlayerColorPalette(
        palette: widget.palette,
        choice: settings.playerColorChoice,
        onSelected: (value) => Navigator.pop(sheetContext, value),
      ),
    );
    if (choice != null && mounted) {
      _set(settings.copyWith(playerColorChoice: choice));
    }
  }

  @override
  Widget build(BuildContext context) => _MenuScaffold(
    background: _aqua,
    topLeft: _BackButton(onTap: () => Navigator.pop(context)),
    child: SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(18, 147, 18, 28),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 324),
          child: _ClassicPanel(
            padding: const EdgeInsets.fromLTRB(35, 31, 35, 29),
            child: Column(
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Ойыншы түсі:',
                        style: TextStyle(fontSize: 27),
                      ),
                    ),
                    Semantics(
                      button: true,
                      label: 'Ойыншы түсін таңдау',
                      child: AntiyoyPressable(
                        key: const ValueKey('player-color-selector'),
                        onTap: _openPlayerColorPicker,
                        child: _PlayerColorChoice(
                          palette: widget.palette,
                          choice: settings.playerColorChoice,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 50),
                _LargeToggleRow(
                  label: 'Slay ережесі',
                  value: settings.slayRules,
                  onChanged: (value) =>
                      _set(settings.copyWith(slayRules: value)),
                ),
                _LargeToggleRow(
                  label: 'Соғыс тұманы',
                  value: settings.fogOfWar,
                  onChanged: (value) =>
                      _set(settings.copyWith(fogOfWar: value)),
                ),
                _LargeToggleRow(
                  label: 'Дипломатия',
                  value: settings.diplomacy,
                  onChanged: (value) =>
                      _set(settings.copyWith(diplomacy: value)),
                ),
                const SizedBox(height: 45),
                _SetupSlider(
                  title: 'Провинциялар',
                  horizontalOverhang: 9,
                  value: settings.startingProvinceCount.toDouble(),
                  min: 0,
                  max: 3,
                  divisions: 3,
                  valueLabel: settings.startingProvinceCount == 0
                      ? 'Әдепкі'
                      : '${settings.startingProvinceCount}',
                  onChanged: (value) => _set(
                    settings.copyWith(startingProvinceCount: value.round()),
                  ),
                ),
                const SizedBox(height: 37),
                _SetupSlider(
                  title: 'Ағаштар',
                  horizontalOverhang: 9,
                  value: settings.treePercent.toDouble(),
                  min: 0,
                  max: 100,
                  divisions: 10,
                  valueLabel: '${settings.treePercent}%',
                  onChanged: (value) =>
                      _set(settings.copyWith(treePercent: value.round())),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class _LevelsScreen extends StatelessWidget {
  const _LevelsScreen({required this.repository});

  final SettingsRepository repository;

  @override
  Widget build(BuildContext context) => _MenuScaffold(
    background: _aqua,
    topLeft: _BackButton(onTap: () => Navigator.pop(context)),
    child: FutureBuilder<int>(
      future: repository.unlockedLevels(),
      builder: (context, snapshot) {
        final unlocked = snapshot.data ?? 9;
        return Center(
          child: Container(
            width: 314,
            margin: const EdgeInsets.fromLTRB(22, 124, 22, 24),
            padding: const EdgeInsets.all(17),
            decoration: _panelDecoration(_green),
            child: GridView.builder(
              shrinkWrap: true,
              itemCount: campaignScenarios.length,
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 5,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
              ),
              itemBuilder: (context, index) {
                final level = index + 1;
                final available = level <= unlocked;
                final border = level <= 8
                    ? const Color(0xffd06db1)
                    : level <= 24
                    ? const Color(0xff768ee0)
                    : const Color(0xffe07c79);
                final scenario = campaignScenarios[index];
                return Semantics(
                  button: available,
                  label: available
                      ? '$level-деңгейді бастау: ${scenario.title}'
                      : '$level-деңгей жабық: ${scenario.title}',
                  hint: available
                      ? 'Ұзақ бассаңыз редакторға көшіріледі'
                      : null,
                  child: AntiyoyPressable(
                    onTap: available
                        ? () => Navigator.pop(context, _levelConfig(level))
                        : null,
                    onLongPress: available
                        ? () => Navigator.pop(
                            context,
                            _EditorConfigRequest(_levelConfig(level)),
                          )
                        : null,
                    child: Stack(
                      children: [
                        Container(
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: const Color(0xffd7efd6),
                            border: Border.all(color: border, width: 2),
                          ),
                          child: Text(
                            '$level',
                            style: const TextStyle(fontSize: 19),
                          ),
                        ),
                        if (!available)
                          const Positioned(
                            right: 2,
                            top: 0,
                            child: Icon(Icons.lock, size: 12),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        );
      },
    ),
  );

  static GameConfig _levelConfig(int level) =>
      campaignScenarios[(level - 1).clamp(0, campaignScenarios.length - 1)]
          .toConfig();
}

class _CampaignScreen extends StatefulWidget {
  const _CampaignScreen({required this.editor, required this.mod});

  final EditorRepository editor;
  final GameMod mod;

  @override
  State<_CampaignScreen> createState() => _CampaignScreenState();
}

class _CampaignScreenState extends State<_CampaignScreen> {
  bool filters = false;
  bool showHistorical = true;
  bool showSingle = true;
  bool showMultiplayer = true;
  bool showDiplomacy = true;
  bool showFog = true;
  late final Future<GameState?> editorDraft = _loadPlayableEditorDraft();

  static const levels = playerScenarios;

  Future<GameState?> _loadPlayableEditorDraft() async {
    final draft = await widget.editor.loadDraft(rules: widget.mod.rules);
    return draft != null &&
            EditorRepository.isValidState(
              draft,
              expectedModId: widget.mod.id,
              requirePlayable: true,
              rules: widget.mod.rules,
            )
        ? draft
        : null;
  }

  List<PlayerScenario> get visibleLevels => levels
      .where((level) {
        if (level.historical && !showHistorical) return false;
        if (level.multiplayer && !showMultiplayer) return false;
        if (!level.multiplayer && !showSingle) return false;
        if (level.diplomacy && !showDiplomacy) return false;
        if (level.fog && !showFog) return false;
        return true;
      })
      .toList(growable: false);

  @override
  Widget build(BuildContext context) => _MenuScaffold(
    background: _violet,
    topLeft: _BackButton(onTap: () => Navigator.pop(context)),
    topRight: _TopTextButton(
      label: 'Фильтрлер',
      color: _olive,
      onTap: () => setState(() => filters = !filters),
    ),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(36, 126, 36, 26),
      child: filters
          ? _ClassicPanel(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text('СҮЗГІЛЕР', style: TextStyle(fontSize: 28)),
                  ),
                  const SizedBox(height: 8),
                  _ToggleRow(
                    label: 'Тарихи',
                    value: showHistorical,
                    onChanged: (value) =>
                        setState(() => showHistorical = value),
                  ),
                  _ToggleRow(
                    label: 'Бір ойыншы',
                    value: showSingle,
                    onChanged: (value) => setState(() => showSingle = value),
                  ),
                  _ToggleRow(
                    label: 'Бір құрылғыда бірнеше адам',
                    value: showMultiplayer,
                    onChanged: (value) =>
                        setState(() => showMultiplayer = value),
                  ),
                  _ToggleRow(
                    label: 'Дипломатия',
                    value: showDiplomacy,
                    onChanged: (value) => setState(() => showDiplomacy = value),
                  ),
                  _ToggleRow(
                    label: 'Соғыс тұманы',
                    value: showFog,
                    onChanged: (value) => setState(() => showFog = value),
                  ),
                ],
              ),
            )
          : FutureBuilder<GameState?>(
              future: editorDraft,
              builder: (context, snapshot) {
                final draft = snapshot.data;
                final extra = draft == null ? 0 : 1;
                return _ClassicPanel(
                  padding: EdgeInsets.zero,
                  child: ListView.builder(
                    itemCount: visibleLevels.length + extra + 1,
                    itemBuilder: (context, index) {
                      if (index == 0) {
                        return const SizedBox(
                          height: 60,
                          child: Center(
                            child: Text(
                              'Ойыншы деңгейлері',
                              style: TextStyle(fontSize: 27),
                            ),
                          ),
                        );
                      }
                      if (draft != null && index == 1) {
                        return _MenuBand(
                          label: 'Менің редактор картам\nЖергілікті жоба',
                          color: _green,
                          height: 80,
                          align: Alignment.centerLeft,
                          onTap: () => Navigator.pop(
                            context,
                            GameState.fromJson(draft.toJson()),
                          ),
                        );
                      }
                      final item = visibleLevels[index - extra - 1];
                      final colors = [_olive, _blue, _green];
                      return _MenuBand(
                        label: '${item.name}\n${item.author}',
                        color: colors[(index - extra - 1) % colors.length],
                        height: 80,
                        align: Alignment.centerLeft,
                        onTap: () => Navigator.pop(context, item.toConfig()),
                        onLongPress: () => Navigator.pop(
                          context,
                          _EditorConfigRequest(item.toConfig()),
                        ),
                      );
                    },
                  ),
                );
              },
            ),
    ),
  );
}

class _SettingsScreen extends StatefulWidget {
  const _SettingsScreen({
    required this.repository,
    required this.saves,
    required this.editor,
    required this.modId,
    required this.rules,
  });

  final SettingsRepository repository;
  final SaveRepository saves;
  final EditorRepository editor;
  final String modId;
  final GameRules rules;

  @override
  State<_SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<_SettingsScreen> {
  AppSettings settings = const AppSettings();

  @override
  void initState() {
    super.initState();
    widget.repository.load().then((value) {
      if (mounted) setState(() => settings = value);
    });
  }

  void _set(AppSettings value) {
    setState(() => settings = value);
    widget.repository.save(value);
  }

  @override
  Widget build(BuildContext context) => _MenuScaffold(
    background: _violet,
    topLeft: _BackButton(onTap: () => Navigator.pop(context)),
    topRight: _SquareIconButton(
      label: 'Ақпарат',
      icon: Icons.info,
      color: _blue,
      onTap: () => Navigator.of(
        context,
      ).push(MaterialPageRoute<void>(builder: (_) => const _AboutScreen())),
    ),
    child: ListView(
      padding: const EdgeInsets.fromLTRB(36, 126, 36, 28),
      children: [
        _ClassicPanel(
          child: Column(
            children: [
              _ToggleRow(
                label: 'Автосақтау',
                value: settings.autosave,
                onChanged: (value) => _set(settings.copyWith(autosave: value)),
              ),
              _ToggleRow(
                label: 'Ход соңы үшін ұстап тұру',
                value: settings.confirmEndTurn,
                onChanged: (value) =>
                    _set(settings.copyWith(confirmEndTurn: value)),
              ),
            ],
          ),
        ),
        const SizedBox(height: 22),
        _ClassicPanel(
          child: Column(
            children: [
              _ClassicSlider(
                title: 'Сезімталдық',
                value: settings.sensitivity.toDouble(),
                min: 1,
                max: 10,
                divisions: 9,
                valueLabel: '${settings.sensitivity}',
                onChanged: (value) =>
                    _set(settings.copyWith(sensitivity: value.round())),
              ),
              const SizedBox(height: 20),
              _ToggleRow(
                label: 'Солақай режим',
                value: settings.leftHanded,
                onChanged: (value) =>
                    _set(settings.copyWith(leftHanded: value)),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        _TopTextButton(
          label: 'Прогресті көшіру',
          color: _green,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => _ProgressTransferScreen(
                settings: widget.repository,
                saves: widget.saves,
                editor: widget.editor,
                modId: widget.modId,
                rules: widget.rules,
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

class _AboutScreen extends StatelessWidget {
  const _AboutScreen();

  @override
  Widget build(BuildContext context) => _MenuScaffold(
    background: _violet,
    topLeft: _BackButton(onTap: () => Navigator.pop(context)),
    topRight: _TopTextButton(
      label: 'Анықтама',
      color: _green,
      onTap: () => Navigator.of(
        context,
      ).push(MaterialPageRoute<void>(builder: (_) => const _HelpScreen())),
    ),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(36, 160, 36, 28),
      child: _ClassicPanel(
        child: const Text(
          'Бұл — минималистік гексагон стратегиясы.\n\n'
          'Жерді жаулап, экономиканы дамытып, әскер, қамал, порт, кеме және артиллерияны тең ұстаңыз.\n\n'
          'Ойын офлайн жұмыс істейді және жарнамасыз.',
          style: TextStyle(fontSize: 21, height: 1.45),
        ),
      ),
    ),
  );
}

class _HelpScreen extends StatelessWidget {
  const _HelpScreen();

  @override
  Widget build(BuildContext context) => _MenuScaffold(
    background: _violet,
    topLeft: _BackButton(onTap: () => Navigator.pop(context)),
    child: ListView(
      padding: const EdgeInsets.fromLTRB(36, 126, 36, 28),
      children: const [
        _ClassicPanel(
          child: Text(
            'Негізгі ереже\n\n'
            '• Жер табыс береді, әскер мен құрылыстар шығын жейді.\n'
            '• Әскер өз жерімен 4 ұяшыққа дейін қозғалады.\n'
            '• Қамал көршілес жерді қорғайды.\n'
            '• Порттан кеме шығады; кеме десантты уақытша қала ретінде асырайды.\n'
            '• Артиллерия автоматты оқталып, теңіздегі жауға атады.\n'
            '• Slay ережесінде бүкіл құрлық басынан түстерге бөлінеді; 2–5 жалғасқан жер қала болады, жалғыз жердің экономикасы болмайды. Шабуыл күші қорғаныстан міндетті түрде жоғары, ферма мен күшті қамал салынбайды. Портқа 5, артиллерияға 7 жер керек; жоғары теңіз деңгейлері мемлекет үлкейгенде ашылады.\n'
            '• Соғыс тұманында қала 4, әскер 2, қамал 3/5 ұяшық радиусын ашады.\n'
            '• Дипломатия бейтараптық, 12 ходтық достық, соғыс, бітім ұсыныстары және 10 ходтық соғыс салқындауынан тұрады.',
            style: TextStyle(fontSize: 19, height: 1.35),
          ),
        ),
      ],
    ),
  );
}

class _SaveSlotsScreen extends StatelessWidget {
  const _SaveSlotsScreen({required this.saves, required this.onLoad});

  final SaveRepository saves;
  final Future<void> Function() onLoad;

  @override
  Widget build(BuildContext context) => _MenuScaffold(
    background: _violet,
    topLeft: _BackButton(onTap: () => Navigator.pop(context)),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(36, 126, 36, 28),
      child: _ClassicPanel(
        padding: EdgeInsets.zero,
        child: FutureBuilder<bool>(
          future: saves.hasSave(),
          builder: (context, snapshot) => ListView(
            children: [
              const Padding(
                padding: EdgeInsets.all(8),
                child: Text(
                  'Сақтаулар',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 28),
                ),
              ),
              _MenuBand(
                label: snapshot.data == true
                    ? 'Автосақтау\nСоңғы ойын'
                    : 'Автосақтау\nбос',
                color: _olive,
                height: 86,
                align: Alignment.centerLeft,
                onTap: snapshot.data == true
                    ? () async {
                        Navigator.pop(context);
                        await onLoad();
                      }
                    : null,
              ),
              const Padding(
                padding: EdgeInsets.all(18),
                child: Text(
                  'Автосақтау әр толық ход аяқталғаннан кейін жаңарады.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 18),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _ProgressTransferScreen extends StatefulWidget {
  const _ProgressTransferScreen({
    required this.settings,
    required this.saves,
    required this.editor,
    required this.modId,
    required this.rules,
  });

  final SettingsRepository settings;
  final SaveRepository saves;
  final EditorRepository editor;
  final String modId;
  final GameRules rules;

  @override
  State<_ProgressTransferScreen> createState() =>
      _ProgressTransferScreenState();
}

class _ProgressTransferScreenState extends State<_ProgressTransferScreen> {
  String status =
      'Баптаулар, кампания прогресі, автосақтау және редактор картасы көшіріледі.';

  Future<void> _export() async {
    final settings = jsonDecode(await widget.settings.exportRaw());
    final saveRaw = await widget.saves.exportRaw();
    final editorRaw = await widget.editor.exportRaw(rules: widget.rules);
    final bundle = jsonEncode({
      'schema': 1,
      'progress': settings,
      'save': saveRaw == null ? null : jsonDecode(saveRaw),
      'editor': editorRaw == null ? null : jsonDecode(editorRaw),
    });
    await Clipboard.setData(ClipboardData(text: bundle));
    if (mounted) setState(() => status = 'Прогресс алмасу буферіне көшірілді.');
  }

  Future<void> _import() async {
    final clipboard = await Clipboard.getData(Clipboard.kTextPlain);
    final raw = clipboard?.text;
    if (raw == null || raw.isEmpty) {
      if (mounted) setState(() => status = 'Алмасу буферінде дерек жоқ.');
      return;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) throw const FormatException('Bundle is not a map.');
      final bundle = decoded.cast<String, dynamic>();
      if (bundle['schema'] != 1 || bundle['progress'] is! Map) {
        throw const FormatException('Unsupported progress bundle.');
      }
      final progress = (bundle['progress'] as Map).cast<String, dynamic>();
      if (progress['version'] != 1 || progress['settings'] is! Map) {
        throw const FormatException('Unsupported settings bundle.');
      }
      final settingsJson = (progress['settings'] as Map)
          .cast<String, dynamic>();
      if (!AppSettings.isValidJson(settingsJson)) {
        throw const FormatException('Invalid settings bundle.');
      }
      final importedSettings = AppSettings.fromJson(settingsJson);
      final unlocked = progress['unlockedLevels'];
      if (unlocked is! int || unlocked < 1 || unlocked > 50) {
        throw const FormatException('Invalid campaign progress.');
      }

      GameState? importedSave;
      final save = bundle['save'];
      if (save != null) {
        if (save is! Map) throw const FormatException('Invalid save state.');
        importedSave = EditorRepository.decodeStateJson(
          save.cast<String, dynamic>(),
          expectedModId: widget.modId,
          rules: widget.rules,
        );
        if (importedSave == null) {
          throw const FormatException('Invalid save state.');
        }
      }

      GameState? importedEditor;
      final editor = bundle['editor'];
      if (editor != null) {
        importedEditor = widget.editor.decode(
          jsonEncode(editor),
          rules: widget.rules,
        );
        if (importedEditor == null || importedEditor.modId != widget.modId) {
          throw const FormatException('Invalid editor state.');
        }
      }

      // Validate every section before writing any section. A malformed tail
      // can no longer leave settings/save partially imported.
      await widget.settings.save(importedSettings);
      await widget.settings.setUnlockedLevels(unlocked);
      if (importedSave == null) {
        await widget.saves.clear();
      } else {
        await widget.saves.save(importedSave);
      }
      if (importedEditor != null) {
        await widget.editor.saveDraft(importedEditor);
      } else {
        await widget.editor.clearDraft();
      }
      if (mounted) {
        setState(() => status = 'Прогресс сәтті қалпына келтірілді.');
      }
    } on Object {
      if (mounted) setState(() => status = 'Дерек форматы дұрыс емес.');
    }
  }

  @override
  Widget build(BuildContext context) => _MenuScaffold(
    background: _aqua,
    topLeft: _BackButton(onTap: () => Navigator.pop(context)),
    child: Center(
      child: Padding(
        padding: const EdgeInsets.all(36),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _ClassicPanel(
              child: Text(
                status,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 20, height: 1.35),
              ),
            ),
            const SizedBox(height: 32),
            _TopTextButton(
              label: 'Прогресті экспорттау',
              color: _green,
              onTap: _export,
            ),
            const SizedBox(height: 18),
            _TopTextButton(
              label: 'Прогресті импорттау',
              color: _blue,
              onTap: _import,
            ),
          ],
        ),
      ),
    ),
  );
}

class _MenuScaffold extends StatelessWidget {
  const _MenuScaffold({
    required this.background,
    required this.child,
    this.topLeft,
    this.topRight,
  });

  final Color background;
  final Widget child;
  final Widget? topLeft;
  final Widget? topRight;

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: background,
    body: DecoratedBox(
      decoration: BoxDecoration(
        color: background,
        gradient: LinearGradient(
          colors: [DalaTheme.paper, DalaTheme.canvas],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          const _MenuParticles(),
          SafeArea(child: child),
          if (topLeft != null || topRight != null)
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [?topLeft, const Spacer(), ?topRight],
                ),
              ),
            ),
        ],
      ),
    ),
  );
}

class _MenuParticles extends StatelessWidget {
  const _MenuParticles();

  @override
  Widget build(BuildContext context) => const AntiyoyAnimatedParticles();
}

class _ClassicPanel extends StatelessWidget {
  const _ClassicPanel({
    required this.child,
    this.padding = const EdgeInsets.all(22),
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => Container(
    clipBehavior: Clip.antiAlias,
    padding: padding,
    decoration: _panelDecoration(_paper),
    child: child,
  );
}

BoxDecoration _panelDecoration(Color color) => DalaTheme.panel(color);

class _MenuBand extends StatelessWidget {
  const _MenuBand({
    required this.label,
    required this.color,
    this.onTap,
    this.onLongPress,
    this.height = 54,
    this.align = Alignment.center,
  });

  final String label;
  final Color color;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double height;
  final Alignment align;

  @override
  Widget build(BuildContext context) => Semantics(
    button: onTap != null,
    label: label.replaceAll('\n', ', '),
    hint: onLongPress == null ? null : 'Ұзақ бассаңыз редакторға көшіріледі',
    child: AntiyoyPressable(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        height: height,
        width: double.infinity,
        margin: const EdgeInsets.fromLTRB(10, 0, 10, 7),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        alignment: align,
        decoration: BoxDecoration(
          color: Color.lerp(DalaTheme.paper, color, .35),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            Container(
              width: 5,
              height: 22,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                label,
                style: const TextStyle(
                  fontSize: 16,
                  height: 1.15,
                  fontWeight: FontWeight.w600,
                  color: DalaTheme.ink,
                ),
              ),
            ),
            if (onTap != null)
              const Icon(
                Icons.chevron_right_rounded,
                size: 20,
                color: DalaTheme.deepWater,
              ),
          ],
        ),
      ),
    ),
  );
}

class _EditorConfigRequest {
  const _EditorConfigRequest(this.config);

  final GameConfig config;
}

class _BackButton extends StatelessWidget {
  const _BackButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: 'Артқа',
    child: AntiyoyPressable(
      onTap: onTap,
      child: Container(
        width: 72,
        height: 55,
        decoration: _panelDecoration(_orange),
        child: Center(
          child: DalaAsset('assets/classic/arrow.png', width: 43, height: 43),
        ),
      ),
    ),
  );
}

class _TopTextButton extends StatelessWidget {
  const _TopTextButton({
    required this.label,
    required this.color,
    required this.onTap,
  });

  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    child: AntiyoyPressable(
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minWidth: 126),
        height: 55,
        padding: const EdgeInsets.symmetric(horizontal: 18),
        alignment: Alignment.center,
        decoration: _panelDecoration(color),
        child: Text(label, style: const TextStyle(fontSize: 20)),
      ),
    ),
  );
}

class _SquareAssetButton extends StatelessWidget {
  const _SquareAssetButton({
    required this.label,
    required this.asset,
    required this.onTap,
  });

  final String label;
  final String asset;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    child: AntiyoyPressable(
      onTap: onTap,
      child: Container(
        width: 58,
        height: 58,
        padding: const EdgeInsets.all(8),
        decoration: _panelDecoration(_olive),
        child: DalaAsset(asset),
      ),
    ),
  );
}

class _SquareIconButton extends StatelessWidget {
  const _SquareIconButton({
    required this.label,
    required this.icon,
    required this.color,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    child: AntiyoyPressable(
      onTap: onTap,
      child: Container(
        width: 58,
        height: 58,
        alignment: Alignment.center,
        decoration: _panelDecoration(color),
        child: Icon(icon, size: 35, color: Colors.black),
      ),
    ),
  );
}

class _SetupSlider extends StatelessWidget {
  const _SetupSlider({
    required this.title,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.valueLabel,
    required this.onChanged,
    this.horizontalOverhang = 20,
  });

  final String title;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String valueLabel;
  final ValueChanged<double> onChanged;
  final double horizontalOverhang;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(title, style: const TextStyle(fontSize: 20, height: 1.15)),
      SizedBox(
        height: 48,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned(
              left: -horizontalOverhang,
              right: -horizontalOverhang,
              bottom: -6,
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  activeTrackColor: DalaTheme.deepWater,
                  inactiveTrackColor: DalaTheme.line,
                  thumbColor: DalaTheme.deepWater,
                  tickMarkShape: const RoundSliderTickMarkShape(
                    tickMarkRadius: 2.3,
                  ),
                  activeTickMarkColor: DalaTheme.paper,
                  inactiveTickMarkColor: DalaTheme.deepWater,
                  overlayShape: SliderComponentShape.noOverlay,
                  trackHeight: 4,
                ),
                child: Slider(
                  value: value.clamp(min, max).toDouble(),
                  min: min,
                  max: max,
                  divisions: divisions,
                  onChanged: onChanged,
                ),
              ),
            ),
            Positioned(
              right: 4,
              top: -1,
              child: IgnorePointer(
                child: ColoredBox(
                  color: _paper,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: Text(
                      valueLabel,
                      style: const TextStyle(fontSize: 22, height: 1),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ],
  );
}

class _InlineMoreButton extends StatelessWidget {
  const _InlineMoreButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: 'Қосымша',
    child: AntiyoyPressable(
      onTap: onTap,
      child: Container(
        width: 126,
        height: 48,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: _green,
          borderRadius: BorderRadius.circular(14),
        ),
        child: const Text(
          'Қосымша',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
      ),
    ),
  );
}

class _PlayerColorChoice extends StatelessWidget {
  const _PlayerColorChoice({required this.palette, required this.choice});

  final List<Color> palette;
  final int choice;

  @override
  Widget build(BuildContext context) {
    final random = choice < 0 || palette.isEmpty;
    final color = random ? Colors.white70 : palette[choice % palette.length];
    return random
        ? const _RandomColorSwatch(size: 39)
        : _SolidColorSwatch(color: color, size: 39);
  }
}

class _PlayerColorPalette extends StatelessWidget {
  const _PlayerColorPalette({
    required this.palette,
    required this.choice,
    required this.onSelected,
  });

  final List<Color> palette;
  final int choice;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = constraints.maxWidth;
      final step = width / 8;
      final tileSize = width / 8.5;
      final items = <int>[...List<int>.generate(palette.length, (i) => i), -1];
      return Material(
        key: const ValueKey('player-color-palette'),
        color: _paper,
        child: SizedBox(
          width: width,
          height: width * .5,
          child: Stack(
            children: [
              for (var index = 0; index < items.length; index++)
                Positioned(
                  left: step * ((index % 7) + 1) - tileSize / 2,
                  top: step * ((index ~/ 7) + 1) - tileSize / 2,
                  child: _PaletteChoice(
                    value: items[index],
                    color: items[index] < 0
                        ? Colors.transparent
                        : palette[items[index]],
                    size: tileSize,
                    selected: choice == items[index],
                    onTap: () => onSelected(items[index]),
                  ),
                ),
            ],
          ),
        ),
      );
    },
  );
}

class _PaletteChoice extends StatelessWidget {
  const _PaletteChoice({
    required this.value,
    required this.color,
    required this.size,
    required this.selected,
    required this.onTap,
  });

  final int value;
  final Color color;
  final double size;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: selected,
    label: value < 0 ? 'Кездейсоқ түс' : '${value + 1}-ойыншы түсі',
    child: AntiyoyPressable(
      key: ValueKey(value < 0 ? 'player-color-random' : 'player-color-$value'),
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: value < 0
          ? _RandomColorSwatch(size: size)
          : _SolidColorSwatch(color: color, size: size),
    ),
  );
}

class _SolidColorSwatch extends StatelessWidget {
  const _SolidColorSwatch({required this.color, required this.size});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: color,
      border: Border.all(color: const Color(0xff303030), width: 2),
    ),
  );
}

class _RandomColorSwatch extends StatelessWidget {
  const _RandomColorSwatch({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      border: Border.all(color: const Color(0xff303030), width: 2),
    ),
    child: DalaAsset(
      'assets/classic/random_color_pixel.png',
      fit: BoxFit.fill,
      filterQuality: FilterQuality.none,
    ),
  );
}

class _LargeToggleRow extends StatelessWidget {
  const _LargeToggleRow({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: () => onChanged(!value),
    child: SizedBox(
      height: 48,
      child: Row(
        children: [
          Expanded(child: Text(label, style: const TextStyle(fontSize: 20))),
          Container(
            width: 27,
            height: 27,
            decoration: BoxDecoration(
              color: value ? Colors.black : Colors.transparent,
              border: Border.all(color: Colors.black, width: 2),
            ),
            child: value
                ? const Icon(Icons.check, color: Colors.white, size: 20)
                : null,
          ),
        ],
      ),
    ),
  );
}

class _ClassicSlider extends StatelessWidget {
  const _ClassicSlider({
    required this.title,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.valueLabel,
    required this.onChanged,
  });

  final String title;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String valueLabel;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Align(
        alignment: Alignment.centerLeft,
        child: Text(title, style: const TextStyle(fontSize: 20)),
      ),
      Transform.translate(
        offset: const Offset(0, -6),
        child: Row(
          children: [
            Expanded(
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  activeTrackColor: Colors.black,
                  inactiveTrackColor: Colors.black,
                  thumbColor: Colors.black,
                  tickMarkShape: const RoundSliderTickMarkShape(
                    tickMarkRadius: 3.3,
                  ),
                  activeTickMarkColor: Colors.black,
                  inactiveTickMarkColor: Colors.black,
                  overlayShape: SliderComponentShape.noOverlay,
                  trackHeight: 2.3,
                ),
                child: Slider(
                  value: value,
                  min: min,
                  max: max,
                  divisions: divisions,
                  onChanged: onChanged,
                ),
              ),
            ),
            SizedBox(
              width: 100,
              child: Text(
                valueLabel,
                textAlign: TextAlign.right,
                style: const TextStyle(fontSize: 21),
              ),
            ),
          ],
        ),
      ),
    ],
  );
}

class _ToggleRow extends StatelessWidget {
  const _ToggleRow({required this.label, required this.value, this.onChanged});

  final String label;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onChanged == null ? null : () => onChanged!(!value),
    child: SizedBox(
      height: 51,
      child: Row(
        children: [
          Expanded(child: Text(label, style: const TextStyle(fontSize: 21))),
          Container(
            width: 25,
            height: 25,
            decoration: BoxDecoration(
              color: value ? Colors.black : Colors.transparent,
              border: Border.all(color: Colors.black, width: 2),
            ),
            child: value
                ? const Icon(Icons.check, color: Colors.white, size: 19)
                : null,
          ),
        ],
      ),
    ),
  );
}

String _mapSizeLabel(MapSize value) => switch (value) {
  MapSize.small => 'кіші',
  MapSize.medium => 'орта',
  MapSize.large => 'үлкен',
  MapSize.huge => 'алып',
  MapSize.giant => 'орасан',
};

String _humanPlayersLabel(int value) => switch (value) {
  0 => 'боттар шайқасы',
  1 => 'бір ойыншы',
  _ => 'мультиплеер ${value}x',
};

String _difficultyLabel(AiDifficulty value) => switch (value) {
  AiDifficulty.veryEasy => 'өте жеңіл',
  AiDifficulty.easy => 'жеңіл',
  AiDifficulty.normal => 'қалыпты',
  AiDifficulty.hard => 'қиын',
  AiDifficulty.veryHard => 'сарапшы',
  AiDifficulty.master => 'шебер',
};
