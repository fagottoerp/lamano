import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_chat_demo/constants/constants.dart';
import 'package:flutter_chat_demo/pages/group_live_map_page.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

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
    this.groupId,
    this.groupName,
    this.currentUserId,
    this.currentUserName,
  });

  /// Para `live=false` el payload es el JSON `{"lat":..,"lng":..}`.
  /// Para `live=true` el payload es el docId en `liveLocations`.
  final String payload;
  final bool isMe;
  final bool live;
  final String? groupId;
  final String? groupName;
  final String? currentUserId;
  final String? currentUserName;

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
            groupId: groupId,
            groupName: groupName,
            currentUserId: currentUserId,
            currentUserName: currentUserName,
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
    return _MapCard(
      lat: lat,
      lng: lng,
      isMe: isMe,
      live: false,
      active: true,
      groupId: groupId,
      groupName: groupName,
      currentUserId: currentUserId,
      currentUserName: currentUserName,
    );
  }
}

class _MapCard extends StatefulWidget {
  const _MapCard({
    required this.lat,
    required this.lng,
    required this.isMe,
    required this.live,
    required this.active,
    this.groupId,
    this.groupName,
    this.currentUserId,
    this.currentUserName,
  });

  final double? lat;
  final double? lng;
  final bool isMe;
  final bool live;
  final bool active;
  final String? groupId;
  final String? groupName;
  final String? currentUserId;
  final String? currentUserName;

  @override
  State<_MapCard> createState() => _MapCardState();
}

class _MapCardState extends State<_MapCard> {
  bool _expanded = true;

  bool get _canOpenGroupLiveMap {
    return widget.live &&
        widget.groupId?.isNotEmpty == true &&
        widget.groupName?.isNotEmpty == true &&
        widget.currentUserId?.isNotEmpty == true &&
        widget.currentUserName?.isNotEmpty == true;
  }

  Future<void> _open() async {
    if (_canOpenGroupLiveMap) {
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => GroupLiveMapPage(
            groupId: widget.groupId!,
            groupName: widget.groupName!,
            currentUserId: widget.currentUserId!,
            currentUserName: widget.currentUserName!,
          ),
        ),
      );
      return;
    }

    if (widget.lat == null || widget.lng == null) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _FullscreenLocationMapPage(
          lat: widget.lat!,
          lng: widget.lng!,
          isLive: widget.live && widget.active,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasPos = widget.lat != null &&
        widget.lng != null &&
        (widget.lat != 0.0 || widget.lng != 0.0);
    final canOpen = _canOpenGroupLiveMap || hasPos;

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
                          : 'Ubicación compartida',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                        ),
                        overflow: TextOverflow.ellipsis,
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
            firstChild: InkWell(
              onTap: canOpen ? _open : null,
              child: SizedBox(
                height: 160,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: hasPos
                          ? _MiniMap(
                              key: ValueKey('${widget.lat}_${widget.lng}_${widget.live ? 1 : 0}'),
                              lat: widget.lat!,
                              lng: widget.lng!,
                              live: widget.live && widget.active,
                            )
                          : Container(
                              color: ColorConstants.surfaceLight,
                              child: const Center(
                                child: Icon(Icons.location_searching,
                                    color: ColorConstants.greyColor, size: 32),
                              ),
                            ),
                    ),
                    if (canOpen)
                      const Positioned(
                        right: 8,
                        bottom: 8,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: Color(0xB3000000),
                            borderRadius: BorderRadius.all(Radius.circular(10)),
                          ),
                          child: Padding(
                            padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.zoom_out_map, color: Colors.white, size: 13),
                                SizedBox(width: 4),
                                Text(
                                  'Tocar para ampliar',
                                  style: TextStyle(color: Colors.white, fontSize: 10),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
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
  const _MiniMap({super.key, required this.lat, required this.lng, required this.live});
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

class _FullscreenLocationMapPage extends StatelessWidget {
  const _FullscreenLocationMapPage({
    required this.lat,
    required this.lng,
    required this.isLive,
  });

  final double lat;
  final double lng;
  final bool isLive;

  @override
  Widget build(BuildContext context) {
    final point = LatLng(lat, lng);
    return Scaffold(
      appBar: AppBar(
        title: Text(isLive ? 'Ubicación en vivo' : 'Ubicación compartida'),
      ),
      body: FlutterMap(
        options: MapOptions(
          initialCenter: point,
          initialZoom: 16,
          interactionOptions: const InteractionOptions(
            flags: InteractiveFlag.pinchZoom |
                InteractiveFlag.drag |
                InteractiveFlag.doubleTapZoom |
                InteractiveFlag.flingAnimation,
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
              width: 44,
              height: 44,
              child: Icon(
                Icons.location_pin,
                color: isLive ? Colors.red : Colors.redAccent.shade700,
                size: 44,
              ),
            ),
          ]),
        ],
      ),
    );
  }
}
