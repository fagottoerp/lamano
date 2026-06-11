import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' hide Path;
import 'package:fluttertoast/fluttertoast.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:record/record.dart';

import 'package:flutter_chat_demo/constants/constants.dart';
import 'package:flutter_chat_demo/providers/auth_provider.dart' as app_auth;
import 'package:flutter_chat_demo/providers/chat_provider.dart';
import 'package:flutter_chat_demo/services/live_location_service.dart';
import 'package:flutter_chat_demo/widgets/theme_widgets.dart';

class GpsVivoPage extends StatefulWidget {
  const GpsVivoPage({super.key, this.focusLat, this.focusLng, this.focusLabel});

  final double? focusLat;
  final double? focusLng;
  final String? focusLabel;

  @override
  State<GpsVivoPage> createState() => _GpsVivoPageState();
}

class _GpsVivoPageState extends State<GpsVivoPage> {
  final MapController _mapController = MapController();
  String? _selectedUserId;
  late final Future<bool> _isAdminFuture = _checkIsAdmin();

  // Walkie-talkie PTT (Push-To-Talk)
  final _audioRecorder = AudioRecorder();
  bool _isRecording = false;
  String? _recordingPath;
  int _recordSeconds = 0;
  Timer? _recordTimer;
  late final ChatProvider _chatProvider;
  late final app_auth.AuthProvider _authProvider;

  @override
  void initState() {
    super.initState();
    _chatProvider = context.read<ChatProvider>();
    _authProvider = context.read<app_auth.AuthProvider>();
  }

  @override
  void dispose() {
    _recordTimer?.cancel();
    _audioRecorder.dispose();
    super.dispose();
  }

