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
  Widget build(BuildContext context) => DefaultTabController(
    length: 2,
    child: Scaffold(
      backgroundColor: DalaTheme.canvas,
      appBar: AppBar(
        title: const Text('Модтар мен карталар'),
        bottom: const TabBar(
          tabs: [
            Tab(text: 'Модтар'),
            Tab(text: 'Карталар'),
          ],
        ),
      ),
      body: AnimatedBuilder(
        animation: widget.library,
        builder: (context, _) {
          final library = widget.library;
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      onPressed: _busy ? null : _import,
                      icon: const Icon(Icons.file_open_outlined),
                      label: const Text('Импорт'),
                    ),
                    if (library.storage is ContentFolderPicker &&
                        (library.storage as ContentFolderPicker)
                            .canChooseFolder)
                      OutlinedButton.icon(
                        onPressed: _busy
                            ? null
                            : () => _run(() async {
                                if (await (library.storage
                                        as ContentFolderPicker)
                                    .chooseFolder()) {
                                  await library.refresh();
                                }
                              }),
                        icon: const Icon(Icons.folder_open),
                        label: const Text('Қалтаны таңдау'),
                      ),
                    OutlinedButton.icon(
                      onPressed: _busy ? null : () => _run(library.refresh),
                      icon: const Icon(Icons.refresh),
                      label: const Text('Қайта оқу'),
                    ),
                    OutlinedButton(
                      onPressed: _busy ? null : _template,
                      child: const Text('Мод үлгісі'),
                    ),
                  ],
                ),
              ),
              if (_busy) const LinearProgressIndicator(),
              if (library.errors.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    library.errors.join('\n'),
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: DalaTheme.rose),
                  ),
                ),
              Expanded(
                child: TabBarView(
                  children: [
                    ListView(
                      padding: const EdgeInsets.all(12),
                      children: [
                        Card(
                          child: ListTile(
                            title: const Text('Кәдімгі DALA'),
                            subtitle: const Text(
                              'Жаңа ойынға қолданылатын ережелер',
                            ),
                            trailing: Icon(
                              library.activeHash == null
                                  ? Icons.check_circle
                                  : Icons.radio_button_unchecked,
                            ),
                            onTap: _busy
                                ? null
                                : () => _run(() => library.activate(null)),
                          ),
                        ),
                        for (final entry in library.mods)
                          Card(
                            child: Column(
                              children: [
                                ListTile(
                                  title: Text(entry.mod.name),
                                  subtitle: Text(
                                    'v${entry.mod.version}${entry.mod.author.isEmpty ? '' : ' · ${entry.mod.author}'}\n${entry.mod.description}',
                                  ),
                                  trailing: Switch(
                                    value: entry.hash == library.activeHash,
                                    onChanged: _busy
                                        ? null
                                        : (on) => _run(
                                            () => library.activate(
                                              on ? entry.hash : null,
                                            ),
                                          ),
                                  ),
                                ),
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.end,
                                  children: [
                                    TextButton(
                                      onPressed: _busy
                                          ? null
                                          : () => _run(() async {
                                              await ContentFiles.save(
                                                '${entry.mod.id}.dalamod',
                                                entry.package.encode(),
                                              );
                                            }),
                                      child: const Text('Экспорт'),
                                    ),
                                    TextButton(
                                      onPressed: _busy
                                          ? null
                                          : () => _run(
                                              () => library.remove(entry.path),
                                            ),
                                      child: const Text('Өшіру'),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        if (library.mods.isEmpty)
                          const Padding(
                            padding: EdgeInsets.all(20),
                            child: Text(
                              'Мод үлгісін экспорттап, mod.json ережелерін өзгертіңіз. ZIP архивін .dalamod деп атаңыз да mods қалтасына салыңыз немесе импорттаңыз.',
                            ),
                          ),
                        const Padding(
                          padding: EdgeInsets.all(12),
                          child: Text(
                            'Бір ереже моды қосылады. Жаңа шайқас оны автоматты қолданады. Бұрынғы сақтаулар өз ережесін сақтайды.',
                          ),
                        ),
                      ],
                    ),
                    ListView(
                      padding: const EdgeInsets.all(12),
                      children: [
                        if (library.maps.isEmpty)
                          const Padding(
                            padding: EdgeInsets.all(20),
                            child: Text(
                              'Редакторда карта жасап, «Кітапханаға сақтау» басыңыз. .dalamap файлын maps қалтасына салуға немесе импорттауға болады.',
                            ),
                          ),
                        for (final entry in library.maps)
                          Card(
                            child: Column(
                              children: [
                                ListTile(
                                  leading: const Icon(Icons.map_outlined),
                                  title: Text(entry.map.name),
                                  subtitle: Text(
                                    library.modForMap(entry)?.name ??
                                        'Керек мод: ${entry.map.modId}',
                                  ),
                                ),
                                Wrap(
                                  spacing: 8,
                                  children: [
                                    FilledButton(
                                      onPressed:
                                          _busy ||
                                              library.modForMap(entry) == null
                                          ? null
                                          : () => Navigator.pop(context, entry),
                                      child: const Text('Ойнау'),
                                    ),
                                    TextButton(
                                      onPressed: _busy
                                          ? null
                                          : () => _run(() async {
                                              await ContentFiles.save(
                                                'dala-map.dalamap',
                                                entry.map.encode(),
                                              );
                                            }),
                                      child: const Text('Экспорт'),
                                    ),
                                    if (entry.packageHash == null)
                                      TextButton(
                                        onPressed: _busy
                                            ? null
                                            : () => _run(
                                                () =>
                                                    library.remove(entry.path),
                                              ),
                                        child: const Text('Өшіру'),
                                      ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              if (library.location.isNotEmpty)
                SafeArea(
                  top: false,
                  child: ListTile(
                    dense: true,
                    leading: const Icon(Icons.folder_outlined),
                    title: Text(
                      library.location,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: const Text('mods / maps · жолды көшіру'),
                    onTap: () => Clipboard.setData(
                      ClipboardData(text: library.location),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    ),
  );
}
