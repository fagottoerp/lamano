import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_chat_demo/constants/constants.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

class MapaMundisPage extends StatefulWidget {
  const MapaMundisPage({super.key});

  @override
  State<MapaMundisPage> createState() => _MapaMundisPageState();
}

class _MapaMundisPageState extends State<MapaMundisPage> {
  static const LatLng _chileCenter = LatLng(-35.6751, -71.5430);

  final MapController _mapController = MapController();
  final Distance _distance = const Distance();

  List<_Comisaria> _allStations = const [];
  Position? _myPosition;
  bool _loading = true;
  String? _error;
  bool _focusedOnce = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final stationsFuture = _loadStations();
      final locationFuture = _resolveLocation();
      final results = await Future.wait([stationsFuture, locationFuture]);
      if (!mounted) return;
      setState(() {
        _allStations = results[0] as List<_Comisaria>;
        _myPosition = results[1] as Position?;
        _loading = false;
      });
      _focusInitial();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'No se pudo cargar el Mapa Mundis (GTA).';
      });
    }
  }

  Future<List<_Comisaria>> _loadStations() async {
    final raw = await rootBundle.loadString('assets/carabineros_stations.json');
    final data = jsonDecode(raw) as Map<String, dynamic>;
    final list = (data['stations'] as List<dynamic>? ?? const [])
        .cast<Map<String, dynamic>>()
        .map(_Comisaria.fromJson)
        .toList();
    return list;
  }

  Future<Position?> _resolveLocation() async {
    try {
      var serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) return null;

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return null;
      }

      final last = await Geolocator.getLastKnownPosition();
      if (last != null) return last;
      return Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.medium,
      );
    } catch (_) {
      return null;
    }
  }

  void _focusInitial() {
    if (_focusedOnce) return;
    _focusedOnce = true;

    final hasMe = _myPosition != null;
    final center = hasMe
        ? LatLng(_myPosition!.latitude, _myPosition!.longitude)
        : _chileCenter;
    final zoom = hasMe ? 12.5 : 5.2;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _mapController.move(center, zoom);
    });
  }

  List<_Comisaria> _nearestStations() {
    if (_myPosition == null || _allStations.isEmpty) return const [];
    final myLat = _myPosition!.latitude;
    final myLng = _myPosition!.longitude;

    final sorted = [..._allStations]
      ..sort((a, b) {
        final da = Geolocator.distanceBetween(myLat, myLng, a.lat, a.lng);
        final db = Geolocator.distanceBetween(myLat, myLng, b.lat, b.lng);
        return da.compareTo(db);
      });
    return sorted.take(12).toList();
  }

  Future<void> _openInGoogleMaps(_Comisaria station) async {
    final uri = Uri.parse(
      'https://www.google.com/maps/search/?api=1&query=${station.lat},${station.lng}',
    );
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Text(
            _error!,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.redAccent),
          ),
        ),
      );
    }

    final nearest = _nearestStations();
    final myLatLng = _myPosition == null
        ? null
        : LatLng(_myPosition!.latitude, _myPosition!.longitude);

    final markers = <Marker>[
      ..._allStations.map(
        (s) => Marker(
          point: LatLng(s.lat, s.lng),
          width: 16,
          height: 16,
          child: const Icon(
            Icons.location_on,
            size: 15,
            color: Colors.red,
          ),
        ),
      ),
      if (myLatLng != null)
        Marker(
          point: myLatLng,
          width: 24,
          height: 24,
          child: const Icon(
            Icons.my_location,
            size: 22,
            color: Colors.blue,
          ),
        ),
    ];

    return Column(
      children: [
        Container(
          width: double.infinity,
          color: Colors.white,
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
          child: Row(
            children: [
              const Icon(Icons.map, color: ColorConstants.themeColor, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Mapa Mundis (GTA) · ${_allStations.length} comisarías',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: ColorConstants.textPrimary,
                  ),
                ),
              ),
              if (myLatLng != null)
                TextButton(
                  onPressed: () => _mapController.move(myLatLng, 13),
                  child: const Text('Mi ubicación'),
                ),
            ],
          ),
        ),
        Expanded(
          child: FlutterMap(
            mapController: _mapController,
            options: const MapOptions(
              initialCenter: _chileCenter,
              initialZoom: 5.2,
              minZoom: 4,
              maxZoom: 18,
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.lamano.clonewhatsapp',
              ),
              MarkerLayer(markers: markers),
              if (myLatLng != null)
                CircleLayer(
                  circles: [
                    CircleMarker(
                      point: myLatLng,
                      radius: 40,
                      useRadiusInMeter: true,
                      color: Colors.blue.withValues(alpha: 0.12),
                      borderColor: Colors.blue.withValues(alpha: 0.3),
                      borderStrokeWidth: 1,
                    ),
                  ],
                ),
            ],
          ),
        ),
        if (nearest.isNotEmpty)
          Container(
            height: 120,
            color: Colors.white,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.all(10),
              itemBuilder: (_, i) {
                final st = nearest[i];
                final m = _distance.as(
                  LengthUnit.Kilometer,
                  myLatLng!,
                  LatLng(st.lat, st.lng),
                );
                return InkWell(
                  onTap: () {
                    final p = LatLng(st.lat, st.lng);
                    _mapController.move(p, 14.5);
                  },
                  child: Container(
                    width: 250,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF6F8FA),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: ColorConstants.divider),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          st.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${st.comunaName}, ${st.regionName}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 11, color: Colors.black54),
                        ),
                        const Spacer(),
                        Row(
                          children: [
                            Text(
                              '${m.toStringAsFixed(1)} km',
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                color: ColorConstants.themeColor,
                              ),
                            ),
                            const Spacer(),
                            IconButton(
                              visualDensity: VisualDensity.compact,
                              iconSize: 18,
                              onPressed: () => _openInGoogleMaps(st),
                              icon: const Icon(Icons.navigation_outlined),
                              tooltip: 'Abrir en Google Maps',
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              },
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemCount: nearest.length,
            ),
          ),
      ],
    );
  }
}

class _Comisaria {
  final String stationId;
  final String name;
  final double lat;
  final double lng;
  final String regionName;
  final String comunaName;

  const _Comisaria({
    required this.stationId,
    required this.name,
    required this.lat,
    required this.lng,
    required this.regionName,
    required this.comunaName,
  });

  factory _Comisaria.fromJson(Map<String, dynamic> json) {
    return _Comisaria(
      stationId: (json['stationId'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      lat: (json['lat'] as num).toDouble(),
      lng: (json['lng'] as num).toDouble(),
      regionName: (json['regionName'] ?? '').toString(),
      comunaName: (json['comunaName'] ?? '').toString(),
    );
  }
}
