import 'catalog.dart';

final _templates = [
  for (final entry in gameTranslations.entries)
    if (entry.key.contains(RegExp(r'\{\d+\}')))
      _Template(entry.key, entry.value),
]..sort((a, b) => b.specificity.compareTo(a.specificity));

String translateGameText(String source, String language) {
  if (language == 'kk') return source;
  final index = language == 'ru' ? 0 : 1;
  final exact = gameTranslations[source];
  if (exact != null) return exact[index];
  for (final template in _templates) {
    final match = template.pattern.firstMatch(source);
    if (match != null) {
      return template.translations[index].replaceAllMapped(
        RegExp(r'\{(\d+)\}'),
        (m) {
          final group = template.arguments.indexOf(int.parse(m[1]!)) + 1;
          return match[group] ?? '';
        },
      );
    }
  }
  // Composite HUD lines keep numbers, player names and mod titles intact.
  for (final separator in ['\n', ' · ']) {
    if (source.contains(separator)) {
      return source
          .split(separator)
          .map((part) => translateGameText(part, language))
          .join(separator);
    }
  }
  return source;
}

/// One selected language is loaded at a time, including its dynamic templates.
class GameTranslationCatalog {
  GameTranslationCatalog(this.strings)
    : _templates = [
        for (final entry in strings.entries)
          if (entry.key.contains(RegExp(r'\{\d+\}')))
            _Template(entry.key, [entry.value]),
      ]..sort((a, b) => b.specificity.compareTo(a.specificity));

  final Map<String, String> strings;
  final List<_Template> _templates;

  String translate(String source) {
    final exact = strings[source];
    if (exact != null) return exact;
    for (final template in _templates) {
      final match = template.pattern.firstMatch(source);
      if (match == null) continue;
      return template.translations.first.replaceAllMapped(
        RegExp(r'\{(\d+)\}'),
        (m) => match[template.arguments.indexOf(int.parse(m[1]!)) + 1] ?? '',
      );
    }
    for (final separator in ['\n', ' · ']) {
      if (source.contains(separator)) {
        return source.split(separator).map(translate).join(separator);
      }
    }
    return source;
  }
}

class _Template {
  _Template(String source, this.translations) {
    specificity = source.replaceAll(RegExp(r'\{\d+\}'), '').length;
    final buffer = StringBuffer('^');
    var cursor = 0;
    for (final match in RegExp(r'\{(\d+)\}').allMatches(source)) {
      buffer.write(RegExp.escape(source.substring(cursor, match.start)));
      buffer.write('(.+?)');
      arguments.add(int.parse(match[1]!));
      cursor = match.end;
    }
    buffer.write(RegExp.escape(source.substring(cursor)));
    buffer.write(r'$');
    pattern = RegExp(buffer.toString(), dotAll: true);
  }
  late final RegExp pattern;
  late final int specificity;
  final List<int> arguments = [];
  final List<String> translations;
}
