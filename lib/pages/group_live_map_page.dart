import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_chat_demo/constants/constants.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

class GroupLiveMapPage extends StatefulWidget {
  const GroupLiveMapPage({
    super.key,
    required this.groupId,
    required this.groupName,
    required this.currentUserId,
    required this.currentUserName,
  });

  final String groupId;
  final String groupName;
  final String currentUserId;
  final String currentUserName;

  @override
  State<GroupLiveMapPage> createState() => _GroupLiveMapPageState();
}

class _GroupLiveMapPageState extends State<GroupLiveMapPage> {
  final _mapController = MapController();
  StreamSubscription<QuerySnapshot>? _membersSub;

  Position? _myPosition;
  LatLng _initialCenter = const LatLng(0, 0);
  Map<String, Map<String, dynamic>> _members = {};
  bool _initialCentered = false;

  @override
  void initState() {
    super.initState();
    _initPosition();
    _listenMembers();
  }

  Future<void> _initPosition() async {
    // Solo centrar el mapa en mi última ubicación conocida.
    // Esta pantalla NO comparte ubicación; eso lo controla el botón del chat.
    try {
      Position? pos = await Geolocator.getLastKnownPosition();
      pos ??= await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.medium);
      if (mounted) {
        setState(() {
          _myPosition = pos;
          _initialCenter = LatLng(pos!.latitude, pos.longitude);
        });
        _mapController.move(_initialCenter, 15);
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _membersSub?.cancel();
    // Importante: NO borramos la ubicación al cerrar el mapa.
    // El usuario decide cuándo dejar de compartir desde el botón del chat.
    super.dispose();
  }

  void _listenMembers() {
    _membersSub = FirebaseFirestore.instance
        .collection(FirestoreConstants.pathGroupLocations)
        .doc(widget.groupId)
        .collection('members')
        .snapshots()
        .listen((snapshot) {
      if (!mounted) return;
      final updated = <String, Map<String, dynamic>>{};
      for (final doc in snapshot.docs) {
        final data = doc.data();
        if (data['lat'] != null && data['lng'] != null) {
          updated[doc.id] = data;
        }
      }
      setState(() => _members = updated);
    });
  }

  void _fitAll() {
    if (_members.isEmpty) return;
    final points = _members.values
        .map((m) => LatLng(
              (m['lat'] as num).toDouble(),
              (m['lng'] as num).toDouble(),
            ))
        .toList();
    if (points.length == 1) {
      _mapController.move(points.first, 15);
    } else {
      _mapController.fitCamera(
        CameraFit.coordinates(
          coordinates: points,
          padding: const EdgeInsets.all(60),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final markers = _members.entries.map((entry) {
      final lat = (entry.value['lat'] as num).toDouble();
      final lng = (entry.value['lng'] as num).toDouble();
      final name = entry.value['name'] as String? ?? '?';
      final isMe = entry.key == widget.currentUserId;

      return Marker(
        point: LatLng(lat, lng),
        width: 80,
        height: 60,
        child: Column(
          children: [
            Icon(
              Icons.location_pin,
              color: isMe ? Colors.red : Colors.blue,
              size: 36,
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              decoration: BoxDecoration(
                color: isMe ? Colors.red : Colors.blue,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                isMe ? 'Yo' : name,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      );
    }).toList();

    final onlineCount = _members.length;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          children: [
            const Text(
              'Mapa en vivo',
              style: TextStyle(color: ColorConstants.primaryColor),
            ),
            Text(
              widget.groupName,
              style: const TextStyle(
                  color: ColorConstants.greyColor, fontSize: 11),
            ),
          ],
        ),
        centerTitle: true,
        actions: [
          if (onlineCount > 1)
            IconButton(
              icon: const Icon(Icons.fit_screen),
              tooltip: 'Ver a todos',
              onPressed: _fitAll,
              color: ColorConstants.primaryColor,
            ),
        ],
      ),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _initialCenter,
              initialZoom: _myPosition != null ? 15 : 2,
            ),
            children: [
              TileLayer(
                urlTemplate:
                    'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.lamano.clonewhatsapp',
              ),
              MarkerLayer(markers: markers),
            ],
          ),

          // Overlay informativo cuando nadie está compartiendo todavía.
          if (_members.isEmpty)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  color: Colors.black26,
                  alignment: Alignment.center,
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 32),
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.location_searching,
                            size: 36, color: ColorConstants.primaryColor),
                        SizedBox(height: 10),
                        Text(
                          'Aún nadie comparte ubicación',
                          style: TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 14),
                          textAlign: TextAlign.center,
                        ),
                        SizedBox(height: 6),
                        Text(
                          'Pide a los miembros que toquen el botón de ubicación en el chat.',
                          style: TextStyle(fontSize: 12, color: Colors.black54),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),

          // Contador de miembros en línea
          Positioned(
            top: 12,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.92),
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: const [
                    BoxShadow(blurRadius: 6, color: Colors.black26)
                  ],
                ),
                child: Text(
                  onlineCount == 0
                      ? 'Nadie en el mapa aún...'
                      : '$onlineCount miembro${onlineCount != 1 ? 's' : ''} compartiendo ubicación',
                  style: const TextStyle(
                    color: ColorConstants.primaryColor,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: _myPosition != null
          ? FloatingActionButton(
              mini: true,
              tooltip: 'Mi ubicación',
              backgroundColor: ColorConstants.primaryColor,
              onPressed: () => _mapController.move(
                LatLng(_myPosition!.latitude, _myPosition!.longitude),
                16,
              ),
              child: const Icon(Icons.my_location, color: Colors.white),
            )
          : null,
    );
  }
}
