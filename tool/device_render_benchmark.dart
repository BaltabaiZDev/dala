// Run with ANTIYOY_BENCHMARK=1 and `flutter build apk --profile
// --target tool/device_render_benchmark.dart`. Separate Android package/data.
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import 'package:antiyoy_self/src/game/game_controller.dart';
import 'package:antiyoy_self/src/game/map_generator.dart';
import 'package:antiyoy_self/src/game/models.dart';
import 'package:antiyoy_self/src/modding/game_mod.dart';
import 'package:antiyoy_self/src/persistence/save_repository.dart';
import 'package:antiyoy_self/src/ui/game_screen.dart';
import 'package:antiyoy_self/src/ui/map_viewport.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  final mod = await GameMod.loadDefault();
  final watch = Stopwatch()..start();
  print('ANTIYOY_STRESS generation_start rss=${ProcessInfo.currentRss}');
  final state = await generateMapAsync(
    mod,
    const GameConfig(
      mapSize: MapSize.giant,
      playerCount: 15,
      humanCount: 15,
      startingProvinceCount: 3,
      treePercent: 100,
      seed: 20260903,
      diplomacy: true,
    ),
  );
  print(
    'ANTIYOY_STRESS generation_done ms=${watch.elapsedMilliseconds} rss=${ProcessInfo.currentRss} provinces=${state.provinces.length}',
  );
  final controller = GameController(
    mod: mod,
    state: state,
    saves: SaveRepository(),
    autosaveEnabled: false,
    authoritativeSimulation: false,
  );
  print(
    'ANTIYOY_STRESS controller_done ms=${watch.elapsedMilliseconds} rss=${ProcessInfo.currentRss}',
  );
  runApp(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(fontFamily: 'Antiyoy'),
      home: _Probe(controller),
    ),
  );
}

class _Probe extends StatefulWidget {
  const _Probe(this.controller);
  final GameController controller;
  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> with SingleTickerProviderStateMixin {
  final _label = ValueNotifier('Phone render probe · warmup');
  final _samples = <int, List<FrameTiming>>{};
  late final Ticker _driver;
  MapViewport? _map;
  Size _view = Size.zero;
  double _elapsed = 0;
  int _selectionTick = -1;
  int _phase = -1;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    SchedulerBinding.instance.addTimingsCallback(_timings);
    _driver = createTicker(_tick)..start();
  }

  void _findMap(Element e) {
    if (e.widget is MapViewport) {
      _map = e.widget as MapViewport;
      _view = (e.renderObject as RenderBox).size;
      _map!.onInteractionStart?.call();
      return;
    }
    e.visitChildElements(_findMap);
  }

  void _timings(List<FrameTiming> values) {
    if (_phase >= 0 && !_done && (_elapsed - 4) % 15 >= 2) {
      _samples.putIfAbsent(_phase, () => []).addAll(values);
    }
  }

  void _tick(Duration elapsed) {
    _elapsed = elapsed.inMicroseconds / 1000000;
    if (_elapsed < 4) return;
    if (_map == null) {
      (context as Element).visitChildElements(_findMap);
      if (_map == null) return;
    }
    final phase = ((_elapsed - 4) / 15).floor();
    if (phase >= 3) {
      _done = true;
      _driver.stop();
      final report = <String, Object?>{};
      for (final entry in _samples.entries) {
        double percentile(List<double> values, double p) {
          values.sort();
          return values[(p * (values.length - 1)).round()];
        }

        final frames = entry.value;
        final build = [
          for (final f in frames) f.buildDuration.inMicroseconds / 1000,
        ];
        final raster = [
          for (final f in frames) f.rasterDuration.inMicroseconds / 1000,
        ];
        report[['overview', 'pan', 'select'][entry.key]] = {
          'frames': frames.length,
          'buildP50': percentile(build, .5),
          'buildP95': percentile(build, .95),
          'rasterP50': percentile(raster, .5),
          'rasterP95': percentile(raster, .95),
          'rasterMax': raster.last,
          'rasterOver32': raster.where((v) => v > 32).length,
        };
      }
      print('ANTIYOY_PHONE_BENCH ${jsonEncode(report)}');
      _label.value = 'Phone render probe · complete';
      return;
    }
    if (_phase != phase) {
      _phase = phase;
      _label.value =
          'Phone render probe · ${['overview', 'pan', 'select'][phase]}';
    }
    final map = _map!;
    final fit = map.minScale;
    final t = _elapsed - 4 - phase * 15;
    final zoom = phase == 0
        ? fit * (1.1 + .09 * math.sin(t))
        : .68 + .14 * math.sin(t * .7);
    final center = Offset(
      map.canvasSize.width * (.5 + .23 * math.sin(t * .6)),
      map.canvasSize.height * (.5 + .26 * math.cos(t * .7)),
    );
    final bounds = MapCameraBounds(
      viewport: _view,
      canvas: map.canvasSize,
      minScale: fit,
    );
    map.transformationController.value = bounds.constrain(
      MapCameraBounds.matrix(zoom, _view.center(Offset.zero) - center * zoom),
    );
    if (phase == 2 && (t / .7).floor() != _selectionTick) {
      _selectionTick = (t / .7).floor();
      final p = widget.controller.state.provinces.firstWhere(
        (p) => p.owner == 0,
      );
      widget.controller.tapTile(p.capital);
      widget.controller.setTool(
        _selectionTick.isEven ? PlayerTool.unit1 : PlayerTool.select,
      );
      _map = null; // picks up the changed available viewport after opening HUD
    }
  }

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      GameScreen(controller: widget.controller),
      Positioned(
        top: 55,
        left: 55,
        right: 55,
        child: IgnorePointer(
          child: ValueListenableBuilder(
            valueListenable: _label,
            builder: (_, text, _) => Text(
              text,
              textDirection: TextDirection.ltr,
              style: const TextStyle(
                fontSize: 11,
                color: Colors.white,
                backgroundColor: Colors.black54,
              ),
            ),
          ),
        ),
      ),
    ],
  );

  @override
  void dispose() {
    SchedulerBinding.instance.removeTimingsCallback(_timings);
    _driver.dispose();
    _label.dispose();
    super.dispose();
  }
}
