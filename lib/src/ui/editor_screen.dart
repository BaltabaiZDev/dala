import '../l10n/game_locale.dart';
import 'dala_theme.dart';
import 'organic_cells.dart';
import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../game/game_engine.dart';
import '../game/map_generator.dart';
import '../game/models.dart';
import '../modding/game_mod.dart';
import '../modding/content_library.dart';
import '../modding/content_files.dart';
import '../modding/content_package.dart';
import '../persistence/antiyoy_hd_level_importer.dart';
import '../persistence/editor_repository.dart';
import 'antiyoy_loading.dart';
import 'classic_assets.dart';
import 'map_viewport.dart';
import 'top_snack_bar.dart';

const _editorAqua = DalaTheme.canvas;
const _editorPaper = DalaTheme.paper;
const _editorGreen = DalaTheme.green;
const _editorOrange = DalaTheme.gold;
const _editorBlue = DalaTheme.blue;
const _editorOlive = DalaTheme.gold;

enum _EditorTool { terrain, owner, object, unit, navy }

enum _EditorNavalAsset { none, boat1, boat2, seaMint, seaFort }

enum _EditorMenuAction {
  save,
  load,
  export,
  import,
  regenerate,
  blank,
  saveMap,
  exportFile,
  importFile,
}

/// A state-backed map editor. All visible actions modify, persist or launch a
/// real [GameState]; there are no demo-only controls on this screen.
class EditorScreen extends StatefulWidget {
  const EditorScreen({
    required this.mod,
    required this.repository,
    this.initialState,
    this.library,
    super.key,
  });

