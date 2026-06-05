import 'package:flutter/material.dart';
import 'package:flutter_chat_demo/constants/constants.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

class LocationShareResult {
  const LocationShareResult({
    required this.lat,
    required this.lng,
    required this.shareLive,
  });

  final double lat;
  final double lng;
  final bool shareLive;
}

class LocationSharePickerPage extends StatefulWidget {
  const LocationSharePickerPage({super.key, this.title = 'Enviar ubicación'});

  final String title;

  @override
  State<LocationSharePickerPage> createState() => _LocationSharePickerPageState();
}

class _LocationSharePickerPageState extends State<LocationSharePickerPage> {
  final MapController _mapController = MapController();
  final TextEditingController _searchController = TextEditingController();

  bool _loading = true;
  LatLng _selected = const LatLng(-33.4489, -70.6693);

  @override
  void initState() {
    super.initState();
    _initLocation();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _initLocation() async {
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        if (mounted) setState(() => _loading = false);
        return;
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        if (mounted) setState(() => _loading = false);
        return;
      }

      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
      );
      final target = LatLng(pos.latitude, pos.longitude);

      if (!mounted) return;
      setState(() {
        _selected = target;
        _loading = false;
      });

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        try {
          _mapController.move(target, 16);
        } catch (_) {}
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _openGoogleMaps() async {
    final uri = Uri.parse(
      'https://www.google.com/maps/search/?api=1&query=${_selected.latitude},${_selected.longitude}',
    );
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  void _sendCurrent() {
    Navigator.pop(
      context,
      LocationShareResult(
        lat: _selected.latitude,
        lng: _selected.longitude,
        shareLive: false,
      ),
    );
  }

  void _sendLive() {
    Navigator.pop(
      context,
      LocationShareResult(
        lat: _selected.latitude,
        lng: _selected.longitude,
        shareLive: true,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0.2,
        foregroundColor: Colors.black,
        title: Text(widget.title),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
            child: TextField(
              controller: _searchController,
              readOnly: true,
              onTap: () => Fluttertoast.showToast(msg: 'Búsqueda por dirección: próximamente'),
              decoration: InputDecoration(
                hintText: 'Buscar o escribir dirección',
                prefixIcon: const Icon(Icons.search),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                filled: true,
                fillColor: const Color(0xFFF2F3F5),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12),
              ),
            ),
          ),
          Expanded(
            child: Stack(
              children: [
                FlutterMap(
                  mapController: _mapController,
                  options: MapOptions(
                    initialCenter: _selected,
                    initialZoom: 15,
                    onPositionChanged: (_, hasGesture) {
                      if (!hasGesture) return;
                      final c = _mapController.camera.center;
                      setState(() => _selected = c);
                    },
                  ),
                  children: [
                    TileLayer(
                      urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                      userAgentPackageName: 'com.lamano.clonewhatsapp',
                    ),
                  ],
                ),
                const IgnorePointer(
                  child: Center(
                    child: Icon(Icons.location_on, color: Colors.red, size: 42),
                  ),
                ),
                Positioned(
                  right: 12,
                  top: 12,
                  child: FloatingActionButton.small(
                    heroTag: 'gps_center_picker',
                    backgroundColor: Colors.white,
                    onPressed: _initLocation,
                    child: const Icon(Icons.gps_fixed, color: ColorConstants.primaryColor),
                  ),
                ),
                if (_loading)
                  const Positioned.fill(
                    child: ColoredBox(
                      color: Color(0x55000000),
                      child: Center(
                        child: CircularProgressIndicator(color: ColorConstants.primaryColor),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 14),
            decoration: const BoxDecoration(
              color: Color(0xFFF5F5F7),
              border: Border(top: BorderSide(color: Color(0xFFE3E3E8))),
            ),
            child: Column(
              children: [
                ListTile(
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  tileColor: Colors.white,
                  leading: const CircleAvatar(
                    backgroundColor: Color(0xFFE9F7EF),
                    child: Icon(Icons.near_me, color: Colors.green),
                  ),
                  title: const Text('Compartir ubicación en tiempo real'),
                  subtitle: const Text('Los demás verán tus movimientos', style: TextStyle(fontSize: 12)),
                  onTap: _sendLive,
                ),
                const SizedBox(height: 8),
                ListTile(
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  tileColor: Colors.white,
                  leading: const CircleAvatar(
                    backgroundColor: Color(0xFFE8F0FE),
                    child: Icon(Icons.my_location, color: Colors.blue),
                  ),
                  title: const Text('Enviar mi ubicación seleccionada'),
                  subtitle: Text(
                    '${_selected.latitude.toStringAsFixed(5)}, ${_selected.longitude.toStringAsFixed(5)}',
                    style: const TextStyle(fontSize: 12),
                  ),
                  onTap: _sendCurrent,
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _openGoogleMaps,
                  icon: const Icon(Icons.open_in_new),
                  label: const Text('Abrir esta ubicación en Google Maps'),
                  style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(44)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}