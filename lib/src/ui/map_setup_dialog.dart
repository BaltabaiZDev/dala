import 'package:flutter/material.dart';
import '../l10n/game_locale.dart';
import '../modding/content_package.dart';

/// Only seat allocation changes; authored terrain, rules and factions stay fixed.
Future<int?> showMapSetup(
  BuildContext context,
  DalaMap map, {
  bool lan = false,
}) => showDialog<int>(
  context: context,
  builder: (_) => _MapSetup(map: map, lan: lan),
);

class _MapSetup extends StatefulWidget {
  const _MapSetup({required this.map, required this.lan});
  final DalaMap map;
  final bool lan;
  @override
  State<_MapSetup> createState() => _MapSetupState();
}

class _MapSetupState extends State<_MapSetup> {
  late int _humans = widget.lan ? 2 : 1;
  @override
  Widget build(BuildContext context) {
    final map = widget.map;
    final minimum = widget.lan ? 2 : 1;
    final playable = map.maxHumanCount >= minimum;
    return AlertDialog(
      scrollable: true,
      title: const GameText('Карта дайындығы'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GameText(
              map.name,
              translate: false,
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            GameText(
              'Өлшемі: ${map.width} × ${map.height} · Тараптар: ${map.activeFactions.length}',
            ),
            const SizedBox(height: 8),
            const GameText(
              'Картаның жері, өлшемі және тараптары автор белгілегендей сақталады.',
            ),
            const SizedBox(height: 16),
            if (playable) ...[
              DropdownButtonFormField<int>(
                key: const ValueKey('map-human-count'),
                initialValue: _humans,
                isExpanded: true,
                decoration: const InputDecoration(label: GameText('Адам саны')),
                items: [
                  for (var n = minimum; n <= map.maxHumanCount; n++)
                    DropdownMenuItem(
                      value: n,
                      child: GameText(
                        'Адамдар: $n · Боттар: ${map.activeFactions.length - n}',
                      ),
                    ),
                ],
                onChanged: (value) {
                  if (value != null) setState(() => _humans = value);
                },
              ),
              const SizedBox(height: 8),
              const GameText('Қалған тараптарды боттар басқарады.'),
              if (map.maxHumanCount < map.activeFactions.length)
                const GameText('Жері жоқ тарапқа адам тағайындалмайды.'),
            ] else
              const GameText(
                'Бұл картада LAN үшін алғашқы екі тараптың да жері болуы керек. Редакторда түзетіңіз.',
              ),
            if (widget.lan) ...[
              const SizedBox(height: 12),
              const GameText(
                'Қонақтарға карта автоматты жіберіледі. Қажетті модтар бәрінде орнатылуы керек.',
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const GameText('Бас тарту'),
        ),
        FilledButton(
          key: const ValueKey('map-setup-start'),
          onPressed: playable ? () => Navigator.pop(context, _humans) : null,
          child: const GameText('Бастау'),
        ),
      ],
    );
  }
}
