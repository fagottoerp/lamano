import 'package:flutter/material.dart';

/// Stub — llamadas deshabilitadas temporalmente.
class LiveKitCallPage extends StatelessWidget {
  final String roomName;
  final String callerName;
  final bool isVideo;

  const LiveKitCallPage({
    super.key,
    required this.roomName,
    required this.callerName,
    required this.isVideo,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A1628),
      body: SafeArea(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              isVideo ? Icons.videocam_off : Icons.call_end,
              size: 64,
              color: Colors.white54,
            ),
            const SizedBox(height: 16),
            const Text(
              'Llamadas temporalmente deshabilitadas',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white70, fontSize: 16),
            ),
            const SizedBox(height: 24),
            TextButton(
              onPressed: () => Navigator.of(context).maybePop(),
              child: const Text('Volver', style: TextStyle(color: Colors.white70)),
            ),
          ],
        ),
      ),
    );
  }
}
