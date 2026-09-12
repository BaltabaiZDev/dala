import 'dart:convert';

import '../game/game_controller.dart';
import '../game/models.dart';
import 'lan_protocol.dart';

class LanCommandDispatcher {
  const LanCommandDispatcher();

  Future<Map<String, dynamic>> dispatch({
    required GameController controller,
    required int player,
    required LanGameCommand command,
  }) async {
    final savedHostUi = controller.captureNetworkUiState();
    controller.applyNetworkUiState(command.ui.toJson(), notify: false);
    Map<String, dynamic>? resultUi;
    try {
      await controller.runAsNetworkPlayer(player, () async {
        final args = command.arguments;
        switch (command.action) {
          case 'tapModTile':
            controller.tapModTile(_requiredIndex(args, 'index'));
            break;
          case 'tapTile':
            controller.tapTile(_requiredIndex(args, 'index'));
            break;
          case 'tapWaterCell':
            controller.tapWaterCell(_requiredIndex(args, 'index'));
            break;
          case 'longPressTile':
            controller.longPressTile(_requiredIndex(args, 'index'));
            break;
          case 'longPressWaterCell':
            controller.longPressWaterCell(_requiredIndex(args, 'index'));
            break;
          case 'upgradeSelectedPort':
            controller.upgradeSelectedPort();
            break;
          case 'upgradeSelectedArtillery':
            controller.upgradeSelectedArtillery();
            break;
          case 'undo':
            controller.undo();
            break;
          case 'finishTurn':
            await controller.finishTurn();
            break;
          case 'requestBetterDiplomacy':
            controller.requestBetterDiplomacy(_requiredPlayer(args, 'other'));
            break;
          case 'worsenDiplomacy':
            controller.worsenDiplomacy(_requiredPlayer(args, 'other'));
            break;
          case 'resolveDiplomacyProposal':
            final raw = _requiredMap(args, 'proposal');
            final requested = DiplomacyProposal.fromJson(raw);
            final proposal = controller.state.diplomacyProposals
                .where(
                  (candidate) =>
                      candidate.from == requested.from &&
                      candidate.to == requested.to &&
                      candidate.type == requested.type &&
                      candidate.createdRound == requested.createdRound &&
                      jsonEncode(candidate.toJson()) ==
                          jsonEncode(requested.toJson()),
                )
                .firstOrNull;
            if (proposal == null) throw StateError('Ұсыныс енді жоқ.');
            controller.resolveDiplomacyProposal(
              proposal,
              accept: args['accept'] as bool? ?? false,
            );
            break;
          case 'submitPeaceConferenceProposal':
            final allocations = <int, List<int>>{};
            for (final entry in _requiredMap(args, 'allocations').entries) {
              final owner = int.tryParse(entry.key);
              if (owner == null || entry.value is! List) {
                throw const FormatException('Жер бөлінісі жарамсыз.');
              }
              allocations[owner] = (entry.value as List)
                  .whereType<num>()
                  .map((value) => value.toInt())
                  .toList();
            }
            controller.submitPeaceConferenceProposal(
              conferenceId: _requiredIndex(args, 'conferenceId'),
              allocations: allocations,
            );
            break;
          case 'acceptPeaceConference':
            controller.acceptPeaceConference(
              _requiredIndex(args, 'conferenceId'),
            );
            break;
          case 'sendDiplomacyExchange':
            final rawTerms = args['terms'];
            if (rawTerms != null &&
                (rawTerms is! List ||
                    rawTerms.isEmpty ||
                    rawTerms.length > 3)) {
              throw const FormatException('Мәміле шарттары жарамсыз');
            }
            controller.sendDiplomacyExchange(
              other: _requiredPlayer(args, 'other'),
              fromOffer: DiplomacyOffer.fromJson(
                _requiredMap(args, 'fromOffer'),
              ),
              toOffer: DiplomacyOffer.fromJson(_requiredMap(args, 'toOffer')),
              terms: (rawTerms as List?)
                  ?.map(
                    (raw) => DiplomacyTerm.fromJson(
                      (raw as Map).cast<String, dynamic>(),
                    ),
                  )
                  .toList(),
            );
            break;
          case 'influenceDiplomacyOpinion':
            controller.influenceDiplomacyOpinion(
              _requiredPlayer(args, 'other'),
              improve: args['improve'] as bool,
            );
            break;
          case 'sendDiplomacyMessage':
            final text = (args['text'] as String? ?? '');
            controller.sendDiplomacyMessage(
              other: _requiredPlayer(args, 'other'),
              text: text.length <= lanMaxMessageLength
                  ? text
                  : text.substring(0, lanMaxMessageLength),
            );
            break;
          case 'dismissDiplomacyMessage':
            final requested = DiplomacyMessage.fromJson(
              _requiredMap(args, 'message'),
            );
            final message = controller.state.diplomacyMessages
                .where(
                  (candidate) =>
                      candidate.from == requested.from &&
                      candidate.to == requested.to &&
                      candidate.text == requested.text &&
                      candidate.createdRound == requested.createdRound,
                )
                .firstOrNull;
            if (message == null) throw StateError('Хат енді жоқ.');
            controller.dismissDiplomacyMessage(message);
            break;
          case 'clearDiplomacyInbox':
            controller.clearDiplomacyInbox();
            break;
          case 'toggleBlackMark':
            controller.toggleBlackMark(_requiredPlayer(args, 'other'));
            break;
          default:
            throw UnsupportedError('Белгісіз LAN әрекеті: ${command.action}');
        }
      });
      resultUi = controller.captureNetworkUiState();
      return resultUi;
    } finally {
      controller.applyNetworkUiState(savedHostUi, notify: true);
    }
  }

  int _requiredIndex(Map<String, dynamic> args, String key) {
    final value = args[key];
    if (value is! num || value.toInt() < 0) {
      throw FormatException('$key жарамсыз.');
    }
    return value.toInt();
  }

  int _requiredPlayer(Map<String, dynamic> args, String key) =>
      _requiredIndex(args, key);

  Map<String, dynamic> _requiredMap(Map<String, dynamic> args, String key) {
    final value = args[key];
    if (value is! Map) throw FormatException('$key жарамсыз.');
    return value.cast<String, dynamic>();
  }
}
