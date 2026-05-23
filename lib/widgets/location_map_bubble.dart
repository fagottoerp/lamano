import 'dart:async';
import 'dart:convert';
import 'dart:math';

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

class _MapCard extends StatefulWidget {
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

  @override
  State<_MapCard> createState() => _MapCardState();
}

class _MapCardState extends State<_MapCard> {
  bool _expanded = true;

  Future<void> _open() async {
    if (widget.lat == null || widget.lng == null) return;
    final uri = Uri.parse(
        'https://www.google.com/maps/search/?api=1&query=${widget.lat},${widget.lng}');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasPos = widget.lat != null &&
        widget.lng != null &&
        (widget.lat != 0.0 || widget.lng != 0.0);

    return Container(
      width: 240,
      decoration: BoxDecoration(
        color: widget.isMe ? ColorConstants.bgSent : ColorConstants.bgReceived,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: ColorConstants.divider, width: 1),
        boxShadow: const [BoxShadow(color: Color(0x18000000), blurRadius: 4, offset: Offset(0, 2))],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header con toggle minimizar — tap en cualquier lado del header
          Material(
            color: ColorConstants.primaryColor,
            child: InkWell(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
                child: Row(
                  children: [
                    Icon(
                      widget.live
                          ? (widget.active ? Icons.location_on : Icons.location_off)
                          : Icons.place,
                      size: 16,
                      color: widget.live
                          ? (widget.active ? const Color(0xFFB9FBD4) : Colors.redAccent.shade100)
                          : Colors.white,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        widget.live
                            ? (widget.active ? 'Ubicación en vivo 🔴' : 'Ubicación finalizada')
                            : 'Ubicación del motoboy',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (hasPos)
                      GestureDetector(
                        onTap: _open,
                        child: const Tooltip(
                          message: 'Abrir en Google Maps',
                          child: Icon(Icons.open_in_new, size: 14, color: Colors.white70),
                        ),
                      ),
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _expanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                            size: 14,
                            color: Colors.white,
                          ),
                          const SizedBox(width: 2),
                          Text(
                            _expanded ? 'Ocultar' : 'Ver mapa',
                            style: const TextStyle(color: Colors.white, fontSize: 10),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          // Mapa colapsable
          AnimatedCrossFade(
            firstChild: SizedBox(
              height: 160,
              child: hasPos
                  ? _MiniMap(
                      lat: widget.lat!,
                      lng: widget.lng!,
                      live: widget.live && widget.active)
                  : Container(
                      color: ColorConstants.surfaceLight,
                      child: const Center(
                        child: Icon(Icons.location_searching,
                            color: ColorConstants.greyColor, size: 32),
                      ),
                    ),
            ),
            secondChild: const SizedBox(height: 0),
            crossFadeState: _expanded ? CrossFadeState.showFirst : CrossFadeState.showSecond,
            duration: const Duration(milliseconds: 220),
          ),
        ],
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
    return FlutterMap(
      mapController: _controller,
      options: MapOptions(
        initialCenter: point,
        initialZoom: 15,
        interactionOptions: const InteractionOptions(
          flags: InteractiveFlag.pinchZoom |
              InteractiveFlag.drag |
              InteractiveFlag.doubleTapZoom,
        ),
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
      );
  }
}
