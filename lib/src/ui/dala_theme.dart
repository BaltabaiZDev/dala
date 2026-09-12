import 'package:flutter/material.dart';

class DalaTheme {
  static const ink = Color(0xff243e38);
  static const paper = Color(0xfff5f0e3);
  static const canvas = Color(0xffe2dfcb);
  static const green = Color(0xff86b793);
  static const teal = Color(0xff73acb1);
  static const gold = Color(0xffdbc18a);
  static const rose = Color(0xffce8f7f);
  static const blue = Color(0xff9bbed0);
  static const line = Color(0xffc4cbb8);
  static const water = Color(0xff669ea9);
  static const deepWater = Color(0xff365c68);

  static ThemeData get light => ThemeData(
    useMaterial3: true,
    fontFamily: 'Dala Sans',
    fontFamilyFallback: const ['Dala Math', 'Dala Symbols'],
    colorScheme: ColorScheme.fromSeed(
      seedColor: const Color(0xff397c69),
      surface: paper,
      onSurface: ink,
      primary: const Color(0xff397c69),
      secondary: teal,
      tertiary: gold,
    ),
    scaffoldBackgroundColor: canvas,
    textTheme: ThemeData.light().textTheme.apply(
      fontFamily: 'Dala Sans',
      fontFamilyFallback: const ['Dala Math', 'Dala Symbols'],
      bodyColor: ink,
      displayColor: ink,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: paper,
      foregroundColor: ink,
      elevation: 0,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: paper,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(48, 46),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white54,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: line),
      ),
    ),
    dividerTheme: const DividerThemeData(color: line, thickness: 1),
  );

  static BoxDecoration panel([Color color = paper]) => BoxDecoration(
    color: color,
    borderRadius: BorderRadius.circular(22),
    border: Border.all(color: Colors.white.withValues(alpha: .65)),
    boxShadow: const [
      BoxShadow(color: Color(0x20243e38), blurRadius: 20, offset: Offset(0, 7)),
    ],
  );
}