  final GameMod mod;
  final EditorRepository repository;
  final GameState? initialState;
  final ContentLibrary? library;

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> {
  GameState? _state;
  Timer? _autosaveTimer;
  Future<void> _saveQueue = Future<void>.value();
  int _stateRevision = 0;
  int _persistedRevision = -1;
  _EditorTool _tool = _EditorTool.owner;
  TileObject _object = TileObject.town;
  _EditorNavalAsset _navalAsset = _EditorNavalAsset.boat1;
  int _owner = 0;
  int _strength = 1;
  int? _selectedTile;
  String _status = 'Карта жүктелуде…';
  bool _allowPop = false;
  bool _leaving = false;
  bool _panMode = true;
  ClassicSprites? _sprites;

  @override
  void initState() {
    super.initState();
    _loadSprites();
    _loadInitialState();
  }

  @override
  void dispose() {
    _autosaveTimer?.cancel();
    _sprites?.dispose();
    super.dispose();
  }

  Future<void> _loadSprites() async {
    final sprites = await ClassicSprites.load();
    if (!mounted) {
      sprites.dispose();
      return;
    }
    setState(() => _sprites = sprites);
  }

  Future<void> _loadInitialState() async {
    final supplied = widget.initialState;
    final compatibleInitial = supplied?.modId == widget.mod.id
        ? GameState.fromJson(supplied!.toJson())
        : null;
    final state =
        compatibleInitial ??
        MapGenerator(widget.mod).createBlank(const GameConfig());
    _normalize(state);
    if (!mounted) return;
    setState(() {
      _state = state;
      _owner = state.turn.clamp(0, state.config.playerCount - 1);
      _status = compatibleInitial == null
          ? 'Жаңа бос карта'
          : 'Карта редакторда ашылды';
    });
  }

  Future<GameState> _generate(GameConfig source) {
    final seed = math.Random.secure().nextInt(0x7fffffff);
    return generateMapAsync(
      widget.mod,
      _copyConfig(source, seed: seed, campaignLevel: null),
    );
  }

  void _normalize(GameState state) {
    state.modSnapshot = widget.mod.toJson();
    final existingProvinceIds = state.provinces
        .map((province) => province.id)
        .toSet();
    MapGenerator.ensureWaterCells(state);
    GameEngine(
      mod: widget.mod,
      state: state,
    ).rebuildProvinces(preserveNewCapitalUnits: true);
    for (final province in state.provinces) {
      if (!existingProvinceIds.contains(province.id) && province.money == 0) {
        province.money = widget.mod.rules.initialMoney;
      }
    }
    state
      ..winner = null
      ..turn = state.turn.clamp(0, state.config.playerCount - 1);
  }

  void _scheduleAutosave() {
    _autosaveTimer?.cancel();
    final revision = ++_stateRevision;
    _autosaveTimer = Timer(const Duration(milliseconds: 320), () async {
      final state = _state;
      if (state == null) return;
      final snapshot = GameState.fromJson(state.toJson());
      await _queueDraftSave(snapshot, revision, announce: true);
    });
  }

  Future<void> _queueDraftSave(
    GameState snapshot,
    int revision, {
    bool announce = false,
  }) {
    final queued = _saveQueue.catchError((Object _) {}).then((_) async {
      if (revision < _persistedRevision) return;
      await widget.repository.saveDraft(snapshot);
      _persistedRevision = revision;
      if (announce && mounted && revision == _stateRevision) {
        setState(() => _status = 'Автосақталды');
      }
    });
    _saveQueue = queued;
    return queued;
  }

  Future<void> _flushCurrentDraft({String? successStatus}) async {
    _autosaveTimer?.cancel();
    final state = _state;
    if (state == null) return;
    final revision = ++_stateRevision;
    final snapshot = GameState.fromJson(state.toJson());
    await _queueDraftSave(snapshot, revision);
    if (successStatus != null) _showStatus(successStatus);
  }

  void _editTile(int index) {
    final state = _state;
    if (state == null || index < 0 || index >= state.hexes.length) return;
    final tile = state.hexes[index];
    if (!tile.inWorld) return;
    if (_tool == _EditorTool.navy) {
      _editWaterCell(state, tile);
      return;
    }
    var changed = false;
    setState(() {
      _selectedTile = index;
      switch (_tool) {
        case _EditorTool.terrain:
          tile.active = !tile.active;
          if (!tile.active) {
            tile
              ..owner = -1
              ..object = TileObject.none
              ..unit = null
              ..treeBorn = -1
              ..artilleryAmmo = 0
              ..artilleryCooldown = 0;
          }
          _normalize(state);
          changed = true;
          break;
        case _EditorTool.owner:
          if (!tile.active) tile.active = true;
          tile.owner = tile.owner == _owner ? -1 : _owner;
          if (tile.owner < 0) {
            tile
              ..object = TileObject.none
              ..unit = null;
          }
          _normalize(state);
          changed = true;
          break;
        case _EditorTool.object:
          if (!tile.active) {
            _status =
                'Алдымен «Жер» құралымен бұл ұяшықты құрлыққа айналдырыңыз';
            return;
          }
          if (_requiresOwner(_object) && tile.owner < 0) {
            tile.owner = _owner;
            _normalize(state);
          }
          final province = GameEngine(
            mod: widget.mod,
            state: state,
          ).provinceAt(index);
          if (_requiresOwner(_object) && province == null) {
            tile.owner = -1;
            _normalize(state);
            _status = 'Алдымен кемінде екі көршілес жерді бір түске бояңыз';
            return;
          }
          final isCapital = province?.capital == index;
          if (isCapital && _object != TileObject.town) {
            _status = 'Алдымен қаланы сол провинцияның басқа жеріне қойыңыз';
            return;
          }
          final needsCoast =
              _object == TileObject.port1 ||
              _object == TileObject.port2 ||
              _object == TileObject.artillery1 ||
              _object == TileObject.artillery2 ||
              _object == TileObject.artillery3;
          if (needsCoast &&
              !state.waterCells.any(
                (cell) => cell.navigable && cell.coastTiles.contains(index),
              )) {
            _status = 'Порт пен артиллерия кеме жүретін жағалауға қойылады';
            return;
          }
          if (_object == TileObject.town && province != null) {
            final previous = state.hexes[province.capital];
            if (previous.index != index) {
              previous
                ..object = TileObject.none
                ..treeBorn = -1;
            }
            province.capital = index;
          }
          tile
            ..object = _object
            ..treeBorn = _isTree(_object) ? state.round : -1
            ..artilleryCooldown = 0
            ..artilleryAmmo = _artilleryAmmo(_object);
          if (_object != TileObject.none) tile.unit = null;
          changed = true;
          break;
        case _EditorTool.unit:
          if (!tile.active) tile.active = true;
          final assignedOwner = tile.owner < 0;
          if (tile.owner < 0) {
            tile.owner = _owner;
            _normalize(state);
          }
          final province = GameEngine(
            mod: widget.mod,
            state: state,
          ).provinceAt(index);
          if (province == null) {
            if (assignedOwner) {
              tile.owner = -1;
              _normalize(state);
            }
            _status = 'Алдымен кемінде екі көршілес жерді бір түске бояңыз';
            return;
          }
          if (province.capital == index) {
            _status = 'Қала тұрған жерге әскер қойылмайды';
            return;
          }
          if (tile.unit?.strength == _strength) {
            tile.unit = null;
          } else {
            tile
              ..object = TileObject.none
              ..treeBorn = -1
              ..artilleryAmmo = 0
              ..artilleryCooldown = 0;
            tile.unit = GameUnit(strength: _strength, ready: true);
          }
          changed = true;
          break;
        case _EditorTool.navy:
          break;
      }
      if (changed) _status = 'Өзгеріс сақталуда…';
    });
    if (changed) _scheduleAutosave();
  }

  void _editWaterCell(GameState state, HexTile tile) {
    if (tile.active) {
      _showStatus('Теңіз нысаны су ұяшығына қойылады');
      return;
    }
    MapGenerator.ensureWaterCells(state);
    WaterCell? selected;
    for (final cell in state.waterCells) {
      if (cell.tiles.contains(tile.index)) {
        selected = cell;
        break;
      }
    }
    if (selected == null || !selected.navigable) {
      _showStatus('Бұл су аймағында кеме жүре алмайды');
      return;
    }
    if (_navalAsset == _EditorNavalAsset.none) {
      setState(() {
        _selectedTile = tile.index;
        selected!
          ..boat = null
          ..seaFort = null
          ..seaMint = false;
        _status = 'Теңіз ұяшығы тазартылды';
      });
      _scheduleAutosave();
      return;
    }
    if (_navalAsset == _EditorNavalAsset.seaMint) {
      setState(() {
        _selectedTile = tile.index;
        selected!
          ..boat = null
          ..seaFort = null
          ..seaMint = true;
        _status = 'Су жалбызы сақталуда…';
      });
      _scheduleAutosave();
      return;
    }
    final ownerProvinces = state.provinces
        .where((province) => province.owner == _owner)
        .toList();
    if (ownerProvinces.isEmpty) {
      _showStatus('Алдымен осы түске кемінде бір провинция жасаңыз');
      return;
    }
    ownerProvinces.sort((first, second) {
      final firstCoastal = first.tiles.any(selected!.coastTiles.contains);
      final secondCoastal = second.tiles.any(selected.coastTiles.contains);
      if (firstCoastal != secondCoastal) return firstCoastal ? -1 : 1;
      return second.tiles.length.compareTo(first.tiles.length);
    });
    final home = ownerProvinces.first;
    setState(() {
      _selectedTile = tile.index;
      switch (_navalAsset) {
        case _EditorNavalAsset.none:
          break;
        case _EditorNavalAsset.boat1:
        case _EditorNavalAsset.boat2:
          selected!
            ..seaFort = null
            ..seaMint = false
            ..boat = GameBoat(
              id: state.nextNavalEntityId++,
              owner: _owner,
              level: _navalAsset == _EditorNavalAsset.boat1 ? 1 : 2,
              homeProvinceId: home.id,
              ready: true,
            );
          break;
        case _EditorNavalAsset.seaFort:
          selected!
            ..boat = null
            ..seaMint = false
            ..seaFort = SeaFort(
              id: state.nextNavalEntityId++,
              owner: _owner,
              homeProvinceId: home.id,
            );
          break;
        case _EditorNavalAsset.seaMint:
          break;
      }
      _status = 'Теңіз нысаны сақталуда…';
    });
    _scheduleAutosave();
  }

  int _artilleryAmmo(TileObject object) => switch (object) {
    TileObject.artillery1 => widget.mod.rules.artilleryAmmoCapacity[1],
    TileObject.artillery2 => widget.mod.rules.artilleryAmmoCapacity[2],
    TileObject.artillery3 => widget.mod.rules.artilleryAmmoCapacity[3],
    _ => 0,
  };

  bool _requiresOwner(TileObject object) => switch (object) {
    TileObject.town ||
    TileObject.farm ||
    TileObject.tower ||
    TileObject.strongTower ||
    TileObject.port1 ||
    TileObject.port2 ||
    TileObject.artillery1 ||
    TileObject.artillery2 ||
    TileObject.artillery3 => true,
    _ => false,
  };

  bool _isTree(TileObject object) =>
      object == TileObject.pine || object == TileObject.palm;

  Future<void> _saveNow() async {
    await _flushCurrentDraft(successStatus: 'Жоба сақталды');
  }

  Future<void> _leaveEditor() async {
    if (_leaving) return;
    _leaving = true;
    try {
      final shouldLeave = await _confirmLeaveEditor();
      if (!mounted || !shouldLeave) return;
      await _flushCurrentDraft();
      if (!mounted) return;
      setState(() => _allowPop = true);
      Navigator.of(context).pop();
    } on Object {
      if (mounted) _showStatus('Жобаны сақтау мүмкін болмады');
    } finally {
      _leaving = false;
    }
  }

  Future<bool> _confirmLeaveEditor() async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 28),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 360),
          decoration: BoxDecoration(
            color: _editorPaper,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.black87, width: 2),
            boxShadow: const [
              BoxShadow(
                color: Colors.black45,
                blurRadius: 9,
                offset: Offset(0, 5),
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(18, 18, 18, 14),
                child: GameText(
                  'Редактордан шығу?',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 20, color: Colors.black),
                ),
              ),
              _EditorLeaveChoice(
                color: _editorOrange,
                label: 'Редакторға қайту',
                onTap: () => Navigator.pop(dialogContext, false),
              ),
              _EditorLeaveChoice(
                color: _editorGreen,
                label: 'Сақтау және шығу',
                onTap: () => Navigator.pop(dialogContext, true),
              ),
            ],
          ),
        ),
      ),
    );
    return result ?? false;
  }

  Future<void> _loadDraft() async {
    _autosaveTimer?.cancel();
    await _saveQueue.catchError((Object _) {});
    final loaded = await widget.repository.loadDraft(rules: widget.mod.rules);
    if (!mounted) return;
    if (loaded == null || loaded.modId != widget.mod.id) {
      _showStatus('Сақталған жоба жоқ');
      return;
    }
    _normalize(loaded);
    setState(() {
      _state = loaded;
      _selectedTile = null;
      _owner = _owner.clamp(0, loaded.config.playerCount - 1);
      _status = 'Жоба жүктелді';
    });
    _persistedRevision = ++_stateRevision;
  }

  Future<void> _saveMapFile({bool export = false}) async {
    final state = _state;
    if (state == null) return;
    var enteredName = 'Менің картам';
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const GameText('Карта атауы'),
        content: TextFormField(
          initialValue: enteredName,
          onChanged: (value) => enteredName = value,
          maxLength: 80,
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const GameText('Бас тарту'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, enteredName),
            child: const GameText('Сақтау'),
          ),
        ],
      ),
    );
    if (!mounted || name == null) return;
    try {
      final map = DalaMap.fromState(name, state, widget.mod);
      if (export) {
        if (await ContentFiles.save('dala-map.dalamap', map.encode())) {
          _showStatus('Карта файлға экспортталды');
        }
      } else {
        final library = widget.library ?? ContentLibrary(widget.mod);
        await library.importFile('dala-map.dalamap', map.encode());
        _showStatus('Карта кітапханаға сақталды');
      }
    } on Object catch (error) {
      _showStatus(error.toString());
    }
  }

  Future<void> _importMapFile() async {
    try {
      final file = await ContentFiles.pick();
      if (file == null || !mounted) return;
      final map = DalaMap.decode(file.bytes, mod: widget.mod);
      final state = map.createState(widget.mod);
      setState(() {
        _state = state;
        _selectedTile = null;
        _owner = 0;
      });
      _scheduleAutosave();
      _showStatus('Карта файлдан жүктелді');
    } on Object catch (error) {
      _showStatus(error.toString());
    }
  }

  Future<void> _export() async {
    final state = _state;
    if (state == null) return;
    await _flushCurrentDraft();
    await Clipboard.setData(
      ClipboardData(text: widget.repository.encode(state)),
    );
    _showStatus('Карта коды алмасу буферіне көшірілді');
  }

  Future<void> _import() async {
    _autosaveTimer?.cancel();
    await _saveQueue.catchError((Object _) {});
    final raw = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    final imported = raw == null
        ? null
        : widget.repository.decode(raw, rules: widget.mod.rules) ??
              const AntiyoyHdLevelImporter().decode(raw, widget.mod);
    if (!mounted) return;
    if (imported == null || imported.modId != widget.mod.id) {
      _showStatus('Алмасу буферіндегі карта жарамсыз');
      return;
    }
    _normalize(imported);
    if (!EditorRepository.isValidState(
      imported,
      expectedModId: widget.mod.id,
      rules: widget.mod.rules,
    )) {
      _showStatus('Импортталған картада жарамсыз нысан бар');
      return;
    }
    setState(() {
      _state = imported;
      _selectedTile = null;
      _owner = 0;
      _status = 'Карта импортталды';
    });
    final revision = ++_stateRevision;
    await _queueDraftSave(GameState.fromJson(imported.toJson()), revision);
  }

  Future<void> _regenerate({bool blank = false, GameConfig? config}) async {
    final current = _state;
    if (current == null) return;
    final nextConfig = config ?? current.config;
    final generated = await runWithAntiyoyLoader(
      context,
      semanticsLabel: blank ? 'Бос карта жасалуда' : 'Карта жасалуда',
      task: () async => blank
          ? MapGenerator(widget.mod).createBlank(nextConfig)
          : await _generate(nextConfig),
    );
    if (!mounted) return;
    _normalize(generated);
    setState(() {
      _state = generated;
      _selectedTile = null;
      _owner = _owner.clamp(0, generated.config.playerCount - 1);
      _status = blank ? 'Бос карта жасалды' : 'Жаңа карта жасалды';
    });
    _scheduleAutosave();
  }

  Future<void> _openSettings() async {
    final state = _state;
    if (state == null) return;
    final config = await showModalBottomSheet<GameConfig>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _EditorSettingsSheet(config: state.config),
    );
    if (!mounted || config == null) return;
    await _regenerate(config: config);
  }

  Future<void> _play() async {
    final source = _state;
    if (source == null) return;
    final playable = GameState.fromJson(source.toJson());
    _normalize(playable);
    final alive = playable.provinces.map((province) => province.owner).toSet();
    if (!alive.contains(0) || alive.length < 2) {
      _showStatus(
        'Ойнату үшін 0-түсте және кемінде бір қарсыласта қала болсын',
      );
      return;
    }
    playable
      ..turn = 0
      ..round = 1
      ..winner = null;
    for (final tile in playable.hexes) {
      tile.unit?.ready = true;
    }
    for (final cell in playable.waterCells) {
      cell.boat?.ready = true;
    }
    if (!EditorRepository.isValidState(
      playable,
      expectedModId: widget.mod.id,
      requirePlayable: true,
      rules: widget.mod.rules,
    )) {
      _showStatus('Картада байланыссыз жер немесе жарамсыз нысан бар');
      return;
    }
    _state = playable;
    await _flushCurrentDraft();
    if (mounted) {
      setState(() => _allowPop = true);
      Navigator.pop(context, playable);
    }
  }

  void _showStatus(String message) {
    if (!mounted) return;
    setState(() => _status = message);
    showTopSnackBar(
      context,
      message,
      duration: const Duration(milliseconds: 1500),
    );
  }

  Future<void> _handleMenu(_EditorMenuAction action) async {
    switch (action) {
      case _EditorMenuAction.saveMap:
        await _saveMapFile();
        break;
      case _EditorMenuAction.exportFile:
        await _saveMapFile(export: true);
        break;
      case _EditorMenuAction.importFile:
        await _importMapFile();
        break;
      case _EditorMenuAction.save:
        await _saveNow();
        break;
      case _EditorMenuAction.load:
        await _loadDraft();
        break;
      case _EditorMenuAction.export:
        await _export();
        break;
      case _EditorMenuAction.import:
        await _import();
        break;
      case _EditorMenuAction.regenerate:
        await _regenerate();
        break;
      case _EditorMenuAction.blank:
        await _regenerate(blank: true);
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = _state;
    final palette = _rotatedPalette(
      widget.mod.palette,
      state?.config.playerColorOffset ?? 0,
    );
    return PopScope(
      canPop: _allowPop,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leaveEditor();
      },
      child: Scaffold(
        backgroundColor: DalaTheme.deepWater,
        body: SafeArea(
          child: Column(
            children: [
              _EditorHeader(
                status: _status,
                panMode: _panMode,
                onBack: _leaveEditor,
                onPanModeChanged: () => setState(() {
                  _panMode = !_panMode;
                  _status = _panMode
                      ? 'Картаны жылжыту режимі'
                      : 'Сызу режимі: басыңыз немесе сырғытыңыз';
                }),
                onSettings: _openSettings,
                onMenu: _handleMenu,
                onPlay: state == null ? null : _play,
              ),
              Expanded(
                child: state == null
                    ? const AntiyoyLoadingOverlay(
                        semanticsLabel: 'Редактор дайындалуда',
                      )
                    : _EditorBoard(
                        state: state,
                        palette: palette,
                        sprites: _sprites,
                        selectedTile: _selectedTile,
                        panMode: _panMode,
                        onTileTap: _editTile,
                      ),
              ),
              if (state != null)
                _EditorToolbar(
                  tool: _tool,
                  owner: _owner,
                  ownerCount: state.config.playerCount,
                  palette: palette,
                  sprites: _sprites,
                  object: _object,
                  navalAsset: _navalAsset,
                  strength: _strength,
                  onToolChanged: (value) => setState(() => _tool = value),
                  onOwnerChanged: (value) => setState(() => _owner = value),
                  onObjectChanged: (value) => setState(() => _object = value),
                  onNavalAssetChanged: (value) =>
                      setState(() => _navalAsset = value),
                  onStrengthChanged: (value) =>
                      setState(() => _strength = value),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EditorHeader extends StatelessWidget {
  const _EditorHeader({
    required this.status,
    required this.panMode,
    required this.onBack,
    required this.onPanModeChanged,
    required this.onSettings,
    required this.onMenu,
    required this.onPlay,
  });

  final String status;
  final bool panMode;
  final VoidCallback onBack;
  final VoidCallback onPanModeChanged;
  final VoidCallback onSettings;
  final ValueChanged<_EditorMenuAction> onMenu;
  final VoidCallback? onPlay;

  @override
  Widget build(BuildContext context) => Container(
    height: 72,
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
    color: _editorAqua,
    child: Row(
      children: [
        _EditorHeaderButton(
          tooltip: 'Артқа',
          color: _editorOrange,
          icon: Icons.arrow_back,
          onTap: onBack,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const GameText(
                'Редактор',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 24, height: 1),
              ),
              const SizedBox(height: 4),
              GameText(
                status,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 14),
              ),
            ],
          ),
        ),
        _EditorHeaderButton(
          key: const ValueKey('editor-pan-paint-toggle'),
          tooltip: panMode ? 'Сызу режиміне өту' : 'Картаны жылжыту',
          color: panMode ? _editorOrange : _editorGreen,
          icon: panMode ? Icons.pan_tool_alt : Icons.brush,
          onTap: onPanModeChanged,
        ),
        const SizedBox(width: 7),
        _EditorHeaderButton(
          tooltip: 'Карта баптаулары',
          color: _editorBlue,
          icon: Icons.tune,
          onTap: onSettings,
        ),
        const SizedBox(width: 7),
        PopupMenuButton<_EditorMenuAction>(
          tooltip: 'Карта әрекеттері',
          onSelected: onMenu,
          itemBuilder: (_) => const [
            PopupMenuItem(
              value: _EditorMenuAction.save,
              child: GameText('Жобаны сақтау'),
            ),
            PopupMenuItem(
              value: _EditorMenuAction.load,
              child: GameText('Жобаны жүктеу'),
            ),
            PopupMenuDivider(),
            PopupMenuItem(
              value: _EditorMenuAction.saveMap,
              child: GameText('Кітапханаға сақтау'),
            ),
            PopupMenuItem(
              value: _EditorMenuAction.exportFile,
              child: GameText('.dalamap экспорттау'),
            ),
            PopupMenuItem(
              value: _EditorMenuAction.importFile,
              child: GameText('Карта файлын импорттау'),
            ),
            PopupMenuItem(
              value: _EditorMenuAction.export,
              child: GameText('Картаны экспорттау'),
            ),
            PopupMenuItem(
              value: _EditorMenuAction.import,
              child: GameText('Картаны импорттау'),
            ),
            PopupMenuDivider(),
            PopupMenuItem(
              value: _EditorMenuAction.regenerate,
              child: GameText('Картаны қайта жасау'),
            ),
            PopupMenuItem(
              value: _EditorMenuAction.blank,
              child: GameText('Бос жер картасы'),
            ),
          ],
          child: const _EditorButtonSurface(
            color: _editorOlive,
            child: Icon(Icons.more_vert, color: Colors.black),
          ),
        ),
        const SizedBox(width: 7),
        _EditorHeaderButton(
          tooltip: 'Картаны ойнату',
          color: _editorGreen,
          icon: Icons.play_arrow,
          onTap: onPlay,
        ),
      ],
    ),
  );
}

class _EditorLeaveChoice extends StatelessWidget {
  const _EditorLeaveChoice({
    required this.color,
    required this.label,
    required this.onTap,
  });

  final Color color;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: color,
    child: InkWell(
      onTap: onTap,
      child: SizedBox(
        width: double.infinity,
        height: 58,
        child: Center(
          child: GameText(
            label,
            maxLines: 1,
            style: const TextStyle(fontSize: 22, color: Colors.black),
          ),
        ),
      ),
    ),
  );
}

class _EditorHeaderButton extends StatelessWidget {
  const _EditorHeaderButton({
    super.key,
    required this.tooltip,
    required this.color,
    required this.icon,
    required this.onTap,
  });

  final String tooltip;
  final Color color;
  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: context.trNullable(tooltip),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: _EditorButtonSurface(
        color: color,
        child: Icon(icon, color: Colors.black),
      ),
    ),
  );
}

