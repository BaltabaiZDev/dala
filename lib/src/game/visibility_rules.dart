part of 'game_engine.dart';

/// Shared by the visible board and combat so normal scouts can spot for mod units.
Set<int> landVisionTiles(
  GameState state,
  GameMod mod,
  bool Function(int) allied,
) {
  final visible = <int>{};
  visible.addAll(
    modVisionTiles(
      state,
      mod,
      allied,
    ).where((index) => state.hexes[index].active),
  );
  for (final tile in state.hexes) {
    if (!tile.active || !allied(tile.owner)) continue;
    final radius = switch (tile.object) {
      TileObject.town => 4,
      TileObject.strongTower => 5,
      TileObject.tower => 3,
      TileObject.port2 => 3,
      TileObject.port1 => 2,
      TileObject.artillery3 => 5,
      TileObject.artillery2 => 4,
      TileObject.artillery1 => 3,
      _ => tile.unit == null ? 1 : 2,
    };
    _revealLandRadius(state, tile.index, radius, visible);
  }
  // A fleet must be able to scout the shore it is touching. Previously
  // boats only revealed water cells, so fog kept valid landing targets
  // untappable even when a cargo unit could legally disembark there.
  for (final cell in state.waterCells) {
    if (!cell.navigable) continue;
    final boat = cell.boat;
    final fort = cell.seaFort;
    var coastRadius = 0;
    if (boat != null && allied(boat.owner)) {
      coastRadius = boat.level >= 2 ? 2 : 1;
    }
    if (fort != null && allied(fort.owner)) {
      if (coastRadius < 2) coastRadius = 2;
    }
    if (coastRadius == 0) continue;
    for (final coastTile in cell.coastTiles) {
      if (coastTile < 0 || coastTile >= state.hexes.length) continue;
      if (!state.hexes[coastTile].active) continue;
      _revealLandRadius(state, coastTile, coastRadius, visible);
    }
  }
  return visible;
}

Set<int> waterVisionCells(
  GameState state,
  GameMod mod,
  bool Function(int) allied, {
  Set<int>? land,
}) {
  final tiles = land ?? landVisionTiles(state, mod, allied);
  final visible = <int>{};
  final custom = modVisionTiles(state, mod, allied);
  for (final cell in state.waterCells) {
    if (cell.navigable && cell.tiles.any(custom.contains)) {
      visible.add(cell.index);
    }
    if (cell.coastTiles.any(tiles.contains)) {
      _revealWaterRadius(state, cell.index, 1, visible);
    }
    if (allied(cell.boat?.owner ?? -1)) {
      _revealWaterRadius(state, cell.index, 2, visible);
    }
    if (allied(cell.seaFort?.owner ?? -1)) {
      _revealWaterRadius(state, cell.index, 3, visible);
    }
  }
  return visible;
}

void _revealLandRadius(
  GameState visibleState,
  int start,
  int radius,
  Set<int> visible,
) {
  final distances = <int, int>{start: 0};
  final queue = <int>[start];
  for (var cursor = 0; cursor < queue.length; cursor++) {
    final index = queue[cursor];
    visible.add(index);
    final distance = distances[index]!;
    if (distance >= radius) continue;
    for (final neighbor in visibleState.hexes[index].neighbors) {
      if (distances.containsKey(neighbor) ||
          !visibleState.hexes[neighbor].active) {
        continue;
      }
      distances[neighbor] = distance + 1;
      queue.add(neighbor);
    }
  }
}

void _revealWaterRadius(
  GameState visibleState,
  int start,
  int radius,
  Set<int> visible,
) {
  final distances = <int, int>{start: 0};
  final queue = <int>[start];
  for (var cursor = 0; cursor < queue.length; cursor++) {
    final index = queue[cursor];
    if (index < 0 || index >= visibleState.waterCells.length) continue;
    final cell = visibleState.waterCells[index];
    if (!cell.navigable) continue;
    visible.add(index);
    final distance = distances[index]!;
    if (distance >= radius) continue;
    for (final neighbor in cell.neighbors) {
      if (distances.containsKey(neighbor)) continue;
      distances[neighbor] = distance + 1;
      queue.add(neighbor);
    }
  }
}
