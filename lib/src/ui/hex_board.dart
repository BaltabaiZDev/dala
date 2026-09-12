import 'dala_theme.dart';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../game/game_controller.dart';
import '../game/game_engine.dart';
import '../game/models.dart';
import '../modding/game_mod.dart';
import 'classic_assets.dart';
import 'diplomacy_badge.dart';
import 'map_raster_cache.dart';
import 'map_viewport.dart';
import 'organic_cells.dart';

void _drawDefenseShield(
  Canvas canvas,
  Offset center,
  Color color,
  double animation,
) {
  final value = animation.clamp(0.0, 1.0);
  if (value <= 0) return;
  final scale = .58 + .42 * Curves.easeOutBack.transform(value);
  canvas.save();
  canvas.translate(center.dx, center.dy - 3 * (1 - value));
  canvas.scale(scale, scale);
  final shield = Path()
    ..moveTo(-9, -10)
    ..quadraticBezierTo(0, -6.5, 9, -10)
    ..lineTo(9, -1)
    ..cubicTo(8.5, 5.5, 4.2, 10, 0, 12)
    ..cubicTo(-4.2, 10, -8.5, 5.5, -9, -1)
    ..close();
  canvas.drawPath(
    shield.shift(const Offset(1.5, 2)),
    Paint()..color = Colors.black.withValues(alpha: .35 * value),
  );
  canvas.drawPath(
    shield,
    Paint()
      ..color = const Color(0xff11191d).withValues(alpha: value)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeJoin = StrokeJoin.round,
  );
  canvas.drawPath(
    shield,
    Paint()..color = color.withValues(alpha: .95 * value),
  );
  canvas.drawLine(
    const Offset(-4.5, -5),
    const Offset(3.5, -7),
    Paint()
      ..color = Colors.white.withValues(alpha: .72 * value)
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round,
  );
  canvas.restore();
}

double _twoDimensionalScale(Matrix4 transform) => math.sqrt(
  math.pow(transform.entry(0, 0), 2) + math.pow(transform.entry(1, 0), 2),
);

class HexBoard extends StatefulWidget {
  const HexBoard({
    required this.controller,
    this.onForeignDiplomacyRequested,
    super.key,
  });

  final GameController controller;
  final ValueChanged<int>? onForeignDiplomacyRequested;

  static const double hexRadius = 30;
  static const double padding = 100;
  static const double overviewAnimationPauseRatio = 1.22;
  static const double overviewAnimationResumeRatio = 1.38;

  static Offset centerOf(HexTile tile) => OrganicCells.center(tile.q, tile.r);

  /// Pixel extent derived from actual coordinates. This supports both legacy
  /// rhombus saves and the rectangular offset grid used by newly built maps.
  static Size canvasSize(GameState state) {
    if (state.hexes.isEmpty) return const Size(padding * 2, padding * 2);
    var maxX = 0.0;
    var maxY = 0.0;
    for (final tile in state.hexes) {
      if (!tile.inWorld) continue;
      final center = centerOf(tile);
      maxX = math.max(maxX, center.dx);
      maxY = math.max(maxY, center.dy);
    }
    return Size(maxX + hexRadius + padding, maxY + hexRadius + padding);
  }

  @visibleForTesting
  static double minimumScaleFor(Size viewport, GameState state) {
    final canvas = canvasSize(state);
    if (viewport.isEmpty || canvas.isEmpty) return .03;
    final fit = math.min(
      viewport.width / canvas.width,
      viewport.height / canvas.height,
    );
    // The limiting canvas dimension must touch the viewport at minimum zoom.
    // Going below the true fit scale makes a giant map collapse into a tiny
    // thumbnail that can then be pushed into a corner of the sea background.
    return fit.clamp(.0001, .3).toDouble();
  }

  @visibleForTesting
  static bool idlePieceAnimationsEnabledFor(
    GameState state, {
    bool disableAnimations = false,
    double? currentScale,
    double? minimumScale,
    bool wasOverviewSuppressed = false,
  }) {
    if (disableAnimations || state.hexes.isEmpty) return false;
    if (currentScale == null || minimumScale == null) return true;
    return !shouldSuppressOverviewAnimations(
      currentScale: currentScale,
      minimumScale: minimumScale,
      currentlySuppressed: wasOverviewSuppressed,
    );
  }

  /// Pauses decorative animation only near the fitted whole-map overview.
  /// Separate enter/exit ratios provide hysteresis while pinch-zooming.
  @visibleForTesting
  static bool shouldSuppressOverviewAnimations({
    required double currentScale,
    required double minimumScale,
    bool currentlySuppressed = false,
  }) {
    if (!currentScale.isFinite ||
        !minimumScale.isFinite ||
        currentScale <= 0 ||
        minimumScale <= 0) {
      return false;
    }
    final ratio = currentScale / minimumScale;
    return currentlySuppressed
        ? ratio < overviewAnimationResumeRatio
        : ratio <= overviewAnimationPauseRatio;
  }

  @visibleForTesting
  static Matrix4 constrainTransform({
    required Matrix4 transform,
    required Size viewport,
    required Size canvas,
    required double minScale,
    double maxScale = 2.6,
  }) {
    return MapCameraBounds(
      viewport: viewport,
      canvas: canvas,
      minScale: minScale,
      maxScale: maxScale,
    ).constrain(transform);
  }

  @visibleForTesting
  static (int, int) axialCoordinateAt(Offset point) {
    return OrganicCells.coordinateAt(point);
  }

  static Offset centerOfWater(GameState state, WaterCell cell) {
    var dx = 0.0;
    var dy = 0.0;
    for (final index in cell.tiles) {
      final center = centerOf(state.hexes[index]);
      dx += center.dx;
      dy += center.dy;
    }
    return Offset(dx / cell.tiles.length, dy / cell.tiles.length);
  }

  /// Every map object that belongs to [player] and should be kept in view when
  /// a human turn starts. Land from separate provinces and naval objects are
  /// deliberately combined instead of choosing only the largest province.
  @visibleForTesting
  static List<Offset> playerAssetCenters(GameState state, int player) => [
    for (final tile in state.hexes)
      if (tile.active && tile.owner == player) centerOf(tile),
    for (final cell in state.waterCells)
      if (cell.boat?.owner == player || cell.seaFort?.owner == player)
        centerOfWater(state, cell),
  ];

  @override
  State<HexBoard> createState() => _HexBoardState();
}

class _HexBoardState extends State<HexBoard> with TickerProviderStateMixin {
  final TransformationController _transformation = TransformationController();
  late final AnimationController _jumpAnimation;
  late final AnimationController _cameraAnimation;
  late final AnimationController _battleAnimation;
  late final AnimationController _fortDestructionAnimation;
  Animation<Matrix4>? _cameraTransform;
  ClassicSprites? _sprites;
  Size? _initialViewport;
  int? _focusedTurn;
  final Map<int, double> _humanPlayerScales = {};
  int? _playedBattleSerial;
  int? _playedFortDestructionSerial;
  int? _playedArtillerySerial;
  int _playedArtilleryVolleyIndex = -1;
  GameState? _hitTestState;
  Map<(int, int), int> _tileByCoordinate = const {};
  Map<int, int> _waterByTile = const {};
  double? _animationMinimumScale;
  bool _overviewAnimationsSuppressed = false;
  bool _systemAnimationsDisabled = false;
  bool _animationDetailSyncScheduled = false;
  int? _pieceFrameSignature;
  HexPieceFrame? _pieceFrame;
  GameState? _pieceFrameState;
  final HexTerrainCache _terrainCache = HexTerrainCache();
  final MapRasterCache _maskCache = MapRasterCache(
    maxDetailBytes: 12 * 1024 * 1024,
    backgroundColor: Colors.transparent,
  );
  Size _rasterViewport = Size.zero;
  double _rasterPixelRatio = 1;
  final MapPieceCullWindow _stillPieceWindow = MapPieceCullWindow();
  final MapPieceCullWindow _objectWindow = MapPieceCullWindow();

