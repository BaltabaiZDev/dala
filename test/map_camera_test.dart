import 'dart:math' as math;

import 'package:antiyoy_self/src/ui/map_viewport.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const bounds = MapCameraBounds(
  viewport: Size(390, 650),
  canvas: Size(4000, 6000),
  minScale: .0975,
);

void settle(MapCameraMotion motion) {
  for (var frame = 0; frame < 240 && motion.moving; frame++) {
    motion.step(1 / 60);
    expect(motion.transform, bounds.constrain(motion.transform));
  }
  expect(motion.moving, isFalse);
}

void main() {
  test(
    'sub-unit XY scale ignores the legacy Z=1 and preserves focal anchor',
    () {
      final motion = MapCameraMotion(
        bounds,
        Matrix4.diagonal3Values(.2, .2, 1)..setTranslationRaw(-200, -200, 0),
      );
      const focal = Offset(195, 325);
      final anchor = (focal - motion.offset) / motion.zoom;
      motion.input(focal: focal, factor: 1.2);
      for (var frame = 0; frame < 50; frame++) {
        motion.step(1 / 60);
        expect(
          (motion.offset + anchor * motion.zoom - focal).distance,
          lessThan(.00001),
        );
        expect(motion.zoom, inInclusiveRange(.2, .24));
      }
      expect(motion.zoom, closeTo(.24, .000001));
    },
  );

  test(
    'fit zoom never cover-snaps or moves at either boundary under pressure',
    () {
      final motion = MapCameraMotion(
        bounds,
        Matrix4.diagonal3Values(bounds.minScale, bounds.minScale, 1),
      );
      final fitted = motion.transform;
      for (var event = 0; event < 500; event++) {
        motion.input(
          focal: const Offset(180, 300),
          delta: Offset(event.isEven ? 900 : -900, 500),
          factor: .1,
        );
        motion.step(1 / 60);
        expect(motion.transform, fitted);
        expect(motion.moving, isFalse);
      }
      motion.input(focal: const Offset(180, 300), factor: 1.1);
      expect(motion.targetZoom, closeTo(bounds.minScale * 1.1, .000001));
      settle(motion);
    },
  );

  test('edge reversal responds immediately and outward inertia stops', () {
    final motion = MapCameraMotion(
      bounds,
      MapCameraBounds.matrix(.5, Offset.zero),
    );
    for (var event = 0; event < 500; event++) {
      motion.input(
        focal: const Offset(150, 150),
        delta: const Offset(600, 600),
      );
    }
    expect(motion.targetOffset, Offset.zero);
    motion.input(focal: const Offset(140, 140), delta: const Offset(-10, -10));
    expect(motion.targetOffset, const Offset(-10, -10));
    settle(motion);
    motion.fling(const Offset(100000, 100000));
    settle(motion);
    expect(motion.velocity, Offset.zero);
    expect(motion.offset, Offset.zero);
  });

  test('smoothing and kinetic displacement agree at 30 60 and 120 Hz', () {
    Offset at(int fps) {
      final motion = MapCameraMotion(
        bounds,
        MapCameraBounds.matrix(.5, const Offset(-900, -1100)),
      );
      motion.input(focal: const Offset(180, 300), delta: const Offset(70, 30));
      for (var i = 0; i < fps; i++) {
        motion.step(1 / fps);
      }
      motion.fling(const Offset(800, 300));
      for (var i = 0; i < fps * 2; i++) {
        motion.step(1 / fps);
      }
      return motion.offset;
    }

    expect((at(30) - at(60)).distance, lessThan(.2));
    expect((at(60) - at(120)).distance, lessThan(.2));
  });

  test(
    'mixed pinch drag and wild input stays finite and inside bounds every frame',
    () {
      final motion = MapCameraMotion(bounds, Matrix4.identity());
      final rng = math.Random(704);
      for (var event = 0; event < 3000; event++) {
        motion.input(
          focal: Offset(rng.nextDouble() * 390, rng.nextDouble() * 650),
          delta: Offset(
            rng.nextDouble() * 900 - 450,
            rng.nextDouble() * 900 - 450,
          ),
          factor: math.exp(rng.nextDouble() * 6 - 3),
        );
        motion.step(1 / 60);
        expect(motion.transform.storage.every((n) => n.isFinite), isTrue);
        expect(motion.transform, bounds.constrain(motion.transform));
      }
      settle(motion);
    },
  );

  test(
    'still-piece overscan reuses a window instead of repainting each pixel',
    () {
      final window = MapPieceCullWindow();
      Rect? previous;
      var builds = 0;
      for (var frame = 0; frame < 1000; frame++) {
        final view = Rect.fromLTWH(200 + frame * .5, 300, 400, 600);
        final next = window.resolve(view);
        expect(
          next.contains(view.topLeft) && next.contains(view.bottomRight),
          isTrue,
        );
        if (next != previous) builds++;
        previous = next;
      }
      expect(builds, lessThan(6));
      final tiny = window.resolve(const Rect.fromLTWH(400, 400, 100, 100));
      expect(tiny.width, lessThan(previous!.width));
      expect(
        window.resolve(const Rect.fromLTWH(401, 400, 100, 100)),
        same(tiny),
      );
    },
  );

  testWidgets(
    'wheel floods coalesce to display frames and never rebuild the board',
    (tester) async {
      final camera = TransformationController(
        MapCameraBounds.matrix(.2, const Offset(-100, -100)),
      );
      var builds = 0;
      var paints = 0;
      await mount(
        tester,
        camera,
        child: Builder(
          builder: (_) {
            builds++;
            return CustomPaint(painter: CountPainter(() => paints++));
          },
        ),
      );
      final baselineBuilds = builds;
      final baselinePaints = paints;
      var notifications = 0;
      camera.addListener(() => notifications++);
      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(pointer.hover(const Offset(195, 325)));
      for (var event = 0; event < 200; event++) {
        await tester.sendEventToBinding(pointer.scroll(const Offset(0, -1)));
      }
      expect(notifications, 0);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      expect(notifications, 1);
      await tester.pumpAndSettle();
      expect(
        MapCameraBounds.scaleOf(camera.value),
        closeTo(.2 * math.exp(200 / 210), .0001),
      );
      expect(builds, baselineBuilds);
      expect(paints, baselinePaints);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      camera.dispose();
    },
  );

  testWidgets(
    'real drag stays bounded before finger up and reversing has no dead zone',
    (tester) async {
      final camera = TransformationController(
        MapCameraBounds.matrix(.4, const Offset(-100, -100)),
      );
      await mount(tester, camera);
      final finger = await tester.startGesture(const Offset(80, 130));
      await finger.moveTo(const Offset(140, 200));
      await tester.pump();
      for (var i = 0; i < 25; i++) {
        await finger.moveBy(const Offset(10, 10));
        await tester.pump(const Duration(milliseconds: 16));
        expect(camera.value, bounds.constrain(camera.value));
      }
      await tester.pumpAndSettle();
      expect(camera.value.entry(0, 3), 0);
      expect(camera.value.entry(1, 3), 0);
      await finger.moveBy(const Offset(-20, -20));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      expect(camera.value.entry(0, 3), lessThan(0));
      await finger.up();
      await tester.pumpAndSettle();
      expect(camera.value, bounds.constrain(camera.value));
      await tester.pumpWidget(const SizedBox());
      camera.dispose();
    },
  );

  testWidgets(
    'real pinch at sub-unit scale does not jump and one-finger transition is stable',
    (tester) async {
      final camera = TransformationController(
        Matrix4.diagonal3Values(.2, .2, 1)..setTranslationRaw(-200, -200, 0),
      );
      await mount(tester, camera);
      final first = await tester.startGesture(
        const Offset(110, 300),
        pointer: 1,
      );
      final second = await tester.startGesture(
        const Offset(280, 300),
        pointer: 2,
      );
      for (var i = 0; i < 8; i++) {
        await first.moveBy(const Offset(-4, 0));
        await second.moveBy(const Offset(4, 0));
        await tester.pump(const Duration(milliseconds: 16));
        expect(
          MapCameraBounds.scaleOf(camera.value),
          inInclusiveRange(.2, .31),
        );
      }
      await tester.pumpAndSettle();
      expect(MapCameraBounds.scaleOf(camera.value), greaterThan(.23));
      final beforeLift = camera.value.clone();
      await second.up();
      await tester.pump(const Duration(milliseconds: 16));
      expect(
        (camera.value.entry(0, 3) - beforeLift.entry(0, 3)).abs(),
        lessThan(1),
      );
      await first.up();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      camera.dispose();
    },
  );

  testWidgets(
    'viewport resize is constrained and locked editor strokes never move camera',
    (tester) async {
      final camera = TransformationController(
        MapCameraBounds.matrix(.2, const Offset(-100, -100)),
      );
      var strokes = 0;
      await mount(
        tester,
        camera,
        enabled: false,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanUpdate: (_) => strokes++,
          child: const ColoredBox(color: Colors.blue),
        ),
      );
      final before = camera.value.clone();
      await tester.drag(find.byType(MapViewport), const Offset(80, 100));
      await tester.pumpAndSettle();
      expect(strokes, greaterThan(0));
      expect(camera.value, before);
      await mount(tester, camera, size: const Size(800, 400));
      expect(
        camera.value,
        const MapCameraBounds(
          viewport: Size(800, 400),
          canvas: Size(4000, 6000),
          minScale: .0975,
        ).constrain(camera.value),
      );
      await tester.pumpWidget(const SizedBox());
      camera.dispose();
    },
  );
}

Future<void> mount(
  WidgetTester tester,
  TransformationController camera, {
  Widget child = const ColoredBox(color: Colors.blue),
  bool enabled = true,
  Size size = const Size(390, 650),
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      home: MapViewport(
        transformationController: camera,
        canvasSize: bounds.canvas,
        minScale: bounds.minScale,
        interactionEnabled: enabled,
        child: child,
      ),
    ),
  );
  await tester.pump();
}

class CountPainter extends CustomPainter {
  CountPainter(this.onPaint);
  final VoidCallback onPaint;
  @override
  void paint(Canvas canvas, Size size) {
    onPaint();
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.blue);
  }

  @override
  bool shouldRepaint(CountPainter oldDelegate) => false;
}
