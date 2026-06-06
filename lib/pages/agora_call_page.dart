import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:jitsi_meet_flutter_sdk/jitsi_meet_flutter_sdk.dart';
import '../services/call_service.dart';

const String kJitsiDomain = 'jitsi.38.247.147.220.nip.io';
const String kJitsiTokenApi = 'http://38.247.147.220/lamano/api_jitsi_token.php';

// Nombre de clase mantenido para no romper imports existentes
class AgoraCallPage extends StatefulWidget {
  final String callId;
  final String peerName;
  final String peerAvatar;
  final bool isVideo;
  final bool isCaller;
  final bool isGroup;

  const AgoraCallPage({
    super.key,
    required this.callId,
    required this.peerName,
    required this.peerAvatar,
    required this.isVideo,
    required this.isCaller,
    this.isGroup = false,
  });

  @override
  State<AgoraCallPage> createState() => _AgoraCallPageState();
}

class _AgoraCallPageState extends State<AgoraCallPage> {
  final _jitsi = JitsiMeet();
  bool _ended = false;
  String? _error;
  StreamSubscription? _callStatusSub;

  @override
  void initState() {
    super.initState();
    if (!widget.isGroup) _watchCallStatus();
    _join();
  }

  void _watchCallStatus() {
    _callStatusSub = CallService.watchCall(widget.callId).listen((snap) {
      final status = (snap.data()?['status'] as String?) ?? '';
      if ((status == 'ended' || status == 'declined') && !_ended) {
        _endLocally();
      }
    });
  }

  Future<String> _fetchToken(String room) async {
    try {
      final resp = await http.post(
        Uri.parse(kJitsiTokenApi),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'room': room, 'user_name': widget.peerName}),
      ).timeout(const Duration(seconds: 15));
      final data = jsonDecode(resp.body);
      return (data['token'] as String?) ?? '';
    } catch (e) {
      debugPrint('[JITSI] token error: $e');
      return '';
    }
  }

  Future<void> _join() async {
    // Sanitizar callId igual que el servidor PHP
    final room = widget.callId.replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '');

    final token = await _fetchToken(room);
    if (token.isEmpty) {
      if (mounted) setState(() => _error = 'Error al obtener token de llamada');
      return;
    }

    final listener = JitsiMeetEventListener(
      conferenceJoined: (url) {
        debugPrint('[JITSI] joined: $url');
      },
      conferenceTerminated: (url, error) {
        debugPrint('[JITSI] terminated: $url error=$error');
        _hangUp();
      },
      conferenceWillJoin: (url) {
        debugPrint('[JITSI] willJoin: $url');
      },
    );

    final options = JitsiMeetConferenceOptions(
      serverURL: 'https://$kJitsiDomain',
      room: room,
      token: token,
      configOverrides: {
        'startWithAudioMuted': false,
        'startWithVideoMuted': !widget.isVideo,
        'prejoinPageEnabled': false,
        'disableDeepLinking': true,
      },
      featureFlags: {
        FeatureFlags.addPeopleEnabled: false,
        FeatureFlags.calenderEnabled: false,
        FeatureFlags.callIntegrationEnabled: true,
        FeatureFlags.carModeEnabled: false,
        FeatureFlags.closeCaptionsEnabled: false,
        FeatureFlags.helpButtonEnabled: false,
        FeatureFlags.inviteEnabled: false,
        FeatureFlags.kickOutEnabled: false,
        FeatureFlags.liveStreamingEnabled: false,
        FeatureFlags.lobbyModeEnabled: false,
        FeatureFlags.meetingNameEnabled: false,
        FeatureFlags.meetingPasswordEnabled: false,
        FeatureFlags.pipEnabled: true,
        FeatureFlags.raiseHandEnabled: false,
        FeatureFlags.recordingEnabled: false,
        FeatureFlags.securityOptionEnabled: false,
        FeatureFlags.serverUrlChangeEnabled: false,
        FeatureFlags.tileViewEnabled: widget.isGroup,
        FeatureFlags.toolboxAlwaysVisible: false,
        FeatureFlags.videoShareEnabled: false,
        FeatureFlags.chatEnabled: false,
        FeatureFlags.reactionsEnabled: false,
        FeatureFlags.speakerStatsEnabled: false,
        FeatureFlags.iosRecordingEnabled: false,
        FeatureFlags.unsafeRoomWarningEnabled: false,
        FeatureFlags.welcomePageEnabled: false,
        FeatureFlags.preJoinPageEnabled: false,
      },
    );

    try {
      await _jitsi.join(options, listener);
    } catch (e) {
      if (mounted) setState(() => _error = 'Error al unirse: $e');
    }
  }

  Future<void> _hangUp() async {
    if (_ended) return;
    _ended = true;
    try {
      if (!widget.isGroup) {
        if (widget.isCaller) {
          await CallService.endCall(widget.callId);
        } else {
          await CallService.declineCall(widget.callId);
        }
      }
    } catch (_) {}
    await _endLocally();
  }

  Future<void> _endLocally() async {
    _callStatusSub?.cancel();
    try { await _jitsi.hangUp(); } catch (_) {}
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _callStatusSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.call_end, color: Colors.red, size: 56),
                const SizedBox(height: 16),
                Text(_error!, style: const TextStyle(color: Colors.white70)),
                const SizedBox(height: 24),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Volver', style: TextStyle(color: Colors.white)),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircleAvatar(
                radius: 52,
                backgroundColor: const Color(0xFF0f3460),
                backgroundImage: widget.peerAvatar.isNotEmpty
                    ? NetworkImage(widget.peerAvatar)
                    : null,
                child: widget.peerAvatar.isEmpty
                    ? Text(
                        widget.peerName.isNotEmpty ? widget.peerName[0].toUpperCase() : '?',
                        style: const TextStyle(fontSize: 40, color: Colors.white),
                      )
                    : null,
              ),
              const SizedBox(height: 20),
              Text(widget.peerName,
                  style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              const Text('Conectando...', style: TextStyle(color: Colors.white60)),
              const SizedBox(height: 24),
              const CircularProgressIndicator(color: Colors.white54),
              const SizedBox(height: 32),
              TextButton.icon(
                onPressed: _hangUp,
                icon: const Icon(Icons.call_end, color: Colors.red),
                label: const Text('Colgar', style: TextStyle(color: Colors.red)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
