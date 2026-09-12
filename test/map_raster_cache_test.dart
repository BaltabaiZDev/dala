import 'dart:async';
import 'dart:ui' as ui;

import 'package:antiyoy_self/src/ui/map_raster_cache.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'pixel cache reuses terrain across camera transforms and bounds memory',
    () async {
      final probe = _RasterProbe();
      final cache = probe.cache;
      probe.draw(1);
      await probe.drain();
      expect(cache.textureCount, 1);
      final firstCalls = probe.calls;
      for (var i = 0; i < 50; i++) {
        cache.setViewport(ui.Rect.fromLTWH(i.toDouble(), 0, 350, 400), .5);
        probe.draw(1);
      }
      await probe.drain();
      expect(probe.calls, firstCalls);
      expect(cache.builds, 1);

      for (final x in [0.0, 700.0, 0.0, 350.0]) {
        cache.setViewport(ui.Rect.fromLTWH(x, 0, 400, 800), 2);
        await probe.drain();
        expect(
          cache.textureBytes,
          lessThanOrEqualTo(800 * 800 * 4 + cache.maxDetailBytes),
        );
      }
      expect(cache.builds, 1);
      expect(probe.calls, lessThan(12));
      cache.dispose();
      expect(cache.textureBytes, 0);
    },
  );

  test(
    'new fog/state epoch immediately drops old textures and ignores late results',
    () async {
      final probe = _RasterProbe();
      probe.draw(1);
      await probe.drain();
      expect(probe.cache.textureCount, 1);
      final held = Completer<void>();
      probe.hold = held.future;
      probe.draw(2);
      probe.startNext();
      expect(probe.cache.textureCount, 0);
      probe.draw(3);
      held.complete();
      await probe.finishCurrent();
      expect(probe.cache.textureCount, 0);
      probe.hold = null;
      await probe.drain();
      expect(probe.cache.textureCount, 1);
      expect(probe.cache.builds, 3);
      probe.cache.dispose();
    },
  );

  test(
    'disposing or hiding a layer does not keep a background raster loop alive',
    () async {
      final probe = _RasterProbe();
      probe.draw(1);
      probe.cache.setActive(false);
      probe.startNext();
      expect(probe.calls, 0);
      probe.cache.setActive(true);
      final held = Completer<void>();
      probe.hold = held.future;
      probe.startNext();
      probe.cache.dispose();
      held.complete();
      await probe.finishCurrent();
      expect(probe.cache.textureCount, 0);
      expect(probe.jobs, isEmpty);
    },
  );

  test(
    'transparent detail replacement does not double the mask opacity',
    () async {
      final probe = _RasterProbe(background: const ui.Color(0x00000000));
      probe.cache.setViewport(const ui.Rect.fromLTWH(0, 0, 400, 400), 2);
      probe.draw(1);
      await probe.drain();
      final picture = probe.draw(1, retain: true)!;
      final image = await picture.toImage(20, 20);
      final bytes = (await image.toByteData())!.buffer.asUint8List();
      expect(bytes[3], inInclusiveRange(100, 104)); // 0x66, not ~0xa3
      picture.dispose();
      image.dispose();
      probe.cache.dispose();
    },
  );

  test(
    'failed texture allocation falls back once instead of retrying every frame',
    () async {
      final probe = _RasterProbe(fail: true);
      probe.draw(1);
      await probe.drain();
      for (var i = 0; i < 10; i++) {
        probe.draw(1);
      }
      await probe.drain();
      expect(probe.calls, 1);
      expect(probe.cache.textureCount, 0);
      expect(probe.cache.builds, 1);
      probe.cache.dispose();
    },
  );
}

class _RasterProbe {
  _RasterProbe({
    ui.Color background = const ui.Color(0xff12384f),
    bool fail = false,
  }) {
    cache = MapRasterCache(
      maxDetailBytes: 5 * 1024 * 1024,
      backgroundColor: background,
      schedule: jobs.add,
      rasterizer: (picture, width, height) {
        calls++;
        final future = () async {
          if (hold != null) await hold;
          if (fail) throw StateError('test allocation failure');
          return picture.toImage(width, height);
        }();
        current = future.then<void>((_) {}, onError: (Object _) {});
        return future;
      },
    );
  }
  late final MapRasterCache cache;
  final jobs = <VoidCallback>[];
  Future<void>? hold;
  Future<void>? current;
  int calls = 0;

  ui.Picture? draw(int signature, {bool retain = false}) {
    final recorder = ui.PictureRecorder();
    cache.draw(
      ui.Canvas(recorder),
      signature,
      (canvas) {
        canvas.drawRect(
          const ui.Rect.fromLTWH(0, 0, 800, 800),
          ui.Paint()..color = const ui.Color(0x66000000),
        );
      },
      size: const ui.Size(800, 800),
      rasterize: true,
    );
    final picture = recorder.endRecording();
    if (retain) return picture;
    picture.dispose();
    return null;
  }

  void startNext() {
    jobs.removeAt(0)();
  }

  Future<void> finishCurrent() async {
    await current;
    await Future<void>.delayed(Duration.zero);
  }

  Future<void> drain() async {
    var count = 0;
    while (jobs.isNotEmpty) {
      expect(
        count++,
        lessThan(16),
        reason: 'raster cache must settle, not churn',
      );
      startNext();
      await finishCurrent();
    }
  }
}
