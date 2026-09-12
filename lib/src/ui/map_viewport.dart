import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// One two-dimensional boundary policy for drag, pinch, wheel and inertia.
/// Unlike InteractiveViewer's cover constraint, a fitted map may be smaller
/// than the viewport on one axis. That axis stays centered throughout input.
class MapCameraBounds {
  const MapCameraBounds({
    required this.viewport,
    required this.canvas,
    required this.minScale,
    this.maxScale = 2.6,
  });

  final Size viewport;
  final Size canvas;
  final double minScale;
  final double maxScale;

  static double scaleOf(Matrix4 value) => math.sqrt(
    value.entry(0, 0) * value.entry(0, 0) +
        value.entry(1, 0) * value.entry(1, 0),
  );

  static double fitScale(Size viewport, Size canvas, {double max = .3}) => math
      .min(viewport.width / canvas.width, viewport.height / canvas.height)
      .clamp(.0001, max)
      .toDouble();

  double scale(double value) =>
      value.isFinite ? value.clamp(minScale, maxScale).toDouble() : minScale;

  Offset position(Offset value, double scale) {
    double axis(double offset, double view, double world) {
      if (world <= view) return (view - world) / 2;
      return offset.isFinite ? offset.clamp(view - world, 0).toDouble() : 0;
    }

    return Offset(
      axis(value.dx, viewport.width, canvas.width * scale),
      axis(value.dy, viewport.height, canvas.height * scale),
    );
  }

  Matrix4 constrain(Matrix4 value) {
    final zoom = scale(scaleOf(value));
    final offset = position(Offset(value.entry(0, 3), value.entry(1, 3)), zoom);
    return matrix(zoom, offset);
  }

  /// Keep an active cell reachable when a HUD panel reduces the viewport.
  /// Only translate if it is clipped; do not reset the player's zoom/pan.
  Matrix4 revealPoint(Matrix4 value, Offset worldPoint, {double margin = 36}) {
    final bounded = constrain(value);
    final zoom = scaleOf(bounded);
    final offset = Offset(bounded.entry(0, 3), bounded.entry(1, 3));
    final screen = worldPoint * zoom + offset;
    final mx = math.min(margin, viewport.width / 4);
    final my = math.min(margin, viewport.height / 4);
    final visible = Offset(
      screen.dx.clamp(mx, viewport.width - mx),
      screen.dy.clamp(my, viewport.height - my),
    );
    return matrix(zoom, position(offset + visible - screen, zoom));
  }

  static Matrix4 matrix(double zoom, Offset offset) =>
      Matrix4.diagonal3Values(zoom, zoom, zoom)
        ..setTranslationRaw(offset.dx, offset.dy, 0);
}

/// Pure, frame-rate-independent motion. Classic CameraController separates
/// bounded target/view positions and damps kinetics; this uses elapsed seconds
/// instead of its per-frame factors. No game state or network work happens here.
class MapCameraMotion {
  MapCameraMotion(this.bounds, Matrix4 initial) {
    reset(initial);
  }

  MapCameraBounds bounds;
  late double zoom;
  late Offset offset;
  late double targetZoom;
  late Offset targetOffset;
  Offset velocity = Offset.zero;
  double response = 36;

  Matrix4 get transform => MapCameraBounds.matrix(zoom, offset);
  bool get moving =>
      velocity != Offset.zero || zoom != targetZoom || offset != targetOffset;

  void reset(Matrix4 value) {
    zoom = targetZoom = bounds.scale(MapCameraBounds.scaleOf(value));
    offset = targetOffset = bounds.position(
      Offset(value.entry(0, 3), value.entry(1, 3)),
      zoom,
    );
    velocity = Offset.zero;
  }

  void stop() {
    velocity = Offset.zero;
    targetZoom = zoom;
    targetOffset = offset;
  }

  void input({
    required Offset focal,
    Offset delta = Offset.zero,
    double factor = 1,
    bool wheel = false,
  }) {
    if (!focal.dx.isFinite ||
        !focal.dy.isFinite ||
        !factor.isFinite ||
        factor <= 0 ||
        !delta.dx.isFinite ||
        !delta.dy.isFinite) {
      return;
    }
    velocity = Offset.zero;
    response = wheel ? 22 : 36;
    // Incremental input rebases at a clamped edge. Excess finger/wheel travel
    // never accumulates a dead zone that must be undone before reversing.
    final anchor = (focal - delta - targetOffset) / targetZoom;
    targetZoom = bounds.scale(targetZoom * factor);
    targetOffset = bounds.position(focal - anchor * targetZoom, targetZoom);
  }

