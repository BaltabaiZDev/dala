import 'dart:math' as math;
import 'package:flutter/material.dart';

/// One continuous design coordinate system for controls, text and hit testing.
/// The board is still painted at the effective device pixel ratio, not captured
/// as a low-resolution screenshot. Insets and keyboard bounds use the same scale.
class DalaViewport extends StatelessWidget {
  const DalaViewport({required this.child, super.key});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        if (size.isEmpty || !size.isFinite) return const SizedBox.shrink();
        // Fit the design to both dimensions. Using only the short side made
        // desktop/landscape menus taller than the available play surface.
        final scale = math.min(size.width / 390, size.height / 640);
        final logicalSize = Size(size.width / scale, size.height / scale);
        return FittedBox(
          fit: BoxFit.fill,
          alignment: Alignment.topLeft,
          child: SizedBox.fromSize(
            size: logicalSize,
            child: MediaQuery(
              data: media.copyWith(
                size: logicalSize,
                devicePixelRatio: media.devicePixelRatio * scale,
                padding: media.padding / scale,
                viewPadding: media.viewPadding / scale,
                viewInsets: media.viewInsets / scale,
                systemGestureInsets: media.systemGestureInsets / scale,
              ),
              child: child,
            ),
          ),
        );
      },
    );
  }
}
