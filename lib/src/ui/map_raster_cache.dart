import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

typedef MapRasterizer =
    Future<ui.Image> Function(ui.Picture picture, int width, int height);

/// Pixel cache, not just a display list. Mobile GPUs must not tessellate every
/// hex/path again when the camera transform changes. A bounded overview covers
/// the whole map; sharper, visible 512-world-unit tiles are populated serially.
/// Nothing here is simulation state or belongs in a save/network snapshot.
class MapRasterCache extends ChangeNotifier {
  MapRasterCache({
    this.maxDetailBytes = 48 * 1024 * 1024,
    this.backgroundColor = const ui.Color(0xff365c68),
    MapRasterizer? rasterizer,
    void Function(VoidCallback)? schedule,
  }) : _rasterizer = rasterizer ?? _toImage,
       _schedule = schedule ?? _afterFrame;

  static const tileSize = 512.0;
  // The overview is deliberately lower detail: at this zoom objects are tiny,
  // while halving texture area avoids a visible GPU upload pause on phones.
  static const overviewExtent = 1536.0;
  final int maxDetailBytes;
  final ui.Color backgroundColor;
  final MapRasterizer _rasterizer;
  final void Function(VoidCallback) _schedule;
  ui.Picture? _picture;
  ui.Picture? _overviewPicture;
  void Function(ui.Canvas, ui.Rect)? _recordRegion;
  int? _signature;
  ui.Size _size = ui.Size.zero;
  ui.Rect _view = ui.Rect.zero;
  double _pixelScale = 1;
  _MapTexture? _overview;
  final _tiles = <(int, int, int), _MapTexture>{};
  int _detailBytes = 0;
  int _epoch = 0;
  int? _failedEpoch;
  bool _busy = false;
  bool _scheduled = false;
  bool _disposed = false;
  bool _rasterEnabled = false;
  bool _active = true;
  int builds = 0;

  @visibleForTesting
  int get textureBytes => _detailBytes + (_overview?.bytes ?? 0);
  @visibleForTesting
  int get textureCount => _tiles.length + (_overview == null ? 0 : 1);

  bool hasDetailAt(ui.Offset point) =>
      _level > 0 &&
      _tiles.containsKey((
        (point.dx / tileSize).floor(),
        (point.dy / tileSize).floor(),
        _level,
      ));

  void setActive(bool active) {
    _active = active;
    if (active) _requestJob();
  }

  static Future<ui.Image> _toImage(ui.Picture p, int w, int h) =>
      p.toImage(w, h);

