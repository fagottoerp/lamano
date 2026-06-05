import 'package:flutter/material.dart';
import '../services/call_service.dart';
import 'agora_call_page.dart';

/// Full-screen overlay shown when an incoming call arrives.
/// Push this as a modal route from home_page when FCM delivers
/// a data message with type == 'incoming_call'.
class IncomingCallScreen extends StatelessWidget {
  final String callId;
  final String callerName;
  final String callerAvatar;
  final bool isVideo;
  final bool isGroup;

  const IncomingCallScreen({
    super.key,
    required this.callId,
    required this.callerName,
    required this.callerAvatar,
    required this.isVideo,
    this.isGroup = false,
  });

  void _accept(BuildContext context) async {
    if (!isGroup) await CallService.acceptCall(callId);
    if (context.mounted) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => AgoraCallPage(
            callId: callId,
            peerName: callerName,
            peerAvatar: callerAvatar,
            isVideo: isVideo,
            isCaller: false,
            isGroup: isGroup,
          ),
        ),
      );
    }
  }

  void _decline(BuildContext context) async {
    await CallService.declineCall(callId);
    if (context.mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF1a1a2e), Color(0xFF0f3460)],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              const SizedBox(height: 60),
              // Call type label
              Text(
                isGroup
                    ? (isVideo ? 'Videollamada grupal' : 'Llamada grupal')
                    : (isVideo ? 'Videollamada entrante' : 'Llamada de voz entrante'),
                style: const TextStyle(color: Colors.white54, fontSize: 15),
              ),
              const SizedBox(height: 30),
              // Avatar
              CircleAvatar(
                radius: 65,
                backgroundColor: const Color(0xFF16213e),
                backgroundImage: callerAvatar.isNotEmpty
                    ? NetworkImage(callerAvatar)
                    : null,
                child: callerAvatar.isEmpty
                    ? Text(
                        callerName.isNotEmpty
                            ? callerName[0].toUpperCase()
                            : '?',
                        style: const TextStyle(
                            fontSize: 52, color: Colors.white),
                      )
                    : null,
              ),
              const SizedBox(height: 24),
              Text(
                callerName,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Spacer(),
              // Action buttons
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 60, vertical: 40),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    // Decline
                    _ActionButton(
                      icon: Icons.call_end,
                      color: Colors.red,
                      label: 'Rechazar',
                      onTap: () => _decline(context),
                    ),
                    // Accept
                    _ActionButton(
                      icon: isVideo ? Icons.videocam : Icons.call,
                      color: Colors.green,
                      label: 'Aceptar',
                      onTap: () => _accept(context),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label;
  final VoidCallback onTap;

  const _ActionButton({
    required this.icon,
    required this.color,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 68,
            height: 68,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            child: Icon(icon, color: Colors.white, size: 32),
          ),
          const SizedBox(height: 8),
          Text(label,
              style: const TextStyle(color: Colors.white70, fontSize: 13)),
        ],
      ),
    );
  }
}
