import 'package:flutter/material.dart';

/// Renders [text] with a rainbow gradient shader — for admin names only.
class RainbowText extends StatelessWidget {
  final String text;
  final TextStyle? style;

  const RainbowText(this.text, {Key? key, this.style}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final base = style ?? const TextStyle(fontWeight: FontWeight.bold, fontSize: 11);
    return ShaderMask(
      blendMode: BlendMode.srcIn,
      shaderCallback: (bounds) => const LinearGradient(
        colors: [
          Color(0xFFFF0000),
          Color(0xFFFF7F00),
          Color(0xFFFFFF00),
          Color(0xFF00CC00),
          Color(0xFF0000FF),
          Color(0xFF8B00FF),
        ],
      ).createShader(Rect.fromLTWH(0, 0, bounds.width, bounds.height)),
      child: Text(text, style: base.copyWith(color: Colors.white)),
    );
  }
}
