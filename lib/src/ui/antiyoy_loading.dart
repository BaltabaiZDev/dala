import 'dart:async';

import 'package:flutter/material.dart';
import 'dala_art.dart';

/// Runs [task] while a small Classic-style loading mark blocks the root UI.
///
/// The task starts after the overlay has had a chance to paint once, so even a
/// synchronous map generation step cannot hide the loading state completely.
Future<T> runWithAntiyoyLoader<T>(
  BuildContext context, {
  required String semanticsLabel,
  required FutureOr<T> Function() task,
}) async {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return Future<T>.sync(task);

  final entry = OverlayEntry(
    builder: (_) => AntiyoyLoadingOverlay(semanticsLabel: semanticsLabel),
  );
  overlay.insert(entry);
  try {
    await WidgetsBinding.instance.endOfFrame;
    return await Future<T>.sync(task);
  } finally {
    if (entry.mounted) entry.remove();
  }
}

class AntiyoyLoadingOverlay extends StatefulWidget {
  const AntiyoyLoadingOverlay({required this.semanticsLabel, super.key});

  final String semanticsLabel;

  @override
  State<AntiyoyLoadingOverlay> createState() => _AntiyoyLoadingOverlayState();
}

class _AntiyoyLoadingOverlayState extends State<AntiyoyLoadingOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _opacity;
  late final Animation<Offset> _offset;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 680),
    )..repeat(reverse: true);
    _opacity = Tween<double>(
      begin: 0.68,
      end: 1,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));
    _offset = Tween<Offset>(
      begin: const Offset(0, -0.06),
      end: const Offset(0, 0.06),
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const ModalBarrier(dismissible: false, color: Color(0x73000000)),
        Center(
          child: Semantics(
            container: true,
            liveRegion: true,
            label: widget.semanticsLabel,
            child: ExcludeSemantics(
              child: Material(
                type: MaterialType.transparency,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    FadeTransition(
                      opacity: _opacity,
                      child: SlideTransition(
                        position: _offset,
                        child: const SizedBox.square(
                          dimension: 58,
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              DalaAsset(
                                'hex_color5',
                                width: 58,
                                height: 58,
                                filterQuality: FilterQuality.none,
                              ),
                              DalaAsset(
                                'castle',
                                width: 36,
                                height: 36,
                                filterQuality: FilterQuality.none,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      '...',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 30,
                        height: 0.9,
                        shadows: [Shadow(color: Colors.black, blurRadius: 2)],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
