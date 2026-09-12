import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'languages.dart';
import 'translations.dart';

/// Language only affects presentation. Saves, LAN messages and mod identities
/// retain their original data and therefore stay identical on every device.
class GameLocale extends ChangeNotifier {
  GameLocale({String language = 'kk'})
    : _language = supported.contains(language) ? language : 'kk';
  static final supported = List<String>.unmodifiable(
    dalaLanguages.map((language) => language.code),
  );
  static final supportedLocales = List<Locale>.unmodifiable(
    dalaLanguages.map((language) => language.locale),
  );
  static const preferenceKey = 'dala.language';
  String _language;
  String get language => _language;
  Locale get locale =>
      dalaLanguages.firstWhere((l) => l.code == _language).locale;
  final Map<String, String> _cache = {};
  GameTranslationCatalog? _catalog;
  int _request = 0;

  Future<GameTranslationCatalog?> _readCatalog(String code) async {
    if (const ['kk', 'ru', 'en'].contains(code)) return null;
    final raw = await rootBundle.loadString(
      'assets/l10n/$code.json',
      cache: false,
    );
    return GameTranslationCatalog(
      Map<String, String>.from(jsonDecode(raw) as Map),
    );
  }

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(preferenceKey);
    final code = supported.contains(saved) ? saved! : _language;
    try {
      _catalog = await _readCatalog(code);
      _language = code;
      _cache.clear();
      notifyListeners();
    } on Object {
      // A damaged language asset must not prevent launching the game.
      _language = 'kk';
      _catalog = null;
    }
  }

  Future<void> select(String language) async {
    if (!supported.contains(language)) return;
    final request = ++_request;
    final catalog = await _readCatalog(language);
    if (request != _request) return;
    final prefs = await SharedPreferences.getInstance();
    if (request != _request) return;
    await prefs.setString(preferenceKey, language);
    if (request != _request) return;
    _language = language;
    _catalog = catalog;
    _cache.clear();
    notifyListeners();
  }

  String translate(String source) {
    if (_language == 'kk' || source.isEmpty) return source;
    final cached = _cache[source];
    if (cached != null) return cached;
    final result =
        _catalog?.translate(source) ?? translateGameText(source, _language);
    if (_cache.length >= 1024) _cache.clear();
    _cache[source] = result;
    return result;
  }
}

class GameLocaleScope extends InheritedNotifier<GameLocale> {
  const GameLocaleScope({
    required GameLocale controller,
    required super.child,
    super.key,
  }) : super(notifier: controller);

  static GameLocale? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<GameLocaleScope>()?.notifier;
}

extension GameTranslation on BuildContext {
  String tr(String text) =>
      GameLocaleScope.maybeOf(this)?.translate(text) ?? text;
  String? trNullable(String? text) => text == null ? null : tr(text);
}

/// Const-friendly presentation boundary for both static labels and game hints.
/// User-authored names/descriptions explicitly opt out with [translate].
class GameText extends StatelessWidget {
  const GameText(
    this.data, {
    super.key,
    this.style,
    this.textAlign,
    this.textDirection,
    this.softWrap,
    this.overflow,
    this.maxLines,
    this.semanticsLabel,
    this.textWidthBasis,
    this.textHeightBehavior,
    this.textScaler,
    this.strutStyle,
    this.translate = true,
  });
  final String data;
  final TextStyle? style;
  final TextAlign? textAlign;
  final TextDirection? textDirection;
  final bool? softWrap;
  final TextOverflow? overflow;
  final int? maxLines;
  final String? semanticsLabel;
  final TextWidthBasis? textWidthBasis;
  final TextHeightBehavior? textHeightBehavior;
  final TextScaler? textScaler;
  final StrutStyle? strutStyle;
  final bool translate;
  @override
  Widget build(BuildContext context) => Text(
    translate ? context.tr(data) : data,
    style: style,
    textAlign: textAlign,
    textDirection: textDirection,
    softWrap: softWrap,
    overflow: overflow,
    maxLines: maxLines,
    semanticsLabel: semanticsLabel == null ? null : context.tr(semanticsLabel!),
    textWidthBasis: textWidthBasis,
    textHeightBehavior: textHeightBehavior,
    textScaler: textScaler,
    strutStyle: strutStyle,
  );
}

class LanguagePicker extends StatelessWidget {
  const LanguagePicker({super.key});
  @override
  Widget build(BuildContext context) {
    final controller = GameLocaleScope.maybeOf(context);
    final current = dalaLanguages.firstWhere(
      (language) => language.code == (controller?.language ?? 'kk'),
    );
    return ListTile(
      key: const ValueKey('language-picker'),
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.language),
      title: const GameText('Тіл'),
      subtitle: Text(current.nativeName),
      trailing: const Icon(Icons.chevron_right),
      onTap: controller == null
          ? null
          : () => showDialog<void>(
              context: context,
              builder: (_) => _LanguageDialog(controller: controller),
            ),
    );
  }
}

class _LanguageDialog extends StatefulWidget {
  const _LanguageDialog({required this.controller});
  final GameLocale controller;
  @override
  State<_LanguageDialog> createState() => _LanguageDialogState();
}

class _LanguageDialogState extends State<_LanguageDialog> {
  String _query = '';
  bool _loading = false;
  String? _error;

  Future<void> _select(String code) async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await widget.controller.select(code);
      if (mounted) Navigator.pop(context);
    } on Object {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Тіл жүктелмеді. Қайта көріңіз.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final matches = dalaLanguages
        .where(
          (l) => '${l.nativeName} ${l.englishName} ${l.code}'
              .toLowerCase()
              .contains(_query),
        )
        .toList();
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .75,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: GameText(
                        'Тіл',
                        style: TextStyle(fontWeight: FontWeight.w800),
                      ),
                    ),
                    IconButton(
                      tooltip: context.tr('Артқа'),
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                TextField(
                  key: const ValueKey('language-search'),
                  enabled: !_loading,
                  decoration: InputDecoration(
                    hintText: context.tr('Тілді іздеу'),
                    prefixIcon: const Icon(Icons.search),
                  ),
                  onChanged: (value) =>
                      setState(() => _query = value.trim().toLowerCase()),
                ),
                if (_loading) const LinearProgressIndicator(),
                if (_error != null) GameText(_error!),
                Expanded(
                  child: matches.isEmpty
                      ? const Center(child: GameText('Тіл табылмады'))
                      : ListView.builder(
                          itemCount: matches.length,
                          itemBuilder: (context, i) {
                            final language = matches[i];
                            final selected =
                                language.code == widget.controller.language;
                            return ListTile(
                              key: ValueKey('language-${language.code}'),
                              selected: selected,
                              title: Text(language.nativeName),
                              subtitle: Text(language.englishName),
                              trailing: selected
                                  ? const Icon(Icons.check)
                                  : null,
                              onTap: _loading
                                  ? null
                                  : () => _select(language.code),
                            );
                          },
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