  @override
  void initState() {
    super.initState();
    _jumpAnimation = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 520),
    )..repeat();
    _transformation.addListener(_handleTransformChanged);
    _cameraAnimation =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 280),
        )..addListener(() {
          final transform = _cameraTransform?.value;
          if (transform != null) _transformation.value = transform;
        });
    _battleAnimation = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 430),
    );
    _fortDestructionAnimation = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 480),
    );
    ClassicSprites.load(
      teamColors: widget.controller.mod.palette,
      overrides: widget.controller.mod.sprites,
    ).then((sprites) {
      if (!mounted) {
        sprites.dispose();
        return;
      }
      setState(() => _sprites = sprites);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final disabled = MediaQuery.disableAnimationsOf(context);
    if (_systemAnimationsDisabled == disabled) return;
    _systemAnimationsDisabled = disabled;
    _scheduleAnimationDetailSync();
  }

  @override
  void dispose() {
    _terrainCache.dispose();
    _maskCache.dispose();
    _sprites?.dispose();
    _jumpAnimation.dispose();
    _cameraAnimation.dispose();
    _battleAnimation.dispose();
    _fortDestructionAnimation.dispose();
    _transformation.removeListener(_handleTransformChanged);
    _transformation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.controller.viewState;
    final targets = widget.controller.targetTiles;
    final waterTargets = widget.controller.targetWaterCells;
    _maskCache.setActive(
      widget.controller.tool != PlayerTool.select ||
          targets.isNotEmpty ||
          waterTargets.isNotEmpty,
    );
    final visibleTiles = widget.controller.visibleTileIndices;
    final visibleWaterCells = widget.controller.visibleWaterCellIndices;
    final boardRenderSignature = _boardRenderSignature(
      state,
      visibleTiles,
      visibleWaterCells,
      targets,
      waterTargets,
    );
    final terrainSignature = _boardRenderSignature(
      state,
      visibleTiles,
      visibleWaterCells,
      targets,
      waterTargets,
      terrainOnly: true,
    );
    final unitRenderSignature = _unitRenderSignature(
      state,
      visibleTiles,
      visibleWaterCells,
    );
    if (_pieceFrameState != state ||
        _pieceFrame == null ||
        _pieceFrameSignature != unitRenderSignature) {
      _pieceFrame = HexPieceFrame(state, visibleTiles, visibleWaterCells);
      _pieceFrameState = state;
      _pieceFrameSignature = unitRenderSignature;
    }
    final battle = widget.controller.boatBattleAnimation;
    final fortDestruction = widget.controller.seaFortDestructionAnimation;
    if (battle != null && battle.serial != _playedBattleSerial) {
      _playedBattleSerial = battle.serial;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _battleAnimation.forward(from: 0);
      });
    }
    if (fortDestruction != null &&
        fortDestruction.serial != _playedFortDestructionSerial) {
      _playedFortDestructionSerial = fortDestruction.serial;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _fortDestructionAnimation.forward(from: 0);
      });
    }
    final artilleryStrikes = widget.controller.artilleryFireAnimation;
    final artilleryVolleys = artilleryStrikeVolleys(artilleryStrikes);
    final boardSize = HexBoard.canvasSize(state);
    final boardPainter = HexBoardPainter(
      renderSignature: boardRenderSignature,
      terrainCache: _terrainCache,
      terrainSignature: terrainSignature,
      state: state,
      mod: widget.controller.mod,
      fogActive: widget.controller.fogActive,
      sprites: _sprites,
      selected: widget.controller.selectedTile,
      selectedWater: widget.controller.selectedWaterCell,
      selectionOpacity: widget.controller.selectionOpacity,
      moveTargets: targets,
      waterTargets: waterTargets,
      defensePreviewTiles: widget.controller.defensePreviewTiles,
      defensePreviewWaterCells: widget.controller.defensePreviewWaterCells,
      defensePreviewOpacity: widget.controller.defensePreviewOpacity,
      artilleryRangePreview: widget.controller.artilleryRangePreview,
      artilleryVolleys: artilleryVolleys,
      artilleryFireProgress: 1 - widget.controller.artilleryFireOpacity,
      visibleTiles: visibleTiles,
      visibleWaterCells: visibleWaterCells,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewport = constraints.biggest;
        _rasterViewport = viewport;
        _rasterPixelRatio = MediaQuery.devicePixelRatioOf(context);
        _syncRasterViewport();
        final minimumScale = HexBoard.minimumScaleFor(viewport, state);
        _animationMinimumScale = minimumScale;
        final currentScale = _twoDimensionalScale(_transformation.value);
        final animateIdlePieces = HexBoard.idlePieceAnimationsEnabledFor(
          state,
          disableAnimations: _systemAnimationsDisabled,
          currentScale: currentScale,
          minimumScale: minimumScale,
          wasOverviewSuppressed: _overviewAnimationsSuppressed,
        );
        if (animateIdlePieces ==
            (_overviewAnimationsSuppressed || _systemAnimationsDisabled)) {
          _scheduleAnimationDetailSync();
        }
        final focusPlayer = widget.controller.localPlayer ?? state.turn;
        final turnChanged = _focusedTurn != focusPlayer;
        final viewportChanged = _initialViewport != viewport;
        if (!widget.controller.artilleryCinematicActive &&
            (turnChanged || _initialViewport == null)) {
          final previousTurn = _focusedTurn;
          if (turnChanged &&
              previousTurn != null &&
              state.isHuman(previousTurn)) {
            _humanPlayerScales[previousTurn] = _twoDimensionalScale(
              _transformation.value,
            ).clamp(minimumScale, 2.6);
          }
          _focusedTurn = focusPlayer;
          _initialViewport = viewport;
          // AI turns are simulated without dragging the shared camera across
          // the board. Human players each keep their own preferred zoom.
          if (state.isHuman(focusPlayer)) {
            final player = focusPlayer;
            final savedScale = _humanPlayerScales[player];
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) {
                _focusPlayer(
                  viewport,
                  player: player,
                  animate: previousTurn != null,
                  preferredScale: savedScale,
                );
              }
            });
          }
        }
        if (!turnChanged && viewportChanged) {
          _initialViewport = viewport;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || widget.controller.artilleryCinematicActive) return;
            final tile = widget.controller.selectedTile;
            final water = widget.controller.selectedWaterCell;
            final point = tile != null && tile >= 0 && tile < state.hexes.length
                ? HexBoard.centerOf(state.hexes[tile])
                : water != null && water >= 0 && water < state.waterCells.length
                ? HexBoard.centerOfWater(state, state.waterCells[water])
                : null;
            if (point == null) return;
            _cameraAnimation.stop();
            _transformation.value = MapCameraBounds(
              viewport: viewport,
              canvas: boardSize,
              minScale: minimumScale,
            ).revealPoint(_transformation.value, point);
          });
        }
        if (artilleryVolleys.isNotEmpty) {
          final serial = widget.controller.artilleryAnimationSerial;
          if (serial != _playedArtillerySerial) {
            _playedArtillerySerial = serial;
            _playedArtilleryVolleyIndex = -1;
          }
          final artilleryProgress = (1 - widget.controller.artilleryFireOpacity)
              .clamp(0.0, .9999);
          final volleyIndex = (artilleryProgress * artilleryVolleys.length)
              .floor();
          final shouldFocusVolley = volleyIndex != _playedArtilleryVolleyIndex;
          if (shouldFocusVolley) {
            _playedArtilleryVolleyIndex = volleyIndex;
            final volley = artilleryVolleys[volleyIndex];
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _focusArtilleryAction(viewport, volley);
            });
          }
        }
        return DecoratedBox(
          decoration: const BoxDecoration(color: DalaTheme.deepWater),
          child: MapViewport(
            transformationController: _transformation,
            canvasSize: boardSize,
            minScale: minimumScale,
            maxScale: 2.6,
            scaleFactor: 320 - widget.controller.sensitivity * 22,
            onInteractionStart: () {
              _cameraAnimation.stop();
            },
            child: SizedBox(
              width: boardSize.width,
              height: boardSize.height,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  RepaintBoundary(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTapUp: (details) {
                        final index = _nearestTile(
                          details.localPosition,
                          state,
                        );
                        if (index == null) return;
                        if (state.hexes[index].active) {
                          final diplomacyPlayer = widget.controller
                              .diplomacyPlayerForTile(index);
                          final openDiplomacy =
                              widget.onForeignDiplomacyRequested;
                          if (diplomacyPlayer != null &&
                              openDiplomacy != null) {
                            openDiplomacy(diplomacyPlayer);
                          } else {
                            widget.controller.tapTile(index);
                          }
                        } else {
                          final waterIndex = _waterIndexForTile(index, state);
                          if (waterIndex != null) {
                            widget.controller.tapWaterCell(waterIndex);
                          }
                        }
                      },
                      onLongPressStart: (details) {
                        final index = _nearestTile(
                          details.localPosition,
                          state,
                        );
                        if (index == null) return;
                        if (state.hexes[index].active) {
                          widget.controller.longPressTile(index);
                        } else {
                          final waterIndex = _waterIndexForTile(index, state);
                          if (waterIndex != null) {
                            widget.controller.longPressWaterCell(waterIndex);
                          }
                        }
                      },
                      onLongPressEnd: (_) => widget.controller.endLongPress(),
                      child: CustomPaint(
                        isComplex: state.hexes.length < 1200,
                        // Our bounded textures replace Flutter's unbounded
                        // whole-board raster-cache hint on very large maps.
                        willChange: state.hexes.length >= 1200,
                        painter: boardPainter,
                      ),
                    ),
                  ),
                  IgnorePointer(
                    child: AnimatedBuilder(
                      animation: Listenable.merge([
                        _transformation,
                        _battleAnimation,
                        _fortDestructionAnimation,
                      ]),
                      builder: (context, _) {
                        final view = Rect.fromPoints(
                          _transformation.toScene(Offset.zero),
                          _transformation.toScene(
                            Offset(viewport.width, viewport.height),
                          ),
                        ).inflate(80);
                        final stillView = _stillPieceWindow.resolve(view);
                        final objectView = _objectWindow.resolve(view);
                        HexUnitPainter painter(
                          HexPiecePass pass,
                          double jump,
                        ) => HexUnitPainter(
                          renderSignature: unitRenderSignature,
                          state: state,
                          mod: widget.controller.mod,
                          sprites: _sprites,
                          frame: _pieceFrame,
                          pass: pass,
                          viewBounds: pass == HexPiecePass.animated
                              ? view
                              : stillView,
                          jumpProgress: jump,
                          alertOwner: widget.controller.visibilityPlayer,
                          selectedProvinceId:
                              widget.controller.selectedOwnProvince?.id,
                          visibleTiles: visibleTiles,
                          visibleWaterCells: visibleWaterCells,
                          hiddenBoatCell:
                              fortDestruction != null &&
                                  _fortDestructionAnimation.value < .64
                              ? fortDestruction.toWaterCell
                              : battle != null && _battleAnimation.value < .58
                              ? battle.toWaterCell
                              : null,
                        );
                        return Stack(
                          fit: StackFit.expand,
                          children: [
                            if (state.hexes.length >= 1200)
                              RepaintBoundary(
                                child: CustomPaint(
                                  willChange: true,
                                  painter: HexStaticObjectPainter(
                                    source: boardPainter,
                                    viewBounds: objectView,
                                    signature: boardRenderSignature,
                                    overview: _overviewAnimationsSuppressed,
                                  ),
                                ),
                              ),
                            RepaintBoundary(
                              child: CustomPaint(
                                isComplex: state.hexes.length < 1200,
                                willChange: state.hexes.length >= 1200,
                                painter: painter(
                                  animateIdlePieces
                                      ? HexPiecePass.still
                                      : HexPiecePass.all,
                                  0,
                                ),
                              ),
                            ),
                            if (animateIdlePieces)
                              RepaintBoundary(
                                child: AnimatedBuilder(
                                  animation: _jumpAnimation,
                                  builder: (context, _) => CustomPaint(
                                    willChange: true,
                                    painter: painter(
                                      HexPiecePass.animated,
                                      _jumpAnimation.value,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        );
                      },
                    ),
                  ),
                  if (battle != null)
                    IgnorePointer(
                      child: RepaintBoundary(
                        child: AnimatedBuilder(
                          animation: _battleAnimation,
                          builder: (context, _) => CustomPaint(
                            painter: BoatBattlePainter(
                              state: state,
                              mod: widget.controller.mod,
                              sprites: _sprites,
                              battle: battle,
                              progress: _battleAnimation.value,
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (fortDestruction != null)
                    IgnorePointer(
                      child: RepaintBoundary(
                        child: AnimatedBuilder(
                          animation: _fortDestructionAnimation,
                          builder: (context, _) => CustomPaint(
                            painter: SeaFortDestructionPainter(
                              state: state,
                              mod: widget.controller.mod,
                              sprites: _sprites,
                              destruction: fortDestruction,
                              progress: _fortDestructionAnimation.value,
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (widget.controller.artilleryFireAnimation.isNotEmpty)
                    IgnorePointer(
                      child: RepaintBoundary(
                        child: CustomPaint(
                          painter: ArtilleryFirePainter(
                            state: state,
                            mod: widget.controller.mod,
                            sprites: _sprites,
                            volleys: artilleryVolleys,
                            progress:
                                1 - widget.controller.artilleryFireOpacity,
                          ),
                        ),
                      ),
                    ),
                  if (widget.controller.tool != PlayerTool.select ||
                      targets.isNotEmpty ||
                      waterTargets.isNotEmpty)
                    IgnorePointer(
                      child: RepaintBoundary(
                        child: CustomPaint(
                          willChange: state.hexes.length >= 1200,
                          painter: HexActionMaskPainter(
                            cache: _maskCache,
                            signature: Object.hash(
                              terrainSignature,
                              Object.hashAllUnordered(targets),
                              Object.hashAllUnordered(waterTargets),
                              widget.controller.selectedTile,
                              widget.controller.selectedWaterCell,
                            ),
                            state: state,
                            targets: targets,
                            waterTargets: waterTargets,
                            selected: widget.controller.selectedTile,
                            selectedWater: widget.controller.selectedWaterCell,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void _handleTransformChanged() {
    _syncRasterViewport();
    _syncAnimationDetailMode();
  }

  void _syncRasterViewport() {
    if (_rasterViewport.isEmpty) return;
    _terrainCache.setViewport(
      Rect.fromPoints(
        _transformation.toScene(Offset.zero),
        _transformation.toScene(_rasterViewport.bottomRight(Offset.zero)),
      ),
      _twoDimensionalScale(_transformation.value) * _rasterPixelRatio,
    );
    _maskCache.setViewport(
      Rect.fromPoints(
        _transformation.toScene(Offset.zero),
        _transformation.toScene(_rasterViewport.bottomRight(Offset.zero)),
      ),
      _twoDimensionalScale(_transformation.value) * _rasterPixelRatio,
    );
  }

  void _scheduleAnimationDetailSync() {
    if (_animationDetailSyncScheduled) return;
    _animationDetailSyncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _animationDetailSyncScheduled = false;
      if (mounted) _syncAnimationDetailMode();
    });
  }

  void _syncAnimationDetailMode() {
    final minimumScale = _animationMinimumScale;
    if (!mounted || minimumScale == null) return;
    final overviewSuppressed = HexBoard.shouldSuppressOverviewAnimations(
      currentScale: _twoDimensionalScale(_transformation.value),
      minimumScale: minimumScale,
      currentlySuppressed: _overviewAnimationsSuppressed,
    );
    final animationsSuppressed =
        overviewSuppressed || _systemAnimationsDisabled;
    widget.controller.setOverviewAnimationsSuppressed(animationsSuppressed);
    if (_overviewAnimationsSuppressed == overviewSuppressed) {
      if (animationsSuppressed && _jumpAnimation.isAnimating) {
        _jumpAnimation.stop();
        _jumpAnimation.value = 0;
      } else if (!animationsSuppressed && !_jumpAnimation.isAnimating) {
        _jumpAnimation.repeat();
      }
      return;
    }
    setState(() => _overviewAnimationsSuppressed = overviewSuppressed);
    if (animationsSuppressed) {
      _jumpAnimation.stop();
      _jumpAnimation.value = 0;
    } else if (!_jumpAnimation.isAnimating) {
      _jumpAnimation.repeat();
    }
  }

  void _focusPlayer(
    Size viewport, {
    required int player,
    required bool animate,
    double? preferredScale,
  }) {
    final state = widget.controller.viewState;
    final minimumScale = HexBoard.minimumScaleFor(viewport, state);
    final boardSize = HexBoard.canvasSize(state);
    final centers = HexBoard.playerAssetCenters(state, player);
    if (centers.isEmpty) return;
    final minX = centers.map((point) => point.dx).reduce(math.min);
    final maxX = centers.map((point) => point.dx).reduce(math.max);
    final minY = centers.map((point) => point.dy).reduce(math.min);
    final maxY = centers.map((point) => point.dy).reduce(math.max);
    final empireWidth = maxX - minX + HexBoard.hexRadius * 3.2;
    final empireHeight = maxY - minY + HexBoard.hexRadius * 3.2;
    final slay = state.config.slayRules;
    final fittedScale = math
        .min(
          viewport.width * (slay ? .9 : .78) / empireWidth,
          viewport.height * (slay ? .74 : .66) / empireHeight,
        )
        .clamp(.3, slay ? 1.35 : 1.15);
    final scale = (preferredScale ?? fittedScale).clamp(minimumScale, 2.6);
    final target = Offset((minX + maxX) / 2, (minY + maxY) / 2);
    final dx = viewport.width / 2 - target.dx * scale;
    final dy = viewport.height * .46 - target.dy * scale;
    final next = HexBoard.constrainTransform(
      transform: Matrix4.diagonal3Values(scale, scale, 1)
        ..setTranslationRaw(dx, dy, 0),
      viewport: viewport,
      canvas: boardSize,
      minScale: minimumScale,
    );
    _cameraAnimation.stop();
    if (!animate) {
      _transformation.value = next;
      return;
    }
    _cameraTransform =
        Matrix4Tween(
          begin: Matrix4.copy(_transformation.value),
          end: next,
        ).animate(
          CurvedAnimation(
            parent: _cameraAnimation,
            curve: Curves.easeInOutCubic,
          ),
        );
    _cameraAnimation.forward(from: 0);
  }

  void _focusArtilleryAction(Size viewport, List<ArtilleryStrike> strikes) {
    if (strikes.isEmpty) return;
    final centers = <Offset>[];
    for (final strike in strikes) {
      if (strike.fromTile >= 0 &&
          strike.fromTile < widget.controller.viewState.hexes.length) {
        centers.add(
          HexBoard.centerOf(widget.controller.viewState.hexes[strike.fromTile]),
        );
      }
      if (strike.toWaterCell >= 0 &&
          strike.toWaterCell < widget.controller.viewState.waterCells.length) {
        centers.add(
          HexBoard.centerOfWater(
            widget.controller.viewState,
            widget.controller.viewState.waterCells[strike.toWaterCell],
          ),
        );
      }
    }
    if (centers.isEmpty) return;
    final target = centers.reduce((a, b) => a + b) / centers.length.toDouble();
    final state = widget.controller.viewState;
    final minimumScale = HexBoard.minimumScaleFor(viewport, state);
    final scale = _twoDimensionalScale(
      _transformation.value,
    ).clamp(minimumScale, 2.6);
    final next = HexBoard.constrainTransform(
      transform: Matrix4.diagonal3Values(scale, scale, 1)
        ..setTranslationRaw(
          viewport.width / 2 - target.dx * scale,
          viewport.height * .44 - target.dy * scale,
          0,
        ),
      viewport: viewport,
      canvas: HexBoard.canvasSize(state),
      minScale: minimumScale,
    );
    _cameraAnimation.stop();
    _cameraTransform =
        Matrix4Tween(
          begin: Matrix4.copy(_transformation.value),
          end: next,
        ).animate(
          CurvedAnimation(
            parent: _cameraAnimation,
            curve: Curves.easeInOutCubic,
          ),
        );
    _cameraAnimation.forward(from: 0);
  }

  int? _nearestTile(Offset point, GameState state) {
    _ensureHitTestIndex(state);
    final coordinate = HexBoard.axialCoordinateAt(point);
    final index = _tileByCoordinate[coordinate];
    if (index == null || !state.hexes[index].inWorld) return null;
    return OrganicCells.path(coordinate.$1, coordinate.$2).contains(point)
        ? index
        : null;
  }

  int? _waterIndexForTile(int tile, GameState state) {
    _ensureHitTestIndex(state);
    return _waterByTile[tile];
  }

  void _ensureHitTestIndex(GameState state) {
    if (identical(_hitTestState, state)) return;
    _hitTestState = state;
    _tileByCoordinate = HexBoardPainter.axialIndexFor(state);
    _waterByTile = <int, int>{
      for (final cell in state.waterCells)
        for (final tile in cell.tiles) tile: cell.index,
    };
  }

  int _boardRenderSignature(
    GameState state,
    Set<int> visibleTiles,
    Set<int> visibleWaterCells,
    Set<int> targets,
    Set<int> waterTargets, {
    bool terrainOnly = false,
  }) => Object.hash(
    terrainOnly ? null : state.turn,
    Object.hashAll(
      state.hexes.map((tile) {
        final claim = tile.coalitionClaim;
        return Object.hash(
          tile.inWorld,
          tile.q,
          tile.r,
          tile.active,
          // Dart VM gives -1 and 0 the same int hash. Normalize the neutral
          // sentinel before hashing or player zero's captures stay invisible.
          tile.owner + 1,
          tile.object,
          claim?.captor,
          claim == null ? 0 : Object.hashAll(claim.members),
          claim == null ? 0 : Object.hashAll(claim.contributors),
        );
      }),
    ),
    Object.hashAll(
      state.waterCells.map(
        (cell) => Object.hash(cell.navigable, Object.hashAll(cell.tiles)),
      ),
    ),
    widget.controller.fogActive,
    Object.hashAllUnordered(visibleTiles),
    Object.hashAllUnordered(visibleWaterCells),
    terrainOnly ? null : widget.controller.selectedTile,
    terrainOnly ? null : widget.controller.selectedWaterCell,
    terrainOnly ? null : (widget.controller.selectionOpacity * 1000).round(),
    terrainOnly ? null : Object.hashAllUnordered(targets),
    terrainOnly ? null : Object.hashAllUnordered(waterTargets),
    terrainOnly
        ? null
        : Object.hashAllUnordered(widget.controller.defensePreviewTiles),
    terrainOnly
        ? null
        : Object.hashAllUnordered(widget.controller.defensePreviewWaterCells),
    terrainOnly
        ? null
        : (widget.controller.defensePreviewOpacity * 1000).round(),
    terrainOnly ? null : widget.controller.artilleryRangePreview,
    Object.hash(
      widget.controller.artilleryAnimationSerial,
      widget.controller.artilleryFireAnimation.isNotEmpty,
    ),
    terrainOnly
        ? null
        : (widget.controller.artilleryFireOpacity * 1000).round(),
    identityHashCode(_sprites),
  );

  int _unitRenderSignature(
    GameState state,
    Set<int> visibleTiles,
    Set<int> visibleWaterCells,
  ) => Object.hash(
    state.turn,
    Object.hashAll(
      state.hexes.map((tile) {
        final unit = tile.unit;
        return unit == null
            ? 0
            : Object.hash(
                tile.index,
                unit.strength,
                unit.owner + 1,
                unit.ready,
              );
      }),
    ),
    Object.hashAll(
      state.waterCells.map((cell) {
        final boat = cell.boat;
        final fort = cell.seaFort;
        return Object.hash(
          cell.index,
          cell.seaMint,
          boat == null ? null : boat.owner + 1,
          boat?.level,
          boat?.ready,
          boat?.usedCapacity,
          boat == null ? 0 : Object.hashAll(boat.supportedTiles),
          fort == null ? null : fort.owner + 1,
        );
      }),
    ),
    Object.hashAll(
      state.provinces.map(
        (province) => Object.hash(
          province.id,
          province.owner,
          province.capital,
          province.money >= 10,
        ),
      ),
    ),
    Object.hashAll(
      state.diplomacyRelations.expand(
        (row) => row.map((status) => status.index),
      ),
    ),
    Object.hashAll(state.diplomacyBlackMarks.expand((row) => row)),
    Object.hashAllUnordered(visibleTiles),
    Object.hashAllUnordered(visibleWaterCells),
    widget.controller.visibilityPlayer,
    widget.controller.selectedOwnProvince?.id,
    widget.controller.boatBattleAnimation?.serial,
    widget.controller.seaFortDestructionAnimation?.serial,
    identityHashCode(_sprites),
  );
}

/// Objects remain sharp independently of terrain resolution. Only a retained
/// visible window is recorded; the full overview keeps strategic buildings,
/// avoiding thousands of sub-pixel tree textures on a mobile GPU.
class HexStaticObjectPainter extends CustomPainter {
  HexStaticObjectPainter({
    required this.source,
    required this.viewBounds,
    required this.signature,
    required this.overview,
  }) : super(repaint: source.terrainCache);
  final HexBoardPainter source;
  final Rect viewBounds;
  final int signature;
  final bool overview;

  @override
  void paint(Canvas canvas, Size size) {
    if (overview) return;
    for (final tile in source.state.hexes) {
      if (!tile.active ||
          tile.object == TileObject.none ||
          !source.visibleTiles.contains(tile.index)) {
        continue;
      }
      if (!const {
        TileObject.pine,
        TileObject.palm,
        TileObject.grave,
        TileObject.farm,
      }.contains(tile.object)) {
        continue;
      }
      final center = HexBoard.centerOf(tile);
      if (!viewBounds.contains(center)) continue;
      final cache = source.terrainCache;
      if (cache != null &&
          [
            const Offset(-24, -24),
            const Offset(24, -24),
            const Offset(-24, 24),
            const Offset(24, 24),
          ].every((offset) => cache.hasDetailAt(center + offset))) {
        continue;
      }
      source._drawObject(canvas, center, tile);
    }
  }

  @override
  bool shouldRepaint(HexStaticObjectPainter oldDelegate) =>
      signature != oldDelegate.signature ||
      viewBounds != oldDelegate.viewBounds ||
      overview != oldDelegate.overview;
}

class HexActionMaskPainter extends CustomPainter {
  HexActionMaskPainter({
    this.cache,
    this.signature,
    required this.state,
    required this.targets,
    required this.waterTargets,
    required this.selected,
    required this.selectedWater,
  }) : super(repaint: cache);

  final MapRasterCache? cache;
  final int? signature;
  final GameState state;
  final Set<int> targets;
  final Set<int> waterTargets;
  final int? selected;
  final int? selectedWater;

  @override
  void paint(Canvas canvas, Size size) {
    if (cache != null && signature != null) {
      cache!.draw(
        canvas,
        signature!,
        _paintMask,
        size: size,
        rasterize:
            state.hexes.length >= 1200 &&
            !const bool.fromEnvironment('ANTIYOY_VECTOR_TERRAIN'),
      );
    } else {
      _paintMask(canvas);
    }
  }

  void _paintMask(Canvas canvas) {
    final shadow = Paint()..color = const Color(0x66000000);
    for (final tile in state.hexes) {
      if (!tile.active ||
          tile.index == selected ||
          targets.contains(tile.index)) {
        continue;
      }
      canvas.drawPath(
        _hexPath(HexBoard.centerOf(tile), HexBoard.hexRadius - 1),
        shadow,
      );
    }
    for (final cell in state.waterCells) {
      if (cell.index == selectedWater || waterTargets.contains(cell.index)) {
        continue;
      }
      for (final tileIndex in cell.tiles) {
        canvas.drawPath(
          _hexPath(
            HexBoard.centerOf(state.hexes[tileIndex]),
            HexBoard.hexRadius + .3,
          ),
          shadow,
        );
      }
    }
  }

  Path _hexPath(Offset center, double radius) => OrganicCells.around(
    center,
    inset: math.max(0, HexBoard.hexRadius - radius),
  );

  @override
  bool shouldRepaint(HexActionMaskPainter oldDelegate) =>
      signature == null || signature != oldDelegate.signature;
}

class HexTerrainCache extends MapRasterCache {
  HexTerrainCache({super.rasterizer, super.schedule});
  List<int> _cells = [];
  int? _environment;

  List<Rect>? changedCells(HexBoardPainter painter) {
    final state = painter.state;
    final environment = Object.hash(
      state.width,
      state.height,
      identityHashCode(painter.sprites),
      painter.mod.neutralColor,
      painter.mod.waterColor,
      Object.hashAll(painter.mod.palette),
      Object.hashAll(
        state.waterCells.map(
          (c) => Object.hash(c.navigable, Object.hashAll(c.tiles)),
        ),
      ),
    );
    final all =
        environment != _environment || _cells.length != state.hexes.length;
    final dirty = <Rect>[];
    final next = <int>[];
    for (final tile in state.hexes) {
      final water = painter._waterByTile[tile.index];
      final visible = tile.active
          ? painter.visibleTiles.contains(tile.index)
          : painter.visibleWaterCells.contains(water);
      final claim = tile.coalitionClaim;
      final hash = Object.hash(
        tile.q,
        tile.r,
        tile.inWorld,
        tile.active,
        tile.owner + 1,
        tile.object,
        painter.fogActive,
        visible,
        claim?.captor,
        claim == null ? null : Object.hashAll(claim.members),
        claim == null ? null : Object.hashAll(claim.contributors),
        painter._firingTiles.contains(tile.index),
      );
      next.add(hash);
      if (!all && _cells[tile.index] != hash) {
        // Include neighbors' borders and overhanging sprites.
        dirty.add(
          Rect.fromCircle(center: HexBoard.centerOf(tile), radius: 100),
        );
      }
    }
    _cells = next;
    _environment = environment;
    return all ? null : dirty;
  }
}

class HexBoardPainter extends CustomPainter {
  HexBoardPainter({
    this.renderSignature,
    this.terrainCache,
    this.terrainSignature,
    required this.state,
    required this.mod,
    required this.fogActive,
    required this.sprites,
    required this.selected,
    required this.selectedWater,
    required this.selectionOpacity,
    required this.moveTargets,
    required this.waterTargets,
    required this.defensePreviewTiles,
    required this.defensePreviewWaterCells,
    required this.defensePreviewOpacity,
    required this.artilleryRangePreview,
    required this.artilleryVolleys,
    required this.artilleryFireProgress,
    required this.visibleTiles,
    required this.visibleWaterCells,
  }) : super(repaint: terrainCache);

  final int? renderSignature;
  final HexTerrainCache? terrainCache;
  final int? terrainSignature;
  final GameState state;
  final GameMod mod;
  final bool fogActive;
  final ClassicSprites? sprites;
  final int? selected;
  final int? selectedWater;
  final double selectionOpacity;
  final Set<int> moveTargets;
  final Set<int> waterTargets;
  final Set<int> defensePreviewTiles;
  final Set<int> defensePreviewWaterCells;
  final double defensePreviewOpacity;
  final bool artilleryRangePreview;
  final List<List<ArtilleryStrike>> artilleryVolleys;
  final double artilleryFireProgress;
  final Set<int> visibleTiles;
  final Set<int> visibleWaterCells;

  late final Map<int, int> _waterByTile = {
    for (final cell in state.waterCells)
      for (final tile in cell.tiles) tile: cell.index,
  };
  Rect? _recordBounds;
  bool _inRecordBounds(HexTile tile) =>
      _recordBounds == null || _recordBounds!.contains(HexBoard.centerOf(tile));

  static const Color _hiddenFogColor = Color(0xff637879);
  static const Color _deepWaterColor = Color(0xff365c68);

  @visibleForTesting
  static Map<(int, int), int> axialIndexFor(GameState state) => {
    for (final tile in state.hexes) (tile.q, tile.r): tile.index,
  };

  @override
  void paint(Canvas canvas, Size size) {
    final cache = terrainCache;
    final signature = terrainSignature;
    if (cache != null && signature != null) {
      cache.draw(
        canvas,
        signature,
        (canvas) => _paintTerrain(canvas, highlights: false),
        size: size,
        rasterize:
            state.hexes.length >= 1200 &&
            !const bool.fromEnvironment('ANTIYOY_VECTOR_TERRAIN'),
        recordOverview: state.hexes.length >= 1200
            ? (canvas) =>
                  _paintTerrain(canvas, highlights: false, overview: true)
            : null,
        recordRegion: (canvas, bounds) {
          _recordBounds = bounds.inflate(70);
          try {
            _paintTerrain(canvas, highlights: false);
          } finally {
            _recordBounds = null;
          }
        },
        changedRegions: () => cache.changedCells(this),
      );
      _drawHighlights(canvas);
    } else {
      _paintTerrain(canvas);
    }
    _drawDefensePreview(canvas);
    if (selected != null &&
        selected! >= 0 &&
        selected! < state.hexes.length &&
        state.hexes[selected!].active &&
        visibleTiles.contains(selected)) {
      _drawSelection(canvas, HexBoard.centerOf(state.hexes[selected!]));
    }
  }

  void _paintTerrain(
    Canvas canvas, {
    bool highlights = true,
    bool overview = false,
  }) {
    _drawWater(canvas, highlights: highlights);
    for (final tile in state.hexes) {
      if (!tile.active || !_inRecordBounds(tile)) continue;
      final center = HexBoard.centerOf(tile);
      _drawHex(canvas, center, tile);
      if (highlights &&
          visibleTiles.contains(tile.index) &&
          moveTargets.contains(tile.index)) {
        _drawMoveTarget(canvas, center);
      }
      if ((!overview ||
              !const {
                TileObject.pine,
                TileObject.palm,
                TileObject.grave,
                TileObject.farm,
              }.contains(tile.object)) &&
          visibleTiles.contains(tile.index) &&
          (highlights || !_firingTiles.contains(tile.index))) {
        _drawObject(canvas, center, tile);
      }
    }
    _drawFogMask(canvas);
    _drawGrid(canvas, overview: overview);
  }

  late final Set<int> _firingTiles = {
    for (final volley in artilleryVolleys)
      for (final strike in volley) strike.fromTile,
  };

  void _drawHighlights(Canvas canvas) {
    for (final index in moveTargets) {
      if (!visibleTiles.contains(index) ||
          index < 0 ||
          index >= state.hexes.length) {
        continue;
      }
      final tile = state.hexes[index];
      if (!tile.active || !_inRecordBounds(tile)) continue;
      final center = HexBoard.centerOf(tile);
      _drawMoveTarget(canvas, center);
      if (!_firingTiles.contains(index)) {
        _drawObject(canvas, center, tile);
      }
    }
    final target = Paint()
      ..color = mod.palette[state.turn % mod.palette.length].withValues(
        alpha: .44,
      );
    for (final index in waterTargets) {
      if (!visibleWaterCells.contains(index) ||
          index < 0 ||
          index >= state.waterCells.length) {
        continue;
      }
      for (final tileIndex in state.waterCells[index].tiles) {
        canvas.drawPath(
          _hexPath(
            HexBoard.centerOf(state.hexes[tileIndex]),
            HexBoard.hexRadius - 2,
          ),
          target,
        );
      }
    }
    final index = selectedWater;
    if (index != null &&
        index >= 0 &&
        index < state.waterCells.length &&
        visibleWaterCells.contains(index)) {
      canvas.drawCircle(
        HexBoard.centerOfWater(state, state.waterCells[index]),
        24,
        Paint()
          ..color = mod.palette[state.turn % mod.palette.length].withValues(
            alpha: .95,
          )
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3,
      );
    }
    for (final index in _firingTiles) {
      if (index < 0 ||
          index >= state.hexes.length ||
          !visibleTiles.contains(index)) {
        continue;
      }
      final tile = state.hexes[index];
      _drawObject(canvas, HexBoard.centerOf(tile), tile);
    }
  }

  void _drawDefensePreview(Canvas canvas) {
    if ((defensePreviewTiles.isEmpty && defensePreviewWaterCells.isEmpty) ||
        defensePreviewOpacity <= 0) {
      return;
    }
    for (final index in defensePreviewTiles) {
      if (index < 0 || index >= state.hexes.length) continue;
      final tile = state.hexes[index];
      if (!tile.active || tile.owner < 0) continue;
      final isDefenseSource = switch (tile.object) {
        TileObject.town || TileObject.tower || TileObject.strongTower => true,
        _ => false,
      };
      if (isDefenseSource) continue;
      final center = HexBoard.centerOf(tile);
      final color = mod.palette[tile.owner % mod.palette.length];
      _drawDefenseShield(canvas, center, color, defensePreviewOpacity);
    }
    for (final waterIndex in defensePreviewWaterCells) {
      if (waterIndex < 0 || waterIndex >= state.waterCells.length) continue;
      final cell = state.waterCells[waterIndex];
      if (artilleryRangePreview) {
        final color = mod.palette[state.turn % mod.palette.length];
        for (final tileIndex in cell.tiles) {
          final path = _hexPath(
            HexBoard.centerOf(state.hexes[tileIndex]),
            HexBoard.hexRadius - 2,
          );
          canvas.drawPath(
            path,
            Paint()
              ..color = color.withValues(alpha: .22 * defensePreviewOpacity),
          );
          canvas.drawPath(
            path,
            Paint()
              ..color = color.withValues(alpha: defensePreviewOpacity)
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2.4,
          );
        }
        final center = HexBoard.centerOfWater(state, cell);
        final markerPaint = Paint()
          ..color = const Color(
            0xff101619,
          ).withValues(alpha: defensePreviewOpacity)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3;
        canvas.drawCircle(center, 10, markerPaint);
        canvas.drawLine(
          center.translate(-15, 0),
          center.translate(15, 0),
          markerPaint,
        );
        canvas.drawLine(
          center.translate(0, -15),
          center.translate(0, 15),
          markerPaint,
        );
        canvas.drawCircle(
          center,
          7,
          Paint()
            ..color = color.withValues(alpha: defensePreviewOpacity)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2,
        );
        continue;
      }
      if (cell.seaFort != null) continue;
      final fortOwner = state.waterCells
          .where(
            (candidate) =>
                candidate.seaFort != null &&
                (candidate.index == waterIndex ||
                    candidate.neighbors.contains(waterIndex)),
          )
          .map((candidate) => candidate.seaFort!.owner)
          .cast<int?>()
          .firstWhere((_) => true, orElse: () => state.turn)!;
      final color = mod.palette[fortOwner % mod.palette.length];
      _drawDefenseShield(
        canvas,
        HexBoard.centerOfWater(state, cell),
        color,
        defensePreviewOpacity,
      );
    }
  }

  void _drawWater(Canvas canvas, {bool highlights = true}) {
    final fill = Paint()..color = mod.waterColor.withValues(alpha: .96);
    final deepFill = Paint()..color = _deepWaterColor;
    final target = Paint()
      ..color = mod.palette[state.turn % mod.palette.length].withValues(
        alpha: .44,
      );
    final waterByTile = <int, int>{
      for (final cell in state.waterCells)
        for (final tile in cell.tiles) tile: cell.index,
    };
    // Terrain is painted per hex, not per packed naval cell. This guarantees
    // that every in-world water hex reaches the canvas even while an old save
    // is being repaired or a cell grouping changes at an irregular coast.
    for (final tile in state.hexes) {
      if (!tile.inWorld || tile.active || !_inRecordBounds(tile)) continue;
      final cellIndex = waterByTile[tile.index];
      final cellVisible =
          cellIndex != null && visibleWaterCells.contains(cellIndex);
      final path = _hexPath(HexBoard.centerOf(tile), HexBoard.hexRadius + .5);
      canvas.drawPath(path, cellVisible || fogActive ? fill : deepFill);
      if (highlights && cellVisible && waterTargets.contains(cellIndex)) {
        canvas.drawPath(path, target);
      }
    }
    for (final cell in state.waterCells) {
      if (highlights &&
          selectedWater == cell.index &&
          visibleWaterCells.contains(cell.index)) {
        canvas.drawCircle(
          HexBoard.centerOfWater(state, cell),
          24,
          Paint()
            ..color = mod.palette[state.turn % mod.palette.length].withValues(
              alpha: .95,
            )
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3,
        );
      }
    }
  }

  void _drawHex(Canvas canvas, Offset center, HexTile tile) {
    final path = _hexPath(center, HexBoard.hexRadius + .25);
    canvas.drawPath(
      path,
      Paint()
        ..color = tile.owner < 0
            ? mod.neutralColor
            : mod.palette[tile.owner % mod.palette.length],
    );
    final claim = tile.coalitionClaim;
    if ((!fogActive || visibleTiles.contains(tile.index)) && claim != null) {
      final contributors =
          (claim.contributors.isNotEmpty ? claim.contributors : claim.members)
              .toSet()
              .toList()
            ..sort();
      if (contributors.length < 2) return;
      final radius = HexBoard.hexRadius * 2.2;
      final circle = Rect.fromCircle(center: center, radius: radius);
      final sweep = math.pi * 2 / contributors.length;
      canvas.save();
      canvas.clipPath(path);
      for (var i = 0; i < contributors.length; i++) {
        final start = -math.pi / 2 + sweep * i;
        final wedge = Path()
          ..moveTo(center.dx, center.dy)
          ..lineTo(
            center.dx + math.cos(start) * radius,
            center.dy + math.sin(start) * radius,
          )
          ..arcTo(circle, start, sweep, false)
          ..close();
        final color = mod.palette[contributors[i] % mod.palette.length];
        canvas.drawPath(wedge, Paint()..color = color);
      }
      canvas.restore();
    }
  }

  void _drawFogMask(Canvas canvas) {
    if (!fogActive) return;
    final waterByTile = <int, int>{
      for (final cell in state.waterCells)
        for (final tile in cell.tiles) tile: cell.index,
    };
    final fogPaint = Paint()..color = _hiddenFogColor;
    // Apply one final opaque terrain-agnostic mask. Drawing it after the base
    // terrain prevents land, navigable sea, deep sea, and incomplete legacy
    // water packing from producing different shades under fog.
    for (final tile in state.hexes) {
      if (!tile.inWorld ||
          !_inRecordBounds(tile) ||
          _terrainTileVisible(tile.index, waterByTile)) {
        continue;
      }
      canvas.drawPath(
        _hexPath(HexBoard.centerOf(tile), HexBoard.hexRadius + .65),
        fogPaint,
      );
    }
  }

  void _drawMoveTarget(Canvas canvas, Offset center) {
    canvas.drawPath(
      _hexPath(center, HexBoard.hexRadius - 3),
      Paint()
        ..color = mod.palette[state.turn % mod.palette.length].withValues(
          alpha: .44,
        ),
    );
  }

  void _drawObject(Canvas canvas, Offset center, HexTile tile) {
    final artilleryLevel = switch (tile.object) {
      TileObject.artillery1 => 1,
      TileObject.artillery2 => 2,
      TileObject.artillery3 => 3,
      _ => 0,
    };
    final objectName = switch (tile.object) {
      TileObject.pine => 'pine',
      TileObject.palm => 'palm',
      TileObject.town => 'castle',
      TileObject.farm => 'farm1',
      TileObject.tower => 'tower',
      TileObject.strongTower => 'strong_tower',
      TileObject.grave => 'grave',
      TileObject.port1 => 'port1',
      TileObject.port2 => 'port2',
      TileObject.artillery1 ||
      TileObject.artillery2 ||
      TileObject.artillery3 => 'artillery_base',
      TileObject.none => null,
    };
    if (objectName != null && sprites != null) {
      final teamMasked = switch (tile.object) {
        TileObject.town ||
        TileObject.farm ||
        TileObject.tower ||
        TileObject.strongTower ||
        TileObject.port1 ||
        TileObject.port2 => true,
        _ => false,
      };
      final artilleryPose = artilleryLevel > 0
          ? _artilleryPose(tile.index, center)
          : null;
      _drawImage(canvas, sprites![objectName], center, const Size(47, 47));
      if (artilleryPose != null) {
        canvas.save();
        canvas.translate(center.dx, center.dy);
        canvas.rotate(artilleryPose.$1);
        canvas.translate(-artilleryPose.$3, 0);
        _drawImage(
          canvas,
          sprites!['artillery_turret'],
          Offset.zero,
          const Size(47, 47),
        );
        canvas.restore();
        if (artilleryPose.$2 > 0) {
          final muzzle =
              center +
              Offset(math.cos(artilleryPose.$1), math.sin(artilleryPose.$1)) *
                  (22 - artilleryPose.$3);
          canvas.drawCircle(
            muzzle,
            5 + 5 * artilleryPose.$2,
            Paint()
              ..color = const Color(
                0xffffe077,
              ).withValues(alpha: artilleryPose.$2),
          );
        }
      }
      if (teamMasked && tile.owner >= 0) {
        _drawImage(
          canvas,
          sprites!['${objectName}_team'],
          center,
          const Size(47, 47),
          tint: mod.palette[tile.owner % mod.palette.length],
        );
      }
      if (tile.owner >= 0) {
        final teamColor = mod.palette[tile.owner % mod.palette.length];
        for (var i = 0; i < artilleryLevel; i++) {
          canvas.drawCircle(
            center.translate((i - (artilleryLevel - 1) / 2) * 6, 18),
            2.2,
            Paint()
              ..color = teamColor
              ..style = PaintingStyle.fill,
          );
        }
      }
    }
  }

  (double, double, double) _artilleryPose(int tileIndex, Offset center) {
    const idleAngle = -2.55;
    if (artilleryVolleys.isEmpty) return (idleAngle, 0, 0);
    final timeline =
        artilleryFireProgress.clamp(0.0, .9999) * artilleryVolleys.length;
    final activeIndex = timeline.floor();
    if (activeIndex < 0 || activeIndex >= artilleryVolleys.length) {
      return (idleAngle, 0, 0);
    }
    ArtilleryStrike? strike;
    for (final candidate in artilleryVolleys[activeIndex]) {
      if (candidate.fromTile == tileIndex) {
        strike = candidate;
        break;
      }
    }
    if (strike == null ||
        strike.toWaterCell < 0 ||
        strike.toWaterCell >= state.waterCells.length) {
      return (idleAngle, 0, 0);
    }
    final local = timeline - activeIndex;
    final target = HexBoard.centerOfWater(
      state,
      state.waterCells[strike.toWaterCell],
    );
    final targetAngle = math.atan2(
      target.dy - center.dy,
      target.dx - center.dx,
    );
    var delta = targetAngle - idleAngle;
    while (delta > math.pi) {
      delta -= math.pi * 2;
    }
    while (delta < -math.pi) {
      delta += math.pi * 2;
    }
    final aim = Curves.easeOutCubic.transform((local / .38).clamp(0, 1));
    final flash = local >= .4 && local <= .56
        ? math.sin(((local - .4) / .16) * math.pi).clamp(0, 1).toDouble()
        : 0.0;
    final recoil = local >= .4 && local <= .62
        ? math.sin(((local - .4) / .22) * math.pi).clamp(0, 1).toDouble() * 3.5
        : 0.0;
    return (idleAngle + delta * aim, flash, recoil);
  }

  void _drawGrid(Canvas canvas, {bool overview = false}) {
    // Full-map batches are useful for the overview but prevent spatial
    // culling when rendering one detail chunk. Keep detail commands granular.
    final batched = overview;
    if (batched) _edgeBatches = {};
    const directions = [(1, 0), (1, -1), (0, -1), (-1, 0), (-1, 1), (0, 1)];
    final tileByCoordinate = axialIndexFor(state);
    final waterByTile = <int, int>{
      for (final cell in state.waterCells)
        for (final tile in cell.tiles) tile: cell.index,
    };
    for (final tile in state.hexes) {
      if (!tile.active || !_inRecordBounds(tile)) continue;
      final center = HexBoard.centerOf(tile);
      final tileVisible = visibleTiles.contains(tile.index);
      for (var edge = 0; edge < directions.length; edge++) {
        final nq = tile.q + directions[edge].$1;
        final nr = tile.r + directions[edge].$2;
        final neighborIndex = tileByCoordinate[(nq, nr)];
        final neighbor = neighborIndex == null
            ? null
            : state.hexes[neighborIndex];
        if (neighbor != null &&
            neighbor.active &&
            neighbor.index < tile.index) {
          continue;
        }
        final masksUnknownTerrain =
            neighbor != null &&
            neighbor.inWorld &&
            masksUnknownTerrainBoundary(
              fogActive: fogActive,
              firstVisible: tileVisible,
              secondVisible: _terrainTileVisible(neighbor.index, waterByTile),
            );
        final sameOwner =
            masksUnknownTerrain ||
            neighbor != null &&
                neighbor.active &&
                fogSafeSameOwner(
                  tileOwner: tile.owner,
                  neighborOwner: neighbor.owner,
                  tileVisible: visibleTiles.contains(tile.index),
                  neighborVisible: visibleTiles.contains(neighbor.index),
                );
        if (overview && sameOwner) continue;
        _drawEdge(
          canvas,
          center,
          edge,
          sameOwner: sameOwner,
          coastEdge:
              !masksUnknownTerrain && (neighbor == null || !neighbor.active),
        );
      }
    }
    for (final cell in state.waterCells) {
      final cellVisible = visibleWaterCells.contains(cell.index);
      for (final tileIndex in cell.tiles) {
        final tile = state.hexes[tileIndex];
        if (!_inRecordBounds(tile)) continue;
        final center = HexBoard.centerOf(tile);
        for (var edge = 0; edge < directions.length; edge++) {
          final nq = tile.q + directions[edge].$1;
          final nr = tile.r + directions[edge].$2;
          final neighborIndex = tileByCoordinate[(nq, nr)];
          final neighbor = neighborIndex == null
              ? null
              : state.hexes[neighborIndex];
          final seaBoundary = neighbor == null || !neighbor.inWorld;
          if (overview && !seaBoundary) continue;
          if (neighbor != null && neighbor.inWorld) {
            if (neighbor.active) continue;
            final otherWater = waterByTile[neighbor.index];
            final masksUnknownTerrain = masksUnknownTerrainBoundary(
              fogActive: fogActive,
              firstVisible: cellVisible,
              secondVisible: _terrainTileVisible(neighbor.index, waterByTile),
            );
            if (masksUnknownTerrain) {
              if (neighbor.index < tile.index) continue;
              _drawEdge(canvas, center, edge, sameOwner: true);
              continue;
            }
            if (otherWater == cell.index ||
                (otherWater != null && otherWater < cell.index)) {
              continue;
            }
          }
          _drawEdge(
            canvas,
            center,
            edge,
            sameOwner: false,
            waterEdge: true,
            seaBoundary: seaBoundary,
          );
        }
      }
    }
    if (batched) {
      for (final batch in _edgeBatches!.values) {
        canvas.drawPath(batch.$2, batch.$1);
      }
      _edgeBatches = null;
    }
  }

  Map<(int, double), (Paint, Path)>? _edgeBatches;

  bool _terrainTileVisible(int tileIndex, Map<int, int> waterByTile) {
    if (tileIndex < 0 || tileIndex >= state.hexes.length) return false;
    final tile = state.hexes[tileIndex];
    if (!tile.inWorld) return false;
    if (tile.active) return visibleTiles.contains(tileIndex);
    final waterIndex = waterByTile[tileIndex];
    return waterIndex != null && visibleWaterCells.contains(waterIndex);
  }

  void _drawEdge(
    Canvas canvas,
    Offset center,
    int edge, {
    required bool sameOwner,
    bool waterEdge = false,
    bool coastEdge = false,
    bool seaBoundary = false,
  }) {
    final path = OrganicCells.edgePath(center, edge);
    final paint = Paint()
      ..color = seaBoundary
          ? const Color(0xcc0b2635)
          : sameOwner
          ? const Color(0x34496151)
          : waterEdge
          ? const Color(0x688bcecf)
          : coastEdge
          ? const Color(0xffeee3c5)
          : const Color(0xa03f5f55)
      ..strokeWidth = seaBoundary
          ? 2.7
          : sameOwner
          ? 1.0
          : waterEdge
          ? 1.2
          : coastEdge
          ? 2.6
          : 1.8
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;
    final batches = _edgeBatches;
    if (batches == null) {
      canvas.drawPath(path, paint);
    } else {
      final batch = batches.putIfAbsent((
        paint.color.toARGB32(),
        paint.strokeWidth,
      ), () => (paint, Path()));
      batch.$2.addPath(path, Offset.zero);
    }
  }

  static double edgeNormal(int edge) => const [
    math.pi / 6,
    -math.pi / 6,
    -math.pi / 2,
    -5 * math.pi / 6,
    5 * math.pi / 6,
    math.pi / 2,
  ][edge];

  @visibleForTesting
  static bool fogSafeSameOwner({
    required int tileOwner,
    required int neighborOwner,
    required bool tileVisible,
    required bool neighborVisible,
  }) {
    // A real ownership boundary is knowledge about both cells. If either side
    // is under fog, render the edge as an ordinary grid line so distant enemy
    // provinces cannot be reconstructed from their silhouettes.
    if (!tileVisible || !neighborVisible) return true;
    return tileOwner == neighborOwner;
  }

  @visibleForTesting
  static bool masksUnknownTerrainBoundary({
    required bool fogActive,
    required bool firstVisible,
    required bool secondVisible,
  }) => fogActive && !firstVisible && !secondVisible;

  void _drawSelection(Canvas canvas, Offset center) {
    final paint = Paint()
      ..color = const Color(0xdd111111).withValues(alpha: selectionOpacity)
      ..strokeWidth = 3.4
      ..strokeCap = StrokeCap.round;
    paint
      ..style = PaintingStyle.stroke
      ..color = const Color(0xfffff6d9).withValues(alpha: selectionOpacity);
    canvas.drawPath(OrganicCells.around(center, inset: 2), paint);
  }

  void _drawImage(
    Canvas canvas,
    ui.Image image,
    Offset center,
    Size target, {
    Color? tint,
    double opacity = 1,
  }) {
    final tinted = tint == null ? null : sprites?.tintedSprite(image, tint);
    if (tinted != null) {
      image = tinted.$1;
      tint = null;
    }
    final source =
        tinted?.$2 ??
        Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble());
    final destination = Rect.fromCenter(
      center: center,
      width: target.width,
      height: target.height,
    );
    final paint = Paint()..color = Colors.white.withValues(alpha: opacity);
    if (tint != null) {
      paint.colorFilter = ColorFilter.mode(
        tint.withValues(alpha: opacity),
        BlendMode.srcIn,
      );
    }
    canvas.drawImageRect(image, source, destination, paint);
  }

  Path _hexPath(Offset center, double radius) => OrganicCells.around(
    center,
    inset: math.max(0, HexBoard.hexRadius - radius),
  );

  @override
  bool shouldRepaint(HexBoardPainter oldDelegate) =>
      renderSignature == null ||
      oldDelegate.renderSignature == null ||
      oldDelegate.renderSignature != renderSignature;
}

enum HexPiecePass { all, still, animated }

/// Build piece lists only when simulation/visibility changes, never per idle
/// frame. This mirrors Classic's unit list instead of scanning empty terrain.
class HexPieceFrame {
  HexPieceFrame(GameState state, Set<int> visibleTiles, Set<int> visibleWater)
    : units = [
        for (final tile in state.hexes)
          if (tile.active &&
              tile.unit != null &&
              visibleTiles.contains(tile.index))
            tile,
      ],
      water = [
        for (final cell in state.waterCells)
          if (visibleWater.contains(cell.index) &&
              (cell.boat != null || cell.seaFort != null || cell.seaMint))
            cell,
      ],
      provinces = [
        for (final province in state.provinces)
          if (visibleTiles.contains(province.capital)) province,
      ] {
    movingUnits = units
        .where((tile) => HexUnitPainter.shouldBounceUnit(state, tile))
        .toList();
    movingWater = water
        .where(
          (cell) =>
              cell.boat != null &&
              HexUnitPainter.shouldBounceBoat(state, cell.boat!),
        )
        .toList();
  }

  final List<HexTile> units;
  final List<WaterCell> water;
  final List<Province> provinces;
  late final List<HexTile> movingUnits;
  late final List<WaterCell> movingWater;
}

class HexUnitPainter extends CustomPainter {
  HexUnitPainter({
    this.renderSignature,
    required this.state,
    required this.mod,
    required this.sprites,
    required this.jumpProgress,
    required this.alertOwner,
    required this.selectedProvinceId,
    required this.visibleTiles,
    required this.visibleWaterCells,
    this.hiddenBoatCell,
    this.frame,
    this.pass = HexPiecePass.all,
    this.viewBounds,
  });

  final int? renderSignature;
  final GameState state;
  final GameMod mod;
  final ClassicSprites? sprites;
  final double jumpProgress;
  final int alertOwner;
  final int? selectedProvinceId;
  final Set<int> visibleTiles;
  final Set<int> visibleWaterCells;
  final int? hiddenBoatCell;
  final HexPieceFrame? frame;
  final HexPiecePass pass;
  final Rect? viewBounds;

  bool _inView(Offset center) =>
      viewBounds == null || viewBounds!.contains(center);
  bool _inPass(bool animated) =>
      pass == HexPiecePass.all || (pass == HexPiecePass.animated) == animated;

  @override
  void paint(Canvas canvas, Size size) {
    if (sprites == null) return;
    if (pass != HexPiecePass.animated) _drawNavalSupplyLinks(canvas);
    for (final tile
        in (pass == HexPiecePass.animated
                ? frame?.movingUnits
                : frame?.units) ??
            state.hexes) {
      final unit = tile.unit;
      if (!tile.active || unit == null || !visibleTiles.contains(tile.index)) {
        continue;
      }
      if (!_inPass(shouldBounceUnit(state, tile)) ||
          !_inView(HexBoard.centerOf(tile))) {
        continue;
      }
      final jumpHeight = shouldBounceUnit(state, tile)
          ? 4 * jumpProgress * (1 - jumpProgress) * 5
          : 0.0;
      final center = HexBoard.centerOf(tile).translate(0, -jumpHeight);
      _drawImage(
        canvas,
        sprites!['man${unit.strength - 1}'],
        center,
        const Size(46, 46),
      );
      _drawImage(
        canvas,
        sprites!['man${unit.strength - 1}_team'],
        center,
        const Size(46, 46),
        tint: (unit.owner >= 0 ? unit.owner : tile.owner) < 0
            ? const Color(0xff777777)
            : mod.palette[(unit.owner >= 0 ? unit.owner : tile.owner) %
                  mod.palette.length],
      );
    }
    for (final cell
        in (pass == HexPiecePass.animated
                ? frame?.movingWater
                : frame?.water) ??
            state.waterCells) {
      if (!visibleWaterCells.contains(cell.index)) continue;
      if (!_inView(HexBoard.centerOfWater(state, cell))) continue;
      if (cell.seaMint && pass != HexPiecePass.animated) {
        _drawImage(
          canvas,
          sprites!['sea_mint'],
          HexBoard.centerOfWater(state, cell),
          const Size(50, 50),
        );
      }
      final fort = cell.seaFort;
      if (fort != null && pass != HexPiecePass.animated) {
        final center = HexBoard.centerOfWater(state, cell);
        _drawImage(canvas, sprites!['sea_fort'], center, const Size(52, 52));
      }
      if (cell.index == hiddenBoatCell) continue;
      final boat = cell.boat;
      if (boat == null) continue;
      if (!_inPass(shouldBounceBoat(state, boat))) continue;
      final jumpHeight = shouldBounceBoat(state, boat)
          ? 4 * jumpProgress * (1 - jumpProgress) * 5
          : 0.0;
      final center = HexBoard.centerOfWater(
        state,
        cell,
      ).translate(0, -jumpHeight);
      _drawImage(
        canvas,
        sprites!['boat${boat.level}'],
        center,
        Size(boat.level == 1 ? 48 : 56, boat.level == 1 ? 48 : 56),
      );
      _drawImage(
        canvas,
        sprites!['boat${boat.level}_team'],
        center,
        Size(boat.level == 1 ? 48 : 56, boat.level == 1 ? 48 : 56),
        tint: boat.owner < 0
            ? const Color(0xff777777)
            : mod.palette[boat.owner % mod.palette.length],
      );
      if (boat.cargo.isNotEmpty) {
        final painter = TextPainter(
          text: TextSpan(
            text: '${boat.usedCapacity}',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.bold,
              shadows: [Shadow(color: Colors.black, blurRadius: 3)],
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        painter.paint(canvas, center.translate(-painter.width / 2, 17));
      }
    }
    for (final province in frame?.provinces ?? state.provinces) {
      if (!_inPass(true)) continue;
      if (!shouldDrawProvinceAlert(
        province: province,
        alertOwner: alertOwner,
        selectedProvinceId: selectedProvinceId,
        visibleTiles: visibleTiles,
      )) {
        continue;
      }
      final center = HexBoard.centerOf(state.hexes[province.capital]);
      if (!_inView(center)) continue;
      final jump = 4 * jumpProgress * (1 - jumpProgress) * 7;
      _drawImage(
        canvas,
        sprites!['exclamation_mark'],
        center.translate(14, -18 - jump),
        const Size(23, 23),
      );
    }
    if (pass != HexPiecePass.animated) _drawDiplomaticIndicators(canvas);
  }

  void _drawDiplomaticIndicators(Canvas canvas) {
    if (!state.config.diplomacy) return;
    for (final province in frame?.provinces ?? state.provinces) {
      if (!shouldDrawDiplomaticIndicator(
        state: state,
        province: province,
        viewer: alertOwner,
        visibleTiles: visibleTiles,
      )) {
        continue;
      }
      final status = state.diplomacyRelations[alertOwner][province.owner];
      final capitalCenter = HexBoard.centerOf(state.hexes[province.capital]);
      if (!_inView(capitalCenter)) continue;
      final markerCenter = capitalCenter.translate(18, -17);
      canvas.drawCircle(
        markerCenter.translate(1.3, 1.5),
        8.5,
        Paint()..color = Colors.black.withValues(alpha: .42),
      );
      canvas.drawCircle(
        markerCenter,
        7,
        Paint()..color = relationIndicatorColor(status),
      );
      canvas.drawCircle(
        markerCenter,
        7,
        Paint()
          ..color = const Color(0xff202020)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.7,
      );
      if (state.diplomacyBlackMarks[alertOwner][province.owner]) {
        _drawImage(
          canvas,
          sprites!['diplomacy_black_mark'],
          capitalCenter.translate(27, -27),
          const Size(18, 18),
        );
      }
    }
  }

  @visibleForTesting
  static Color relationIndicatorColor(DiplomacyStatus status) =>
      diplomacyStatusColor(status);

  @visibleForTesting
  static bool shouldDrawDiplomaticIndicator({
    required GameState state,
    required Province province,
    required int viewer,
    required Set<int> visibleTiles,
  }) =>
      state.config.diplomacy &&
      viewer >= 0 &&
      viewer < state.config.playerCount &&
      province.owner >= 0 &&
      province.owner < state.config.playerCount &&
      province.owner != viewer &&
      province.capital >= 0 &&
      province.capital < state.hexes.length &&
      visibleTiles.contains(province.capital);

  static bool shouldDrawProvinceAlert({
    required Province province,
    required int alertOwner,
    required int? selectedProvinceId,
    required Set<int> visibleTiles,
  }) =>
      province.owner == alertOwner &&
      province.id != selectedProvinceId &&
      province.money >= 10 &&
      visibleTiles.contains(province.capital);

  void _drawNavalSupplyLinks(Canvas canvas) {
    for (final cell in frame?.water ?? state.waterCells) {
      if (!visibleWaterCells.contains(cell.index)) continue;
      final boat = cell.boat;
      final supported = boat?.supportedTiles.toSet() ?? const <int>{};
      if (boat == null ||
          supported.isEmpty ||
          supported.any((index) => index < 0 || index >= state.hexes.length)) {
        continue;
      }
      final anchors = supported.where(cell.coastTiles.contains).toList();
      if (anchors.isEmpty) continue;
      final boatCenter = HexBoard.centerOfWater(state, cell);
      final visited = <int>{};
      final queue = <int>[];
      // A water region can touch several separate coast tiles. Each one is a
      // direct boat anchor and needs its own visible rope; previously only the
      // first anchor was drawn, which made a valid landed unit look unsupported.
      for (final anchor in anchors) {
        _drawSupplyLink(
          canvas,
          boatCenter,
          HexBoard.centerOf(state.hexes[anchor]),
          withIcon: true,
        );
        if (visited.add(anchor)) queue.add(anchor);
      }
      for (var cursor = 0; cursor < queue.length; cursor++) {
        final from = queue[cursor];
        for (final neighbor in state.hexes[from].neighbors) {
          if (!supported.contains(neighbor) || !visited.add(neighbor)) {
            continue;
          }
          queue.add(neighbor);
          _drawSupplyLink(
            canvas,
            HexBoard.centerOf(state.hexes[from]),
            HexBoard.centerOf(state.hexes[neighbor]),
            withIcon: false,
          );
        }
      }
    }
  }

  void _drawSupplyLink(
    Canvas canvas,
    Offset from,
    Offset to, {
    required bool withIcon,
  }) {
    final delta = to - from;
    if (delta.distance == 0) return;
    final direction = delta / delta.distance;
    final start = from + direction * 18;
    final end = to - direction * 19;
    canvas.drawLine(
      start,
      end,
      Paint()
        ..color = const Color(0xdd21170f)
        ..strokeWidth = 5
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawLine(
      start,
      end,
      Paint()
        ..color = const Color(0xffd4a85d)
        ..strokeWidth = 2.4
        ..strokeCap = StrokeCap.round,
    );
    if (withIcon) {
      _drawImage(
        canvas,
        sprites!['naval_supply_link'],
        Offset.lerp(start, end, .58)!,
        const Size(27, 27),
      );
    }
  }

  static bool shouldBounceUnit(GameState state, HexTile tile) =>
      tile.unit?.ready == true &&
      (tile.unit!.owner >= 0 ? tile.unit!.owner : tile.owner) == state.turn;

  static bool shouldBounceBoat(GameState state, GameBoat boat) =>
      boat.ready && boat.owner == state.turn;

  void _drawImage(
    Canvas canvas,
    ui.Image image,
    Offset center,
    Size target, {
    Color? tint,
  }) {
    final tinted = tint == null ? null : sprites?.tintedSprite(image, tint);
    if (tinted != null) {
      image = tinted.$1;
      tint = null;
    }
    canvas.drawImageRect(
      image,
      tinted?.$2 ??
          Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Rect.fromCenter(
        center: center,
        width: target.width,
        height: target.height,
      ),
      Paint()
        ..colorFilter = tint == null
            ? null
            : ColorFilter.mode(tint, BlendMode.srcIn),
    );
  }

  @override
  bool shouldRepaint(HexUnitPainter oldDelegate) =>
      renderSignature == null ||
      oldDelegate.renderSignature == null ||
      oldDelegate.renderSignature != renderSignature ||
      oldDelegate.sprites != sprites ||
      oldDelegate.hiddenBoatCell != hiddenBoatCell ||
      oldDelegate.pass != pass ||
      oldDelegate.viewBounds != viewBounds ||
      oldDelegate.jumpProgress != jumpProgress;
}

class BoatBattlePainter extends CustomPainter {
  const BoatBattlePainter({
    required this.state,
    required this.mod,
    required this.sprites,
    required this.battle,
    required this.progress,
  });

  final GameState state;
  final GameMod mod;
  final ClassicSprites? sprites;
  final BoatBattleAnimation battle;
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    if (sprites == null || progress >= .999) return;
    final from = HexBoard.centerOfWater(
      state,
      state.waterCells[battle.fromWaterCell],
    );
    final to = HexBoard.centerOfWater(
      state,
      state.waterCells[battle.toWaterCell],
    );
    final approach = Curves.easeInCubic.transform((progress / .48).clamp(0, 1));
    final impact = ((progress - .38) / .62).clamp(0.0, 1.0);
    final fade = (1 - impact).clamp(0.0, 1.0);
    final attackerCenter = Offset.lerp(from, to, approach)!;

    if (progress < .58) {
      _drawBoat(
        canvas,
        attackerCenter,
        battle.attackerLevel,
        battle.attackerOwner,
        1,
      );
      _drawBoat(canvas, to, battle.defenderLevel, battle.defenderOwner, 1);
    } else if (battle.bothSunk) {
      final spread = 9 * impact;
      _drawBoat(
        canvas,
        to.translate(-spread, 2 * impact),
        battle.attackerLevel,
        battle.attackerOwner,
        fade,
      );
      _drawBoat(
        canvas,
        to.translate(spread, 2 * impact),
        battle.defenderLevel,
        battle.defenderOwner,
        fade,
      );
    } else {
      final sink = ((progress - .58) / .42).clamp(0.0, 1.0);
      _drawBoat(
        canvas,
        to.translate(0, 10 * sink),
        battle.defenderLevel,
        battle.defenderOwner,
        (1 - sink).clamp(0, 1),
      );
    }

    if (progress >= .32) {
      final ringPaint = Paint()
        ..color = const Color(0xffffdc73).withValues(alpha: .9 * fade)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4 * fade
        ..strokeCap = StrokeCap.round;
      canvas.drawCircle(to, 8 + 27 * impact, ringPaint);
      final blade = Paint()
        ..color = Colors.white.withValues(alpha: .95 * fade)
        ..strokeWidth = 3.2
        ..strokeCap = StrokeCap.round;
      final arm = 10 + 7 * impact;
      canvas.drawLine(to.translate(-arm, -arm), to.translate(arm, arm), blade);
      canvas.drawLine(to.translate(-arm, arm), to.translate(arm, -arm), blade);
    }
  }

  void _drawBoat(
    Canvas canvas,
    Offset center,
    int level,
    int owner,
    double opacity,
  ) {
    final target = Size(level == 1 ? 48 : 56, level == 1 ? 48 : 56);
    _drawImage(
      canvas,
      sprites!['boat$level'],
      center,
      target,
      opacity: opacity,
    );
    _drawImage(
      canvas,
      sprites!['boat${level}_team'],
      center,
      target,
      tint: mod.palette[owner % mod.palette.length],
      opacity: opacity,
    );
  }

  void _drawImage(
    Canvas canvas,
    ui.Image image,
    Offset center,
    Size target, {
    Color? tint,
    required double opacity,
  }) {
    final tinted = tint == null ? null : sprites?.tintedSprite(image, tint);
    if (tinted != null) {
      image = tinted.$1;
      tint = null;
    }
    final paint = Paint()..color = Colors.white.withValues(alpha: opacity);
    if (tint != null) {
      paint.colorFilter = ColorFilter.mode(
        tint.withValues(alpha: opacity),
        BlendMode.srcIn,
      );
    }
    canvas.drawImageRect(
      image,
      tinted?.$2 ??
          Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Rect.fromCenter(
        center: center,
        width: target.width,
        height: target.height,
      ),
      paint,
    );
  }

  @override
  bool shouldRepaint(BoatBattlePainter oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.battle != battle;
}

class SeaFortDestructionPainter extends CustomPainter {
  const SeaFortDestructionPainter({
    required this.state,
    required this.mod,
    required this.sprites,
    required this.destruction,
    required this.progress,
  });

  final GameState state;
  final GameMod mod;
  final ClassicSprites? sprites;
  final SeaFortDestructionAnimation destruction;
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    if (sprites == null || progress >= .999) return;
    final from = HexBoard.centerOfWater(
      state,
      state.waterCells[destruction.fromWaterCell],
    );
    final to = HexBoard.centerOfWater(
      state,
      state.waterCells[destruction.toWaterCell],
    );
    final approach = Curves.easeInOutCubic.transform(
      (progress / .5).clamp(0, 1),
    );
    final impact = ((progress - .42) / .58).clamp(0.0, 1.0);
    final fortOpacity = (1 - impact).clamp(0.0, 1.0);
    final attackerCenter = Offset.lerp(from, to, approach)!;
    if (progress < .64) {
      _drawBoat(
        canvas,
        attackerCenter,
        destruction.attackerLevel,
        destruction.attackerOwner,
      );
    }
    _drawImage(
      canvas,
      sprites!['sea_fort'],
      to.translate(0, 12 * impact),
      const Size(52, 52),
      opacity: fortOpacity,
    );
    if (progress >= .38) {
      final burst = Curves.easeOut.transform(impact);
      canvas.drawCircle(
        to,
        8 + 30 * burst,
        Paint()
          ..color = const Color(0xffffc253).withValues(alpha: .9 * (1 - burst))
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4 * (1 - burst),
      );
      for (var i = 0; i < 7; i++) {
        final angle = i * math.pi * 2 / 7;
        final start = to + Offset(math.cos(angle), math.sin(angle)) * 7;
        final end =
            to + Offset(math.cos(angle), math.sin(angle)) * (13 + 25 * burst);
        canvas.drawLine(
          start,
          end,
          Paint()
            ..color = const Color(
              0xfff4e0a1,
            ).withValues(alpha: .85 * (1 - burst))
            ..strokeWidth = 3
            ..strokeCap = StrokeCap.round,
        );
      }
    }
  }

  void _drawBoat(Canvas canvas, Offset center, int level, int owner) {
    final target = Size(level == 1 ? 48 : 56, level == 1 ? 48 : 56);
    _drawImage(canvas, sprites!['boat$level'], center, target);
    _drawImage(
      canvas,
      sprites!['boat${level}_team'],
      center,
      target,
      tint: mod.palette[owner % mod.palette.length],
    );
  }

  void _drawImage(
    Canvas canvas,
    ui.Image image,
    Offset center,
    Size target, {
    Color? tint,
    double opacity = 1,
  }) {
    final tinted = tint == null ? null : sprites?.tintedSprite(image, tint);
    if (tinted != null) {
      image = tinted.$1;
      tint = null;
    }
    final paint = Paint()..color = Colors.white.withValues(alpha: opacity);
    if (tint != null) {
      paint.colorFilter = ColorFilter.mode(
        tint.withValues(alpha: opacity),
        BlendMode.srcIn,
      );
    }
    canvas.drawImageRect(
      image,
      tinted?.$2 ??
          Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Rect.fromCenter(
        center: center,
        width: target.width,
        height: target.height,
      ),
      paint,
    );
  }

  @override
  bool shouldRepaint(SeaFortDestructionPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.destruction != destruction;
}

class ArtilleryFirePainter extends CustomPainter {
  const ArtilleryFirePainter({
    required this.state,
    required this.mod,
    required this.sprites,
    required this.volleys,
    required this.progress,
  });

  final GameState state;
  final GameMod mod;
  final ClassicSprites? sprites;
  final List<List<ArtilleryStrike>> volleys;
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    if (sprites == null || volleys.isEmpty || progress >= 1) return;
    final timeline = progress.clamp(0.0, .9999) * volleys.length;
    final volleyIndex = timeline.floor();
    if (volleyIndex < 0 || volleyIndex >= volleys.length) return;
    final local = timeline - volleyIndex;
    _drawDestroyedBoatReplays(canvas, volleyIndex, local);
    for (final strike in volleys[volleyIndex]) {
      _drawStrike(canvas, strike, local);
    }
  }

  void _drawStrike(Canvas canvas, ArtilleryStrike strike, double local) {
    if (strike.fromTile < 0 ||
        strike.fromTile >= state.hexes.length ||
        strike.toWaterCell < 0 ||
        strike.toWaterCell >= state.waterCells.length) {
      return;
    }
    final from = HexBoard.centerOf(state.hexes[strike.fromTile]);
    final to = HexBoard.centerOfWater(
      state,
      state.waterCells[strike.toWaterCell],
    );
    final direction = to - from;
    final distance = direction.distance;
    final unit = distance == 0 ? Offset.zero : direction / distance;
    final muzzle = from + unit * 22;
    final shot = Curves.easeIn.transform(((local - .4) / .28).clamp(0, 1));
    final impact = ((local - .67) / .33).clamp(0.0, 1.0);
    if (local >= .4 && local <= .72) {
      final projectile = Offset.lerp(muzzle, to, shot)!;
      final tail = Offset.lerp(muzzle, to, (shot - .12).clamp(0, 1))!;
      canvas.drawLine(
        tail,
        projectile,
        Paint()
          ..color = const Color(0xffffd26a)
          ..strokeWidth = 4.2
          ..strokeCap = StrokeCap.round,
      );
      canvas.drawCircle(projectile, 4.5, Paint()..color = Colors.white);
    }
    if (local >= .62) {
      final burst = Curves.easeOut.transform(impact);
      canvas.drawCircle(
        to,
        8 + (strike.destroyed ? 27 : 18) * burst,
        Paint()
          ..color = const Color(0xffff8b39).withValues(alpha: .8 * (1 - burst))
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4 * (1 - burst),
      );
    }
  }

  void _drawDestroyedBoatReplays(
    Canvas canvas,
    int activeVolley,
    double local,
  ) {
    final destructionByCell = <int, ({ArtilleryStrike strike, int volley})>{};
    for (var volley = 0; volley < volleys.length; volley++) {
      for (final strike in volleys[volley]) {
        if (strike.destroyed) {
          destructionByCell[strike.toWaterCell] = (
            strike: strike,
            volley: volley,
          );
        }
      }
    }
    for (final event in destructionByCell.values) {
      if (activeVolley > event.volley) continue;
      final strike = event.strike;
      if (strike.toWaterCell < 0 ||
          strike.toWaterCell >= state.waterCells.length) {
        continue;
      }
      var opacity = 1.0;
      var sink = 0.0;
      if (activeVolley == event.volley) {
        final impact = ((local - .67) / .33).clamp(0.0, 1.0);
        opacity = (1 - impact).clamp(0.0, 1.0);
        sink = 13 * impact;
      }
      _drawBoat(
        canvas,
        HexBoard.centerOfWater(
          state,
          state.waterCells[strike.toWaterCell],
        ).translate(0, sink),
        strike.targetLevel,
        strike.targetOwner,
        opacity,
      );
    }
  }

  void _drawBoat(
    Canvas canvas,
    Offset center,
    int level,
    int owner,
    double opacity,
  ) {
    final target = Size(level == 1 ? 48 : 56, level == 1 ? 48 : 56);
    _drawImage(
      canvas,
      sprites!['boat$level'],
      center,
      target,
      opacity: opacity,
    );
    _drawImage(
      canvas,
      sprites!['boat${level}_team'],
      center,
      target,
      tint: mod.palette[owner % mod.palette.length],
      opacity: opacity,
    );
  }

  void _drawImage(
    Canvas canvas,
    ui.Image image,
    Offset center,
    Size target, {
    Color? tint,
    required double opacity,
  }) {
    final tinted = tint == null ? null : sprites?.tintedSprite(image, tint);
    if (tinted != null) {
      image = tinted.$1;
      tint = null;
    }
    final paint = Paint()..color = Colors.white.withValues(alpha: opacity);
    if (tint != null) {
      paint.colorFilter = ColorFilter.mode(
        tint.withValues(alpha: opacity),
        BlendMode.srcIn,
      );
    }
    canvas.drawImageRect(
      image,
      tinted?.$2 ??
          Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Rect.fromCenter(
        center: center,
        width: target.width,
        height: target.height,
      ),
      paint,
    );
  }

  @override
  bool shouldRepaint(ArtilleryFirePainter oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.volleys != volleys;
}
