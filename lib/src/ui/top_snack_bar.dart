import '../l10n/game_locale.dart';
import 'dart:async';

import 'package:flutter/material.dart';

OverlayEntry? _visibleTopSnackBar;
Timer? _topSnackBarTimer;

/// Shows the game's transient notice below the system inset at the top edge.
///
/// Flutter's stock [SnackBar] is anchored to the bottom of a [Scaffold]. The
/// Classic layout keeps short notices above the playfield, so this lightweight
/// overlay is shared by every screen instead of relying on brittle margins.
void showTopSnackBar(
  BuildContext context,
  String message, {
  Duration duration = const Duration(seconds: 4),
}) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;

  _topSnackBarTimer?.cancel();
  final previous = _visibleTopSnackBar;
  if (previous != null && previous.mounted) previous.remove();

  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (overlayContext) {
      final topInset = MediaQuery.paddingOf(overlayContext).top;
      return Positioned(
        top: topInset + 8,
        left: 12,
        right: 12,
        child: IgnorePointer(
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Semantics(
                liveRegion: true,
                label: overlayContext.tr(message),
                child: Material(
                  key: const ValueKey('top-snack-bar'),
                  color: const Color(0xee202020),
                  elevation: 8,
                  borderRadius: BorderRadius.circular(9),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 11,
                    ),
                    child: GameText(
                      message,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        height: 1.15,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
  _visibleTopSnackBar = entry;
  late final VoidCallback onEntryChanged;
  onEntryChanged = () {
    if (entry.mounted) return;
    entry.removeListener(onEntryChanged);
    if (identical(_visibleTopSnackBar, entry)) {
      _topSnackBarTimer?.cancel();
      _visibleTopSnackBar = null;
      _topSnackBarTimer = null;
    }
  };
  entry.addListener(onEntryChanged);
  overlay.insert(entry);
  _topSnackBarTimer = Timer(duration, () {
    if (entry.mounted) entry.remove();
    entry.removeListener(onEntryChanged);
    if (identical(_visibleTopSnackBar, entry)) {
      _visibleTopSnackBar = null;
      _topSnackBarTimer = null;
    }
  });
}
