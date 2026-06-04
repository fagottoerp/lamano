import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_chat_demo/constants/firestore_constants.dart';
import 'package:flutter_chat_demo/services/livekit_service.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

class LiveKitCallPage extends StatefulWidget {
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
  State<LiveKitCallPage> createState() => _LiveKitCallPageState();
}

class _LiveKitCallPageState extends State<LiveKitCallPage> {
  final Room _room = Room();
  EventsListener<RoomEvent>? _listener;
  bool _connecting = true;
  bool _connected = false;
  String _status = 'Conectando...';

  @override
  void initState() {
    super.initState();
    _connect();
  }

  @override
  void dispose() {
    _listener?.dispose();
    _room.disconnect();
    super.dispose();
  }

  Future<void> _connect() async {
    try {
      final mic = await Permission.microphone.request();
      final cam = widget.isVideo ? await Permission.camera.request() : PermissionStatus.granted;
      if (mic != PermissionStatus.granted || cam != PermissionStatus.granted) {
        if (mic == PermissionStatus.permanentlyDenied || cam == PermissionStatus.permanentlyDenied) {
          await openAppSettings();
        }
        throw Exception(widget.isVideo
            ? 'Permisos requeridos: camara y microfono'
            : 'Permiso requerido: microfono');
      }

      final prefs = await SharedPreferences.getInstance();
      final identity = prefs.getString(FirestoreConstants.id) ?? '';
      if (identity.isEmpty) {
        throw Exception('Sesion no disponible');
      }

      final nickname = prefs.getString(FirestoreConstants.nickname) ?? 'Usuario';
      final tokenData = await LiveKitService.createRoomToken(
        identity: identity,
        roomName: widget.roomName,
        name: nickname,
      );

      await _room.connect(
        tokenData.url,
        tokenData.token,
        roomOptions: const RoomOptions(adaptiveStream: true, dynacast: true),
      );

      await _room.localParticipant?.setMicrophoneEnabled(true);
      await _room.localParticipant?.setCameraEnabled(widget.isVideo);

      _listener = _room.createListener()
        ..on<RoomDisconnectedEvent>((_) {
          if (!mounted) return;
          setState(() {
            _connected = false;
            _status = 'Llamada finalizada';
          });
          Navigator.of(context).pop();
        })
        ..on<ParticipantConnectedEvent>((event) {
          if (!mounted) return;
          setState(() => _status = '${event.participant.identity} en linea');
        })
        ..on<ParticipantDisconnectedEvent>((event) {
          if (!mounted) return;
          setState(() => _status = '${event.participant.identity} salio');
        });

      if (!mounted) return;
      setState(() {
        _connecting = false;
        _connected = true;
        _status = 'En llamada';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _connecting = false;
        _connected = false;
        _status = 'No se pudo conectar';
      });
      Fluttertoast.showToast(msg: e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _toggleMic() async {
    final enabled = _room.localParticipant?.isMicrophoneEnabled() ?? false;
    await _room.localParticipant?.setMicrophoneEnabled(!enabled);
    if (mounted) setState(() {});
  }

  Future<void> _toggleCam() async {
    final enabled = _room.localParticipant?.isCameraEnabled() ?? false;
    await _room.localParticipant?.setCameraEnabled(!enabled);
    if (mounted) setState(() {});
  }

  Future<void> _hangup() async {
    await _room.disconnect();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final micOn = _room.localParticipant?.isMicrophoneEnabled() ?? false;
    final camOn = _room.localParticipant?.isCameraEnabled() ?? false;

    return Scaffold(
      backgroundColor: const Color(0xFF0A1628),
      appBar: AppBar(
        title: Text(widget.isVideo ? 'Videollamada' : 'Llamada de voz'),
        centerTitle: true,
      ),
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 34),
            CircleAvatar(
              radius: 42,
              backgroundColor: Colors.white12,
              child: Text(
                widget.callerName.isNotEmpty
                    ? widget.callerName[0].toUpperCase()
                    : '?',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 34,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              widget.callerName,
              style: const TextStyle(color: Colors.white, fontSize: 24),
            ),
            const SizedBox(height: 8),
            Text(
              _status,
              style: TextStyle(
                color: _connected ? Colors.greenAccent : Colors.white70,
                fontSize: 13,
              ),
            ),
            if (_connecting) ...[
              const SizedBox(height: 14),
              const CircularProgressIndicator(color: Colors.white),
            ],
            const Spacer(),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _CircleAction(
                    icon: micOn ? Icons.mic : Icons.mic_off,
                    color: micOn ? const Color(0xFF1B4332) : Colors.orange,
                    label: micOn ? 'Mic on' : 'Mic off',
                    onTap: _toggleMic,
                  ),
                  if (widget.isVideo)
                    _CircleAction(
                      icon: camOn ? Icons.videocam : Icons.videocam_off,
                      color: camOn ? const Color(0xFF1B4332) : Colors.orange,
                      label: camOn ? 'Cam on' : 'Cam off',
                      onTap: _toggleCam,
                    ),
                  _CircleAction(
                    icon: Icons.call_end,
                    color: Colors.red,
                    label: 'Colgar',
                    onTap: _hangup,
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

class _CircleAction extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label;
  final VoidCallback onTap;

  const _CircleAction({
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
            width: 62,
            height: 62,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            child: Icon(icon, color: Colors.white, size: 30),
          ),
          const SizedBox(height: 7),
          Text(label, style: const TextStyle(color: Colors.white70, fontSize: 12)),
        ],
      ),
    );
  }
}