class _EditorButtonSurface extends StatelessWidget {
  const _EditorButtonSurface({required this.color, required this.child});

  final Color color;
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    width: 44,
    height: 44,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(12),
      boxShadow: const [
        BoxShadow(color: Colors.black38, blurRadius: 4, offset: Offset(0, 3)),
      ],
    ),
    child: child,
  );
}

class _EditorToolbar extends StatelessWidget {
  const _EditorToolbar({
    required this.tool,
    required this.owner,
    required this.ownerCount,
    required this.palette,
    required this.sprites,
    required this.object,
    required this.navalAsset,
    required this.strength,
    required this.onToolChanged,
    required this.onOwnerChanged,
    required this.onObjectChanged,
    required this.onNavalAssetChanged,
    required this.onStrengthChanged,
  });

  final _EditorTool tool;
  final int owner;
  final int ownerCount;
  final List<Color> palette;
  final ClassicSprites? sprites;
  final TileObject object;
  final _EditorNavalAsset navalAsset;
  final int strength;
  final ValueChanged<_EditorTool> onToolChanged;
  final ValueChanged<int> onOwnerChanged;
  final ValueChanged<TileObject> onObjectChanged;
  final ValueChanged<_EditorNavalAsset> onNavalAssetChanged;
  final ValueChanged<int> onStrengthChanged;