  void fling(Offset pixelsPerSecond) {
    if (!pixelsPerSecond.dx.isFinite || !pixelsPerSecond.dy.isFinite) return;
    final speed = pixelsPerSecond.distance;
    velocity = speed < 50
        ? Offset.zero
        : pixelsPerSecond * (math.min(speed, 2200) / speed);
  }

  void step(double seconds) {
    if (!seconds.isFinite || seconds <= 0 || !moving) return;
    final dt = seconds.clamp(0.0, .05).toDouble();
    if (velocity != Offset.zero) {
      final decay = math.exp(-10 * dt);
      final next = targetOffset + velocity * ((1 - decay) / 10);
      final bounded = bounds.position(next, targetZoom);
      velocity = Offset(
        (bounded.dx - next.dx).abs() > .00001 ? 0 : velocity.dx * decay,
        (bounded.dy - next.dy).abs() > .00001 ? 0 : velocity.dy * decay,
      );
      if (velocity.distance < 4) velocity = Offset.zero;
      targetOffset = bounded;
    }
    final alpha = 1 - math.exp(-response * dt);
    zoom += (targetZoom - zoom) * alpha;
    offset = bounds.position(Offset.lerp(offset, targetOffset, alpha)!, zoom);
    if ((zoom - targetZoom).abs() * bounds.canvas.longestSide < .05 &&
        (offset - targetOffset).distance < .05) {
      zoom = targetZoom;
      offset = targetOffset;
    }
  }
}

/// Camera notifications are limited to one per display frame. The child is
/// retained, so a 120/240 Hz pointer stream doesn't rebuild game/HUD widgets.
class MapViewport extends StatefulWidget {
  const MapViewport({
    super.key,
    required this.transformationController,
    required this.canvasSize,
    required this.minScale,
    required this.child,
    this.maxScale = 2.6,
    this.scaleFactor = 210,
    this.interactionEnabled = true,
    this.onInteractionStart,
  });

  final TransformationController transformationController;
  final Size canvasSize;
  final double minScale;
  final double maxScale;
  final double scaleFactor;
  final bool interactionEnabled;
  final VoidCallback? onInteractionStart;
  final Widget child;

  @override
  State<MapViewport> createState() => _MapViewportState();
}

