import 'package:flutter/widgets.dart';

class DalaLanguage {
  const DalaLanguage(this.code, this.nativeName, this.englishName);
  final String code;
  final String nativeName;
  final String englishName;
  Locale get locale {
    final parts = code.split('_');
    return Locale(parts.first, parts.length > 1 ? parts[1] : null);
  }
}

// Classic Antiyoy's 25 languages, plus DALA's original Kazakh.
const dalaLanguages = [
  DalaLanguage('kk', 'Қазақша', 'Kazakh'),
  DalaLanguage('ru', 'Русский', 'Russian'),
  DalaLanguage('en', 'English', 'English'),
  DalaLanguage('uk', 'Українська', 'Ukrainian'),
  DalaLanguage('de', 'Deutsch', 'German'),
  DalaLanguage('cs', 'Čeština', 'Czech'),
  DalaLanguage('fr', 'Français', 'French'),
  DalaLanguage('pl', 'Polski', 'Polish'),
  DalaLanguage('it', 'Italiano', 'Italian'),
  DalaLanguage('es', 'Español', 'Spanish'),
  DalaLanguage('sk', 'Slovenčina', 'Slovak'),
  DalaLanguage('zh_CN', '简体中文', 'Chinese (Simplified)'),
  DalaLanguage('tr', 'Türkçe', 'Turkish'),
  DalaLanguage('bg', 'Български', 'Bulgarian'),
  DalaLanguage('pt_BR', 'Português (Brasil)', 'Portuguese (Brazil)'),
  DalaLanguage('nl', 'Nederlands', 'Dutch'),
  DalaLanguage('hu', 'Magyar', 'Hungarian'),
  DalaLanguage('be', 'Беларуская', 'Belarusian'),
  DalaLanguage('id', 'Bahasa Indonesia', 'Indonesian'),
  DalaLanguage('el', 'Ελληνικά', 'Greek'),
  DalaLanguage('nb', 'Norsk bokmål', 'Norwegian Bokmål'),
  DalaLanguage('sr', 'Српски', 'Serbian'),
  DalaLanguage('lt', 'Lietuvių', 'Lithuanian'),
  DalaLanguage('hr', 'Hrvatski', 'Croatian'),
  DalaLanguage('ca', 'Català', 'Catalan'),
  DalaLanguage('lv', 'Latviešu', 'Latvian'),
];