  @override
  Widget build(BuildContext context) => Material(
    color: _editorPaper,
    elevation: 12,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 38,
            child: LayoutBuilder(
              builder: (context, constraints) => SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: ConstrainedBox(
                  constraints: BoxConstraints(minWidth: constraints.maxWidth),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _ToolButton(
                        label: 'Жер',
                        icon: Icons.water,
                        selected: tool == _EditorTool.terrain,
                        onTap: () => onToolChanged(_EditorTool.terrain),
                      ),
                      _ToolButton(
                        label: 'Түс',
                        icon: Icons.palette,
                        selected: tool == _EditorTool.owner,
                        onTap: () => onToolChanged(_EditorTool.owner),
                      ),
                      _ToolButton(
                        label: 'Нысан',
                        icon: Icons.castle,
                        selected: tool == _EditorTool.object,
                        onTap: () => onToolChanged(_EditorTool.object),
                      ),
                      _ToolButton(
                        label: 'Әскер',
                        icon: Icons.shield,
                        selected: tool == _EditorTool.unit,
                        onTap: () => onToolChanged(_EditorTool.unit),
                      ),
                      _ToolButton(
                        label: 'Теңіз',
                        icon: Icons.directions_boat,
                        selected: tool == _EditorTool.navy,
                        onTap: () => onToolChanged(_EditorTool.navy),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 5),
          SizedBox(
            height: 42,
            child: switch (tool) {
              _EditorTool.terrain => const Center(
                child: GameText(
                  'Ұяшықты басыңыз: жер ↔ су',
                  style: TextStyle(fontSize: 17),
                ),
              ),
              _EditorTool.owner => ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: ownerCount,
                separatorBuilder: (_, _) => const SizedBox(width: 7),
                itemBuilder: (_, index) => _EditorOwnerSwatch(
                  owner: index,
                  color: _paletteColor(palette, index),
                  selected: owner == index,
                  onTap: () => onOwnerChanged(index),
                ),
              ),
              _EditorTool.object => ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: _editableObjects.length,
                separatorBuilder: (_, _) => const SizedBox(width: 6),
                itemBuilder: (_, index) {
                  final value = _editableObjects[index];
                  return _EditorSpriteButton(
                    tooltip: _objectLabel(value),
                    selected: object == value,
                    sprites: sprites,
                    spriteName: _objectSpriteName(value),
                    teamSpriteName: _objectTeamSpriteName(value),
                    teamColor: _paletteColor(palette, owner),
                    badge: _objectLevel(value),
                    onTap: () => onObjectChanged(value),
                  );
                },
              ),
              _EditorTool.unit => ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: 4,
                separatorBuilder: (_, _) => const SizedBox(width: 7),
                itemBuilder: (_, index) {
                  final value = index + 1;
                  return _EditorSpriteButton(
                    tooltip: '$value-деңгейлі әскер',
                    selected: strength == value,
                    sprites: sprites,
                    spriteName: 'man$index',
                    teamSpriteName: 'man${index}_team',
                    teamColor: _paletteColor(palette, owner),
                    badge: value,
                    onTap: () => onStrengthChanged(value),
                  );
                },
              ),
              _EditorTool.navy => ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: _EditorNavalAsset.values.length,
                separatorBuilder: (_, _) => const SizedBox(width: 7),
                itemBuilder: (_, index) {
                  final value = _EditorNavalAsset.values[index];
                  return _EditorSpriteButton(
                    tooltip: _navalAssetLabel(value),
                    selected: navalAsset == value,
                    selectedColor: _editorBlue,
                    sprites: sprites,
                    spriteName: _navalSpriteName(value),
                    teamSpriteName: _navalTeamSpriteName(value),
                    teamColor: _paletteColor(palette, owner),
                    badge: _navalLevel(value),
                    onTap: () => onNavalAssetChanged(value),
                  );
                },
              ),
            },
          ),
        ],
      ),
    ),
  );
}