  Future<bool> _checkIsAdmin() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return false;
    try {
      final doc = await FirebaseFirestore.instance.collection('users').doc(uid).get();
      final data = doc.data() ?? <String, dynamic>{};
      final rolId = (data['rol_id'] ?? '').toString();
      final role = (data['aboutMe'] ?? '').toString().toLowerCase();
      return rolId == '1' || role.contains('admin') || uid == AppConstants.adminFirebaseUid;
    } catch (_) {
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: _isAdminFuture,
      builder: (context, adminSnap) {
        if (!adminSnap.hasData) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator(color: ColorConstants.primaryColor)),
          );
        }
        if (adminSnap.data != true) {
          return const Scaffold(
            body: Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Vista solo para admin',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
              ),
            ),
          );
        }

        return AppBackdrop(
          child: Scaffold(
            backgroundColor: Colors.transparent,
            appBar: AppBar(
              title: const Text('GPS Vivo', style: TextStyle(color: Colors.white)),
              backgroundColor: ColorConstants.primaryColor,
              iconTheme: const IconThemeData(color: Colors.white),
              actions: [
                IconButton(
                  icon: const Icon(Icons.center_focus_strong, color: Colors.white),
                  tooltip: 'Centrar mapa',
                  onPressed: () => setState(() => _selectedUserId = null),
                ),
              ],
            ),
            body: StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('users_locations')
                  .snapshots(),
              builder: (context, snap) {
          final users = <_UserLocation>[];
          if (snap.hasData) {
            for (final doc in snap.data!.docs) {
              final data = doc.data() as Map<String, dynamic>;
              final lat = (data['lat'] as num?)?.toDouble();
              final lng = (data['lng'] as num?)?.toDouble();
              if (lat == null || lng == null) continue;
              users.add(_UserLocation(
                uid: doc.id,
                nickname: data['nickname'] as String? ?? 'Usuario',
                photoUrl: data['photoUrl'] as String? ?? '',
                lat: lat,
                lng: lng,
                updatedAt: data['updatedAt'] as int? ?? 0,
                online: data['online'] as bool? ?? false,
              ));
            }
          }

          // Default center: Chile
          LatLng center = const LatLng(-33.45, -70.65);
          double zoom = 5.0;

          // Si se abrió desde una alerta, centrar ahí
          if (widget.focusLat != null && widget.focusLng != null && _selectedUserId == null) {
            center = LatLng(widget.focusLat!, widget.focusLng!);
            zoom = 16.0;
          } else if (_selectedUserId != null) {
            final sel = users.where((u) => u.uid == _selectedUserId).firstOrNull;
            if (sel != null) {
              center = LatLng(sel.lat, sel.lng);
              zoom = 15.0;
            }
          } else if (users.length == 1) {
            center = LatLng(users[0].lat, users[0].lng);
            zoom = 14.0;
          } else if (users.length > 1) {
            final avgLat = users.map((u) => u.lat).reduce((a, b) => a + b) / users.length;
            final avgLng = users.map((u) => u.lng).reduce((a, b) => a + b) / users.length;
            center = LatLng(avgLat, avgLng);
            zoom = 12.0;
          }

          return Column(
            children: [
              // User chips bar
              if (users.isNotEmpty)
                AppSectionCard(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  child: SizedBox(
                    height: 44,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: users.length,
                      separatorBuilder: (_, __) => const SizedBox(width: 6),
                      itemBuilder: (ctx, i) {
                        final u = users[i];
                        final selected = _selectedUserId == u.uid;
                        return GestureDetector(
                          onTap: () => setState(() {
                            _selectedUserId = selected ? null : u.uid;
                          }),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: selected ? ColorConstants.primaryColor : Colors.white,
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                color: selected ? ColorConstants.primaryColor : ColorConstants.divider,
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                CircleAvatar(
                                  radius: 12,
                                  backgroundImage: u.photoUrl.isNotEmpty
                                      ? NetworkImage(u.photoUrl)
                                      : null,
                                  backgroundColor: Colors.grey.shade300,
                                  child: u.photoUrl.isEmpty
                                      ? Text(u.nickname[0].toUpperCase(),
                                          style: const TextStyle(fontSize: 11))
                                      : null,
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  u.nickname,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: selected ? Colors.white : ColorConstants.textPrimary,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              // Map
              Expanded(
                child: Stack(
                  children: [
                    FlutterMap(
                      mapController: _mapController,
                      options: MapOptions(
                        initialCenter: center,
                        initialZoom: zoom,
                      ),
                      children: [
                        TileLayer(
                          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                          userAgentPackageName: 'com.dfa.flutterchatdemo',
                        ),
                        // Markers de usuarios
                        MarkerLayer(
                          markers: users.map((u) {
                            final isSelected = _selectedUserId == u.uid;
                            final ago = _agoText(u.updatedAt);
                            return Marker(
                              point: LatLng(u.lat, u.lng),
                              width: isSelected ? 90 : 70,
                              height: isSelected ? 80 : 60,
                              child: GestureDetector(
                                onTap: () => setState(() {
                                  _selectedUserId = isSelected ? null : u.uid;
                                }),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: isSelected
                                            ? const Color(0xFF1565C0)
                                            : Colors.white,
                                        borderRadius: BorderRadius.circular(8),
                                        boxShadow: [
                                          BoxShadow(
                                            color: Colors.black26,
                                            blurRadius: 4,
                                            offset: const Offset(0, 2),
                                          ),
                                        ],
                                      ),
                                      child: Text(
                                        u.nickname,
                                        style: TextStyle(
                                          fontSize: 10,
                                          fontWeight: FontWeight.bold,
                                          color: isSelected ? Colors.white : Colors.black87,
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Icon(
                                      Icons.location_on,
                                      color: isSelected
                                          ? const Color(0xFF1565C0)
                                          : (u.online ? Colors.redAccent : Colors.grey),
                                      size: isSelected ? 30 : 24,
                                    ),
                                    if (isSelected && ago.isNotEmpty)
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                        decoration: BoxDecoration(
                                          color: Colors.black54,
                                          borderRadius: BorderRadius.circular(4),
                                        ),
                                        child: Text(
                                          ago,
                                          style: const TextStyle(color: Colors.white, fontSize: 9),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            );
                          }).toList(),
                        ),
                      ],
                    ),
                    // Botones flotantes
                    Positioned(
                      bottom: 16,
                      right: 16,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // Botón Ver Todos
                          FloatingActionButton(
                            mini: true,
                            backgroundColor: ColorConstants.primaryColor,
                            tooltip: 'Ver todos',
                            heroTag: 'btn_view_all',
                            onPressed: () => setState(() => _selectedUserId = null),
                            child: const Icon(Icons.people, color: Colors.white),
                          ),
                          const SizedBox(height: 12),
                          // Botón Walkie-Talkie PTT
                          _buildPttButton(),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
          ),
        );
      },
    );
  }

  String _agoText(int ms) {
    if (ms == 0) return '';
    final diff = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ms));
    if (diff.inSeconds < 60) return 'hace ${diff.inSeconds}s';
    if (diff.inMinutes < 60) return 'hace ${diff.inMinutes}min';
    return 'hace ${diff.inHours}h';
  }

  Widget _buildPttButton() {
    final activeGroupId = LiveLocationService.instance.activeGroupId;
    if (activeGroupId == null) {
      // No hay grupo activo, no mostrar botón
      return const SizedBox.shrink();
    }

    return GestureDetector(
      onLongPressStart: (_) => _startRecording(),
      onLongPressEnd: (_) => _stopAndSendRecording(),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: _isRecording ? 80 : 64,
        height: _isRecording ? 80 : 64,
        decoration: BoxDecoration(
          color: _isRecording ? Colors.red : ColorConstants.primaryColor,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: _isRecording ? Colors.red.withOpacity(0.5) : Colors.black26,
              blurRadius: _isRecording ? 12 : 8,
              spreadRadius: _isRecording ? 2 : 0,
            ),
          ],
        ),
        child: _isRecording
            ? Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.mic, color: Colors.white, size: 28),
                  const SizedBox(height: 2),
                  Text(
                    '${_recordSeconds}s',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              )
            : const Icon(Icons.radio, color: Colors.white, size: 32),
      ),
    );
  }

  Future<void> _startRecording() async {
    final activeGroupId = LiveLocationService.instance.activeGroupId;
    if (activeGroupId == null) {
      Fluttertoast.showToast(msg: 'No hay grupo activo');
      return;
    }

    if (!await _audioRecorder.hasPermission()) {
      Fluttertoast.showToast(msg: 'Sin permiso de micrófono');
      return;
    }

    final dir = await getTemporaryDirectory();
    _recordingPath = '${dir.path}/walkie_${DateTime.now().millisecondsSinceEpoch}.m4a';
    await _audioRecorder.start(
      const RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 64000, sampleRate: 22050),
      path: _recordingPath!,
    );

    _recordSeconds = 0;
    _recordTimer?.cancel();
    _recordTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _recordSeconds++);
    });

    setState(() => _isRecording = true);
    Fluttertoast.showToast(msg: '🎙️ Grabando... (mantén presionado)', toastLength: Toast.LENGTH_SHORT);
  }

  Future<void> _stopAndSendRecording() async {
    _recordTimer?.cancel();
    final path = await _audioRecorder.stop();
    if (!mounted) return;

    setState(() => _isRecording = false);

    if (path == null) {
      Fluttertoast.showToast(msg: 'Error al detener grabación');
      return;
    }

    final file = File(path);
    if (!file.existsSync()) {
      Fluttertoast.showToast(msg: 'Archivo no encontrado');
      return;
    }

    if (_recordSeconds < 1) {
      Fluttertoast.showToast(msg: 'Audio muy corto');
      await file.delete();
      return;
    }

    final activeGroupId = LiveLocationService.instance.activeGroupId;
    if (activeGroupId == null) {
      Fluttertoast.showToast(msg: 'No hay grupo activo');
      await file.delete();
      return;
    }

    // Subir y enviar
    try {
      Fluttertoast.showToast(msg: '📤 Enviando audio...');
      final url = await _chatProvider.uploadFile(file, 'audio');
      await _sendAudioMessage(activeGroupId, url);
      Fluttertoast.showToast(msg: '✅ Audio enviado (${_recordSeconds}s)', backgroundColor: Colors.green);
    } catch (e) {
      Fluttertoast.showToast(msg: 'Error al enviar: $e');
    } finally {
      await file.delete();
    }
  }

  Future<void> _sendAudioMessage(String groupId, String audioUrl) async {
    final userId = _authProvider.userFirebaseId ?? '';
    final nickname = _authProvider.prefs.getString(FirestoreConstants.nickname) ?? 'Usuario';
    final rolId = _authProvider.prefs.getString(FirestoreConstants.rolId) ?? '';
    final ts = DateTime.now().millisecondsSinceEpoch;

    final docRef = FirebaseFirestore.instance
        .collection(FirestoreConstants.pathMessageCollection)
        .doc(groupId)
        .collection(groupId)
        .doc(ts.toString());

    final data = <String, dynamic>{
      FirestoreConstants.idFrom: userId,
      FirestoreConstants.idTo: '',
      FirestoreConstants.timestamp: ts.toString(),
      FirestoreConstants.content: audioUrl,
      FirestoreConstants.type: TypeMessage.audio,
      'senderName': nickname,
      'senderRolId': rolId,
      'readBy': {userId: ts},
    };

    await FirebaseFirestore.instance.runTransaction((tx) async {
      tx.set(docRef, data);
    });
  }
}

class _UserLocation {
  final String uid;
  final String nickname;
  final String photoUrl;
  final double lat;
  final double lng;
  final int updatedAt;
  final bool online;

  const _UserLocation({
    required this.uid,
    required this.nickname,
    required this.photoUrl,
    required this.lat,
    required this.lng,
    required this.updatedAt,
    required this.online,
  });
}
