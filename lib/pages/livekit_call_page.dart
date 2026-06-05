import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_chat_demo/constants/firestore_constants.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:jitsi_meet_flutter_sdk/jitsi_meet_flutter_sdk.dart';
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
  final JitsiMeet _jitsiMeet = JitsiMeet();
  bool _launching = true;
  String _status = 'Conectando...';

  @override
  void initState() {
    super.initState();
    _openJitsi();
  }

  @override
  void dispose() {
    unawaited(_jitsiMeet.hangUp());
    super.dispose();
  }

  Future<void> _openJitsi() async {
    try {
      await _requestCallPermissions();

      final prefs = await SharedPreferences.getInstance();
      final myName = (prefs.getString(FirestoreConstants.nickname) ?? 'Usuario').trim();
      final safeName = myName.isEmpty ? 'Usuario' : myName;

      final options = JitsiMeetConferenceOptions(
        serverURL: 'https://meet.jit.si',
        room: widget.roomName,
        userInfo: JitsiMeetUserInfo(displayName: safeName),
        configOverrides: {
          'prejoinPageEnabled': false,
          'startWithAudioMuted': false,
          'startWithVideoMuted': !widget.isVideo,
          'requireDisplayName': false,
        },
        featureFlags: {
          FeatureFlags.welcomePageEnabled: false,
          FeatureFlags.preJoinPageEnabled: false,
          FeatureFlags.preJoinPageHideDisplayName: true,
          FeatureFlags.callIntegrationEnabled: true,
          FeatureFlags.chatEnabled: true,
          FeatureFlags.inviteEnabled: false,
        },
      );

      await _jitsiMeet.join(
        options,
        JitsiMeetEventListener(
          conferenceWillJoin: (_) {
            if (!mounted) return;
            setState(() => _status = 'Entrando a la llamada...');
          },
          conferenceJoined: (_) {
            if (!mounted) return;
            setState(() {
              _launching = false;
              _status = 'En llamada';
            });
          },
          conferenceTerminated: (_, __) {
            if (!mounted) return;
            Navigator.of(context).maybePop();
          },
          readyToClose: () {
            if (!mounted) return;
            Navigator.of(context).maybePop();
          },
        ),
      );

      if (!mounted) return;
      setState(() {
        _launching = false;
        _status = 'Abriendo interfaz de llamada...';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _launching = false;
        _status = 'No se pudo conectar';
      });
      Fluttertoast.showToast(msg: e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _requestCallPermissions() async {
    var mic = await Permission.microphone.status;
    if (!mic.isGranted) mic = await Permission.microphone.request();
    if (!mic.isGranted) {
      throw Exception('Permiso de microfono denegado');
    }

    if (!widget.isVideo) return;

    var camera = await Permission.camera.status;
    if (!camera.isGranted) camera = await Permission.camera.request();
    if (!camera.isGranted) {
      throw Exception('Permiso de camara denegado');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A1628),
      body: SafeArea(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              widget.isVideo ? Icons.videocam : Icons.call,
              size: 62,
              color: Colors.white,
            ),
            const SizedBox(height: 12),
            Text(
              widget.isVideo ? 'Videollamada' : 'Llamada de voz',
              style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(
              widget.callerName,
              style: const TextStyle(color: Colors.white70, fontSize: 15),
            ),
            if (_launching) const CircularProgressIndicator(color: Colors.white),
            const SizedBox(height: 18),
            Text(
              _status,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 15),
            ),
            const SizedBox(height: 22),
            TextButton.icon(
              onPressed: _openJitsi,
              icon: const Icon(Icons.videocam, color: Colors.white),
              label: const Text('Entrar ahora', style: TextStyle(color: Colors.white)),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Volver al chat', style: TextStyle(color: Colors.white70)),
            ),
          ],
        ),
      ),
    );
  }
}
