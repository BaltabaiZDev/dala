import 'package:flutter/material.dart';
import '../game/game_controller.dart';
import '../game/game_engine.dart';
import '../l10n/game_locale.dart';
import '../modding/game_mod.dart';
import 'dala_theme.dart';
import 'mod_piece.dart';

Future<String?> showModTypeMenu(
  BuildContext context,
  GameMod mod, {
  bool Function(String id)? canBuild,
}) => showModalBottomSheet<String>(
  context: context,
  isScrollControlled: true,
  backgroundColor: DalaTheme.paper,
  shape: const BeveledRectangleBorder(
    borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
  ),
  builder: (context) => Padding(
    padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
    child: _ModTypeMenu(mod: mod, canBuild: canBuild),
  ),
);

class _ModTypeMenu extends StatefulWidget {
  const _ModTypeMenu({required this.mod, this.canBuild});
  final GameMod mod;
  final bool Function(String id)? canBuild;
  @override
  State<_ModTypeMenu> createState() => _ModTypeMenuState();
}

class _ModTypeMenuState extends State<_ModTypeMenu> {
  String _query = '';
  @override
  Widget build(BuildContext context) {
    final mod = widget.mod;
    final ids = [...mod.buildings.keys, ...mod.units.keys].where((id) {
      final name = mod.buildings[id]?.name ?? mod.units[id]!.name;
      return '$id $name'.toLowerCase().contains(_query);
    }).toList();
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight:
              (MediaQuery.sizeOf(context).height -
                      MediaQuery.viewInsetsOf(context).bottom -
                      MediaQuery.paddingOf(context).top -
                      24)
                  .clamp(0, MediaQuery.sizeOf(context).height * .66)
                  .toDouble(),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: GameText(
                      'Мод нысандары',
                      style: TextStyle(
                        fontSize: 20,
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
              if (mod.buildings.length + mod.units.length > 6)
                TextField(
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.search),
                    hintText: context.tr('Іздеу'),
                  ),
                  onChanged: (value) =>
                      setState(() => _query = value.toLowerCase().trim()),
                ),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: ids.length,
                  itemBuilder: (context, index) {
                    final id = ids[index];
                    final building = mod.buildings[id];
                    final unit = mod.units[id];
                    final price = building?.price ?? unit!.price;
                    final upkeep = building?.upkeep ?? unit!.upkeep;
                    final enabled = widget.canBuild?.call(id) ?? true;
                    final production = unit?.requiresBuilding;
                    return Opacity(
                      opacity: enabled ? 1 : .55,
                      child: ListTile(
                        key: ValueKey('mod-type-$id'),
                        contentPadding: EdgeInsets.zero,
                        leading: ModPieceIcon(mod: mod, id: id),
                        title: Text(
                          building?.name ?? unit!.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Wrap(
                          spacing: 10,
                          runSpacing: 2,
                          children: [
                            Text('${context.tr('Бағасы')}: $price'),
                            Text('${context.tr('Шығын')}: $upkeep'),
                            Text(
                              '${context.tr('Көру')}: ${building?.vision ?? unit!.vision}',
                            ),
                            if (unit != null)
                              Text(
                                '${context.tr('Қозғалыс')}: ${unit.moveRange}',
                              ),
                            if (unit != null)
                              Text('${context.tr('Күші')}: ${unit.strength}'),
                            if (building != null && building.income > 0)
                              Text(
                                '+${building.income} ${context.tr('Табыс')}',
                              ),
                            if (building != null && building.defense > 0)
                              Text(
                                '${context.tr('Қорғаныс')}: ${building.defense}',
                              ),
                            if (production != null)
                              Text(mod.buildings[production]!.name),
                          ],
                        ),
                        trailing: const Icon(
                          Icons.add_circle_outline,
                          color: DalaTheme.ink,
                        ),
                        onTap: enabled
                            ? () => Navigator.pop(context, id)
                            : null,
                      ),
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

class ModBuildButton extends StatelessWidget {
  const ModBuildButton({required this.controller, super.key});
  final GameController controller;
  @override
  Widget build(BuildContext context) => InkWell(
    onTap: () async {
      final province = controller.selectedOwnProvince;
      if (province == null) return;
      final id = await showModTypeMenu(
        context,
        controller.mod,
        canBuild: (id) =>
            controller.engine.modBuildTargets(province.id, id).isNotEmpty,
      );
      if (id != null && context.mounted) controller.selectModType(id);
    },
    child: Tooltip(
      message: context.tr('Мод нысандары'),
      child: const Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.extension, size: 23, color: DalaTheme.ink),
          GameText('Модтар', style: TextStyle(fontSize: 12)),
        ],
      ),
    ),
  );
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
