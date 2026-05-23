import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' hide Path;

// Definición local de tipos de alerta
class _AlertDef {
  final int id;
  final String emoji;
  final String label;
  final Color color;
  const _AlertDef(this.id, this.emoji, this.label, this.color);
}

const _kAlertDefs = [
  _AlertDef(1, '🚔', 'Control policial', Color(0xFF3B82F6)),
  _AlertDef(2, '⚠️', 'Accidente',        Color(0xFFEAB308)),
  _AlertDef(3, '🚨', 'Peligro en la vía',Color(0xFFEF4444)),
  _AlertDef(4, '🚧', 'Tráfico / Taco',   Color(0xFFF97316)),
  _AlertDef(5, '🎉', 'KLK MANE ACTIVO',  Color(0xFFEC4899)),
];

_AlertDef _defForKind(int kind) =>
    _kAlertDefs.firstWhere((d) => d.id == kind, orElse: () => _kAlertDefs[2]);

class _AlertMarkerData {
  final String id;
  final int kind;
  final double lat;
  final double lng;
  final String senderName;
  final String groupName;
  final int ts;
  const _AlertMarkerData({required this.id, required this.kind, required this.lat, required this.lng, required this.senderName, required this.groupName, required this.ts});
}

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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('GPS Vivo', style: TextStyle(color: Colors.white)),
        backgroundColor: const Color(0xFF1565C0),
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
            .collection('users')
            .where('online', isEqualTo: true)
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

          // Segundo StreamBuilder para alertas activas
          return StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance
                .collection('alerts')
                .where('expireAt', isGreaterThan: DateTime.now().millisecondsSinceEpoch)
                .snapshots(),
            builder: (context, alertSnap) {
              final alerts = <_AlertMarkerData>[];
              if (alertSnap.hasData) {
                for (final doc in alertSnap.data!.docs) {
                  final d = doc.data() as Map<String, dynamic>;
                  final aLat = (d['lat'] as num?)?.toDouble();
                  final aLng = (d['lng'] as num?)?.toDouble();
                  if (aLat == null || aLng == null) continue;
                  alerts.add(_AlertMarkerData(
                    id: doc.id,
                    kind: (d['alertKind'] as num?)?.toInt() ?? 3,
                    lat: aLat,
                    lng: aLng,
                    senderName: d['senderName'] as String? ?? '',
                    groupName: d['groupName'] as String? ?? '',
                    ts: (d['ts'] as num?)?.toInt() ?? 0,
                  ));
                }
              }

              return Column(
            children: [
              // User chips bar
              if (users.isNotEmpty)
                Container(
                  height: 56,
                  color: const Color(0xFFF5F5F5),
                  child: ListView.separated(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
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
                            color: selected ? const Color(0xFF1565C0) : Colors.white,
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: selected ? const Color(0xFF1565C0) : Colors.grey.shade300,
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
                                  color: selected ? Colors.white : Colors.black87,
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
              // Map
              Expanded(
                child: FlutterMap(
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
                                      : Colors.redAccent,
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
                    // ── Markers de alertas activas ──────────────────────
                    MarkerLayer(
                      markers: alerts.map((a) {
                        final def = _defForKind(a.kind);
                        final minsAgo = ((DateTime.now().millisecondsSinceEpoch - a.ts) / 60000).round();
                        return Marker(
                          point: LatLng(a.lat, a.lng),
                          width: 52,
                          height: 52,
                          child: GestureDetector(
                            onTap: () {
                              showDialog(
                                context: context,
                                builder: (_) => AlertDialog(
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                                  title: Text('${def.emoji} ${def.label}'),
                                  content: Text(
                                    '${a.senderName.isNotEmpty ? 'Reportado por ${a.senderName}' : ''}'
                                    '${a.groupName.isNotEmpty ? '\nGrupo: ${a.groupName}' : ''}'
                                    '\nHace $minsAgo min',
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () => Navigator.pop(context),
                                      child: const Text('Cerrar'),
                                    ),
                                  ],
                                ),
                              );
                            },
                            child: Stack(
                              alignment: Alignment.center,
                              children: [
                                Container(
                                  width: 44,
                                  height: 44,
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    shape: BoxShape.circle,
                                    border: Border.all(color: def.color, width: 2.5),
                                    boxShadow: [BoxShadow(color: def.color.withValues(alpha: 0.35), blurRadius: 8, spreadRadius: 1)],
                                  ),
                                ),
                                Text(def.emoji, style: const TextStyle(fontSize: 22)),
                              ],
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ],
                ),
              ),
              // Barra inferior con conteo de alertas
              if (alerts.isNotEmpty)
                Container(
                  color: const Color(0xFFFFF3E0),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: Row(
                    children: [
                      const Icon(Icons.warning_amber_rounded, size: 14, color: Color(0xFFF97316)),
                      const SizedBox(width: 6),
                      Text(
                        '${alerts.length} alerta${alerts.length > 1 ? 's' : ''} activa${alerts.length > 1 ? 's' : ''}: '
                        '${alerts.map((a) => _defForKind(a.kind).emoji).join(' ')}',
                        style: const TextStyle(fontSize: 11, color: Color(0xFFF97316), fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ),
            ],
          );
        },
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        mini: true,
        backgroundColor: const Color(0xFF1565C0),
        tooltip: 'Ver todos',
        onPressed: () => setState(() => _selectedUserId = null),
        child: const Icon(Icons.people, color: Colors.white),
      ),
    );
  }

  String _agoText(int ms) {
    if (ms == 0) return '';
    final diff = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ms));
    if (diff.inSeconds < 60) return 'hace ${diff.inSeconds}s';
    if (diff.inMinutes < 60) return 'hace ${diff.inMinutes}min';
    return 'hace ${diff.inHours}h';
  }
}

class _UserLocation {
  final String uid;
  final String nickname;
  final String photoUrl;
  final double lat;
  final double lng;
  final int updatedAt;

  const _UserLocation({
    required this.uid,
    required this.nickname,
    required this.photoUrl,
    required this.lat,
    required this.lng,
    required this.updatedAt,
  });
}