class _EditorOwnerSwatch extends StatelessWidget {
  const _EditorOwnerSwatch({
    required this.owner,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final int owner;
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final foreground =
        ThemeData.estimateBrightnessForColor(color) == Brightness.dark
        ? Colors.white
        : Colors.black;
    return _EditorPaletteButton(
      tooltip: '${owner + 1}-ойыншы',
      selected: selected,
      selectedColor: color,
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(5),
          border: Border.all(color: Colors.white70),
        ),
        alignment: Alignment.center,
        child: GameText(
          '${owner + 1}',
          style: TextStyle(
            color: foreground,
            fontSize: 12,
            fontWeight: FontWeight.w900,
            shadows: const [Shadow(color: Colors.black45, blurRadius: 1)],
          ),
        ),
      ),
    );
  }
}

class _EditorSpriteButton extends StatelessWidget {
  const _EditorSpriteButton({
    required this.tooltip,
    required this.selected,
    required this.sprites,
    required this.spriteName,
    required this.onTap,
    this.teamSpriteName,
    this.teamColor,
    this.badge,
    this.selectedColor = _editorGreen,
  });

  final String tooltip;
  final bool selected;
  final ClassicSprites? sprites;
  final String? spriteName;
  final String? teamSpriteName;
  final Color? teamColor;
  final int? badge;
  final Color selectedColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final image = spriteName == null ? null : sprites?.images[spriteName];
    final teamImage = teamSpriteName == null
        ? null
        : sprites?.images[teamSpriteName];
    return _EditorPaletteButton(
      tooltip: tooltip,
      selected: selected,
      selectedColor: selectedColor,
      onTap: onTap,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (spriteName == null)
            const Icon(Icons.block, size: 23, color: Colors.black87)
          else if (image == null)
            const Icon(Icons.image_outlined, size: 21, color: Colors.black38)
          else
            RawImage(
              image: image,
              fit: BoxFit.contain,
              filterQuality: FilterQuality.none,
            ),
          if (teamImage != null && teamColor != null)
            RawImage(
              image: teamImage,
              fit: BoxFit.contain,
              filterQuality: FilterQuality.none,
              color: teamColor,
              colorBlendMode: BlendMode.srcIn,
            ),
          if (badge case final value?)
            Positioned(
              right: 0,
              bottom: 0,
              child: Container(
                width: 15,
                height: 15,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: const Color(0xe6000000),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: GameText(
                  '$value',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 9,
                    height: 1,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _EditorPaletteButton extends StatelessWidget {
  const _EditorPaletteButton({
    required this.tooltip,
    required this.selected,
    required this.selectedColor,
    required this.onTap,
    required this.child,
  });

  final String tooltip;
  final bool selected;
  final Color selectedColor;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: context.trNullable(tooltip),
    child: Semantics(
      button: true,
      selected: selected,
      label: context.trNullable(tooltip),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: 40,
          height: 40,
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: selected
                ? selectedColor.withValues(alpha: .42)
                : Colors.white.withValues(alpha: .32),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected ? Colors.black87 : Colors.black38,
              width: selected ? 2.2 : 1,
            ),
            boxShadow: selected
                ? const [
                    BoxShadow(
                      color: Colors.black26,
                      blurRadius: 3,
                      offset: Offset(0, 2),
                    ),
                  ]
                : null,
          ),
          child: child,
        ),
      ),
    ),
  );
}

