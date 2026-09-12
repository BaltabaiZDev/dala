import 'package:flutter/material.dart';
import '../game/game_controller.dart';
import '../game/game_engine.dart';
import '../game/models.dart';
import '../l10n/game_locale.dart';
import '../modding/game_mod.dart';
import 'dala_theme.dart';
import 'mod_piece.dart';

Future<String?> showModTypeMenu(
  BuildContext context,
  GameMod mod, {
  Iterable<String>? typeIds,
  String title = 'Мод нысандары',
  bool Function(String id)? canBuild,
  String? Function(String id)? unavailableReason,
}) => showModalBottomSheet<String>(
  context: context,
  isScrollControlled: true,
  backgroundColor: DalaTheme.paper,
  shape: const BeveledRectangleBorder(
    borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
  ),
  builder: (context) => Padding(
    padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
    child: _ModTypeMenu(
      mod: mod,
      ids: (typeIds ?? [...mod.buildings.keys, ...mod.units.keys]).toList(),
      title: title,
      unavailableReason:
          unavailableReason ??
          (canBuild == null ? null : (id) => canBuild(id) ? null : 'Орын жоқ'),
    ),
  ),
);

Future<void> showModTypeDetails(BuildContext context, GameMod mod, String id) {
  final building = mod.buildings[id];
  final unit = mod.units[id];
  final name = building?.name ?? unit!.name;
  final stats = <String, Object>{
    'Бағасы': building?.price ?? unit!.price,
    'Шығын': building?.upkeep ?? unit!.upkeep,
    'Көру': building?.vision ?? unit!.vision,
    if (building != null) ...{
      'Табыс': building.income,
      'Қорғаныс': building.defense,
    },
    if (unit != null) ...{
      'Күші': unit.strength,
      'Қозғалыс': unit.moveRange,
      'Өндіріс': unit.requiresBuilding == null
          ? context.tr('Қала')
          : mod.buildings[unit.requiresBuilding]!.name,
    },
  };
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      scrollable: true,
      title: Text(name),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final stat in stats.entries)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text('${context.tr(stat.key)}: ${stat.value}'),
            ),
          if (building != null)
            for (final product in mod.units.values.where(
              (u) => u.requiresBuilding == id,
            ))
              Text('${context.tr('Өндіріс')}: ${product.name}'),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const GameText('Жабу'),
        ),
      ],
    ),
  );
}

class _ModTypeMenu extends StatefulWidget {
  const _ModTypeMenu({
    required this.mod,
    required this.ids,
    required this.title,
    this.unavailableReason,
  });
  final GameMod mod;
  final List<String> ids;
  final String title;
  final String? Function(String id)? unavailableReason;
  @override
  State<_ModTypeMenu> createState() => _ModTypeMenuState();
}

