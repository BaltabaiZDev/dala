import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'translations.dart';

/// Language only affects presentation. Saves, LAN messages and mod identities
/// retain their original data and therefore stay identical on every device.
class GameLocale extends ChangeNotifier {
  GameLocale({String language = 'kk'})
    : _language = supported.contains(language) ? language : 'kk';
  static const supported = ['kk', 'ru', 'en'];
  static const preferenceKey = 'dala.language';
  String _language;
  String get language => _language;
  Locale get locale => Locale(_language);
  final Map<String, String> _cache = {};

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(preferenceKey);
    if (supported.contains(saved)) {
      _language = saved!;
      _cache.clear();
      notifyListeners();
    }
  }

  Future<void> select(String language) async {
    if (!supported.contains(language) || language == _language) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(preferenceKey, language);
    _language = language;
    _cache.clear();
    notifyListeners();
  }

  String translate(String source) {
    if (_language == 'kk' || source.isEmpty) return source;
    final cached = _cache[source];
    if (cached != null) return cached;
    final result = translateGameText(source, _language);
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const GameText('Тіл', style: TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final language in GameLocale.supported)
              ChoiceChip(
                key: ValueKey('language-$language'),
                label: Text(
                  const {
                    'kk': 'Қазақша',
                    'ru': 'Русский',
                    'en': 'English',
                  }[language]!,
                ),
                selected: (controller?.language ?? 'kk') == language,
                onSelected: controller == null
                    ? null
                    : (_) => controller.select(language),
              ),
          ],
        ),
      ],
    );
  }
}
