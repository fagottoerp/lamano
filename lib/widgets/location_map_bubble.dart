import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_chat_demo/constants/constants.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

/// Burbuja con mini mapa para mensajes de ubicación.
///
/// Se usa tanto para mensajes [TypeMessage.location] (snapshot puntual,
/// payload `{"lat":x,"lng":y}`) como para [TypeMessage.liveLocation]
/// (live, payload = docId en `liveLocations`).
class LocationMapBubble extends StatelessWidget {
  const LocationMapBubble({
    super.key,
    required this.payload,
    required this.isMe,
    required this.live,
  });

  /// Para `live=false` el payload es el JSON `{"lat":..,"lng":..}`.
  /// Para `live=true` el payload es el docId en `liveLocations`.
  final String payload;
  final bool isMe;
  final bool live;

  @override
  Widget build(BuildContext context) {
    if (live) {
      return StreamBuilder<DocumentSnapshot>(
        stream: FirebaseFirestore.instance
            .collection(FirestoreConstants.pathLiveLocations)
            .doc(payload)
            .snapshots(),
        builder: (_, snap) {
          final data = snap.data?.data() as Map<String, dynamic>?;
          final active = data?['active'] as bool? ?? false;
          final lat = (data?['lat'] as num?)?.toDouble();
          final lng = (data?['lng'] as num?)?.toDouble();
          return _MapCard(
            lat: lat,
            lng: lng,
            isMe: isMe,
            live: true,
            active: active,
          );
        },
      );
    }

    double? lat;
    double? lng;
    try {
      final raw = jsonDecode(payload);
      if (raw is Map) {
        lat = (raw['lat'] as num?)?.toDouble();
        lng = (raw['lng'] as num?)?.toDouble();
      }
    } catch (_) {}
    return _MapCard(lat: lat, lng: lng, isMe: isMe, live: false, active: true);
  }
}

class _MapCard extends StatelessWidget {
  const _MapCard({
    required this.lat,
    required this.lng,
    required this.isMe,
    required this.live,
    required this.active,
  });

  final double? lat;
  final double? lng;
  final bool isMe;
  final bool live;
  final bool active;

  Future<void> _open() async {
    if (lat == null || lng == null) return;
    final uri =
        Uri.parse('https://www.google.com/maps/search/?api=1&query=$lat,$lng');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasPos = lat != null && lng != null && (lat != 0.0 || lng != 0.0);
    final bgColor =
        isMe ? ColorConstants.greyColor2 : ColorConstants.primaryColor;
    final fgColor =
        isMe ? ColorConstants.primaryColor : Colors.white;

    return GestureDetector(
      onTap: _open,
      child: Container(
        width: 230,
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(12),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: 140,
              child: hasPos
                  ? _MiniMap(lat: lat!, lng: lng!, live: live && active)
                  : Container(
                      color: Colors.black12,
                      child: const Center(
                        child: Icon(Icons.location_searching,
                            color: Colors.white70, size: 32),
                      ),
                    ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
              child: Row(
                children: [
                  Icon(
                    live
                        ? (active ? Icons.location_on : Icons.location_off)
                        : Icons.place,
                    size: 16,
                    color: live
                        ? (active ? Colors.green : Colors.redAccent)
                        : fgColor,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      live
                          ? (active
                              ? 'Ubicación en vivo'
                              : 'Ubicación finalizada')
                          : 'Ubicación',
                      style: TextStyle(
                        color: fgColor,
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (hasPos)
                    Icon(Icons.open_in_new,
                        size: 14, color: fgColor.withValues(alpha: 0.7)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MiniMap extends StatefulWidget {
  const _MiniMap({required this.lat, required this.lng, required this.live});
  final double lat;
  final double lng;
  final bool live;

  @override
  State<_MiniMap> createState() => _MiniMapState();
}

class _MiniMapState extends State<_MiniMap> {
  late final MapController _controller = MapController();

  @override
  void didUpdateWidget(covariant _MiniMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.lat != widget.lat || oldWidget.lng != widget.lng) {
      try {
        _controller.move(LatLng(widget.lat, widget.lng), 15);
      } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) {
    final point = LatLng(widget.lat, widget.lng);
    return IgnorePointer(
      // El mapa no se interactúa dentro de la burbuja: el tap general abre Maps.
      child: FlutterMap(
        mapController: _controller,
        options: MapOptions(
          initialCenter: point,
          initialZoom: 15,
          interactionOptions:
              const InteractionOptions(flags: InteractiveFlag.none),
        ),
        children: [
          TileLayer(
            urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
            userAgentPackageName: 'com.lamano.clonewhatsapp',
          ),
          MarkerLayer(markers: [
            Marker(
              point: point,
              width: 38,
              height: 38,
              child: Icon(
                Icons.location_pin,
                color: widget.live ? Colors.red : Colors.redAccent.shade700,
                size: 38,
              ),
            ),
          ]),
        ],
      ),
    );
  }
}