class _ModTypeMenuState extends State<_ModTypeMenu> {
  String _query = '';
  @override
  Widget build(BuildContext context) {
    final mod = widget.mod;
    final ids = widget.ids.where((id) {
      final name = mod.buildings[id]?.name ?? mod.units[id]!.name;
      return '$id $name'.toLowerCase().contains(_query);
    }).toList();
    final media = MediaQuery.of(context);
    // Row height follows text size, never name length or the number of stats.
    final rowHeight = (22 + media.textScaler.scale(14) * 3.75).clamp(
      76.0,
      double.infinity,
    );
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight:
              (media.size.height -
                      media.viewInsets.bottom -
                      media.padding.top -
                      24)
                  .clamp(0, media.size.height * .62)
                  .toDouble(),
          maxWidth: 560,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 8, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      context.tr(widget.title),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: context.tr('Жабу'),
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              if (widget.ids.length > 6)
                TextField(
                  decoration: InputDecoration(
                    isDense: true,
                    prefixIcon: const Icon(Icons.search),
                    hintText: context.tr('Іздеу'),
                  ),
                  onChanged: (value) =>
                      setState(() => _query = value.toLowerCase().trim()),
                ),
              Flexible(
                child: ids.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.all(16),
                        child: GameText('Бос'),
                      )
                    : ListView.builder(
                        shrinkWrap: true,
                        itemCount: ids.length,
                        itemExtent: rowHeight,
                        itemBuilder: (context, index) {
                          final id = ids[index];
                          final building = mod.buildings[id];
                          final unit = mod.units[id];
                          final name = building?.name ?? unit!.name;
                          final price = building?.price ?? unit!.price;
                          final upkeep = building?.upkeep ?? unit!.upkeep;
                          final reason = widget.unavailableReason?.call(id);
                          return Row(
                            children: [
                              Expanded(
                                child: Opacity(
                                  opacity: reason == null ? 1 : .55,
                                  child: InkWell(
                                    key: ValueKey('mod-type-$id'),
                                    onTap: reason == null
                                        ? () => Navigator.pop(context, id)
                                        : null,
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        vertical: 6,
                                      ),
                                      child: Row(
                                        children: [
                                          ModPieceIcon(
                                            mod: mod,
                                            id: id,
                                            size: 32,
                                          ),
                                          const SizedBox(width: 10),
                                          Expanded(
                                            child: Column(
                                              mainAxisAlignment:
                                                  MainAxisAlignment.center,
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  name,
                                                  maxLines: 2,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: const TextStyle(
                                                    fontSize: 14,
                                                    height: 1.15,
                                                    fontWeight: FontWeight.w600,
                                                  ),
                                                ),
                                                const SizedBox(height: 3),
                                                Text(
                                                  reason == null
                                                      ? '${context.tr('Бағасы')}: $price · ${context.tr('Шығын')}: $upkeep'
                                                      : context.tr(reason),
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: const TextStyle(
                                                    fontSize: 12,
                                                    height: 1.15,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              IconButton(
                                key: ValueKey('mod-info-$id'),
                                tooltip: context.tr('Сипаттама'),
                                onPressed: () =>
                                    showModTypeDetails(context, mod, id),
                                icon: const Icon(Icons.info_outline, size: 20),
                              ),
                            ],
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

List<String> modProductionTypes(GameController controller) {
  final index = controller.selectedTile;
  if (index == null || controller.selectedOwnProvince == null) return [];
  final tile = controller.state.hexes[index];
  return [
    for (final unit in controller.mod.units.values)
      if (unit.requiresBuilding == null
          ? tile.object == TileObject.town
          : tile.buildingTypeId == unit.requiresBuilding)
        unit.id,
  ];
}

String? _unavailable(GameController controller, String id, int? producer) {
  final province = controller.selectedOwnProvince;
  if (province == null ||
      !controller.isLocalHumanTurn ||
      controller.interactionsLocked ||
      controller.networkBusy ||
      controller.state.winner != null) {
    return 'Қазір қолжетімсіз';
  }
  final building = controller.mod.buildings[id];
  final price = building?.price ?? controller.mod.units[id]!.price;
  if (province.money < price) return 'Ақша жетпейді';
  if (controller.engine
      .modBuildTargets(province.id, id, productionTile: producer)
      .isEmpty) {
    return 'Орын жоқ';
  }
  return null;
}

class ModCatalogButton extends StatelessWidget {
  const ModCatalogButton({
    required this.controller,
    this.buildings = false,
    super.key,
  });
  final GameController controller;
  final bool buildings;
  @override
  Widget build(BuildContext context) {
    final ids = buildings
        ? controller.mod.buildings.keys.toList()
        : modProductionTypes(controller);
    final label = buildings ? 'Құрылыс' : 'Әскер';
    final enabled =
        ids.isNotEmpty &&
        controller.isLocalHumanTurn &&
        !controller.interactionsLocked &&
        !controller.networkBusy &&
        controller.state.winner == null;
    return Tooltip(
      message: context.tr(label),
      child: InkWell(
        onTap: !enabled
            ? null
            : () async {
                final producer = controller.selectedTile;
                final id = await showModTypeMenu(
                  context,
                  controller.mod,
                  typeIds: ids,
                  title: buildings
                      ? 'Құрылыс'
                      : controller.selectedModBuilding?.name ?? 'Қала',
                  unavailableReason: (id) =>
                      _unavailable(controller, id, producer),
                );
                if (id != null &&
                    context.mounted &&
                    controller.selectedTile == producer &&
                    _unavailable(controller, id, producer) == null) {
                  controller.selectModType(id);
                }
              },
        child: Opacity(
          opacity: enabled ? 1 : .5,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                buildings
                    ? Icons.add_business_outlined
                    : Icons.group_add_outlined,
                size: 22,
                color: DalaTheme.ink,
              ),
              Text(
                context.tr(label),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ModBuildingPanel extends StatelessWidget {
  const ModBuildingPanel({required this.controller, super.key});
  final GameController controller;
  @override
  Widget build(BuildContext context) {
    final building = controller.selectedModBuilding!;
    return Container(
      height: 66,
      decoration: const BoxDecoration(
        color: DalaTheme.paper,
        border: Border(top: BorderSide(color: DalaTheme.gold, width: 2)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          ModPieceIcon(mod: controller.mod, id: building.id, size: 30),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              building.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
            ),
          ),
          IconButton(
            tooltip: context.tr('Сипаттама'),
            onPressed: () =>
                showModTypeDetails(context, controller.mod, building.id),
            icon: const Icon(Icons.info_outline, size: 20),
          ),
          if (modProductionTypes(controller).isNotEmpty)
            SizedBox(
              width: 72,
              child: ModCatalogButton(controller: controller),
            ),
          IconButton(
            tooltip: context.tr('Жабу'),
            icon: const Icon(Icons.close),
            onPressed: () {
              final capital = controller.selectedOwnProvince?.capital;
              controller.clearSelection();
              if (capital != null) controller.tapTile(capital);
            },
          ),
        ],
      ),
    );
  }
}

class ModAirPanel extends StatelessWidget {
  const ModAirPanel({required this.controller, super.key});
  final GameController controller;
  @override
  Widget build(BuildContext context) {
    final unit = controller.selectedAirUnit;
    final type = controller.mod.units[unit?.typeId];
    if (unit == null || type == null) return const SizedBox.shrink();
    return Container(
      height: 66,
      color: DalaTheme.paper,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          ModPieceIcon(mod: controller.mod, id: type.id),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  type.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                GameText(
                  unit.ready ? 'Ұшу немесе шабуыл' : 'Осы ходта жүріп болды',
                  style: const TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: context.tr('Жабу'),
            icon: const Icon(Icons.close),
            onPressed: controller.clearSelection,
          ),
        ],
      ),
    );
  }
}