class _ToolButton extends StatelessWidget {
  const _ToolButton({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 68,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 5),
          decoration: BoxDecoration(
            color: selected ? _editorGreen : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.black54),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 17),
              const SizedBox(width: 3),
              Flexible(
                child: GameText(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.fade,
                  softWrap: false,
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _EditorBoard extends StatefulWidget {
  const _EditorBoard({
    required this.state,
    required this.palette,
    required this.sprites,
    required this.selectedTile,
    required this.panMode,
    required this.onTileTap,
  });

  static const radius = OrganicCells.radius;
  static const padding = OrganicCells.padding;

  final GameState state;
  final List<Color> palette;
  final ClassicSprites? sprites;
  final int? selectedTile;
  final bool panMode;
  final ValueChanged<int> onTileTap;

  static Offset _center(HexTile tile) => OrganicCells.center(tile.q, tile.r);

  static Size canvasSize(GameState state) {
    var maxX = 0.0;
    var maxY = 0.0;
    for (final tile in state.hexes) {
      if (!tile.inWorld) continue;
      final center = _center(tile);
      maxX = math.max(maxX, center.dx);
      maxY = math.max(maxY, center.dy);
    }
    return Size(maxX + radius + padding, maxY + radius + padding);
  }

  @override
  State<_EditorBoard> createState() => _EditorBoardState();
}

class _EditorBoardState extends State<_EditorBoard> {
  final TransformationController _transformation = TransformationController();
  Size? _lastViewport;
  GameState? _fittedState;
  bool _fitScheduled = false;
  final Set<int> _paintedThisStroke = <int>{};

  @override
  void dispose() {
    _transformation.dispose();
    super.dispose();
  }

  void _scheduleFit(Size viewport, Size canvasSize) {
    if (_fitScheduled) return;
    final needsFit =
        !identical(_fittedState, widget.state) || _lastViewport != viewport;
    if (!needsFit || viewport.isEmpty) return;
    _fitScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _fitScheduled = false;
      if (!mounted) return;
      final scale = MapCameraBounds.fitScale(viewport, canvasSize, max: 2.8);
      final dx = (viewport.width - canvasSize.width * scale) / 2;
      final dy = (viewport.height - canvasSize.height * scale) / 2;
      _transformation.value = Matrix4.diagonal3Values(scale, scale, 1)
        ..setTranslationRaw(dx, dy, 0);
      _fittedState = widget.state;
      _lastViewport = viewport;
    });
  }

  @override
  Widget build(BuildContext context) {
    final size = _EditorBoard.canvasSize(widget.state);
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewport = constraints.biggest;
        _scheduleFit(viewport, size);
        return MapViewport(
          transformationController: _transformation,
          canvasSize: size,
          minScale: MapCameraBounds.fitScale(viewport, size),
          maxScale: 2.8,
          interactionEnabled: widget.panMode,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: widget.panMode
                ? null
                : (details) {
                    _paintedThisStroke.clear();
                    _paintAt(details.localPosition);
                    _paintedThisStroke.clear();
                  },
            onPanStart: widget.panMode
                ? null
                : (details) {
                    _paintedThisStroke.clear();
                    _paintAt(details.localPosition);
                  },
            onPanUpdate: widget.panMode
                ? null
                : (details) => _paintAt(details.localPosition),
            onPanEnd: widget.panMode ? null : (_) => _paintedThisStroke.clear(),
            onPanCancel: widget.panMode ? null : _paintedThisStroke.clear,
            child: CustomPaint(
              key: const ValueKey('editor-board'),
              size: size,
              painter: _EditorBoardPainter(
                state: widget.state,
                palette: widget.palette,
                sprites: widget.sprites,
                selectedTile: widget.selectedTile,
              ),
            ),
          ),
        );
      },
    );
  }

  void _paintAt(Offset position) {
    var nearest = -1;
    var distance = _EditorBoard.radius;
    for (final tile in widget.state.hexes) {
      if (!tile.inWorld) continue;
      final candidate = OrganicCells.path(tile.q, tile.r).contains(position)
          ? 0.0
          : double.infinity;
      if (candidate < distance) {
        distance = candidate;
        nearest = tile.index;
      }
    }
    if (nearest >= 0 && _paintedThisStroke.add(nearest)) {
      widget.onTileTap(nearest);
    }
  }
}

class _EditorBoardPainter extends CustomPainter {
  const _EditorBoardPainter({
    required this.state,
    required this.palette,
    required this.sprites,
    required this.selectedTile,
  });

