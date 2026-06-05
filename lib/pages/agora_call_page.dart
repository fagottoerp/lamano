import 'dart:async';
import 'dart:convert';
import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import '../constants/app_constants.dart';
import '../services/call_service.dart';

/// Agora App ID — Register at https://console.agora.io and set this value.
/// For testing without a token, leave token as null and disable token auth
/// in the Agora Console (Project → No certificate / Testing mode).
const String kAgoraAppId = '41b0a5f3844441c3abf9e4c5fdc2eca9';

class AgoraCallPage extends StatefulWidget {
  final String callId;       // Agora channel name (= Firestore doc ID)
  final String peerName;     // peer name (1:1) or group name (group)
  final String peerAvatar;
  final bool isVideo;
  final bool isCaller;       // true = we initiated, false = we answered
  final bool isGroup;        // true = group call (multiple remote UIDs)

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
  late RtcEngine _engine;
  bool _localVideoMuted = false;
  bool _audioMuted = false;
  bool _speakerOn = true;
  // 1:1
  bool _remoteJoined = false;
  int? _remoteUid;
  // Group: track all remote UIDs
  final Set<int> _remoteUids = {};
  bool _engineReady = false;
  bool _callEnded = false;
  String? _errorMessage;
  bool _joinedChannel = false; // true once onJoinChannelSuccess fires
  Duration _callDuration = Duration.zero;
  Timer? _durationTimer;
  StreamSubscription? _callStatusSub;

  @override
  void initState() {
    super.initState();
    _requestPermissionsAndInit();
    // Group calls: anyone can join/leave freely — no 1:1 status signaling
    if (!widget.isGroup) _watchCallStatus();
  }

  Future<void> _requestPermissionsAndInit() async {
    final List<Permission> perms = [Permission.microphone];
    if (widget.isVideo) perms.add(Permission.camera);
    await perms.request();
    await _initAgora();
  }

