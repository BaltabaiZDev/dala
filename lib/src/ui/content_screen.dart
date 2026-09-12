import '../l10n/game_locale.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../modding/content_files.dart';
import '../modding/content_library.dart';
import '../modding/content_package.dart';
import '../modding/content_storage.dart';
import '../modding/game_mod.dart';
import 'dala_theme.dart';
import 'top_snack_bar.dart';

class ContentScreen extends StatefulWidget {
  const ContentScreen({required this.library, super.key});
  final ContentLibrary library;
  @override
  State<ContentScreen> createState() => _ContentScreenState();
}

class _ContentScreenState extends State<ContentScreen> {
  bool _busy = false;
  bool _maps = false;

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } on Object catch (error) {
      if (mounted) showTopSnackBar(context, error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _import() => _run(() async {
    final file = await ContentFiles.pick();
    if (file == null) return;
    await widget.library.importFile(file.name, file.bytes);
    if (mounted) showTopSnackBar(context, 'Пакет кітапханаға қосылды');
  });

  Future<void> _template() => _run(() async {
    final raw = widget.library.defaultMod.toJson()
      ..['id'] = 'my_dala_mod'
      ..['name'] = 'Менің модым'
      ..['title'] = 'Менің далам'
      ..['author'] = 'Мод авторы'
      ..['description'] =
          'mod.json ішіндегі rules пен palette өрістерін өзгертіңіз.';
    await ContentFiles.save(
      'my_dala_mod.dalamod',
      ContentPackage(mod: GameMod.fromJson(raw)).encode(),
    );
  });

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: DalaTheme.canvas,
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: AnimatedBuilder(
            animation: widget.library,
            builder: (context, _) {
              final library = widget.library;
              return Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Column(
                  children: [
                    Row(
                      children: [
                        IconButton(
                          tooltip: context.trNullable('Артқа'),
                          onPressed: () => Navigator.pop(context),
                          icon: const Icon(Icons.arrow_back_rounded),
                        ),
                        const Expanded(
                          child: GameText(
                            'Модтар мен карталар',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        const Icon(
                          Icons.flag_outlined,
                          color: DalaTheme.deepWater,
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: _tab('Модтар', library.mods.length, false),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _tab('Карталар', library.maps.length, true),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 4,
                      children: [
                        _tool('Импорт', Icons.file_open_outlined, _import),
                        _tool(
                          'Қайта оқу',
                          Icons.refresh,
                          () => _run(library.refresh),
                        ),
                        if (!_maps)
                          _tool(
                            'Мод үлгісі',
                            Icons.inventory_2_outlined,
                            _template,
                          ),
                      ],
                    ),
                    if (_busy) const LinearProgressIndicator(minHeight: 2),
                    if (library.errors.isNotEmpty)
                      GameText(
                        library.errors.join('\n'),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: DalaTheme.rose,
                          fontSize: 12,
                        ),
                      ),
                    Expanded(
                      child: _maps ? _mapList(library) : _modList(library),
                    ),
                    if (library.location.isNotEmpty ||
                        library.storage is ContentFolderPicker)
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          if (library.location.isNotEmpty)
                            _tool(
                              'mods / maps',
                              Icons.folder_outlined,
                              () async {
                                await Clipboard.setData(
                                  ClipboardData(text: library.location),
                                );
                                if (context.mounted) {
                                  showTopSnackBar(
                                    context,
                                    'Қалта жолы көшірілді',
                                  );
                                }
                              },
                            ),
                          if (library.storage is ContentFolderPicker &&
                              (library.storage as ContentFolderPicker)
                                  .canChooseFolder)
                            Flexible(
                              child: _tool(
                                'Қалтаны таңдау',
                                Icons.drive_file_move_outlined,
                                () => _run(() async {
                                  if (await (library.storage
                                          as ContentFolderPicker)
                                      .chooseFolder()) {
                                    await library.refresh();
                                  }
                                }),
                              ),
                            ),
                        ],
                      ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    ),
  );

  Widget _tab(String label, int count, bool maps) => TextButton(
    style: TextButton.styleFrom(
      foregroundColor: DalaTheme.ink,
      backgroundColor: _maps == maps ? DalaTheme.gold : DalaTheme.paper,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      padding: const EdgeInsets.symmetric(vertical: 12),
    ),
    onPressed: () => setState(() => _maps = maps),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        GameText(label, style: const TextStyle(fontWeight: FontWeight.w800)),
        const SizedBox(width: 8),
        GameText('$count', style: const TextStyle(fontSize: 12)),
      ],
    ),
  );

  Widget _tool(String label, IconData icon, VoidCallback onTap) =>
      TextButton.icon(
        style: TextButton.styleFrom(
          foregroundColor: DalaTheme.deepWater,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          textStyle: const TextStyle(fontFamily: 'Dala Sans', fontSize: 12),
        ),
        onPressed: _busy ? null : onTap,
        icon: Icon(icon, size: 16),
        label: GameText(label),
      );

  Widget _modList(ContentLibrary library) {
    final active = library.activeHashes;
    final ordered = [
      ...library.activeMods,
      ...library.mods.where((entry) => !active.contains(entry.hash)),
    ];
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 6),
      children: [
        Row(
          children: [
            Expanded(
              child: GameText(
                active.isEmpty
                    ? 'Модтар өшірулі'
                    : 'Қосулы модтар: ${active.length}',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            TextButton(
              onPressed: _busy
                  ? null
                  : () => _run(() => library.activate(null)),
              child: const GameText(
                'Кәдімгі DALA',
                style: TextStyle(fontSize: 12),
              ),
            ),
          ],
        ),
        if (active.length > 1)
          const Padding(
            padding: EdgeInsets.only(bottom: 10),
            child: GameText(
              'Реті жоғарыдан төмен. Бірдей баптауды төмендегі мод өзгертеді.',
              style: TextStyle(fontSize: 11, color: DalaTheme.deepWater),
            ),
          ),
        if (library.conflicts.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: GameText(
              'Қайталанған баптаулар: ${library.conflicts.length}. Соңғы мод басым.',
              style: const TextStyle(fontSize: 12, color: DalaTheme.deepWater),
            ),
          ),
        for (final entry in ordered) _modRow(entry, active.indexOf(entry.hash)),
        if (ordered.isEmpty)
          const _EmptyContent(
            icon: Icons.inventory_2_outlined,
            title: 'Өз далаңды жаса',
            help: '.dalamod не .zip импорттаңыз немесе мод үлгісін алыңыз.',
          ),
      ],
    );
  }

  Widget _modRow(InstalledMod entry, int rank) => _entry(
    active: rank >= 0,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            if (rank >= 0)
              Padding(
                padding: const EdgeInsets.only(right: 10),
                child: GameText(
                  '${rank + 1}',
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  GameText(
                    entry.mod.name,
                    translate: false,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  GameText(
                    'v${entry.mod.version}${entry.mod.author.isEmpty ? '' : ' · ${entry.mod.author}'}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11),
                  ),
                ],
              ),
            ),
            Switch(
              value: rank >= 0,
              onChanged: _busy
                  ? null
                  : (enabled) => _run(
                      () => widget.library.setEnabled(entry.hash, enabled),
                    ),
            ),
          ],
        ),
        if (entry.mod.description.isNotEmpty)
          GameText(
            entry.mod.description,
            translate: false,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11),
          ),
        Row(
          children: [
            if (rank >= 0) ...[
              IconButton(
                tooltip: context.trNullable('Жоғары'),
                iconSize: 18,
                onPressed: _busy || rank == 0
                    ? null
                    : () => _run(() => widget.library.moveMod(entry.hash, -1)),
                icon: const Icon(Icons.arrow_upward),
              ),
              IconButton(
                tooltip: context.trNullable('Төмен'),
                iconSize: 18,
                onPressed:
                    _busy || rank == widget.library.activeHashes.length - 1
                    ? null
                    : () => _run(() => widget.library.moveMod(entry.hash, 1)),
                icon: const Icon(Icons.arrow_downward),
              ),
            ],
            Expanded(
              child: Align(
                alignment: Alignment.centerRight,
                child: _tool(
                  'Экспорт',
                  Icons.ios_share,
                  () => _run(() async {
                    await ContentFiles.save(
                      '${entry.mod.id}.dalamod',
                      entry.package.encode(),
                    );
                  }),
                ),
              ),
            ),
            IconButton(
              tooltip: context.trNullable('Өшіру'),
              iconSize: 18,
              onPressed: _busy
                  ? null
                  : () => _run(() => widget.library.remove(entry.path)),
              icon: const Icon(Icons.delete_outline),
            ),
          ],
        ),
      ],
    ),
  );

  Widget _mapList(ContentLibrary library) => ListView(
    padding: const EdgeInsets.symmetric(vertical: 12),
    children: [
      if (library.maps.isEmpty)
        const _EmptyContent(
          icon: Icons.map_outlined,
          title: 'Жаңа жорық',
          help: 'Редакторда карта сақтаңыз немесе .dalamap файлын импорттаңыз.',
        ),
      for (final entry in library.maps)
        _mapRow(entry, library.modForMap(entry)),
    ],
  );

  Widget _mapRow(InstalledMap entry, GameMod? mod) => _entry(
    active: false,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GameText(
          entry.map.name,
          translate: false,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
        ),
        GameText(
          mod?.name ?? 'Картаға қажет модтарды орнатыңыз.',
          translate: mod == null,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 11),
        ),
        Row(
          children: [
            TextButton.icon(
              onPressed: _busy || mod == null
                  ? null
                  : () => Navigator.pop(context, entry),
              icon: Icon(
                mod == null ? Icons.lock_outline : Icons.play_arrow,
                size: 18,
              ),
              label: const GameText('Ойнау'),
            ),
            const Spacer(),
            _tool(
              'Экспорт',
              Icons.ios_share,
              () => _run(() async {
                await ContentFiles.save('dala-map.dalamap', entry.map.encode());
              }),
            ),
            if (entry.packageHash == null)
              IconButton(
                tooltip: context.trNullable('Өшіру'),
                iconSize: 18,
                onPressed: _busy
                    ? null
                    : () => _run(() => widget.library.remove(entry.path)),
                icon: const Icon(Icons.delete_outline),
              ),
          ],
        ),
      ],
    ),
  );

  Widget _entry({required bool active, required Widget child}) => Container(
    margin: const EdgeInsets.only(bottom: 8),
    padding: const EdgeInsets.fromLTRB(12, 8, 8, 0),
    decoration: BoxDecoration(
      color: DalaTheme.paper,
      border: Border(
        left: BorderSide(
          width: 4,
          color: active ? DalaTheme.green : DalaTheme.gold,
        ),
      ),
    ),
    child: child,
  );
}

class _EmptyContent extends StatelessWidget {
  const _EmptyContent({
    required this.icon,
    required this.title,
    required this.help,
  });
  final IconData icon;
  final String title;
  final String help;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
    child: Column(
      children: [
        Icon(icon, size: 44, color: DalaTheme.deepWater),
        const SizedBox(height: 14),
        GameText(
          title,
          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
        ),
        const SizedBox(height: 8),
        GameText(
          help,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 13, height: 1.5),
        ),
      ],
    ),
  );
}
