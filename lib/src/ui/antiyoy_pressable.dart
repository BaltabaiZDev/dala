import 'package:flutter/material.dart';

/// Small shared press response for Classic-style surfaces that are not
/// Material buttons. Material buttons keep their native ripple; custom bands,
/// image buttons and menu rows use this scale/elevation-like response.
class AntiyoyPressable extends StatefulWidget {
  const AntiyoyPressable({
    required this.child,
    required this.onTap,
    this.onLongPress,
    this.behavior = HitTestBehavior.opaque,
    super.key,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final HitTestBehavior behavior;

  @override
  State<AntiyoyPressable> createState() => _AntiyoyPressableState();
}

class _AntiyoyPressableState extends State<AntiyoyPressable> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed == value || !mounted) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: widget.behavior,
    onTap: widget.onTap,
    onLongPress: widget.onLongPress,
    onTapDown: widget.onTap == null ? null : (_) => _setPressed(true),
    onTapUp: widget.onTap == null ? null : (_) => _setPressed(false),
    onTapCancel: widget.onTap == null ? null : () => _setPressed(false),
    child: AnimatedScale(
      scale: _pressed ? .955 : 1,
      duration: Duration(milliseconds: _pressed ? 65 : 125),
      curve: _pressed ? Curves.easeOut : Curves.easeOutBack,
      child: AnimatedOpacity(
        opacity: widget.onTap == null ? .48 : (_pressed ? .82 : 1),
        duration: const Duration(milliseconds: 80),
        child: widget.child,
      ),
    ),
  );
}