  final GameState state;
  final List<Color> palette;
  final ClassicSprites? sprites;
  final int? selectedTile;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = DalaTheme.deepWater);
    for (final tile in state.hexes) {
      if (!tile.inWorld) continue;
      final center = _EditorBoard._center(tile);
      final path = OrganicCells.path(tile.q, tile.r);
      final fill = !tile.active
          ? DalaTheme.water
          : tile.owner < 0
          ? DalaTheme.canvas
          : _paletteColor(palette, tile.owner);
      canvas.drawPath(path, Paint()..color = fill);
      canvas.drawPath(
        path,
        Paint()
          ..color = tile.index == selectedTile
              ? Colors.white
              : const Color(0x48496151)
          ..style = PaintingStyle.stroke
          ..strokeWidth = tile.index == selectedTile ? 3.2 : 1.2,
      );
      if (!tile.active || sprites == null) continue;
      _drawObject(canvas, center, tile);
      final unit = tile.unit;
      if (unit != null) {
        final level = math.min(4, math.max(1, unit.strength));
        _drawImage(
          canvas,
          sprites!['man${level - 1}'],
          center,
          const Size(43, 43),
        );
        if (tile.owner >= 0) {
          _drawImage(
            canvas,
            sprites!['man${level - 1}_team'],
            center,
            const Size(43, 43),
            tint: _paletteColor(palette, tile.owner),
          );
        }
      }
    }
    for (final cell in state.waterCells) {
      final boat = cell.boat;
      final fort = cell.seaFort;
      if ((boat == null && fort == null && !cell.seaMint) ||
          cell.tiles.isEmpty ||
          sprites == null) {
        continue;
      }
      var center = Offset.zero;
      var count = 0;
      for (final tileIndex in cell.tiles) {
        if (tileIndex < 0 || tileIndex >= state.hexes.length) continue;
        center += _EditorBoard._center(state.hexes[tileIndex]);
        count++;
      }
      if (count == 0) continue;
      center = Offset(center.dx / count, center.dy / count);
      if (cell.seaMint) {
        _drawImage(canvas, sprites!['sea_mint'], center, const Size(47, 47));
      }
      if (fort != null) {
        _drawImage(canvas, sprites!['sea_fort'], center, const Size(50, 50));
      }
      if (boat != null) {
        final level = math.min(2, math.max(1, boat.level));
        final size = level == 1 ? 47.0 : 53.0;
        _drawImage(canvas, sprites!['boat$level'], center, Size.square(size));
        if (boat.owner >= 0) {
          _drawImage(
            canvas,
            sprites!['boat${level}_team'],
            center,
            Size.square(size),
            tint: _paletteColor(palette, boat.owner),
          );
        }
      }
    }
  }

  void _drawObject(Canvas canvas, Offset center, HexTile tile) {
    final spriteName = _objectSpriteName(tile.object);
    if (spriteName == null) return;
    _drawImage(canvas, sprites![spriteName], center, const Size(46, 46));
    final teamSpriteName = _objectTeamSpriteName(tile.object);
    if (teamSpriteName != null && tile.owner >= 0) {
      _drawImage(
        canvas,
        sprites![teamSpriteName],
        center,
        const Size(46, 46),
        tint: _paletteColor(palette, tile.owner),
      );
    }
    final level = _objectLevel(tile.object);
    if (level == null) return;
    final color = tile.owner < 0
        ? Colors.black87
        : _paletteColor(palette, tile.owner);
    for (var index = 0; index < level; index++) {
      canvas.drawCircle(
        center.translate((index - (level - 1) / 2) * 6, 18),
        2.2,
        Paint()..color = color,
      );
    }
  }

  void _drawImage(
    Canvas canvas,
    ui.Image image,
    Offset center,
    Size target, {
    Color? tint,
  }) {
    final paint = Paint();
    if (tint != null) {
      paint.colorFilter = ColorFilter.mode(tint, BlendMode.srcIn);
    }
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Rect.fromCenter(
        center: center,
        width: target.width,
        height: target.height,
      ),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _EditorBoardPainter oldDelegate) => true;
}

class _EditorSettingsSheet extends StatefulWidget {
  const _EditorSettingsSheet({required this.config});

  final GameConfig config;

  @override
  State<_EditorSettingsSheet> createState() => _EditorSettingsSheetState();
}

class _EditorSettingsSheetState extends State<_EditorSettingsSheet> {
  late MapSize _mapSize = widget.config.mapSize;
  late int _players = widget.config.playerCount;
  late int _humans = widget.config.humanCount;
  late AiDifficulty _difficulty = widget.config.difficulty;
  late int _trees = widget.config.treePercent;
  late bool _slay = widget.config.slayRules;
  late bool _fog = widget.config.fogOfWar;
  late bool _diplomacy = widget.config.diplomacy;

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Container(
      constraints: const BoxConstraints(maxHeight: 680),
      margin: const EdgeInsets.all(12),
      padding: const EdgeInsets.fromLTRB(22, 18, 22, 20),
      decoration: BoxDecoration(
        color: _editorPaper,
        borderRadius: BorderRadius.circular(18),
      ),
      child: ListView(
        shrinkWrap: true,
        children: [
          const GameText(
            'Карта баптаулары',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 20),
          ),
          const SizedBox(height: 8),
          const GameText(
            'Қолданғанда карта жаңа кездейсоқ seed-пен қайта жасалады.',
            textAlign: TextAlign.center,
          ),
          _sheetSlider(
            title: 'Карта өлшемі: ${_mapSizeLabel(_mapSize)}',
            value: _mapSize.index.toDouble(),
            min: 0,
            max: (MapSize.values.length - 1).toDouble(),
            divisions: MapSize.values.length - 1,
            onChanged: (value) => setState(() {
              _mapSize = MapSize.values[value.round()];
              _players = math.min(_players, _mapSize.maxPlayers);
              _humans = math.min(_humans, _players);
            }),
          ),
          _sheetSlider(
            title: 'Түстер: $_players',
            value: _players.toDouble(),
            min: 2,
            max: _mapSize.maxPlayers.toDouble(),
            divisions: _mapSize.maxPlayers - 2,
            onChanged: (value) => setState(() {
              _players = value.round();
              _humans = math.min(_humans, _players);
            }),
          ),
          _sheetSlider(
            title: 'Адамдар: ${_humans == 0 ? 'Боттар шайқасы' : _humans}',
            value: _humans.toDouble(),
            min: 0,
            max: _players.toDouble(),
            divisions: _players,
            onChanged: (value) => setState(() => _humans = value.round()),
          ),
          _sheetSlider(
            title: 'AI: ${_difficultyLabel(_difficulty)}',
            value: _difficulty.index.toDouble(),
            min: 0,
            max: 5,
            divisions: 5,
            onChanged: (value) => setState(
              () => _difficulty = AiDifficulty.values[value.round()],
            ),
          ),
          _sheetSlider(
            title: 'Ағаштар: $_trees%',
            value: _trees.toDouble(),
            min: 0,
            max: 100,
            divisions: 10,
            onChanged: (value) => setState(() => _trees = value.round()),
          ),
          _sheetToggle('Slay ережесі', _slay, (value) => _slay = value),
          _sheetToggle('Соғыс тұманы', _fog, (value) => _fog = value),
          _sheetToggle('Дипломатия', _diplomacy, (value) => _diplomacy = value),
          const SizedBox(height: 12),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: _editorGreen,
              foregroundColor: Colors.black,
              textStyle: const TextStyle(fontSize: 20),
            ),
            onPressed: () => Navigator.pop(
              context,
              GameConfig(
                mapSize: _mapSize,
                playerCount: _players,
                humanCount: _humans,
                seed: math.Random.secure().nextInt(0x7fffffff),
                difficulty: _difficulty,
                treePercent: _trees,
                startingProvinceCount: widget.config.startingProvinceCount,
                playerColorOffset: widget.config.playerColorOffset,
                slayRules: _slay,
                fogOfWar: _fog,
                diplomacy: _diplomacy,
              ),
            ),
            child: const GameText('Қолдану және қайта жасау'),
          ),
        ],
      ),
    ),
  );

  Widget _sheetSlider({
    required String title,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required ValueChanged<double> onChanged,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      GameText(title, style: const TextStyle(fontSize: 18)),
      Slider(
        value: value.clamp(min, max),
        min: min,
        max: max,
        divisions: divisions,
        activeColor: Colors.black,
        inactiveColor: Colors.black45,
        onChanged: onChanged,
      ),
    ],
  );

  Widget _sheetToggle(String label, bool value, ValueChanged<bool> setter) =>
      SwitchListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        title: GameText(label, style: const TextStyle(fontSize: 18)),
        value: value,
        activeTrackColor: _editorGreen,
        onChanged: (next) => setState(() => setter(next)),
      );
}

