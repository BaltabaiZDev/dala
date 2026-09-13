part of 'game_controller.dart';

class TerritorySelection {
  TerritorySelection({
    required this.actor,
    required this.round,
    required this.giver,
    required this.offer,
    required this.readOnly,
    required this.title,
  });
  final int actor, round, giver;
  final DiplomacyOffer offer;
  final bool readOnly;
  final String title;
  final tiles = <int>{};
  final navalRefs = <NavalAssetRef>{};
  final result = Completer<DiplomacyOffer?>();
}

extension TerritorySelectionActions on GameController {
  Future<DiplomacyOffer?> beginTerritorySelection({
    required int giver,
    required DiplomacyOffer offer,
    bool readOnly = false,
    String? title,
  }) {
    finishTerritorySelection(confirm: false);
    final selection = TerritorySelection(
      actor: state.turn,
      round: state.round,
      giver: giver,
      offer: offer,
      readOnly: readOnly,
      title: title ?? playerName(giver),
    );
    territorySelection = selection;
    selection.tiles.addAll(
      offer.tiles.where(
        (index) => canSelectDiplomacyLandTile(giver: giver, index: index),
      ),
    );
    for (final cell in viewState.waterCells) {
      for (final ref in offer.navalRefs) {
        if (canSelectDiplomacyNavalAsset(
          giver: giver,
          waterCell: cell.index,
          reference: ref,
        )) {
          selection.navalRefs.add(ref);
        }
      }
    }
    _notifyTerritoryChanged();
    return selection.result.future;
  }

  Set<int> get territoryWaterSelection {
    final selected = territorySelection?.navalRefs ?? const <NavalAssetRef>{};
    return {
      for (final cell in viewState.waterCells)
        if (visibleWaterCellIndices.contains(cell.index) &&
            ((cell.boat != null &&
                    selected.contains(
                      NavalAssetRef(
                        kind: NavalAssetKind.boat,
                        id: cell.boat!.id,
                      ),
                    )) ||
                (cell.seaFort != null &&
                    selected.contains(
                      NavalAssetRef(
                        kind: NavalAssetKind.seaFort,
                        id: cell.seaFort!.id,
                      ),
                    ))))
          cell.index,
    };
  }

  void toggleTerritoryTile(int index) {
    final selection = territorySelection;
    if (selection == null ||
        selection.readOnly ||
        selection.actor != state.turn ||
        selection.round != state.round ||
        index < 0 ||
        index >= viewState.hexes.length) {
      return;
    }
    if (viewState.hexes[index].active) {
      if (!canSelectDiplomacyLandTile(giver: selection.giver, index: index)) {
        return;
      }
      if (!selection.tiles.add(index)) selection.tiles.remove(index);
    } else {
      final cell = viewState.waterCells
          .where((c) => c.tiles.contains(index))
          .firstOrNull;
      if (cell == null) return;
      for (final ref in [
        if (cell.boat != null)
          NavalAssetRef(kind: NavalAssetKind.boat, id: cell.boat!.id),
        if (cell.seaFort != null)
          NavalAssetRef(kind: NavalAssetKind.seaFort, id: cell.seaFort!.id),
      ]) {
        if (!canSelectDiplomacyNavalAsset(
          giver: selection.giver,
          waterCell: cell.index,
          reference: ref,
        )) {
          continue;
        }
        if (!selection.navalRefs.add(ref)) selection.navalRefs.remove(ref);
      }
    }
    _notifyTerritoryChanged();
  }

  void finishTerritorySelection({required bool confirm}) {
    final selection = territorySelection;
    if (selection == null) return;
    territorySelection = null;
    final valid =
        confirm &&
        selection.actor == state.turn &&
        selection.round == state.round;
    selection.result.complete(
      valid
          ? selection.offer.copyWith(
              tiles:
                  selection.tiles
                      .where(
                        (i) => canSelectDiplomacyLandTile(
                          giver: selection.giver,
                          index: i,
                        ),
                      )
                      .toList()
                    ..sort(),
              navalRefs: selection.navalRefs
                  .where(
                    (ref) => viewState.waterCells.any(
                      (c) => canSelectDiplomacyNavalAsset(
                        giver: selection.giver,
                        waterCell: c.index,
                        reference: ref,
                      ),
                    ),
                  )
                  .toList(),
            )
          : null,
    );
    if (_active) _notifyTerritoryChanged();
  }
}
