import 'package:flutter/material.dart';
import 'package:flutter_chat_demo/constants/constants.dart';

class LoadingView extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xCC111827),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(
              color: ColorConstants.themeColor,
            ),
            const SizedBox(height: 14),
            const Text(
              'Cargando mundo...',
              style: TextStyle(
                color: Color(0xFF00E65A),
                fontFamily: 'monospace',
                fontWeight: FontWeight.w700,
                letterSpacing: 1,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