class _MapViewportState extends State<MapViewport>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);
  MapCameraMotion? _motion;
  Size? _viewport;
  Duration _previousTick = Duration.zero;
  bool _writing = false;
  bool _layoutSyncScheduled = false;
  double _lastGestureScale = 1;
  Offset? _lastFocal;
  int _pointerCount = 0;
  bool _pinched = false;

  @override
  void initState() {
    super.initState();
    widget.transformationController.addListener(_externalTransform);
  }

  @override
  void didUpdateWidget(MapViewport oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.transformationController != widget.transformationController) {
      oldWidget.transformationController.removeListener(_externalTransform);
      widget.transformationController.addListener(_externalTransform);
      _externalTransform();
    }
    if (!widget.interactionEnabled) _stop();
  }

  void _externalTransform() {
    if (_writing) return;
    _ticker.stop();
    _motion?.reset(widget.transformationController.value);
  }

  void _stop() {
    _ticker.stop();
    _motion?.stop();
  }

  void _wake() {
    if (_motion?.moving != true || _ticker.isActive) return;
    _previousTick = Duration.zero;
    _ticker.start();
  }

  void _tick(Duration elapsed) {
    final dt = (elapsed - _previousTick).inMicroseconds / 1000000;
    _previousTick = elapsed;
    _motion!.step(dt);
    _publish();
    if (!_motion!.moving) _ticker.stop();
  }

  void _publish() {
    final value = _motion!.transform;
    if (value == widget.transformationController.value) return;
    _writing = true;
    widget.transformationController.value = value;
    _writing = false;
  }

  void _start(ScaleStartDetails details) {
    widget.onInteractionStart?.call();
    _stop();
    _motion?.reset(widget.transformationController.value);
    _lastGestureScale = 1;
    _lastFocal = details.localFocalPoint;
    _pointerCount = details.pointerCount;
    _pinched = _pointerCount > 1;
  }

  void _update(ScaleUpdateDetails details) {
    if (_motion == null) return;
    final focal = details.localFocalPoint;
    final countChanged = _pointerCount != details.pointerCount;
    _pinched = _pinched || details.pointerCount > 1 || details.scale != 1;
    if (!countChanged) {
      _motion!.input(
        focal: focal,
        delta: focal - (_lastFocal ?? focal),
        factor: details.scale / _lastGestureScale,
      );
    }
    _pointerCount = details.pointerCount;
    _lastGestureScale = details.scale;
    _lastFocal = focal;
    _wake();
  }

  void _end(ScaleEndDetails details) {
    // Zoom has no ballistic tail. It ends at the user's bounded target.
    if (!_pinched) _motion?.fling(details.velocity.pixelsPerSecond);
    _lastFocal = null;
    _wake();
  }

  void _signal(PointerSignalEvent event) {
    if (!widget.interactionEnabled || _motion == null) return;
    if (event is! PointerScrollEvent && event is! PointerScaleEvent) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (event) {
      widget.onInteractionStart?.call();
      if (event is PointerScrollEvent) {
        if (event.kind == PointerDeviceKind.trackpad) {
          _motion!.input(focal: event.localPosition, delta: -event.scrollDelta);
        } else {
          _motion!.input(
            focal: event.localPosition,
            factor: math.exp(
              (-event.scrollDelta.dy / math.max(1, widget.scaleFactor)).clamp(
                -3,
                3,
              ),
            ),
            wheel: true,
          );
        }
      } else if (event is PointerScaleEvent) {
        _motion!.input(focal: event.localPosition, factor: event.scale);
      }
      _wake();
    });
  }

  void _configure(Size viewport) {
    if (_viewport == viewport &&
        _motion?.bounds.canvas == widget.canvasSize &&
        _motion?.bounds.minScale == widget.minScale &&
        _motion?.bounds.maxScale == widget.maxScale) {
      return;
    }
    _viewport = viewport;
    final bounds = MapCameraBounds(
      viewport: viewport,
      canvas: widget.canvasSize,
      minScale: widget.minScale,
      maxScale: widget.maxScale,
    );
    _ticker.stop();
    _motion = MapCameraMotion(bounds, widget.transformationController.value);
    if (_layoutSyncScheduled) return;
    _layoutSyncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _layoutSyncScheduled = false;
      if (!mounted) return;
      // A parent may focus the new human turn in its own layout callback.
      _motion!.reset(widget.transformationController.value);
      _publish();
    });
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      _configure(constraints.biggest);
      return Listener(
        onPointerDown: widget.interactionEnabled
            ? (_) {
                widget.onInteractionStart?.call();
                _stop();
              }
            : null,
        onPointerSignal: _signal,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onScaleStart: widget.interactionEnabled ? _start : null,
          onScaleUpdate: widget.interactionEnabled ? _update : null,
          onScaleEnd: widget.interactionEnabled ? _end : null,
          child: ClipRect(
            child: OverflowBox(
              alignment: Alignment.topLeft,
              minWidth: widget.canvasSize.width,
              maxWidth: widget.canvasSize.width,
              minHeight: widget.canvasSize.height,
              maxHeight: widget.canvasSize.height,
              child: AnimatedBuilder(
                animation: widget.transformationController,
                child: RepaintBoundary(child: widget.child),
                builder: (context, child) => Transform(
                  transform: widget.transformationController.value,
                  child: child,
                ),
              ),
            ),
          ),
        ),
      );
    },
  );

  @override
  void dispose() {
    widget.transformationController.removeListener(_externalTransform);
    _ticker.dispose();
    super.dispose();
  }
}

/// Keep the still-piece display list while panning inside an overscan window.
/// Repainting every piece on every pixel of camera movement defeats caching.
class MapPieceCullWindow {
  Rect? _window;
  Size? _sourceSize;
  Rect resolve(Rect view) {
    final window = _window;
    if (window == null ||
        !window.contains(view.topLeft) ||
        !window.contains(view.bottomRight) ||
        _sourceSize!.width > view.width * 1.8 ||
        _sourceSize!.height > view.height * 1.8) {
      _window = view.inflate(math.max(160, view.shortestSide * .35));
      _sourceSize = view.size;
    }
    return _window!;
  }
}