  static void _afterFrame(VoidCallback callback) {
    SchedulerBinding.instance.addPostFrameCallback((_) => callback());
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  double get _overviewScale =>
      math.min(1, overviewExtent / math.max(1, _size.longestSide));

  int get _level => _pixelScale <= _overviewScale * 1.35
      ? 0
      : _pixelScale <= 1.15
      ? 1
      : 2;

  /// Camera-only changes do not invalidate terrain or start full-map work.
  /// Repaint only when the texture LOD changes; otherwise retained quads move
  /// with the camera, and completed tiles request their own small repaint.
  void setViewport(ui.Rect view, double pixelScale) {
    if (_disposed) return;
    final oldLevel = _level;
    _view = view;
    _pixelScale = pixelScale;
    if (_rasterEnabled && oldLevel != _level) notifyListeners();
    _requestJob();
  }

  void draw(
    ui.Canvas canvas,
    int signature,
    void Function(ui.Canvas) record, {
    ui.Size? size,
    bool rasterize = false,
    void Function(ui.Canvas)? recordOverview,
    void Function(ui.Canvas, ui.Rect)? recordRegion,
    List<ui.Rect>? Function()? changedRegions,
  }) {
    if (_disposed) return;
    final nextSize = size ?? ui.Size.zero;
    if (_picture == null || signature != _signature || nextSize != _size) {
      final dirty = _picture != null && nextSize == _size
          ? changedRegions?.call()
          : null;
      if (_picture == null || nextSize != _size) changedRegions?.call();
      final recorder = ui.PictureRecorder();
      final recordingCanvas = ui.Canvas(recorder);
      // Large terrain is recorded by visible region only when a detail job
      // needs it. Never synchronously record thousands of offscreen objects.
      if (!rasterize || recordRegion == null) record(recordingCanvas);
      final next = recorder.endRecording();
      _recordRegion = rasterize ? recordRegion : null;
      _epoch++;
      _picture?.dispose();
      _picture = next;
      _overviewPicture?.dispose();
      _overviewPicture = null;
      if (recordOverview != null) {
        final recorder = ui.PictureRecorder();
        recordOverview(ui.Canvas(recorder));
        _overviewPicture = recorder.endRecording();
      }
      _signature = signature;
      _size = nextSize;
      builds++;
      if (dirty == null) {
        _clearTextures();
      } else {
        _overview?.image.dispose();
        _overview = null;
        for (final key in _tiles.keys.toList()) {
          final tile = _tiles[key]!;
          if (dirty.any((rect) => rect.overlaps(tile.rect.inflate(2)))) {
            _tiles.remove(key);
            _detailBytes -= tile.bytes;
            tile.image.dispose();
          }
        }
      }
    }
    _rasterEnabled = rasterize && !_size.isEmpty;
    final overview = _overview;
    if (!_rasterEnabled || overview == null) {
      // Always current terrain/fog while the new epoch is being prepared.
      canvas.drawPicture(
        _rasterEnabled ? _overviewPicture ?? _picture! : _picture!,
      );
    } else {
      // Transparent overlays must not be blended twice where a detail tile
      // replaces the overview. Rectangular holes are cheap to clip.
      final transparent = backgroundColor.a < 1 && _level > 0;
      if (transparent) {
        final path = ui.Path()
          ..fillType = ui.PathFillType.evenOdd
          ..addRect(ui.Offset.zero & _size);
        for (final entry in _tiles.entries) {
          if (entry.key.$3 == _level) path.addRect(entry.value.rect);
        }
        canvas.save();
        canvas.clipPath(path, doAntiAlias: false);
      }
      overview.draw(canvas);
      if (transparent) canvas.restore();
      if (_level > 0) {
        for (final entry in _tiles.entries) {
          if (entry.key.$3 == _level) entry.value.draw(canvas);
        }
      }
    }
    _requestJob();
  }

  List<(int, int, int)> _wantedTiles() {
    final level = _level;
    if (level == 0 || _view.isEmpty) return const [];
    final rect = _view.inflate(24).intersect(ui.Offset.zero & _size);
    if (rect.isEmpty) return const [];
    final keys = <(int, int, int)>[
      for (
        var y = (rect.top / tileSize).floor();
        y < (rect.bottom / tileSize).ceil();
        y++
      )
        for (
          var x = (rect.left / tileSize).floor();
          x < (rect.right / tileSize).ceil();
          x++
        )
          (x, y, level),
    ];
    double distance((int, int, int) k) =>
        (ui.Offset((k.$1 + .5) * tileSize, (k.$2 + .5) * tileSize) -
                rect.center)
            .distanceSquared;
    keys.sort((a, b) => distance(a).compareTo(distance(b)));
    // Never churn when one zoom level's entire visible region exceeds memory.
    final bytesPerTile = (tileSize * level + 2).ceil();
    return keys
        .take(maxDetailBytes ~/ (bytesPerTile * bytesPerTile * 4))
        .toList();
  }

  void _requestJob() {
    if (_disposed ||
        !_active ||
        !_rasterEnabled ||
        _picture == null ||
        _busy ||
        _scheduled ||
        _failedEpoch == _epoch) {
      return;
    }
    if (_overview != null && _wantedTiles().every(_tiles.containsKey)) return;
    _scheduled = true;
    _schedule(() {
      _scheduled = false;
      if (!_disposed) _runJob();
    });
  }

  Future<void> _runJob() async {
    if (!_active ||
        _busy ||
        !_rasterEnabled ||
        _picture == null ||
        _failedEpoch == _epoch) {
      return;
    }
    (int, int, int)? key;
    if (_overview != null) {
      final wanted = _wantedTiles();
      for (final k in wanted) {
        final existing = _tiles.remove(k);
        if (existing != null) _tiles[k] = existing;
        if (existing == null) key ??= k;
      }
      if (key == null) return;
    }
    _busy = true;
    final epoch = _epoch;
    final scale = key == null ? _overviewScale : key.$3.toDouble();
    final rect = key == null
        ? ui.Offset.zero & _size
        : ui.Rect.fromLTWH(
            key.$1 * tileSize,
            key.$2 * tileSize,
            tileSize,
            tileSize,
          ).intersect(ui.Offset.zero & _size);
    // One-pixel gutter prevents bilinear seams between adjacent textures.
    final gutter = key == null ? 0 : 1;
    final width = (rect.width * scale).ceil() + gutter * 2;
    final height = (rect.height * scale).ceil() + gutter * 2;
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawColor(backgroundColor, ui.BlendMode.src);
    canvas.translate(gutter - rect.left * scale, gutter - rect.top * scale);
    canvas.scale(scale);
    if (key != null && _recordRegion != null) {
      _recordRegion!(canvas, rect.inflate(2 / scale));
    } else {
      canvas.drawPicture(
        key == null ? _overviewPicture ?? _picture! : _picture!,
      );
    }
    final picture = recorder.endRecording();
    final watch = Stopwatch()..start();
    try {
      final image = await _rasterizer(picture, width, height);
      if (const bool.fromEnvironment('ANTIYOY_CACHE_TRACE') && key == null) {
        debugPrint(
          'ANTIYOY_CACHE_OVERVIEW ${width}x$height ${watch.elapsedMilliseconds}ms',
        );
      }
      if (_disposed || epoch != _epoch) {
        image.dispose();
      } else {
        final texture = _MapTexture(image, rect, scale, gutter);
        if (key == null) {
          _overview = texture;
        } else if (_wantedTiles().contains(key)) {
          while (_detailBytes + texture.bytes > maxDetailBytes &&
              _tiles.isNotEmpty) {
            final oldest = _tiles.remove(_tiles.keys.first)!;
            _detailBytes -= oldest.bytes;
            oldest.image.dispose();
          }
          if (texture.bytes <= maxDetailBytes) {
            _tiles[key] = texture;
            _detailBytes += texture.bytes;
          } else {
            image.dispose();
          }
        } else {
          image.dispose();
        }
        notifyListeners();
      }
    } catch (error) {
      if (!_disposed && epoch == _epoch) {
        _failedEpoch = epoch;
        debugPrint('Map pixel cache fell back to vectors: $error');
      }
    } finally {
      picture.dispose();
      _busy = false;
      _requestJob();
    }
  }

  void _clearTextures() {
    _overview?.image.dispose();
    _overview = null;
    for (final texture in _tiles.values) {
      texture.image.dispose();
    }
    _tiles.clear();
    _detailBytes = 0;
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    _picture?.dispose();
    _picture = null;
    _overviewPicture?.dispose();
    _overviewPicture = null;
    _recordRegion = null;
    _clearTextures();
    super.dispose();
  }
}

class _MapTexture {
  _MapTexture(this.image, this.rect, this.scale, this.gutter);
  final ui.Image image;
  final ui.Rect rect;
  final double scale;
  final int gutter;
  int get bytes => image.width * image.height * 4;
  void draw(ui.Canvas canvas) => canvas.drawImageRect(
    image,
    ui.Rect.fromLTWH(
      gutter.toDouble(),
      gutter.toDouble(),
      rect.width * scale,
      rect.height * scale,
    ),
    rect,
    ui.Paint()..filterQuality = ui.FilterQuality.low,
  );
}
