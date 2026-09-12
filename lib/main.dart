import 'src/ui/dala_theme.dart';
import 'src/ui/dala_viewport.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'src/l10n/game_locale.dart';

import 'src/modding/game_mod.dart';
import 'src/persistence/save_repository.dart';
import 'src/ui/home_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  final gameMod = await GameMod.loadDefault();
  final saves = SaveRepository();
  final language = GameLocale();
  await language.load();
  runApp(AntiyoyApp(gameMod: gameMod, saves: saves, language: language));
}

class AntiyoyApp extends StatefulWidget {
  const AntiyoyApp({
    required this.gameMod,
    required this.saves,
    this.language,
    super.key,
  });

  final GameMod gameMod;
  final SaveRepository saves;
  final GameLocale? language;

  @override
  State<AntiyoyApp> createState() => _AntiyoyAppState();
}

class _AntiyoyAppState extends State<AntiyoyApp> {
  late final GameLocale language = widget.language ?? GameLocale();
  @override
  void dispose() {
    if (widget.language == null) language.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GameLocaleScope(
      controller: language,
      child: AnimatedBuilder(
        animation: language,
        builder: (context, _) => MaterialApp(
          title: widget.gameMod.title,
          debugShowCheckedModeBanner: false,
          theme: DalaTheme.light,
          locale: language.locale,
          supportedLocales: GameLocale.supportedLocales,
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          builder: (context, child) => DalaViewport(child: child!),
          home: HomeScreen(gameMod: widget.gameMod, saves: widget.saves),
        ),
      ),
    );
  }
}