GameConfig _copyConfig(GameConfig source, {int? seed, int? campaignLevel}) =>
    GameConfig(
      mapSize: source.mapSize,
      playerCount: source.playerCount,
      humanCount: source.humanCount,
      seed: seed ?? source.seed,
      difficulty: source.difficulty,
      treePercent: source.treePercent,
      startingProvinceCount: source.startingProvinceCount,
      playerColorOffset: source.playerColorOffset,
      slayRules: source.slayRules,
      fogOfWar: source.fogOfWar,
      diplomacy: source.diplomacy,
      campaignLevel: campaignLevel,
    );

const _editableObjects = <TileObject>[
  TileObject.none,
  TileObject.pine,
  TileObject.palm,
  TileObject.town,
  TileObject.farm,
  TileObject.tower,
  TileObject.strongTower,
  TileObject.grave,
  TileObject.port1,
  TileObject.port2,
  TileObject.artillery1,
  TileObject.artillery2,
  TileObject.artillery3,
];

String _objectLabel(TileObject value) => switch (value) {
  TileObject.none => 'Бос',
  TileObject.pine => 'Қарағай',
  TileObject.palm => 'Пальма',
  TileObject.town => 'Қала',
  TileObject.farm => 'Ферма',
  TileObject.tower => 'Қамал',
  TileObject.strongTower => 'Үлкен қамал',
  TileObject.grave => 'Қабір',
  TileObject.port1 => 'Порт 1',
  TileObject.port2 => 'Порт 2',
  TileObject.artillery1 => 'Арт. 1',
  TileObject.artillery2 => 'Арт. 2',
  TileObject.artillery3 => 'Арт. 3',
};

String? _objectSpriteName(TileObject value) => switch (value) {
  TileObject.none => null,
  TileObject.pine => 'pine',
  TileObject.palm => 'palm',
  TileObject.town => 'castle',
  TileObject.farm => 'farm1',
  TileObject.tower => 'tower',
  TileObject.strongTower => 'strong_tower',
  TileObject.grave => 'grave',
  TileObject.port1 => 'port1',
  TileObject.port2 => 'port2',
  TileObject.artillery1 ||
  TileObject.artillery2 ||
  TileObject.artillery3 => 'artillery',
};

String? _objectTeamSpriteName(TileObject value) => switch (value) {
  TileObject.town => 'castle_team',
  TileObject.farm => 'farm1_team',
  TileObject.tower => 'tower_team',
  TileObject.strongTower => 'strong_tower_team',
  TileObject.port1 => 'port1_team',
  TileObject.port2 => 'port2_team',
  _ => null,
};

int? _objectLevel(TileObject value) => switch (value) {
  TileObject.artillery1 => 1,
  TileObject.artillery2 => 2,
  TileObject.artillery3 => 3,
  _ => null,
};

String _navalAssetLabel(_EditorNavalAsset value) => switch (value) {
  _EditorNavalAsset.none => 'Бос',
  _EditorNavalAsset.boat1 => 'Кеме 1',
  _EditorNavalAsset.boat2 => 'Кеме 2',
  _EditorNavalAsset.seaMint => 'Су жалбызы',
  _EditorNavalAsset.seaFort => 'Теңіз қамалы',
};

String? _navalSpriteName(_EditorNavalAsset value) => switch (value) {
  _EditorNavalAsset.none => null,
  _EditorNavalAsset.boat1 => 'boat1',
  _EditorNavalAsset.boat2 => 'boat2',
  _EditorNavalAsset.seaMint => 'sea_mint',
  _EditorNavalAsset.seaFort => 'sea_fort',
};

String? _navalTeamSpriteName(_EditorNavalAsset value) => switch (value) {
  _EditorNavalAsset.boat1 => 'boat1_team',
  _EditorNavalAsset.boat2 => 'boat2_team',
  _ => null,
};

int? _navalLevel(_EditorNavalAsset value) => switch (value) {
  _EditorNavalAsset.boat1 => 1,
  _EditorNavalAsset.boat2 => 2,
  _ => null,
};

Color _paletteColor(List<Color> palette, int owner) =>
    palette.isEmpty ? Colors.grey : palette[owner % palette.length];

List<Color> _rotatedPalette(List<Color> palette, int offset) {
  if (palette.isEmpty) return const <Color>[];
  final normalized = offset % palette.length;
  return <Color>[
    for (var index = 0; index < palette.length; index++)
      palette[(index + normalized) % palette.length],
  ];
}

String _mapSizeLabel(MapSize value) => switch (value.name) {
  'small' => 'кіші',
  'medium' => 'орташа',
  'large' => 'үлкен',
  'huge' => 'өте үлкен',
  'giant' => 'орасан',
  _ => value.name,
};

String _difficultyLabel(AiDifficulty value) => switch (value) {
  AiDifficulty.veryEasy => 'жаңа ойыншы',
  AiDifficulty.easy => 'жеңіл',
  AiDifficulty.normal => 'орташа',
  AiDifficulty.hard => 'күрделі',
  AiDifficulty.veryHard => 'сарапшы',
  AiDifficulty.master => 'шебер',
};
