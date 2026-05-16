import 'package:flutter/material.dart';
import 'package:jitsi_meet_flutter_sdk/jitsi_meet_flutter_sdk.dart';

/// Full-screen incoming call page — shown via FCM fullScreenIntent.
/// Arguments passed via route:
///   IncomingCallArgs(roomName, callerName, callerUid, isVideo)
class IncomingCallArgs {
  final String roomName;
  final String callerName;
  final String callerUid;
  final bool isVideo;
  final String serverUrl;

  const IncomingCallArgs({
    required this.roomName,
    required this.callerName,
    required this.callerUid,
    required this.isVideo,
    this.serverUrl = 'https://jitsi.38.247.147.220.nip.io',
  });
}

class IncomingCallPage extends StatefulWidget {
  final IncomingCallArgs args;
  const IncomingCallPage({super.key, required this.args});

  @override
  State<IncomingCallPage> createState() => _IncomingCallPageState();
}

class _IncomingCallPageState extends State<IncomingCallPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseCtrl;
  late final Animation<double> _pulse;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    _pulse = Tween<double>(begin: 1.0, end: 1.12).animate(
      CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    super.dispose();
  }

  Future<void> _accept() async {
    Navigator.of(context).pop();
    final jitsi = JitsiMeet();
    await jitsi.join(JitsiMeetConferenceOptions(
      serverURL: widget.args.serverUrl,
      room: widget.args.roomName,
      configOverrides: {
        'startWithAudioMuted': false,
        'startWithVideoMuted': !widget.args.isVideo,
        'subject': widget.args.callerName,
      },
      featureFlags: {
        'unsafeRoomWarning.enabled': false,
        'welcomePage.enabled': false,
        'calendar.enabled': false,
        'recording.enabled': false,
        'liveStreaming.enabled': false,
        'invite.enabled': false,
      },
    ));
  }

  void _decline() {
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A1628),
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 60),
            Text(
              widget.args.isVideo ? 'Videollamada entrante' : 'Llamada entrante',
              style: const TextStyle(color: Colors.white70, fontSize: 16),
            ),
            const SizedBox(height: 32),
            ScaleTransition(
              scale: _pulse,
              child: Container(
                width: 100,
                height: 100,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white12,
                  border: Border.all(color: Colors.white24, width: 2),
                ),
                child: Center(
                  child: Text(
                    widget.args.callerName.isNotEmpty
                        ? widget.args.callerName[0].toUpperCase()
                        : '?',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 44,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 24),
            Text(
              widget.args.callerName,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 28,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Lamano',
              style: TextStyle(color: Colors.white54, fontSize: 14),
            ),
            const Spacer(),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 40),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  // Decline
                  _CallButton(
                    icon: Icons.call_end,
                    color: Colors.red,
                    label: 'Rechazar',
                    onTap: _decline,
                  ),
                  // Accept
                  _CallButton(
                    icon: widget.args.isVideo ? Icons.videocam : Icons.call,
                    color: Colors.green,
                    label: 'Aceptar',
                    onTap: _accept,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CallButton extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label;
  final VoidCallback onTap;

  const _CallButton({
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
        children: [
          Container(
            width: 68,
            height: 68,
            decoration: BoxDecoration(shape: BoxShape.circle, color: color),
            child: Icon(icon, color: Colors.white, size: 32),
          ),
          const SizedBox(height: 10),
          Text(label, style: const TextStyle(color: Colors.white70, fontSize: 13)),
        ],
      ),
    );
  }
}
