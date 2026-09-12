import 'src/ui/dala_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'src/modding/game_mod.dart';
import 'src/persistence/save_repository.dart';
import 'src/ui/home_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  final gameMod = await GameMod.loadDefault();
  final saves = SaveRepository();
  runApp(AntiyoyApp(gameMod: gameMod, saves: saves));
}

class AntiyoyApp extends StatelessWidget {
  const AntiyoyApp({required this.gameMod, required this.saves, super.key});

  final GameMod gameMod;
  final SaveRepository saves;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: gameMod.title,
      debugShowCheckedModeBanner: false,
      theme: DalaTheme.light,
      home: HomeScreen(gameMod: gameMod, saves: saves),
    );
  }
}
