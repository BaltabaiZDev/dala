import 'package:antiyoy_self/src/ui/dala_theme.dart';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:antiyoy_self/src/game/game_engine.dart';
import 'package:antiyoy_self/src/game/models.dart';
import 'package:antiyoy_self/src/game/player_names.dart';
import 'package:antiyoy_self/src/modding/game_mod.dart';
import 'package:antiyoy_self/src/persistence/editor_repository.dart';
import 'package:antiyoy_self/src/ui/diplomacy_badge.dart';
import 'package:antiyoy_self/src/ui/hex_board.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'diplomacy_social_test.dart' show socialFixture;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await (FontLoader(
      'Antiyoy',
    )..addFont(rootBundle.load('assets/classic/font.ttf'))).load();
  });

  test(
    'Classic names are deterministic, varied, unique and bounded for 15 colors',
    () {
      final all = <String>{};
      for (var seed = 0; seed < 100; seed++) {
        final names = generatePlayerNames(seed, 15);
        expect(names, generatePlayerNames(seed, 15));
        expect(names.toSet(), hasLength(15));
        expect(
          names.every(
            (name) =>
                RegExp(r'^[А-Я][а-я]+$').hasMatch(name) && name.length <= 15,
          ),
          isTrue,
        );
        all.addAll(names);
      }
      expect(all.length, greaterThan(900));
    },
  );

  test('new generated names avoid all preserved custom names', () {
    final reserved = generatePlayerNames(7, 15);
    expect(
      generatePlayerNames(
        7,
        15,
        reserved: reserved,
      ).toSet().intersection(reserved.toSet()),
      isEmpty,
    );
  });

  test(
    'names persist without consuming simulation RNG or changing at conquest',
    () async {
      final mod = await GameMod.loadDefault();
      final state = socialFixture();
      final names = List<String>.of(state.playerNames);
      final randomState = state.rngState;
      final roundTrip = GameState.fromJson(
        jsonDecode(jsonEncode(state.toJson())) as Map<String, dynamic>,
      );
      expect(roundTrip.playerNames, names);
      expect(roundTrip.rngState, randomState);
      GameEngine(mod: mod, state: state).rebuildProvinces();
      expect(state.playerNames, names);
    },
  );

  test('old numbered defaults migrate but authored and LAN names survive', () {
    final raw = socialFixture().toJson()..remove('playerNamesVersion');
    raw['playerNames'] = ['Zhanibek', '2-ойыншы', 'Alikhan'];
    final loaded = EditorRepository.decodeStateJson(raw)!;
    expect(loaded.playerName(0), 'Zhanibek');
    expect(loaded.playerName(1), isNot('2-ойыншы'));
    expect(loaded.playerName(2), 'Alikhan');
    loaded.setPlayerName(1, '  Ayan   Khan  ');
    loaded.setPlayerName(2, '3-ойыншы');
    final restored = GameState.fromJson(loaded.toJson());
    expect(restored.playerName(1), 'Ayan Khan');
    expect(restored.playerName(2), '3-ойыншы');
    raw['playerNamesVersion'] = 'invalid';
    expect(EditorRepository.decodeStateJson(raw), isNull);
  });

  testWidgets(
    'all four status seals paint immediately with no image requests',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Row(
            children: [
              for (final status in DiplomacyStatus.values)
                DiplomacyStatusBadge(status: status, size: 39),
            ],
          ),
        ),
      );
      expect(find.byType(Image), findsNothing);
      expect(find.byType(DiplomacyStatusBadge), findsNWidgets(4));
      expect(tester.takeException(), isNull);
      // No precache/pumpAndSettle needed: the first frame contains all faces.
    },
  );

  test(
    'diplomacy seals have distinct visible shapes and consistent map colors',
    () async {
      final pixels = <DiplomacyStatus, List<int>>{};
      for (final status in DiplomacyStatus.values) {
        final recorder = ui.PictureRecorder();
        DiplomacyBadgePainter(
          status,
        ).paint(Canvas(recorder), const Size(64, 64));
        final picture = recorder.endRecording();
        final image = await picture.toImage(64, 64);
        final bytes = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!.buffer.asUint8List();
        pixels[status] = bytes.toList();
        final color = diplomacyStatusColor(status);
        final offset = (15 * 64 + 32) * 4;
        expect(bytes.sublist(offset, offset + 4), [
          (color.r * 255).round(),
          (color.g * 255).round(),
          (color.b * 255).round(),
          255,
        ]);
        expect(color, HexUnitPainter.relationIndicatorColor(status));
        expect(
          [
            for (var i = 3; i < bytes.length; i += 4)
              if (bytes[i] > 0) i,
          ].length,
          greaterThan(1600),
        );
        image.dispose();
        picture.dispose();
      }
      for (final first in DiplomacyStatus.values) {
        for (final second in DiplomacyStatus.values) {
          if (first == second) continue;
          expect(pixels[first], isNot(pixels[second]));
          // Compare symbol ink, independent of the background color.
          List<int> inkPixels(DiplomacyStatus status) => [
            for (var y = 20; y < 48; y++)
              for (var x = 18; x < 48; x++)
                if (pixels[status]![(y * 64 + x) * 4] < 65 &&
                    pixels[status]![(y * 64 + x) * 4 + 1] < 80)
                  y * 64 + x,
          ];
          expect(inkPixels(first), isNot(inkPixels(second)));
        }
      }
    },
  );

  testWidgets('Atlas status badges stay legible beside generated names', (
    tester,
  ) async {
    final names = generatePlayerNames(1906, 4);
    final rows = [
      DiplomacyStatus.peace,
      DiplomacyStatus.alliance,
      DiplomacyStatus.coalition,
      DiplomacyStatus.war,
    ];
    await tester.binding.setSurfaceSize(const Size(360, 248));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: DalaTheme.light,
        home: RepaintBoundary(
          key: const ValueKey('badges'),
          child: Material(
            child: Column(
              children: [
                for (var i = 0; i < rows.length; i++)
                  Container(
                    height: 62,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    color: [
                      const Color(0xffe1cc63),
                      const Color(0xffa65ade),
                      const Color(0xff51cbd0),
                      const Color(0xff70b848),
                    ][i],
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            names[i],
                            style: const TextStyle(fontSize: 23),
                          ),
                        ),
                        DiplomacyStatusBadge(status: rows[i], size: 44),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    await expectLater(
      find.byKey(const ValueKey('badges')),
      matchesGoldenFile('diplomacy_status_badges.png'),
    );
  });
}
