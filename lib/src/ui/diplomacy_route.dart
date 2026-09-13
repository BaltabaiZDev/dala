import 'package:flutter/material.dart';
import '../game/game_controller.dart';
import '../l10n/game_locale.dart';
import 'dala_theme.dart';

Future<void> showDalaDiplomacyPanel(
  BuildContext context,
  GameController controller,
  Widget child,
) => Navigator.of(context).push<void>(
  _DiplomacyRoute(
    controller,
    InheritedTheme.captureAll(
      context,
      DefaultTextStyle(
        style: Theme.of(context).textTheme.bodyMedium!,
        child: child,
      ),
    ),
  ),
);

/// A non-opaque panel keeps the real board, camera and draft mounted. During
/// territorial inspection only the map accepts input behind this route.
class _DiplomacyRoute extends PopupRoute<void> {
  _DiplomacyRoute(this.game, this.child);
  final GameController game;
  final Widget child;
  @override
  Duration get transitionDuration => const Duration(milliseconds: 160);
  @override
  bool get barrierDismissible => true;
  @override
  Color? get barrierColor => Colors.transparent;
  @override
  String? get barrierLabel => 'Close';

  @override
  Widget buildModalBarrier() => AnimatedBuilder(
    animation: game,
    builder: (context, _) => game.territorySelection == null
        ? ModalBarrier(
            color: Colors.transparent,
            dismissible: true,
            onDismiss: () => navigator?.pop(),
          )
        : const SafeArea(
            child: Stack(
              children: [
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  height: 104,
                  child: AbsorbPointer(
                    child: ColoredBox(color: Colors.transparent),
                  ),
                ),
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  height: 124,
                  child: AbsorbPointer(
                    child: ColoredBox(color: Colors.transparent),
                  ),
                ),
              ],
            ),
          ),
  );

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => AnimatedBuilder(
    animation: game,
    builder: (context, _) {
      final selection = game.territorySelection;
      if (selection != null &&
          (selection.actor != game.state.turn ||
              selection.round != game.state.round)) {
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => game.finishTerritorySelection(confirm: false),
        );
      }
      return PopScope(
        canPop: selection == null,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop && game.territorySelection != null) {
            game.finishTerritorySelection(confirm: false);
          }
        },
        child: SafeArea(
          child: Stack(
            children: [
              Align(
                alignment: Alignment.bottomCenter,
                child: Offstage(
                  offstage: selection != null,
                  child: SizedBox(
                    height: MediaQuery.sizeOf(context).height * .5,
                    child: Material(
                      color: DalaTheme.paper,
                      child: DefaultTextStyle(
                        style: Theme.of(context).textTheme.bodyMedium!,
                        child: child,
                      ),
                    ),
                  ),
                ),
              ),
              if (selection != null)
                Align(
                  alignment: Alignment.bottomCenter,
                  child: _TerritoryBar(controller: game, selection: selection),
                ),
            ],
          ),
        ),
      );
    },
  );

  @override
  void dispose() {
    game.finishTerritorySelection(confirm: false);
    super.dispose();
  }
}

class _TerritoryBar extends StatelessWidget {
  const _TerritoryBar({required this.controller, required this.selection});
  final GameController controller;
  final TerritorySelection selection;
  @override
  Widget build(BuildContext context) {
    final price =
        selection.tiles.fold<int>(
          0,
          (sum, i) => sum + controller.engine.diplomacyLandPrice(i),
        ) +
        selection.navalRefs.fold<int>(
          0,
          (sum, ref) => sum + controller.engine.diplomacyNavalPrice(ref),
        );
    return Material(
      color: DalaTheme.paper,
      elevation: 8,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        child: Row(
          children: [
            IconButton(
              key: const ValueKey('territory-cancel'),
              tooltip: context.trNullable('Артқа'),
              onPressed: () =>
                  controller.finishTerritorySelection(confirm: false),
              icon: const Icon(Icons.arrow_back),
            ),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  GameText(
                    selection.title,
                    translate: false,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  GameText(
                    '${selection.tiles.length} жер · ${selection.navalRefs.length} теңіз · Бағасы $price',
                    style: const TextStyle(fontSize: 12),
                  ),
                ],
              ),
            ),
            if (!selection.readOnly)
              IconButton(
                key: const ValueKey('territory-confirm'),
                tooltip: context.trNullable('Дайын'),
                onPressed: () =>
                    controller.finishTerritorySelection(confirm: true),
                icon: const Icon(
                  Icons.check_circle,
                  color: DalaTheme.green,
                  size: 32,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