  Future<String> _fetchToken(String channelName) async {
    try {
      final resp = await http.post(
        Uri.parse(AppConstants.agoraTokenApiUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'channel_name': channelName, 'uid': 0, 'role': 'publisher'}),
      ).timeout(const Duration(seconds: 8));
      final data = jsonDecode(resp.body);
      final token = (data['token'] as String?) ?? '';
      if (token.isEmpty && mounted) {
        setState(() => _errorMessage = 'Error: no se pudo obtener token Agora');
      }
      return token;
    } catch (e) {
      if (mounted) setState(() => _errorMessage = 'Error token: $e');
      return '';
    }
  }

  Future<void> _initAgora() async {
    _engine = createAgoraRtcEngine();
    await _engine.initialize(RtcEngineContext(
      appId: kAgoraAppId,
      channelProfile: ChannelProfileType.channelProfileCommunication,
    ));

    _engine.registerEventHandler(RtcEngineEventHandler(
      onJoinChannelSuccess: (connection, elapsed) {
        if (mounted) setState(() {
          _engineReady = true;
          _joinedChannel = true;
        });
        _startTimer();
      },
      onUserJoined: (connection, remoteUid, elapsed) {
        if (mounted) setState(() {
          _remoteUid = remoteUid;
          _remoteJoined = true;
          _remoteUids.add(remoteUid);
        });
      },
      onUserOffline: (connection, remoteUid, reason) {
        if (mounted) {
          setState(() {
            _remoteUids.remove(remoteUid);
            if (_remoteUid == remoteUid) {
              _remoteUid = _remoteUids.isNotEmpty ? _remoteUids.first : null;
            }
            _remoteJoined = _remoteUids.isNotEmpty;
          });
          // In 1:1, hang up when the other side leaves
          if (!widget.isGroup && _remoteUids.isEmpty) _hangUp();
        }
      },
      onError: (err, msg) {
        if (mounted) setState(() => _errorMessage = 'Error Agora: ${err.name} — $msg');
      },
      onConnectionStateChanged: (connection, state, reason) {
        if (mounted) {
          if (state == ConnectionStateType.connectionStateFailed) {
            setState(() => _errorMessage = 'Sin conexión (${reason.name}). Verifica tu red.');
          } else if (state == ConnectionStateType.connectionStateReconnecting) {
            setState(() => _errorMessage = 'Reconectando...');
          } else if (state == ConnectionStateType.connectionStateConnected) {
            setState(() => _errorMessage = null);
          }
        }
      },
    ));

    if (widget.isVideo) {
      await _engine.enableVideo();
      await _engine.startPreview();
    } else {
      await _engine.disableVideo();
    }
    // Audio must be explicitly enabled in Agora 6.x (off by default)
    await _engine.enableAudio();
    await _engine.setEnableSpeakerphone(_speakerOn);

    final token = await _fetchToken(widget.callId);

    await _engine.joinChannel(
      token: token,
      channelId: widget.callId,
      uid: 0,      // 0 = auto-assigned by Agora
      options: const ChannelMediaOptions(
        clientRoleType: ClientRoleType.clientRoleBroadcaster,
        channelProfile: ChannelProfileType.channelProfileCommunication,
      ),
    );
  }

  void _startTimer() {
    _durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _callDuration += const Duration(seconds: 1));
    });
  }

  /// Watch Firestore for status changes (declined / ended by the other side).
  void _watchCallStatus() {
    _callStatusSub = CallService.watchCall(widget.callId).listen((snap) {
      final data = snap.data();
      if (data == null) return;
      final status = data['status'] as String?;
      if ((status == 'ended' || status == 'declined') && !_callEnded) {
        _endLocally();
      }
    });
  }

  Future<void> _hangUp() async {
    if (_callEnded) return;
    _callEnded = true;
    try { await CallService.endCall(widget.callId); } catch (_) {}
    await _endLocally();
  }

  Future<void> _endLocally() async {
    _durationTimer?.cancel();
    _callStatusSub?.cancel();
    try {
      await _engine.leaveChannel().timeout(const Duration(seconds: 3));
    } catch (_) {}
    try {
      await _engine.release().timeout(const Duration(seconds: 3));
    } catch (_) {}
    if (mounted) Navigator.of(context).pop();
  }

  void _toggleMic() async {
    _audioMuted = !_audioMuted;
    await _engine.muteLocalAudioStream(_audioMuted);
    if (mounted) setState(() {});
  }

  void _toggleCamera() async {
    _localVideoMuted = !_localVideoMuted;
    await _engine.muteLocalVideoStream(_localVideoMuted);
    if (mounted) setState(() {});
  }

  void _toggleSpeaker() async {
    _speakerOn = !_speakerOn;
    await _engine.setEnableSpeakerphone(_speakerOn);
    if (mounted) setState(() {});
  }

  void _flipCamera() async {
    await _engine.switchCamera();
  }

  String _formatDuration(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  void dispose() {
    _durationTimer?.cancel();
    _callStatusSub?.cancel();
    try { _engine.leaveChannel(); } catch (_) {}
    try { _engine.release(); } catch (_) {}
    super.dispose();
  }

  // ── UI ──────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // Remote video (full screen) or avatar background
          if (widget.isVideo && _remoteJoined && _remoteUid != null)
            _buildRemoteVideo()
          else
            _buildAvatarBackground(),

          // Group: small participant tiles (top strip)
          if (widget.isGroup && _remoteUids.length > 1)
            _buildGroupParticipantStrip(),

          // Local video preview (PiP, top-right)
          if (widget.isVideo && !_localVideoMuted && _engineReady)
            _buildLocalVideoPreview(),

          // Top overlay: peer name + status
          _buildTopOverlay(),

          // Bottom controls
          _buildControls(),
        ],
      ),
    );
  }

  Widget _buildRemoteVideo() {
    return Positioned.fill(
      child: AgoraVideoView(
        controller: VideoViewController.remote(
          rtcEngine: _engine,
          canvas: VideoCanvas(uid: _remoteUid),
          connection: RtcConnection(channelId: widget.callId),
        ),
      ),
    );
  }

  Widget _buildAvatarBackground() {
    return Positioned.fill(
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF1a1a2e), Color(0xFF16213e)],
          ),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircleAvatar(
                radius: 60,
                backgroundColor: const Color(0xFF0f3460),
                backgroundImage: widget.peerAvatar.isNotEmpty
                    ? NetworkImage(widget.peerAvatar)
                    : null,
                child: widget.peerAvatar.isEmpty
                    ? Text(
                        widget.peerName.isNotEmpty ? widget.peerName[0].toUpperCase() : '?',
                        style: const TextStyle(fontSize: 48, color: Colors.white),
                      )
                    : null,
              ),
              const SizedBox(height: 20),
              if (widget.isGroup && _remoteUids.isNotEmpty)
                Text(
                  '${_remoteUids.length + 1} participante${_remoteUids.length > 0 ? 's' : ''}',
                  style: const TextStyle(color: Colors.white60, fontSize: 14),
                )
              else if (!_remoteJoined)
                const _PulsingText('Conectando...'),
            ],
          ),
        ),
      ),
    );
  }

  /// Horizontal strip of small video tiles for extra group participants
  Widget _buildGroupParticipantStrip() {
    final extraUids = _remoteUids.skip(1).toList();
    if (extraUids.isEmpty) return const SizedBox.shrink();
    return Positioned(
      top: 100,
      left: 0,
      right: 0,
      height: 100,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        itemCount: extraUids.length,
        separatorBuilder: (_, __) => const SizedBox(width: 6),
        itemBuilder: (_, i) {
          final uid = extraUids[i];
          return ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width: 80,
              child: widget.isVideo
                  ? AgoraVideoView(
                      controller: VideoViewController.remote(
                        rtcEngine: _engine,
                        canvas: VideoCanvas(uid: uid),
                        connection: RtcConnection(channelId: widget.callId),
                      ),
                    )
                  : Container(
                      color: const Color(0xFF1a2a3a),
                      child: const Icon(Icons.person, color: Colors.white54, size: 36),
                    ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildLocalVideoPreview() {
    return Positioned(
      top: 60,
      right: 16,
      width: 100,
      height: 140,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: AgoraVideoView(
          controller: VideoViewController(
            rtcEngine: _engine,
            canvas: const VideoCanvas(uid: 0),
          ),
        ),
      ),
    );
  }

  Widget _buildTopOverlay() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text(
                widget.peerName,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  shadows: [Shadow(blurRadius: 8, color: Colors.black54)],
                ),
              ),
              const SizedBox(height: 4),
              Text(
                _errorMessage != null
                    ? _errorMessage!
                    : widget.isGroup
                        ? (_remoteUids.isNotEmpty
                            ? '${_remoteUids.length + 1} en llamada · ${_formatDuration(_callDuration)}'
                            : _joinedChannel ? 'Esperando participantes...' : 'Conectando al servidor...')
                        : (_remoteJoined
                            ? _formatDuration(_callDuration)
                            : _joinedChannel
                                ? (widget.isCaller ? 'Llamando...' : 'Esperando conexión del otro...')
                                : 'Conectando al servidor...'),
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 14,
                  shadows: [Shadow(blurRadius: 4, color: Colors.black54)],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildControls() {
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.transparent, Colors.black.withOpacity(0.7)],
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              // Mic
              _CallButton(
                icon: _audioMuted ? Icons.mic_off : Icons.mic,
                label: _audioMuted ? 'Mic off' : 'Mic',
                color: _audioMuted ? Colors.red.shade700 : Colors.white24,
                onTap: _toggleMic,
              ),
              // Speaker (audio-only) / Camera flip (video)
              if (widget.isVideo)
                _CallButton(
                  icon: Icons.flip_camera_ios,
                  label: 'Voltear',
                  color: Colors.white24,
                  onTap: _flipCamera,
                )
              else
                _CallButton(
                  icon: _speakerOn ? Icons.volume_up : Icons.hearing,
                  label: _speakerOn ? 'Altavoz' : 'Auricular',
                  color: _speakerOn ? const Color(0xFF00b09b) : Colors.white24,
                  onTap: _toggleSpeaker,
                ),
              // Hang up
              _CallButton(
                icon: Icons.call_end,
                label: 'Colgar',
                color: Colors.red,
                size: 64,
                onTap: _hangUp,
              ),
              // Camera mute (video only)
              if (widget.isVideo)
                _CallButton(
                  icon: _localVideoMuted ? Icons.videocam_off : Icons.videocam,
                  label: _localVideoMuted ? 'Cám off' : 'Cámara',
                  color: _localVideoMuted ? Colors.red.shade700 : Colors.white24,
                  onTap: _toggleCamera,
                )
              else
                // Speaker for audio calls (4th slot)
                _CallButton(
                  icon: Icons.dialpad,
                  label: 'Teclado',
                  color: Colors.white24,
                  onTap: () {}, // placeholder — can add DTMF later
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Reusable call button ──────────────────────────────────────────────────────

class _CallButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final double size;
  final VoidCallback onTap;

  const _CallButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
    this.size = 52,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            child: Icon(icon, color: Colors.white, size: size * 0.46),
          ),
          const SizedBox(height: 6),
          Text(label,
              style: const TextStyle(color: Colors.white70, fontSize: 11)),
        ],
      ),
    );
  }
}

// ── Pulsing "Llamando..." text ────────────────────────────────────────────────

class _PulsingText extends StatefulWidget {
  final String text;
  const _PulsingText(this.text);

  @override
  State<_PulsingText> createState() => _PulsingTextState();
}

class _PulsingTextState extends State<_PulsingText>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(seconds: 1))
      ..repeat(reverse: true);
    _anim = Tween<double>(begin: 0.4, end: 1.0).animate(_ctrl);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _anim,
      child: Text(widget.text,
          style: const TextStyle(color: Colors.white60, fontSize: 15)),
    );
  }
}
