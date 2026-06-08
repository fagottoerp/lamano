import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/services.dart' show SystemSound, SystemSoundType;
import 'package:flutter_chat_demo/constants/constants.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

class MapaMundisPage extends StatefulWidget {
  const MapaMundisPage({super.key});

  @override
  State<MapaMundisPage> createState() => _MapaMundisPageState();
}

class _MapaMundisPageState extends State<MapaMundisPage>
  with SingleTickerProviderStateMixin {
  static const LatLng _santiagoCenter = LatLng(-33.4489, -70.6693);
  static const String _alertsCollection = 'citizen_alerts';
  static const String _geoZonesCollection = 'geo_zones';
  static const String _priorityTemplatesApiUrl =
      'http://38.247.147.220/lamano/api_priority_alert_templates.php';
    static const String _wazeProxyApiUrl =
      'http://38.247.147.220/lamano/api_waze_alerts_proxy.php';
      static const String _poisApiUrl =
        'http://38.247.147.220/lamano/api_pois.php';
    static const String _safePlacesCollection = 'safe_places';

  static final List<_AlertCategory> _categories = [
    _AlertCategory('bache', 'Bache en la via', Icons.construction, Colors.orange),
    _AlertCategory('accidente', 'Accidente de transito', Icons.car_crash, Colors.red),
    _AlertCategory('vehiculo_detenido', 'Vehiculo detenido', Icons.car_repair, Colors.amber),
    _AlertCategory('control_policial', 'Control policial', Icons.local_police, Colors.indigo),
    _AlertCategory('corte_calle', 'Corte de calle', Icons.block, Colors.deepOrange),
    _AlertCategory('objeto_peligroso', 'Objeto peligroso', Icons.warning_amber, Colors.brown),
    _AlertCategory('falta_combustible', 'Falta de combustible', Icons.local_gas_station, Colors.teal, isHelp: true),
    _AlertCategory('ayuda_mecanica', 'Ayuda mecanica', Icons.build_circle, Colors.green, isHelp: true),
    _AlertCategory('asistencia_basica', 'Asistencia basica', Icons.handshake, Colors.lightGreen, isHelp: true),
    _AlertCategory('emergencia_menor', 'Emergencia menor', Icons.health_and_safety, Colors.purple, isHelp: true),
  ];

  static const List<_AlertVisualOption> _adminCustomIconOptions = [
    _AlertVisualOption('warning', Icons.warning_amber_rounded, Color(0xFFD84315)),
    _AlertVisualOption('police', Icons.local_police, Color(0xFF1E4E8A)),
    _AlertVisualOption('accident', Icons.car_crash, Color(0xFFC62828)),
    _AlertVisualOption('roadblock', Icons.block, Color(0xFF6D4C41)),
    _AlertVisualOption('fire', Icons.local_fire_department, Color(0xFFFF6F00)),
    _AlertVisualOption('medical', Icons.medical_services, Color(0xFF2E7D32)),
    _AlertVisualOption('traffic', Icons.traffic, Color(0xFFF9A825)),
    _AlertVisualOption('camera', Icons.videocam, Color(0xFF455A64)),
  ];

  final MapController _mapController = MapController();
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FlutterLocalNotificationsPlugin _localNotif = FlutterLocalNotificationsPlugin();

  StreamSubscription<QuerySnapshot>? _alertsSub;
  StreamSubscription<QuerySnapshot>? _zonesSub;
  StreamSubscription<QuerySnapshot>? _safePlacesSub;
  StreamSubscription<Position>? _positionSub;
  Timer? _dispatchRotateTimer;
  Timer? _alertVisibilityTimer;
  Timer? _proximityBannerTimer;
  late final AnimationController _scannerCtrl;

  List<_Comisaria> _allStations = const [];
  List<_CitizenAlert> _activeAlerts = const [];
  List<_CitizenAlert> _allFetchedAlerts = const [];
  List<_AlertCategory> _priorityCategories = const [];
  List<_GeoZone> _geoZones = const [];
  List<_SafePlace> _safePlaces = const [];
  List<Map<String, dynamic>> _pois = const [];

  Position? _myPosition;
  bool _loading = true;
  String? _error;
  bool _focusedOnce = false;
  LatLng _mapCenter = _santiagoCenter;
  double _mapZoom = 9.2;

  bool _pickPointOnMap = false;
  bool _pickWazePointOnMap = false;
  bool _wazeLoading = false;
  final int _wazeRadiusMeters = 1000;
  _AlertCategory? _pendingCategory;
  String _pendingNote = '';
  _AlertPublishConfig? _pendingPublishConfig;
  String _pendingCustomLabel = '';
  String? _pendingCustomIconKey;
  XFile? _pendingCreatePhoto;
  bool _pendingForcePriority = false;
  bool _pendingForceApproved = false;

  final Set<String> _notifiedNearAlerts = <String>{};
  final Set<String> _notifiedGlobalAlerts = <String>{};
  final Set<String> _insideInstitutionRadius = <String>{};
  final Set<String> _insideAlertRadius = <String>{};
  final Set<String> _insideZoneRadius = <String>{};
  final Map<String, int> _userReputation = <String, int>{};
  int _dispatchIndex = 0;
  bool _alertsPrimed = false;
  bool _isAdmin = false;
  bool _drawZoneMode = false;
  List<LatLng> _zoneDraftPoints = const [];
  String _zoneDraftName = '';
  Color _zoneDraftColor = const Color(0xFFD32F2F);
  String _currentNickname = 'Usuario';
  double _headingDeg = 0;
  bool _hasHeading = false;
  final bool _autoRotateMap = true;
  _MobileMapMode _mobileMapMode = _MobileMapMode.roadmap;
  String? _proximityBannerTitle;
  String? _proximityBannerBody;
  IconData _proximityBannerIcon = Icons.warning_amber_rounded;
  Color _proximityBannerColor = const Color(0xFFC62828);

  // Layer visibility state for mobile filter UI
  final Map<String, bool> _layerVisible = {
    'map': true,
    'carabineros': true,
    'pdi': true,
    'bencineras': true,
    'pois': true,
    'criticos': true,
    'peajes': true,
    'citizen': true,
    'rapidas': true,
    'zones': true,
    'traffic': false,
    'transit': false,
    'bike': false,
  };

  @override
  void initState() {
    super.initState();
    _scannerCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    )
      ..addListener(() {
        if (mounted) setState(() {});
      })
      ..repeat();
    _init();
  }

  Widget _layerChip(String emoji, String label, String key) {
    final active = _layerVisible[key] == true;
    return GestureDetector(
      onTap: () {
        setState(() {
          _layerVisible[key] = !active;
        });
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: active ? Colors.green.withValues(alpha: 0.12) : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: active ? Colors.green : Colors.black12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(emoji),
            const SizedBox(width: 6),
            Text(label, style: TextStyle(fontSize: 13, color: active ? Colors.black : Colors.grey[700])),
          ],
        ),
      ),
    );
  }

  Future<void> _openFiltersSheet() async {
    await showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Filtrar capas', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _buildFilterChip('👮', 'Carabineros', 'carabineros'),
                  _buildFilterChip('🛡️', 'PDI', 'pdi'),
                  _buildFilterChip('⛽', 'Bencineras', 'bencineras'),
                  _buildFilterChip('📍', 'POIs', 'pois'),
                  _buildFilterChip('🚨', 'Críticos', 'criticos'),
                  _buildFilterChip('🛣️', 'Peajes', 'peajes'),
                  _buildFilterChip('📣', 'Alertas', 'citizen'),
                  _buildFilterChip('⚡', 'Rápidas', 'rapidas'),
                  _buildFilterChip('🧭', 'Zonas', 'zones'),
                ],
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Listo'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  FilterChip _buildFilterChip(String emoji, String label, String key) {
    final active = _layerVisible[key] == true;
    return FilterChip(
      label: Text('$emoji $label'),
      selected: active,
      onSelected: (selected) {
        setState(() {
          _layerVisible[key] = selected;
        });
      },
    );
  }

  @override
  void dispose() {
    _alertsSub?.cancel();
    _zonesSub?.cancel();
    _safePlacesSub?.cancel();
    _positionSub?.cancel();
    _dispatchRotateTimer?.cancel();
    _alertVisibilityTimer?.cancel();
    _proximityBannerTimer?.cancel();
    _scannerCtrl.dispose();
    super.dispose();
  }

  void _showProximityBanner({
    required String title,
    required String body,
    required IconData icon,
    required Color color,
  }) {
    _proximityBannerTimer?.cancel();
    if (!mounted) return;
    setState(() {
      _proximityBannerTitle = title;
      _proximityBannerBody = body;
      _proximityBannerIcon = icon;
      _proximityBannerColor = color;
    });

    _proximityBannerTimer = Timer(const Duration(seconds: 6), () {
      if (!mounted) return;
      setState(() {
        _proximityBannerTitle = null;
        _proximityBannerBody = null;
      });
    });
  }

  Future<void> _init() async {
    try {
      await _initLocalNotifications();
      await _loadUserContext();

      final stationsFuture = _loadStations();
      final locationFuture = _resolveLocation();
      final templatesFuture = _loadPriorityCategories();
      final poisFuture = _loadPoisFromApi();
      final results = await Future.wait([stationsFuture, locationFuture, templatesFuture, poisFuture]);

      if (!mounted) return;
      setState(() {
        _allStations = results[0] as List<_Comisaria>;
        _myPosition = results[1] as Position?;
        _priorityCategories = results[2] as List<_AlertCategory>;
        _pois = (results[3] as List<Map<String, dynamic>>);
        if (_myPosition != null) {
          _mapCenter = LatLng(_myPosition!.latitude, _myPosition!.longitude);
          _mapZoom = 12.5;
        }
        _loading = false;
      });

      _focusInitial();
      _listenLiveAlerts();
      _listenGeoZones();
      _listenSafePlaces();
      _startPositionTracking();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'No se pudo cargar la Red de Información Operativa.';
      });
    }
  }

  Future<void> _loadUserContext() async {
    final prefs = await SharedPreferences.getInstance();
    final role = (prefs.getString(FirestoreConstants.aboutMe) ?? '').toLowerCase();
    final rolId = prefs.getString(FirestoreConstants.rolId) ?? '';
    final nickname = prefs.getString(FirestoreConstants.nickname) ?? 'Usuario';
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';

    _currentNickname = nickname;
    _isAdmin = rolId == '1' || role.contains('admin') || uid == AppConstants.adminFirebaseUid;
  }

  Future<List<_AlertCategory>> _loadPriorityCategories() async {
    try {
      final uri = Uri.parse(_priorityTemplatesApiUrl);
      final resp = await http.get(uri);
      if (resp.statusCode != 200) return const [];
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final ok = data['ok'] == true;
      if (!ok) return const [];
      final rows = (data['templates'] as List<dynamic>? ?? const []);
      return rows
          .cast<Map<String, dynamic>>()
          .map((row) => _AlertCategory(
                (row['key'] ?? '').toString(),
                (row['label'] ?? '').toString(),
                Icons.priority_high,
                const Color(0xFFC62828),
                isHelp: row['isHelp'] == true,
                isPriorityTemplate: true,
                sortOrder: (row['sortOrder'] as num?)?.toInt() ?? 0,
              ))
          .toList()
        ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    } catch (_) {
      return const [];
    }
  }

  List<_AlertCategory> _categoriesForCreate() {
    if (_priorityCategories.isEmpty) return _categories;
    return [..._priorityCategories, ..._categories];
  }

  bool get _isCustomAdminEnabled => _isAdmin;

  _AlertCategory _categoryByKey(String key) {
    return _categoriesForCreate().firstWhere(
      (c) => c.key == key,
      orElse: () => const _AlertCategory('otro', 'Alerta', Icons.warning, Colors.red),
    );
  }

  _AlertVisualOption? _customIconByKey(String? key) {
    if (key == null || key.isEmpty) return null;
    for (final opt in _adminCustomIconOptions) {
      if (opt.key == key) return opt;
    }
    return null;
  }

  IconData _alertIcon(_CitizenAlert alert, _AlertCategory category) {
    if (alert.customIconKey != null) {
      return _customIconByKey(alert.customIconKey)?.icon ?? Icons.warning_amber_rounded;
    }
    if (alert.isHelp) {
      return alert.helperMembers.isEmpty ? Icons.help_center : Icons.handshake;
    }
    return category.icon;
  }

  Color _alertIconColor(_CitizenAlert alert, _AlertCategory category) {
    if (alert.customIconKey != null) {
      return _customIconByKey(alert.customIconKey)?.color ?? const Color(0xFFD84315);
    }
    if (alert.isHelp) {
      return alert.helperMembers.isEmpty ? Colors.deepPurple : Colors.green;
    }
    return category.color;
  }

  Future<void> _initLocalNotifications() async {
    await _localNotif.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('app_icon'),
        iOS: DarwinInitializationSettings(),
      ),
    );

    final ios = _localNotif.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>();
    await ios?.requestPermissions(alert: true, badge: true, sound: true);
    final mac = _localNotif.resolvePlatformSpecificImplementation<MacOSFlutterLocalNotificationsPlugin>();
    await mac?.requestPermissions(alert: true, badge: true, sound: true);
  }

  Future<List<_Comisaria>> _loadStations() async {
    final assets = <String>[
      'assets/carabineros_stations.json',
      'assets/pdi_stations.json',
      'assets/bencineras_chile.json',
      'assets/critical_points.json',
      'assets/peajes_porticos_preview.json',
    ];
    final list = <_Comisaria>[];

    for (final asset in assets) {
      try {
        final raw = await rootBundle.loadString(asset);
        final data = jsonDecode(raw) as Map<String, dynamic>;
        final stations = (data['stations'] as List<dynamic>? ?? const [])
            .cast<Map<String, dynamic>>()
            .map(_Comisaria.fromJson)
            .toList();
        list.addAll(stations);
      } catch (_) {
        // Keep map working if one source is temporarily unavailable.
      }
    }

    return list;
  }

  Future<List<Map<String, dynamic>>> _loadPoisFromApi() async {
    try {
      final uri = Uri.parse(_poisApiUrl);
      final resp = await http.get(uri).timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) return const [];
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final rows = (data['pois'] as List<dynamic>? ?? const []);
      return rows
          .map((e) => Map<String, dynamic>.from(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  String _weekdayKeyNow() {
    final d = DateTime.now().weekday; // 1 = Mon, 7 = Sun
    switch (d) {
      case DateTime.monday:
        return 'mon';
      case DateTime.tuesday:
        return 'tue';
      case DateTime.wednesday:
        return 'wed';
      case DateTime.thursday:
        return 'thu';
      case DateTime.friday:
        return 'fri';
      case DateTime.saturday:
        return 'sat';
      case DateTime.sunday:
      default:
        return 'sun';
    }
  }

  bool _isPoiOpen(Map<String, dynamic> poi) {
    try {
      final ohRaw = poi['opening_hours'];
      if (ohRaw == null) return false;
      final Map<String, dynamic> oh = Map<String, dynamic>.from(ohRaw as Map);
      final dayKey = _weekdayKeyNow();
      final today = (oh[dayKey] as List<dynamic>?)?.cast<String>() ?? <String>[];
      if (today.isEmpty) return false;
      final now = DateTime.now();
      final partsOpen = today[0].split(':');
      final partsClose = today.length > 1 ? today[1].split(':') : null;
      if (partsOpen.length < 2) return false;
      final open = DateTime(now.year, now.month, now.day, int.parse(partsOpen[0]), int.parse(partsOpen[1]));
      DateTime close;
      if (partsClose == null || partsClose.length < 2) {
        close = open.add(const Duration(hours: 24));
      } else {
        close = DateTime(now.year, now.month, now.day, int.parse(partsClose[0]), int.parse(partsClose[1]));
      }
      if (close.isBefore(open)) {
        // crosses midnight
        if (now.isAfter(open) || now.isBefore(close)) return true;
        return false;
      }
      return now.isAfter(open) && now.isBefore(close);
    } catch (_) {
      return false;
    }
  }

  Future<void> _showPoiDetails(Map<String, dynamic> poi) async {
    if (!mounted) return;
    var enriched = Map<String, dynamic>.from(poi);
    bool fetchedDetails = false;

    // If no opening_hours or phone info, try server-side Places lookup
    if ((enriched['opening_hours'] == null || enriched['opening_hours'] == {}) &&
        (enriched['phone'] == null && enriched['formatted_phone_number'] == null && enriched['tel'] == null)) {
      try {
        final lat = (enriched['lat'] as num).toDouble();
        final lng = (enriched['lng'] as num).toDouble();
        final uri = Uri.parse('http://38.247.147.220/lamano/api_poi_details.php?lat=$lat&lng=$lng');
        final resp = await http.get(uri).timeout(const Duration(seconds: 8));
        if (resp.statusCode == 200) {
          final data = jsonDecode(resp.body) as Map<String, dynamic>;
          if (data['ok'] == true && data['place'] is Map<String, dynamic>) {
            final place = Map<String, dynamic>.from(data['place'] as Map);
            // Normalize fields into our enriched map
            if (place.containsKey('formatted_phone_number')) enriched['phone'] = place['formatted_phone_number'];
            if (place.containsKey('formatted_address')) enriched['address'] = place['formatted_address'];
            if (place.containsKey('opening_hours')) enriched['place_opening_hours'] = place['opening_hours'];
            if (place.containsKey('plus_code')) enriched['plus_code'] = place['plus_code'];
            fetchedDetails = true;
          }
        }
      } catch (_) {
        // ignore
      }
    }

    final name = (enriched['name'] ?? 'Punto') as String;
    final category = (enriched['category'] ?? 'otro') as String;

    final openNow = fetchedDetails && enriched['place_opening_hours'] != null
        ? (enriched['place_opening_hours']['open_now'] == true)
        : _isPoiOpen(enriched);

    showModalBottomSheet(
      context: context,
      builder: (ctx) {
        String todayHours = 'Horario no disponible';
        if (fetchedDetails && enriched['place_opening_hours'] is Map) {
          final oh = Map<String, dynamic>.from(enriched['place_opening_hours'] as Map);
          if (oh['weekday_text'] is List) {
            final list = (oh['weekday_text'] as List).cast<String>();
            final wk = DateTime.now().weekday; // 1..7
            final idx = (wk % 7); // because Google starts with Sunday in our other logic
            if (idx >= 0 && idx < list.length) {
              todayHours = list[idx];
            } else {
              todayHours = list.join(' · ');
            }
          }
        } else {
          final k = _weekdayKeyNow();
          final opening = enriched['opening_hours'] ?? {};
          final today = (opening[k] as List<dynamic>?)?.cast<String>() ?? [];
          if (today.isEmpty) todayHours = 'Cerrado hoy';
          else todayHours = '${today[0]} - ${today.length > 1 ? today[1] : ''}';
        }

        final phone = (enriched['phone'] ?? enriched['formatted_phone_number'] ?? enriched['tel'] ?? '') as String;
        final address = (enriched['address'] ?? enriched['vicinity'] ?? enriched['formatted_address'] ?? '') as String;
        final plus = (enriched['plus_code'] is Map) ? (enriched['plus_code']['global_code'] ?? enriched['plus_code']['compound_code']) : (enriched['plus_code'] ?? '');

        return Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(child: Text(name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: openNow ? Colors.green[600] : Colors.grey[300],
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(openNow ? 'Abierto' : 'Cerrado', style: TextStyle(color: openNow ? Colors.white : Colors.black87)),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text('Categoría: ' + category.replaceAll('_', ' ')),
              const SizedBox(height: 8),
              const Text('Horario (hoy):', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Text(todayHours),
              if (address.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(address, style: const TextStyle(color: Colors.grey)),
              ],
              if (phone.isNotEmpty) ...[
                const SizedBox(height: 8),
                GestureDetector(
                  onTap: () async {
                    final uri = Uri.parse('tel:${phone.replaceAll(RegExp(r"\\s+"), '')}');
                    if (await canLaunchUrl(uri)) await launchUrl(uri);
                  },
                  child: Text('📞 ' + phone, style: const TextStyle(color: Colors.blueAccent)),
                ),
              ],
              if (plus != null && plus.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text('🔢 ' + plus, style: const TextStyle(color: Colors.grey)),
              ],
              const SizedBox(height: 10),
              Row(
                children: [
                  ElevatedButton.icon(
                    onPressed: () async {
                      Navigator.of(context).pop();
                      final lat = (enriched['lat'] as num).toDouble();
                      final lng = (enriched['lng'] as num).toDouble();
                      _mapController.move(LatLng(lat, lng), 16);
                    },
                    icon: const Icon(Icons.place),
                    label: const Text('Ir al lugar'),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    onPressed: () async {
                      Navigator.of(context).pop();
                      final lat = (enriched['lat'] as num).toDouble();
                      final lng = (enriched['lng'] as num).toDouble();
                      final uri = Uri.parse('https://www.google.com/maps/dir/?api=1&destination=$lat,$lng');
                      if (await canLaunchUrl(uri)) await launchUrl(uri);
                    },
                    icon: const Icon(Icons.directions),
                    label: const Text('Cómo llegar'),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    onPressed: () async {
                      Navigator.of(context).pop();
                      final lat = (enriched['lat'] as num).toDouble();
                      final lng = (enriched['lng'] as num).toDouble();
                      await _markPlaceAsSafe(LatLng(lat, lng), name: name);
                    },
                    icon: const Icon(Icons.shield),
                    label: const Text('Marcar como seguro'),
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
                  ),
                ],
              ),
              const SizedBox(height: 12),
            ],
          ),
        );
      },
    );
  }

  Future<Position?> _resolveLocation() async {
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
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
        locationSettings:
            const LocationSettings(accuracy: LocationAccuracy.medium),
      );
    } catch (_) {
      return null;
    }
  }

  void _startPositionTracking() {
    _positionSub?.cancel();
    _positionSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.medium,
        distanceFilter: 40,
      ),
    ).listen((p) {
      if (!mounted) return;
      setState(() {
        _myPosition = p;
        final h = p.heading;
        if (h.isFinite && h >= 0) {
          _headingDeg = h % 360;
          _hasHeading = true;
        }
      });
      _syncMapOrientationFromHeading();
      _maybeNotifyNearbyAlerts();
      _maybeNotifyNearbyZones();
      _maybeNotifyNearbyInstitutions();
      _syncHelperLocationForActiveAlerts(p);
    });
  }

  void _syncMapOrientationFromHeading() {
    if (!_autoRotateMap || !_hasHeading) return;
    try {
      final current = _mapController.camera.rotation;
      final target = _headingDeg;
      var diff = (target - current).abs();
      if (diff > 180) diff = 360 - diff;
      if (diff < 3) return;
      _mapController.rotate(target);
    } catch (_) {
      // MapController might not be attached yet during first location ticks.
    }
  }

  Future<void> _syncHelperLocationForActiveAlerts(Position p) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null || uid.isEmpty) return;
    final helping = _activeAlerts.where((a) => a.helperMembers.any((h) => h.uid == uid)).toList();
    for (final alert in helping) {
      final doc = _firestore.collection(_alertsCollection).doc(alert.id);
      await _firestore.runTransaction((tx) async {
        final snap = await tx.get(doc);
        if (!snap.exists) return;
        final data = snap.data() as Map<String, dynamic>;
        final raw = (data['helperMembers'] as List<dynamic>? ?? const []);
        final next = raw.map((entry) => Map<String, dynamic>.from(entry as Map)).toList();
        final idx = next.indexWhere((entry) => '${entry['uid']}' == uid);
        if (idx == -1) return;
        next[idx]['lat'] = p.latitude;
        next[idx]['lng'] = p.longitude;
        next[idx]['updatedAtMs'] = DateTime.now().millisecondsSinceEpoch;
        tx.update(doc, {'helperMembers': next});
      });
    }
  }

  void _listenLiveAlerts() {
    _alertsSub?.cancel();
    _alertVisibilityTimer?.cancel();
    _alertsSub = _firestore
        .collection(_alertsCollection)
        .where('status', isEqualTo: 'active')
        .snapshots()
        .listen((snap) {
      if (!mounted) return;
      final parsed = <_CitizenAlert>[];
      for (final doc in snap.docs) {
        try {
          parsed.add(_CitizenAlert.fromDoc(doc));
        } catch (_) {
          // Skip malformed alert docs to keep real-time stream alive.
        }
      }
      _allFetchedAlerts = parsed;
      _applyAlertVisibility();
    });

    _alertVisibilityTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!mounted) return;
      _applyAlertVisibility();
    });
  }

  void _listenGeoZones() {
    _zonesSub?.cancel();
    _zonesSub = _firestore
        .collection(_geoZonesCollection)
        .where('status', isEqualTo: 'active')
        .snapshots()
        .listen((snap) {
      if (!mounted) return;
      final zones = snap.docs
          .map(_GeoZone.fromDoc)
          .where((z) => z.points.length >= 3)
          .toList()
        ..sort((a, b) => b.createdAtMs.compareTo(a.createdAtMs));
      setState(() => _geoZones = zones);
      _maybeNotifyNearbyZones();
    });
  }

  void _listenSafePlaces() {
    _safePlacesSub?.cancel();
    _safePlacesSub = _firestore.collection(_safePlacesCollection).where('status', isEqualTo: 'active').snapshots().listen((snap) {
      if (!mounted) return;
      final list = <_SafePlace>[];
      for (final doc in snap.docs) {
        try {
          list.add(_SafePlace.fromDoc(doc));
        } catch (_) {}
      }
      setState(() => _safePlaces = list);
    }, onError: (_) {});
  }

  void _startZoneDrawMode({required String name, required Color color}) {
    if (!_isAdmin) return;
    setState(() {
      _drawZoneMode = true;
      _zoneDraftName = name;
      _zoneDraftPoints = const [];
      _zoneDraftColor = color;
      _pickPointOnMap = false;
      _pendingCategory = null;
      _pendingNote = '';
      _pendingPublishConfig = null;
      _pendingCustomLabel = '';
      _pendingCustomIconKey = null;
      _pendingCreatePhoto = null;
      _pendingForcePriority = false;
      _pendingForceApproved = false;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Modo delimitación activo: toca el mapa para agregar puntos.')),
    );
  }

  Future<void> _openZoneDrawSetupSheet() async {
    if (!_isAdmin) return;
    final nameCtrl = TextEditingController(text: _zoneDraftName);
    var selectedColor = _zoneDraftColor;

    final start = await showModalBottomSheet<bool>(
          context: context,
          isScrollControlled: true,
          builder: (_) => StatefulBuilder(
            builder: (context, setModalState) => Padding(
              padding: EdgeInsets.only(
                left: 16,
                right: 16,
                top: 16,
                bottom: MediaQuery.of(context).viewInsets.bottom + 16,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Dibujar delimitación',
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: nameCtrl,
                    maxLength: 80,
                    decoration: const InputDecoration(
                      labelText: 'Nombre o delimitación',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text('Selecciona color', style: TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      const Color(0xFFD32F2F),
                      const Color(0xFFF57C00),
                      const Color(0xFFFBC02D),
                      const Color(0xFF2E7D32),
                      const Color(0xFF1565C0),
                    ]
                        .map(
                          (c) => ChoiceChip(
                            selected: selectedColor.toARGB32() == c.toARGB32(),
                            onSelected: (_) => setModalState(() => selectedColor = c),
                            label: Container(
                              width: 16,
                              height: 16,
                              decoration: BoxDecoration(
                                color: c,
                                borderRadius: BorderRadius.circular(999),
                              ),
                            ),
                          ),
                        )
                        .toList(),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => Navigator.of(context).pop(false),
                          child: const Text('Cancelar'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: FilledButton(
                          onPressed: () => Navigator.of(context).pop(true),
                          child: const Text('Dibujar'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ) ??
        false;

    final name = nameCtrl.text.trim();
    nameCtrl.dispose();
    if (!mounted || !start) return;
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Debes ingresar un nombre para la delimitación.')),
      );
      return;
    }
    _startZoneDrawMode(name: name, color: selectedColor);
  }

  void _undoZonePoint() {
    if (_zoneDraftPoints.isEmpty) return;
    setState(() {
      _zoneDraftPoints = _zoneDraftPoints.sublist(0, _zoneDraftPoints.length - 1);
    });
  }

  void _clearZoneDraft({bool exitMode = false}) {
    setState(() {
      _zoneDraftPoints = const [];
      if (exitMode) {
        _drawZoneMode = false;
        _zoneDraftName = '';
      }
    });
  }

  String _colorToHex(Color color) {
    final value = color.toARGB32() & 0x00FFFFFF;
    return '#${value.toRadixString(16).padLeft(6, '0').toUpperCase()}';
  }

  Future<void> _saveZoneDraft() async {
    if (!_isAdmin) return;
    if (_zoneDraftPoints.length < 3) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Debes marcar al menos 3 puntos para cerrar la zona.')),
      );
      return;
    }

    final name = _zoneDraftName.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Debes ingresar un nombre para la delimitación.')),
      );
      return;
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    final ref = await _firestore.collection(_geoZonesCollection).add({
      'name': name,
      'color': _colorToHex(_zoneDraftColor),
      'points': _zoneDraftPoints
          .map((p) => {'lat': p.latitude, 'lng': p.longitude})
          .toList(),
      'status': 'active',
      'isPermanent': true,
      'createdAtMs': now,
      'createdByUid': uid,
      'createdByName': _currentNickname,
    });

    // After creating, open edit sheet to allow adding schedules immediately
    try {
      final doc = await ref.get();
      final data = (doc.data() as Map<String, dynamic>?) ?? <String, dynamic>{};
      final rawPoints = (data['points'] as List<dynamic>? ?? const []);
      final points = rawPoints
          .map((p) => Map<String, dynamic>.from(p as Map))
          .map((p) => LatLng((p['lat'] as num?)?.toDouble() ?? 0, (p['lng'] as num?)?.toDouble() ?? 0))
          .where((p) => p.latitude != 0 || p.longitude != 0)
          .toList();
      final schedules = (data['schedules'] as List<dynamic>? ?? const [])
          .map((s) => Map<String, String>.from(s as Map? ?? <String,String>{}))
          .map((m) => <String,String>{'start': (m['start'] ?? '').toString(), 'end': (m['end'] ?? '').toString(), 'risk': (m['risk'] ?? '').toString()})
          .toList();
      final newZone = _GeoZone(id: ref.id, name: (data['name'] ?? 'Zona').toString(), color: _GeoZone._colorFromHex((data['color'] ?? '#D32F2F').toString()), points: points, createdAtMs: (data['createdAtMs'] as num?)?.toInt() ?? 0, schedules: schedules);
      await _openZoneEditSheet(newZone);
    } catch (_) {
      // ignore
    }

    if (!mounted) return;
    setState(() {
      _drawZoneMode = false;
      _zoneDraftPoints = const [];
      _zoneDraftName = '';
      _zoneDraftColor = const Color(0xFFD32F2F);
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Zona delimitada guardada para toda la comunidad.')),
    );
  }

  Future<void> _openZoneManageSheet(_GeoZone zone) async {
    if (!_isAdmin) return;
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Editar delimitación'),
              subtitle: Text(zone.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              onTap: () => Navigator.of(context).pop('edit'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: const Text('Eliminar delimitación', style: TextStyle(color: Colors.red)),
              subtitle: const Text('Se ocultará para todos los usuarios.'),
              onTap: () => Navigator.of(context).pop('delete'),
            ),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );

    if (!mounted || action == null) return;
    if (action == 'edit') {
      await _openZoneEditSheet(zone);
      return;
    }
    if (action == 'delete') {
      await _deleteZone(zone);
    }
  }

  Future<void> _openZonesAdminSheet() async {
    if (!_isAdmin) return;
    if (_geoZones.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No hay delimitaciones activas para gestionar.')),
      );
      return;
    }

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Delimitaciones activas',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 360,
                child: ListView.separated(
                  itemCount: _geoZones.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final zone = _geoZones[index];
                    return ListTile(
                      leading: Container(
                        width: 14,
                        height: 14,
                        decoration: BoxDecoration(
                          color: zone.color,
                          shape: BoxShape.circle,
                        ),
                      ),
                      title: Text(
                        zone.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text('${zone.points.length} puntos'),
                      onTap: () {
                        Navigator.of(context).pop();
                        _focusZone(zone);
                      },
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: 'Editar',
                            onPressed: () {
                              Navigator.of(context).pop();
                              _openZoneEditSheet(zone);
                            },
                            icon: const Icon(Icons.edit_outlined),
                          ),
                          IconButton(
                            tooltip: 'Eliminar',
                            onPressed: () {
                              Navigator.of(context).pop();
                              _deleteZone(zone);
                            },
                            icon: const Icon(Icons.delete_outline, color: Colors.red),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _focusZone(_GeoZone zone) {
    if (zone.points.isEmpty) return;
    final center = zone.labelPoint;
    setState(() {
      _mapCenter = center;
      _mapZoom = 15.0;
    });
    _mapController.move(center, 15.0);
  }

  Future<void> _openZoneEditSheet(_GeoZone zone) async {
    if (!_isAdmin) return;
    final nameCtrl = TextEditingController(text: zone.name);
    var selectedColor = zone.color;

    final res = await showModalBottomSheet<Map<String,dynamic>>(
          context: context,
          isScrollControlled: true,
          builder: (_) => StatefulBuilder(
            builder: (context, setModalState) {
              final startCtrl = TextEditingController();
              final endCtrl = TextEditingController();
              String selectedRisk = 'bajo';
              final schedulesLocal = List<Map<String,String>>.from(zone.schedules);

              void addLocalSchedule() {
                final s = startCtrl.text.trim();
                final e = endCtrl.text.trim();
                if (s.isEmpty || e.isEmpty) return;
                schedulesLocal.add({'start': s, 'end': e, 'risk': selectedRisk});
                startCtrl.text = '';
                endCtrl.text = '';
                setModalState(() {});
              }

              return Padding(
                padding: EdgeInsets.only(
                  left: 16,
                  right: 16,
                  top: 16,
                  bottom: MediaQuery.of(context).viewInsets.bottom + 16,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Editar delimitación',
                      style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: nameCtrl,
                      maxLength: 80,
                      decoration: const InputDecoration(
                        labelText: 'Nombre o delimitación',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text('Color', style: TextStyle(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        const Color(0xFFD32F2F),
                        const Color(0xFFF57C00),
                        const Color(0xFFFBC02D),
                        const Color(0xFF2E7D32),
                        const Color(0xFF1565C0),
                      ]
                          .map(
                            (c) => ChoiceChip(
                              selected: selectedColor.toARGB32() == c.toARGB32(),
                              onSelected: (_) => setModalState(() => selectedColor = c),
                              label: Container(
                                width: 16,
                                height: 16,
                                decoration: BoxDecoration(
                                  color: c,
                                  borderRadius: BorderRadius.circular(999),
                                ),
                              ),
                            ),
                          )
                          .toList(),
                    ),
                    const SizedBox(height: 10),
                    const Text('Horarios y niveles', style: TextStyle(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 6),
                    Row(children: [
                      Expanded(child: TextField(controller: startCtrl, decoration: const InputDecoration(labelText: 'Inicio (HH:MM)'))),
                      const SizedBox(width:8),
                      Expanded(child: TextField(controller: endCtrl, decoration: const InputDecoration(labelText: 'Fin (HH:MM)'))),
                    ],),
                    const SizedBox(height:6),
                    Row(children:[
                      DropdownButton<String>(value: selectedRisk, items: const [DropdownMenuItem(value:'bajo',child:Text('Bajo')),DropdownMenuItem(value:'medio',child:Text('Medio')),DropdownMenuItem(value:'alto',child:Text('Alto'))], onChanged: (v){ if (v!=null) setModalState(()=> selectedRisk = v); }),
                      const SizedBox(width:8),
                      FilledButton(onPressed: addLocalSchedule, child: const Text('Agregar'))
                    ],),
                    const SizedBox(height:8),
                    SizedBox(height:120, child: ListView.builder(itemCount: schedulesLocal.length,itemBuilder: (_,i){ final s = schedulesLocal[i]; return ListTile(title:Text('${s['start']} - ${s['end']} · ${s['risk']}'), trailing: IconButton(icon: const Icon(Icons.delete), onPressed: (){ schedulesLocal.removeAt(i); setModalState((){}); }),); })),
                    const SizedBox(height: 10),
                    Row(children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () async {
                            // mark zone center as safe place
                            final center = zone.labelPoint;
                            await _markPlaceAsSafe(center, name: nameCtrl.text.trim().isEmpty ? zone.name : nameCtrl.text.trim());
                          },
                          child: const Text('Marcar zona como segura'),
                        ),
                      ),
                    ]),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => Navigator.of(context).pop(null),
                            child: const Text('Cancelar'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: FilledButton(
                            onPressed: () => Navigator.of(context).pop({'name': nameCtrl.text.trim(), 'color': _colorToHex(selectedColor), 'schedules': schedulesLocal}),
                            child: const Text('Guardar cambios'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            },
          ),
        ) ??
        null;

    final newName = (res != null && res['name'] != null) ? (res['name']?.toString() ?? '') : nameCtrl.text.trim();
    final newColor = (res != null && res['color'] != null) ? res['color']?.toString() ?? _colorToHex(selectedColor) : _colorToHex(selectedColor);
    final newSchedules = (res != null && res['schedules'] is List) ? (res['schedules'] as List).cast<Map<String,String>>() : null;
    nameCtrl.dispose();
    if (!mounted || res == null) return;
    if (newName.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Debes ingresar un nombre para la delimitación.')),
      );
      return;
    }
    final updateData = {
      'name': newName,
      'color': newColor,
      'updatedAtMs': DateTime.now().millisecondsSinceEpoch,
      'updatedByUid': FirebaseAuth.instance.currentUser?.uid ?? '',
      'updatedByName': _currentNickname,
    };
    if (newSchedules != null) updateData['schedules'] = newSchedules;
    await _firestore.collection(_geoZonesCollection).doc(zone.id).update(updateData);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Delimitación actualizada.')),
    );
  }

  Future<void> _deleteZone(_GeoZone zone) async {
    if (!_isAdmin) return;
    final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Eliminar delimitación'),
            content: Text('¿Seguro que deseas eliminar "${zone.name}" para todos?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Cancelar'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                style: FilledButton.styleFrom(backgroundColor: Colors.red),
                child: const Text('Eliminar'),
              ),
            ],
          ),
        ) ??
        false;
    if (!mounted || !ok) return;

    await _firestore.collection(_geoZonesCollection).doc(zone.id).update({
      'status': 'inactive',
      'deletedAtMs': DateTime.now().millisecondsSinceEpoch,
      'deletedByUid': FirebaseAuth.instance.currentUser?.uid ?? '',
      'deletedByName': _currentNickname,
    });

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Delimitación eliminada para todos.')),
    );
  }

  bool _isAlertVisibleNow(_CitizenAlert alert, int nowMs) {
    if (alert.startAtMs > nowMs || alert.expiresAtMs <= nowMs) return false;
    if (!alert.recurringDaily) return true;

    final minuteNow = (DateTime.now().hour * 60) + DateTime.now().minute;
    final startMinute = alert.scheduleStartMinute;
    final endMinute = alert.scheduleEndMinute;
    if (startMinute == null || endMinute == null) return true;
    if (startMinute == endMinute) return true;
    if (startMinute < endMinute) {
      return minuteNow >= startMinute && minuteNow < endMinute;
    }
    return minuteNow >= startMinute || minuteNow < endMinute;
  }

  void _applyAlertVisibility() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final alerts = _allFetchedAlerts
        .where((a) => _isAlertVisibleNow(a, now))
        .toList()
      ..sort((a, b) {
        if (a.isPermanent != b.isPermanent) {
          return a.isPermanent ? -1 : 1;
        }
        if (a.isPriority != b.isPriority) {
          return a.isPriority ? -1 : 1;
        }
        return b.createdAtMs.compareTo(a.createdAtMs);
      });

    _startDispatchTicker(alerts);
    _rebuildReputation(alerts);
    _notifyGlobalNewAlerts(alerts);
    setState(() {
      _activeAlerts = alerts;
      if (_dispatchIndex >= alerts.length) {
        _dispatchIndex = 0;
      }
    });
    _maybeNotifyNearbyAlerts();
  }

  void _startDispatchTicker(List<_CitizenAlert> alerts) {
    _dispatchRotateTimer?.cancel();
    if (alerts.length <= 1) return;
    _dispatchRotateTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      if (!mounted || _activeAlerts.isEmpty) return;
      setState(() {
        _dispatchIndex = (_dispatchIndex + 1) % _activeAlerts.length;
      });
    });
  }

  void _rebuildReputation(List<_CitizenAlert> alerts) {
    _userReputation
      ..clear()
      ..addEntries(alerts.map((a) {
        final rep = (a.confirmCount * 2) - a.discardCount;
        return MapEntry(a.createdByUid, rep);
      }));
  }

  Future<void> _notifyGlobalNewAlerts(List<_CitizenAlert> alerts) async {
    if (!_alertsPrimed) {
      _notifiedGlobalAlerts.addAll(alerts.map((a) => a.id));
      _alertsPrimed = true;
      return;
    }
    for (final alert in alerts) {
      if (_notifiedGlobalAlerts.contains(alert.id)) continue;
      _notifiedGlobalAlerts.add(alert.id);

      final id = (alert.id.hashCode ^ 0x41f2) & 0x7fffffff;
      await _localNotif.show(
        id: id,
        title: 'Nueva alerta en tiempo real',
        body: '${alert.categoryLabel} · ${alert.createdByName}',
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            'citizen_alerts_global_v1',
            'Alertas globales ciudadanas',
            importance: Importance.high,
            priority: Priority.high,
          ),
          iOS: DarwinNotificationDetails(),
        ),
      );
      SystemSound.play(SystemSoundType.alert);
    }
  }

  void _focusInitial() {
    if (_focusedOnce) return;
    _focusedOnce = true;

    final hasMe = _myPosition != null;
    final center = hasMe
        ? LatLng(_myPosition!.latitude, _myPosition!.longitude)
      : _santiagoCenter;
    final zoom = hasMe ? 15.0 : 11.3;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _mapController.move(center, zoom);
      if (hasMe) {
        _goToMyLocation();
      }
    });
  }

  void _goToMyLocation() {
    if (_myPosition == null) return;
    final me = LatLng(_myPosition!.latitude, _myPosition!.longitude);
    setState(() {
      _mapCenter = me;
      _mapZoom = 15.0;
    });
    _mapController.move(me, 15.0);
    _syncMapOrientationFromHeading();
  }

  Future<void> _centerOnMyLocationFromButton() async {
    if (_myPosition != null) {
      _goToMyLocation();
      return;
    }

    final resolved = await _resolveLocation();
    if (!mounted) return;
    if (resolved == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No se pudo obtener tu ubicación actual.')),
      );
      return;
    }

    setState(() {
      _myPosition = resolved;
    });
    _goToMyLocation();
  }

  String _googleTileLayerCode(_MobileMapMode mode) {
    switch (mode) {
      case _MobileMapMode.satellite:
        return 's';
      case _MobileMapMode.terrain:
        return 'p';
      case _MobileMapMode.roadmap:
        return 'm';
    }
  }

  String _mobileMapModeLabel(_MobileMapMode mode) {
    switch (mode) {
      case _MobileMapMode.satellite:
        return 'Satelite';
      case _MobileMapMode.terrain:
        return 'Relieve';
      case _MobileMapMode.roadmap:
        return 'Mapa';
    }
  }

  List<_Comisaria> _visibleStationsForMap() {
    if (_allStations.isEmpty) return const [];
    final center = _mapCenter;
    final maxCount = switch (_mapZoom) {
      < 7.5 => 80,
      < 9.5 => 180,
      < 11.5 => 320,
      _ => _allStations.length,
    };

    final sorted = [..._allStations]
      ..sort((a, b) {
        final da = _meterDistance(center, LatLng(a.lat, a.lng));
        final db = _meterDistance(center, LatLng(b.lat, b.lng));
        return da.compareTo(db);
      });
    return sorted.take(maxCount).toList();
  }

  double _meterDistance(LatLng a, LatLng b) =>
      Geolocator.distanceBetween(a.latitude, a.longitude, b.latitude, b.longitude);

  Future<void> _maybeNotifyNearbyAlerts() async {
    if (_myPosition == null || _activeAlerts.isEmpty) return;
    if (_isInsideAnySafePlace(_myPosition!)) return; // suppress alerts while inside a safe place

    const triggerRadiusM = 200.0;
    const releaseRadiusM = 240.0;

    final myLat = _myPosition!.latitude;
    final myLng = _myPosition!.longitude;
    final nextInside = <String>{};

    for (final alert in _activeAlerts) {
      final meters = Geolocator.distanceBetween(myLat, myLng, alert.lat, alert.lng);
      if (meters <= releaseRadiusM) {
        nextInside.add(alert.id);
      }

      final wasInside = _insideAlertRadius.contains(alert.id);
      if (wasInside || meters > triggerRadiusM) continue;

      final body = '${alert.categoryLabel} a ${meters.toStringAsFixed(0)} m.';
      final notifId = alert.id.hashCode & 0x7fffffff;

      await _localNotif.show(
        id: notifId,
        title: 'Alerta cercana',
        body: body,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            'citizen_alerts_v1',
            'Alertas ciudadanas',
            importance: Importance.high,
            priority: Priority.high,
          ),
          iOS: DarwinNotificationDetails(),
        ),
      );

      _showProximityBanner(
        title: 'Te estás acercando a una alerta',
        body: body,
        icon: Icons.warning_amber_rounded,
        color: const Color(0xFFD84315),
      );

      _notifiedNearAlerts.add(alert.id);
      SystemSound.play(SystemSoundType.alert);
    }

    _insideAlertRadius
      ..clear()
      ..addAll(nextInside);
  }

  double _pointToSegmentDistanceMeters(LatLng p, LatLng a, LatLng b) {
    const mPerDegLat = 111320.0;
    final avgLatRad = ((a.latitude + b.latitude) / 2) * (math.pi / 180);
    final mPerDegLng = 111320.0 * math.cos(avgLatRad).abs();

    final ax = a.longitude * mPerDegLng;
    final ay = a.latitude * mPerDegLat;
    final bx = b.longitude * mPerDegLng;
    final by = b.latitude * mPerDegLat;
    final px = p.longitude * mPerDegLng;
    final py = p.latitude * mPerDegLat;

    final abx = bx - ax;
    final aby = by - ay;
    final apx = px - ax;
    final apy = py - ay;
    final ab2 = (abx * abx) + (aby * aby);
    if (ab2 <= 0.0001) {
      final dx = px - ax;
      final dy = py - ay;
      return math.sqrt((dx * dx) + (dy * dy));
    }
    final t = ((apx * abx) + (apy * aby)) / ab2;
    final clampedT = t.clamp(0.0, 1.0);
    final qx = ax + (abx * clampedT);
    final qy = ay + (aby * clampedT);
    final dx = px - qx;
    final dy = py - qy;
    return math.sqrt((dx * dx) + (dy * dy));
  }

  bool _pointInPolygon(LatLng p, List<LatLng> polygon) {
    if (polygon.length < 3) return false;
    var inside = false;
    var j = polygon.length - 1;
    for (var i = 0; i < polygon.length; i++) {
      final xi = polygon[i].longitude;
      final yi = polygon[i].latitude;
      final xj = polygon[j].longitude;
      final yj = polygon[j].latitude;
      final intersects = ((yi > p.latitude) != (yj > p.latitude)) &&
          (p.longitude < (xj - xi) * (p.latitude - yi) / ((yj - yi) == 0 ? 0.0000001 : (yj - yi)) + xi);
      if (intersects) inside = !inside;
      j = i;
    }
    return inside;
  }

  double _distanceToZoneMeters(LatLng point, _GeoZone zone) {
    if (zone.points.length < 3) return double.infinity;
    if (_pointInPolygon(point, zone.points)) return 0;

    var minDistance = double.infinity;
    for (var i = 0; i < zone.points.length; i++) {
      final a = zone.points[i];
      final b = zone.points[(i + 1) % zone.points.length];
      final d = _pointToSegmentDistanceMeters(point, a, b);
      if (d < minDistance) minDistance = d;
    }
    return minDistance;
  }

  bool _isInsideAnySafePlace(Position p) {
    try {
      if (_safePlaces.isEmpty) return false;
      final lat = p.latitude;
      final lng = p.longitude;
      for (final sp in _safePlaces) {
        final meters = Geolocator.distanceBetween(lat, lng, sp.lat, sp.lng);
        if (meters <= (sp.radiusMeters ?? 0)) return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  Future<int?> _showRadiusChoiceDialog() async {
    final options = [50, 100, 200, 500];
    return showDialog<int>(context: context, builder: (ctx) {
      int selected = options[1];
      return AlertDialog(
        title: const Text('Selecciona radio (m)'),
        content: StatefulBuilder(builder: (c, setS) => Column(
          mainAxisSize: MainAxisSize.min,
          children: options.map((o) => RadioListTile<int>(value: o, groupValue: selected, title: Text('$o m'), onChanged: (v){ if (v!=null) setS(()=> selected = v); })).toList(),
        )),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(null), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(selected), child: const Text('OK')),
        ],
      );
    });
  }

  Future<void> _markPlaceAsSafe(LatLng pos, {String? name}) async {
    if (!_isAdmin) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Solo administradores pueden marcar lugares seguros.')));
      return;
    }
    final chosen = await _showRadiusChoiceDialog();
    if (chosen == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    try {
      await _firestore.collection(_safePlacesCollection).add({
        'name': name ?? 'Lugar seguro',
        'location': {'lat': pos.latitude, 'lng': pos.longitude},
        'radiusMeters': chosen,
        'status': 'active',
        'createdAtMs': now,
        'createdByUid': FirebaseAuth.instance.currentUser?.uid ?? '',
        'createdByName': _currentNickname,
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Lugar marcado como seguro.')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No se pudo marcar el lugar seguro.')));
    }
  }

  Future<void> _maybeNotifyNearbyZones() async {
    if (_myPosition == null || _geoZones.isEmpty) return;
    if (_isInsideAnySafePlace(_myPosition!)) return; // suppress zone notifications while inside a safe place

    const triggerRadiusM = 200.0;
    const releaseRadiusM = 240.0;
    final me = LatLng(_myPosition!.latitude, _myPosition!.longitude);
    final nextInside = <String>{};

    for (final zone in _geoZones) {
      final meters = _distanceToZoneMeters(me, zone);
      if (meters <= releaseRadiusM) {
        nextInside.add(zone.id);
      }

      final wasInside = _insideZoneRadius.contains(zone.id);
      if (wasInside || meters > triggerRadiusM) continue;

      final body = meters <= 1
          ? 'Ingresaste a la delimitación ${zone.name}.'
          : 'Estás a ${meters.toStringAsFixed(0)} m de ${zone.name}.';
      final notifId = (zone.id.hashCode ^ 0x7831) & 0x7fffffff;

      await _localNotif.show(
        id: notifId,
        title: 'Zona comunitaria cercana',
        body: body,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            'geo_zones_proximity_v1',
            'Delimitaciones comunitarias',
            importance: Importance.high,
            priority: Priority.high,
          ),
          iOS: DarwinNotificationDetails(),
        ),
      );
      _showProximityBanner(
        title: 'Zona comunitaria cercana',
        body: body,
        icon: Icons.polyline,
        color: const Color(0xFF1565C0),
      );
      SystemSound.play(SystemSoundType.alert);
    }

    _insideZoneRadius
      ..clear()
      ..addAll(nextInside);
  }

  bool _isInstitutionForProximity(_Comisaria station) {
    final i = station.institution;
    return i == 'CARABINEROS' || i == 'PDI' || i == 'CRITICO';
  }

  bool _isSecurityContext(_Comisaria station) => _isInstitutionForProximity(station);

  String _institutionProximityTypeLabel(String institution) {
    switch (institution) {
      case 'PDI':
        return 'PDI';
      case 'CRITICO':
        return 'Aduana / Punto crítico';
      default:
        return 'Comisaría';
    }
  }

  String _proximityStationKey(_Comisaria station) {
    if (station.stationId.isNotEmpty) {
      return '${station.institution}:${station.stationId}';
    }
    return '${station.institution}:${station.lat.toStringAsFixed(6)},${station.lng.toStringAsFixed(6)}';
  }

  Future<void> _maybeNotifyNearbyInstitutions() async {
    if (_myPosition == null || _allStations.isEmpty) return;
    if (_isInsideAnySafePlace(_myPosition!)) return; // suppress institution proximity while inside a safe place

    const triggerRadiusM = 200.0;
    const releaseRadiusM = 240.0;

    final myLat = _myPosition!.latitude;
    final myLng = _myPosition!.longitude;

    final nextInside = <String>{};

    for (final station in _allStations) {
      if (!_isInstitutionForProximity(station)) continue;

      final meters = Geolocator.distanceBetween(myLat, myLng, station.lat, station.lng);
      final stationKey = _proximityStationKey(station);

      if (meters <= releaseRadiusM) {
        nextInside.add(stationKey);
      }

      final wasInside = _insideInstitutionRadius.contains(stationKey);
      if (wasInside || meters > triggerRadiusM) continue;

      final typeLabel = _institutionProximityTypeLabel(station.institution);
      final title = 'Atención de proximidad';
      final body = 'Estás cerca de $typeLabel: ${station.name}. Ten cuidado.';
      final notifId = (stationKey.hashCode ^ 0x5511) & 0x7fffffff;

      await _localNotif.show(
        id: notifId,
        title: title,
        body: body,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            'institution_proximity_v1',
            'Proximidad institucional',
            channelDescription: 'Alertas internas por cercanía a comisarías, PDI y aduanas',
            importance: Importance.high,
            priority: Priority.high,
            enableVibration: true,
            vibrationPattern: Int64List.fromList([0, 300, 200, 300]),
          ),
          iOS: const DarwinNotificationDetails(
            presentAlert: true,
            presentSound: true,
          ),
        ),
      );
      _showProximityBanner(
        title: 'Te estás acercando a un control',
        body: body,
        icon: Icons.local_police,
        color: const Color(0xFF1E4E8A),
      );
      SystemSound.play(SystemSoundType.alert);
    }

    _insideInstitutionRadius
      ..clear()
      ..addAll(nextInside);
  }

  String _safeText(dynamic value, [String fallback = '']) {
    final text = (value ?? '').toString().trim();
    return text.isEmpty ? fallback : text;
  }

  String _wazeCategoryLabel(Map<String, dynamic> item) {
    final type = _safeText(item['type'], 'HAZARD').toUpperCase();
    final subtype = _safeText(item['subtype']).toUpperCase();

    final subtypeLabels = <String, String>{
      'HAZARD_ON_ROAD_POT_HOLE': 'Bache en la vía',
      'HAZARD_ON_ROAD_OBJECT': 'Objeto en la vía',
      'HAZARD_ON_ROAD_CAR_STOPPED': 'Vehículo detenido',
      'HAZARD_ON_ROAD': 'Peligro en la vía',
      'ROAD_CLOSED_HAZARD': 'Calle cerrada',
      'ACCIDENT_MINOR': 'Accidente menor',
      'ACCIDENT_MAJOR': 'Accidente grave',
      'POLICE_VISIBLE': 'Control policial visible',
      'POLICE_HIDING': 'Control policial oculto',
      'JAM_MODERATE_TRAFFIC': 'Tráfico moderado',
      'JAM_HEAVY_TRAFFIC': 'Tráfico intenso',
      'JAM_STAND_STILL_TRAFFIC': 'Tráfico detenido',
    };

    final typeLabels = <String, String>{
      'HAZARD': 'Peligro vial',
      'POLICE': 'Control policial',
      'ACCIDENT': 'Accidente',
      'ROAD_CLOSED': 'Calle cerrada',
      'JAM': 'Congestión',
    };

    final label = subtypeLabels[subtype] ?? typeLabels[type] ?? 'Alerta de tránsito';
    return 'Waze: $label';
  }

  String _wazeCustomIconKey(Map<String, dynamic> item) {
    final type = _safeText(item['type'], 'HAZARD').toUpperCase();
    final subtype = _safeText(item['subtype']).toUpperCase();

    if (type == 'POLICE') return 'police';
    if (type == 'ACCIDENT') return 'accident';
    if (type == 'ROAD_CLOSED') return 'roadblock';
    if (type == 'JAM') return 'traffic';
    if (subtype.contains('POT_HOLE')) return 'roadblock';
    if (subtype.contains('OBJECT')) return 'warning';
    if (subtype.contains('CAR_STOPPED')) return 'warning';
    return 'warning';
  }

  String _wazeStableId(String raw) {
    final input = _safeText(raw, 'waze_api');
    var hash = 0;
    for (var i = 0; i < input.length; i++) {
      hash = ((hash << 5) - hash) + input.codeUnitAt(i);
      hash |= 0;
    }
    return 'waze_api_${hash.abs()}';
  }

  Future<void> _openWazeAdminMode() async {
    if (!_isAdmin) return;
    setState(() {
      _pickWazePointOnMap = true;
      _pickPointOnMap = false;
      _pendingCategory = null;
      _pendingNote = '';
      _pendingPublishConfig = null;
      _pendingCustomLabel = '';
      _pendingCustomIconKey = null;
      _pendingCreatePhoto = null;
      _pendingForcePriority = false;
      _pendingForceApproved = false;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Waze admin activo: toca el mapa para consultar ${_wazeRadiusMeters}m y guardar alertas.')),
    );
  }

  Future<void> _fetchWazeAndPersistAt(LatLng center) async {
    if (!_isAdmin || _wazeLoading) return;
    setState(() => _wazeLoading = true);
    try {
      final uri = Uri.parse(
        '$_wazeProxyApiUrl?lat=${center.latitude.toStringAsFixed(5)}&lng=${center.longitude.toStringAsFixed(5)}&radius_m=$_wazeRadiusMeters',
      );
      final resp = await http.get(uri);
      if (resp.statusCode != 200) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No se pudo consultar Waze API.')),
        );
        return;
      }

      final decoded = jsonDecode(resp.body) as Map<String, dynamic>;
      final data = (decoded['data'] as Map<String, dynamic>? ?? const {});
      final items = [
        ...((data['alerts'] as List<dynamic>? ?? const [])),
        ...((data['jams'] as List<dynamic>? ?? const [])),
      ]
          .whereType<Map<String, dynamic>>()
          .toList();

      if (items.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Waze: sin resultados en ${_wazeRadiusMeters}m.')),
        );
        return;
      }

      final now = DateTime.now().millisecondsSinceEpoch;
      final expiresAtMs = now + const Duration(hours: 2).inMilliseconds;
      final authUid = FirebaseAuth.instance.currentUser?.uid ?? '';
      final byName = _currentNickname;
      var saved = 0;

      for (final item in items) {
        final coords = (item['line_coordinates'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .toList();
        final firstCoord = coords.isEmpty ? null : coords.first;
        final ilat = (item['latitude'] as num?)?.toDouble() ??
          (firstCoord?['lat'] as num?)?.toDouble();
        final ilng = (item['longitude'] as num?)?.toDouble() ??
          (firstCoord?['lon'] as num?)?.toDouble();
        if (ilat == null || ilng == null) continue;

        final type = _safeText(item['type'], 'HAZARD').toUpperCase();
        final subtype = _safeText(item['subtype']).toUpperCase();
        final extId = _safeText(item['uuid'] ?? item['id'] ?? item['jam_uuid'] ?? item['alert_uuid']);
        final key = extId.isNotEmpty
            ? extId
            : '${type}_${subtype}_${ilat.toStringAsFixed(5)}_${ilng.toStringAsFixed(5)}';
        final docId = _wazeStableId(key);

        final noteParts = [
          'Consulta generada por API Waze',
          'Radio: ${_wazeRadiusMeters}m',
          _safeText(item['description']),
        ].where((e) => e.trim().isNotEmpty).toList();

        await _firestore.collection(_alertsCollection).doc(docId).set({
          'category': 'api_waze',
          'categoryLabel': _wazeCategoryLabel(item),
          'customIconKey': _wazeCustomIconKey(item),
          'isHelp': false,
          'isPriority': true,
          'priorityTemplateKey': null,
          'approvedByAdmin': true,
          'approvedAtMs': now,
          'isPermanent': false,
          'note': noteParts.join(' · '),
          'lat': ilat,
          'lng': ilng,
          'createdByUid': authUid,
          'createdByName': byName,
          'createdAtMs': now,
          'startAtMs': now,
          'expiresAtMs': expiresAtMs,
          'status': 'active',
          'confirmUids': <String>[],
          'discardUids': <String>[],
          'helperUid': null,
          'helperName': null,
          'helperDistanceKm': null,
          'helperEtaMin': null,
          'helperAcceptedAtMs': null,
          'helperLat': null,
          'helperLng': null,
          'helperMembers': <Map<String, dynamic>>[],
          'evidenceItems': <Map<String, dynamic>>[],
          'source': 'waze_api',
          'sourceLabel': 'Consulta generada por API',
          'sourceCenterLat': double.parse(center.latitude.toStringAsFixed(6)),
          'sourceCenterLng': double.parse(center.longitude.toStringAsFixed(6)),
          'sourceRadiusM': _wazeRadiusMeters,
          'sourceExternalKey': key,
          'sourceType': type,
          'sourceSubtype': subtype,
        }, SetOptions(merge: true));
        saved++;
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Waze ${_wazeRadiusMeters}m: detectadas ${items.length}, guardadas $saved alertas comunitarias.')),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Error consultando Waze.')),
      );
    } finally {
      if (mounted) setState(() => _wazeLoading = false);
    }
  }

  Future<void> _openInGoogleMaps(double lat, double lng) async {
    try {
      final shortUrl = Uri.parse('https://maps.app.goo.gl/?q=$lat,$lng');
      if (await canLaunchUrl(shortUrl)) {
        await launchUrl(shortUrl, mode: LaunchMode.externalApplication);
      } else {
        final fullUrl = Uri.parse('https://www.google.com/maps/search/?api=1&query=$lat,$lng');
        if (await canLaunchUrl(fullUrl)) {
          await launchUrl(fullUrl, mode: LaunchMode.externalApplication);
        } else if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No se pudo abrir Google Maps')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  String _fuelLabel(String key) {
    switch (key) {
      case 'bencina_93':
        return 'Bencina 93';
      case 'bencina_95':
        return 'Bencina 95';
      case 'bencina_97':
        return 'Bencina 97';
      case 'diesel':
        return 'Diesel';
      default:
        return key;
    }
  }

  String _fmtMinuteOfDay(int minuteOfDay) {
    final hh = (minuteOfDay ~/ 60).toString().padLeft(2, '0');
    final mm = (minuteOfDay % 60).toString().padLeft(2, '0');
    return '$hh:$mm';
  }

  Color _stationPointBorderColor(String institution) {
    switch (institution) {
      case 'PDI':
        return const Color(0xFF1E4E8A);
      case 'BENCINERA':
        return const Color(0xFFE65100);
      case 'CRITICO':
        return const Color(0xFFC62828);
      case 'PEAJE':
        return const Color(0xFF6D4C41);
      default:
        return const Color(0xFF2E7D32);
    }
  }

  Widget _stationPointIcon(_Comisaria station) {
    if (station.institution == 'PDI') {
      return const Icon(Icons.shield, size: 16, color: Color(0xFF1E4E8A));
    }
    if (station.institution == 'BENCINERA') {
      return const Icon(
        Icons.local_gas_station,
        size: 16,
        color: Color(0xFFE65100),
      );
    }
    if (station.institution == 'CRITICO') {
      return const Icon(Icons.account_balance, size: 16, color: Color(0xFFC62828));
    }
    if (station.institution == 'PEAJE') {
      return const Icon(Icons.toll, size: 16, color: Color(0xFF6D4C41));
    }
    return Image.asset('assets/carabineros_roundel.png', width: 18, height: 18);
  }

  Widget _stationPointMarker(_Comisaria station) {
    final border = _stationPointBorderColor(station.institution);
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
        border: Border.all(color: border, width: 2),
        boxShadow: const [
          BoxShadow(color: Colors.black26, blurRadius: 5, offset: Offset(0, 1)),
        ],
      ),
      child: Center(child: _stationPointIcon(station)),
    );
  }

  IconData _stationDetailIcon(String institution) {
    switch (institution) {
      case 'BENCINERA':
        return Icons.local_gas_station;
      case 'PDI':
        return Icons.shield;
      case 'CRITICO':
        return Icons.report;
      case 'PEAJE':
        return Icons.toll;
      default:
        return Icons.local_police;
    }
  }

  Color _stationDetailColor(String institution) {
    switch (institution) {
      case 'BENCINERA':
        return const Color(0xFFE65100);
      case 'PDI':
        return const Color(0xFF1E4E8A);
      case 'CRITICO':
        return const Color(0xFFC62828);
      case 'PEAJE':
        return const Color(0xFF6D4C41);
      default:
        return const Color(0xFF2E7D32);
    }
  }

  void _openStationDetails(_Comisaria station) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    _stationDetailIcon(station.institution),
                    color: _stationDetailColor(station.institution),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      station.brand.isNotEmpty ? station.brand : station.name,
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                '${station.comunaName}, ${station.regionName}',
                style: const TextStyle(color: Colors.black54),
              ),
              if (station.address.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text('Dirección: ${station.address}'),
              ],
              if (station.fuelPrices.isNotEmpty) ...[
                const SizedBox(height: 10),
                const Text(
                  'Combustibles',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                ...station.fuelPrices.entries.map(
                  (entry) => Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text('${_fuelLabel(entry.key)}: ${entry.value}'),
                  ),
                ),
              ],
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close),
                      label: const Text('Cerrar'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () => _openInGoogleMaps(station.lat, station.lng),
                      icon: const Icon(Icons.navigation_outlined),
                      label: const Text('Abrir en Maps'),
                    ),
                  ),
                ],
              ),
              if (_isSecurityContext(station)) ...
              [
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: () async {
                      await _markPlaceAsSafe(
                        LatLng(station.lat, station.lng),
                        name: 'Zona segura: ${station.brand.isNotEmpty ? station.brand : station.name}',
                      );
                      if (mounted) {
                        Navigator.of(context).pop();
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Zona segura creada')),
                        );
                      }
                    },
                    icon: const Icon(Icons.security_outlined),
                    label: const Text('Marcar como zona segura'),
                  ),
                ),
              ]
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openCreateAlertSheet() async {
    // Refresh templates here so users immediately see new admin categories.
    final freshTemplates = await _loadPriorityCategories();
    if (!mounted) return;
    setState(() {
      _priorityCategories = freshTemplates;
    });

    final selectableCategories = _categoriesForCreate();
    final selected = await showModalBottomSheet<_AlertCategory>(
      context: context,
      isScrollControlled: true,
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_isCustomAdminEnabled)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: () {
                        Navigator.of(context).pop();
                        _openCustomAdminAlertSheet();
                      },
                      icon: const Icon(Icons.admin_panel_settings_outlined),
                      label: const Text('Crear propia alerta (solo admin)'),
                    ),
                  ),
                ),
              const Text(
                'Nueva alerta ciudadana',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              const Text(
                'Selecciona una categoria',
                style: TextStyle(color: Colors.black54),
              ),
              const SizedBox(height: 10),
              if (_priorityCategories.isNotEmpty)
                const Padding(
                  padding: EdgeInsets.only(bottom: 8),
                  child: Text(
                    'Llamadas Alertas Prioritarias (creadas por admin) aparecen primero.',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFFC62828)),
                  ),
                ),
              SizedBox(
                height: 350,
                child: GridView.count(
                  crossAxisCount: 2,
                  childAspectRatio: 2.5,
                  children: selectableCategories
                      .map(
                        (c) => Padding(
                          padding: const EdgeInsets.all(4),
                          child: OutlinedButton.icon(
                            onPressed: () => Navigator.of(context).pop(c),
                            icon: Icon(c.icon, color: c.color),
                            label: Text(
                              c.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                      )
                      .toList(),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    if (selected == null || !mounted) return;
    _openCreateModeSheet(selected);
  }

  Future<void> _openCustomAdminAlertSheet() async {
    if (!_isCustomAdminEnabled) return;

    final category = const _AlertCategory(
      'admin_custom',
      'Alerta personalizada',
      Icons.warning_amber_rounded,
      Color(0xFFD84315),
    );

    final nameCtrl = TextEditingController();
    final noteCtrl = TextEditingController();
    var publishMode = 'hours';
    var hours = 6;
    var selectedIconKey = _adminCustomIconOptions.first.key;
    XFile? selectedPhoto;

    final mode = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (_) => StatefulBuilder(
        builder: (context, setModalState) => Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 16,
            bottom: MediaQuery.of(context).viewInsets.bottom + 16,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Crear propia alerta (admin)',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: nameCtrl,
                  maxLength: 80,
                  decoration: const InputDecoration(
                    labelText: 'Nombre de la alerta',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: noteCtrl,
                  maxLength: 140,
                  decoration: const InputDecoration(
                    labelText: 'Descripcion alerta',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Permanencia',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 6),
                DropdownButtonFormField<String>(
                  initialValue: publishMode,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: const [
                    DropdownMenuItem(value: 'hours', child: Text('Por cantidad de horas')),
                    DropdownMenuItem(value: 'permanent', child: Text('Siempre visible')),
                  ],
                  onChanged: (v) {
                    if (v == null) return;
                    setModalState(() => publishMode = v);
                  },
                ),
                if (publishMode == 'hours') ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Text('Horas: '),
                      Expanded(
                        child: Slider(
                          min: 1,
                          max: 168,
                          divisions: 167,
                          value: hours.toDouble(),
                          label: '$hours h',
                          onChanged: (v) {
                            setModalState(() => hours = v.round());
                          },
                        ),
                      ),
                      Text('$hours h'),
                    ],
                  ),
                ],
                const SizedBox(height: 8),
                const Text(
                  'Foto opcional',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () async {
                          final picker = ImagePicker();
                          final picked = await picker.pickImage(
                            source: ImageSource.gallery,
                            imageQuality: 85,
                            maxWidth: 1600,
                          );
                          if (picked == null) return;
                          setModalState(() => selectedPhoto = picked);
                        },
                        icon: const Icon(Icons.photo_library_outlined),
                        label: Text(
                          selectedPhoto == null ? 'Incluir foto' : 'Cambiar foto',
                        ),
                      ),
                    ),
                    if (selectedPhoto != null) ...[
                      const SizedBox(width: 8),
                      IconButton(
                        onPressed: () => setModalState(() => selectedPhoto = null),
                        icon: const Icon(Icons.delete_outline),
                        tooltip: 'Quitar foto',
                      ),
                    ],
                  ],
                ),
                if (selectedPhoto != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      'Foto: ${selectedPhoto!.name}',
                      style: const TextStyle(fontSize: 12, color: Colors.black54),
                    ),
                  ),
                const SizedBox(height: 10),
                const Text(
                  'Icono de alerta',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: _adminCustomIconOptions
                      .map(
                        (opt) => ChoiceChip(
                          selected: selectedIconKey == opt.key,
                          onSelected: (_) => setModalState(() => selectedIconKey = opt.key),
                          label: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(opt.icon, size: 18, color: opt.color),
                              const SizedBox(width: 6),
                              Text(opt.key),
                            ],
                          ),
                        ),
                      )
                      .toList(),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: () => Navigator.of(context).pop('my_location'),
                        icon: const Icon(Icons.my_location),
                        label: const Text('Usar mi ubicacion'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => Navigator.of(context).pop('pick_map'),
                        icon: const Icon(Icons.touch_app),
                        label: const Text('Marcar en mapa'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );

    final note = noteCtrl.text.trim();
    final customLabel = nameCtrl.text.trim();
    noteCtrl.dispose();
    nameCtrl.dispose();

    if (mode == null || !mounted) return;
    if (customLabel.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Debes ingresar un nombre para la alerta.')),
      );
      return;
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    final publishConfig = publishMode == 'permanent'
        ? _AlertPublishConfig(
            startAtMs: now,
            expiresAtMs: now + const Duration(days: 3650).inMilliseconds,
            isPermanent: true,
          )
        : _AlertPublishConfig(
            startAtMs: now,
            expiresAtMs: now + Duration(hours: hours).inMilliseconds,
            isPermanent: false,
          );

    if (mode == 'my_location') {
      if (_myPosition == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No hay ubicacion disponible.')),
        );
        return;
      }
      await _createAlert(
        category: category,
        point: LatLng(_myPosition!.latitude, _myPosition!.longitude),
        note: note,
        publishConfig: publishConfig,
        customLabel: customLabel,
        customIconKey: selectedIconKey,
        initialPhoto: selectedPhoto,
        forcePriority: true,
        forceApproved: true,
      );
      return;
    }

    setState(() {
      _pendingCategory = category;
      _pendingNote = note;
      _pendingPublishConfig = publishConfig;
      _pendingCustomLabel = customLabel;
      _pendingCustomIconKey = selectedIconKey;
      _pendingCreatePhoto = selectedPhoto;
      _pendingForcePriority = true;
      _pendingForceApproved = true;
      _pickPointOnMap = true;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Toca el mapa para publicar la alerta.')),
    );
  }

  Future<void> _openCreateModeSheet(_AlertCategory category) async {
    final nameCtrl = TextEditingController(text: category.label);
    final noteCtrl = TextEditingController();
    var publishMode = 'hours';
    var hours = 6;
    var dailyStart = const TimeOfDay(hour: 1, minute: 0);
    var dailyEnd = const TimeOfDay(hour: 6, minute: 0);

    String fmtTime(TimeOfDay t) {
      final hh = t.hour.toString().padLeft(2, '0');
      final mm = t.minute.toString().padLeft(2, '0');
      return '$hh:$mm';
    }

    Future<TimeOfDay?> pickTime(TimeOfDay initial) async {
      final time = await showTimePicker(
        context: context,
        initialTime: initial,
      );
      return time;
    }

    final mode = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (_) => StatefulBuilder(
        builder: (context, setModalState) => Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.of(context).viewInsets.bottom + 16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              category.label,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: nameCtrl,
              maxLength: 80,
              decoration: const InputDecoration(
                labelText: 'Nombre de la alerta',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 6),
            TextField(
              controller: noteCtrl,
              maxLength: 140,
              decoration: InputDecoration(
                labelText: category.isHelp
                    ? 'Describe brevemente la ayuda'
                    : 'Detalle opcional de la alerta',
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              'Puedes agregar más info ahora y subir foto luego desde el detalle de la alerta.',
              style: TextStyle(fontSize: 12, color: Colors.black54),
            ),
            const SizedBox(height: 4),
            const Text(
              'Permanencia',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            DropdownButtonFormField<String>(
              initialValue: publishMode,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                isDense: true,
              ),
              items: const [
                DropdownMenuItem(value: 'hours', child: Text('Por cantidad de horas')),
                DropdownMenuItem(value: 'daily_window', child: Text('Horario diario (recurrente)')),
                DropdownMenuItem(value: 'permanent', child: Text('Siempre visible')),
              ],
              onChanged: (v) {
                if (v == null) return;
                setModalState(() => publishMode = v);
              },
            ),
            if (publishMode == 'hours') ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  const Text('Horas: '),
                  Expanded(
                    child: Slider(
                      min: 1,
                      max: 168,
                      divisions: 167,
                      value: hours.toDouble(),
                      label: '$hours h',
                      onChanged: (v) {
                        setModalState(() => hours = v.round());
                      },
                    ),
                  ),
                  Text('$hours h'),
                ],
              ),
            ],
            if (publishMode == 'daily_window') ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () async {
                        final picked = await pickTime(dailyStart);
                        if (picked == null) return;
                        setModalState(() => dailyStart = picked);
                      },
                      icon: const Icon(Icons.schedule),
                      label: Text('Desde: ${fmtTime(dailyStart)}'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () async {
                        final picked = await pickTime(dailyEnd);
                        if (picked == null) return;
                        setModalState(() => dailyEnd = picked);
                      },
                      icon: const Icon(Icons.event_available),
                      label: Text('Hasta: ${fmtTime(dailyEnd)}'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              const Text(
                'Se verá solo dentro del horario y reaparecerá cada día.',
                style: TextStyle(color: Colors.black54, fontSize: 12),
              ),
            ],
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () => Navigator.of(context).pop('my_location'),
                    icon: const Icon(Icons.my_location),
                    label: const Text('Usar mi ubicación'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => Navigator.of(context).pop('pick_map'),
                    icon: const Icon(Icons.touch_app),
                    label: const Text('Marcar en mapa'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      ),
    );

    final note = noteCtrl.text.trim();
    final customLabel = nameCtrl.text.trim();
    noteCtrl.dispose();
    nameCtrl.dispose();

    if (mode == null || !mounted) return;
    if (customLabel.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Debes ingresar un nombre para la alerta.')),
      );
      return;
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    _AlertPublishConfig publishConfig;
    if (publishMode == 'permanent') {
      publishConfig = _AlertPublishConfig(
        startAtMs: now,
        expiresAtMs: now + const Duration(days: 3650).inMilliseconds,
        isPermanent: true,
      );
    } else if (publishMode == 'daily_window') {
      publishConfig = _AlertPublishConfig(
        startAtMs: now,
        expiresAtMs: now + const Duration(days: 3650).inMilliseconds,
        isPermanent: false,
        recurringDaily: true,
        scheduleStartMinute: (dailyStart.hour * 60) + dailyStart.minute,
        scheduleEndMinute: (dailyEnd.hour * 60) + dailyEnd.minute,
      );
    } else {
      publishConfig = _AlertPublishConfig(
        startAtMs: now,
        expiresAtMs: now + const Duration(hours: 6).inMilliseconds,
        isPermanent: false,
      );
    }

    if (mode == 'my_location') {
      if (_myPosition == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No hay ubicacion disponible.')),
        );
        return;
      }
      await _createAlert(
        category: category,
        point: LatLng(_myPosition!.latitude, _myPosition!.longitude),
        note: note,
        publishConfig: publishConfig,
        customLabel: customLabel,
      );
      return;
    }

    setState(() {
      _pendingCategory = category;
      _pendingNote = note;
      _pendingPublishConfig = publishConfig;
      _pendingCustomLabel = customLabel;
      _pendingCustomIconKey = null;
      _pendingCreatePhoto = null;
      _pendingForcePriority = false;
      _pendingForceApproved = false;
      _pickPointOnMap = true;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Toca el mapa para publicar la alerta.')),
    );
  }

  Future<void> _createAlert({
    required _AlertCategory category,
    required LatLng point,
    required String note,
    required _AlertPublishConfig publishConfig,
    required String customLabel,
    String? customIconKey,
    XFile? initialPhoto,
    bool forcePriority = false,
    bool forceApproved = false,
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    final uid = user?.uid ?? '';
    final nickname =
        (user?.displayName?.trim().isNotEmpty == true) ? user!.displayName!.trim() : 'Usuario';

    final now = DateTime.now().millisecondsSinceEpoch;
    final isPriority = forcePriority || category.isPriorityTemplate;
    final approvedByAdmin = forceApproved || category.isPriorityTemplate;

    final doc = _firestore.collection(_alertsCollection).doc();
    final evidenceItems = <Map<String, dynamic>>[];
    var initialPhotoFailed = false;

    if (initialPhoto != null && uid.isNotEmpty) {
      try {
        final bytes = await initialPhoto.readAsBytes();
        final ext = initialPhoto.name.toLowerCase().endsWith('.png') ? 'png' : 'jpg';
        final ref = FirebaseStorage.instance
            .ref()
            .child('citizen_alert_evidence/${doc.id}/${uid}_$now.$ext');

        await ref.putData(
          bytes,
          SettableMetadata(contentType: ext == 'png' ? 'image/png' : 'image/jpeg'),
        );
        final url = await ref.getDownloadURL();
        evidenceItems.add({
          'url': url,
          'note': 'Foto inicial de la alerta',
          'uploadedByUid': uid,
          'uploadedByName': nickname,
          'uploadedAtMs': now,
        });
      } catch (_) {
        initialPhotoFailed = true;
      }
    }

    await doc.set({
      'category': category.key,
      'categoryLabel': customLabel,
      'isHelp': category.isHelp,
      'isPriority': isPriority,
      'priorityTemplateKey': category.isPriorityTemplate ? category.key : null,
      'approvedByAdmin': approvedByAdmin,
      'approvedAtMs': approvedByAdmin ? now : null,
      'isPermanent': publishConfig.isPermanent,
      'note': note,
      'lat': point.latitude,
      'lng': point.longitude,
      'customIconKey': customIconKey,
      'createdByUid': uid,
      'createdByName': nickname,
      'createdAtMs': now,
      'startAtMs': publishConfig.startAtMs,
      'expiresAtMs': publishConfig.expiresAtMs,
      'recurringDaily': publishConfig.recurringDaily,
      'scheduleStartMinute': publishConfig.scheduleStartMinute,
      'scheduleEndMinute': publishConfig.scheduleEndMinute,
      'status': 'active',
      'confirmUids': <String>[],
      'discardUids': <String>[],
      'helperUid': null,
      'helperName': null,
      'helperDistanceKm': null,
      'helperEtaMin': null,
      'helperAcceptedAtMs': null,
      'helperLat': null,
      'helperLng': null,
      'helperMembers': <Map<String, dynamic>>[],
      'evidenceItems': evidenceItems,
    });

    if (!mounted) return;
    SystemSound.play(SystemSoundType.alert);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          initialPhotoFailed
              ? 'Alerta publicada, pero no se pudo subir la foto inicial.'
              : 'Alerta publicada para toda la comunidad.',
        ),
      ),
    );
  }

  _RiskLevel _riskLevelOf(_CitizenAlert alert) {
    final score = (alert.confirmCount * 2) - alert.discardCount;
    if (score >= 8) return _RiskLevel.high;
    if (score >= 3) return _RiskLevel.medium;
    return _RiskLevel.low;
  }

  Color _riskColor(_RiskLevel level) {
    switch (level) {
      case _RiskLevel.high:
        return Colors.redAccent;
      case _RiskLevel.medium:
        return Colors.amber;
      case _RiskLevel.low:
        return Colors.lightGreen;
    }
  }

  String _riskLabel(_RiskLevel level) {
    switch (level) {
      case _RiskLevel.high:
        return 'Riesgo alto';
      case _RiskLevel.medium:
        return 'Riesgo medio';
      case _RiskLevel.low:
        return 'Riesgo bajo';
    }
  }

  Future<void> _voteAlert(_CitizenAlert alert, {required bool confirm}) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null || uid.isEmpty) return;

    final doc = _firestore.collection(_alertsCollection).doc(alert.id);

    await _firestore.runTransaction((tx) async {
      final snap = await tx.get(doc);
      if (!snap.exists) return;
      final data = snap.data() as Map<String, dynamic>;

      final confirms = Set<String>.from((data['confirmUids'] as List<dynamic>? ?? const []).map((e) => '$e'));
      final discards = Set<String>.from((data['discardUids'] as List<dynamic>? ?? const []).map((e) => '$e'));

      if (confirm) {
        confirms.add(uid);
        discards.remove(uid);
      } else {
        discards.add(uid);
        confirms.remove(uid);
      }

      final next = <String, dynamic>{
        'confirmUids': confirms.toList(),
        'discardUids': discards.toList(),
      };

      if (discards.length >= confirms.length + 5) {
        next['status'] = 'closed';
      }

      tx.update(doc, next);
    });
  }

  Future<void> _assistAlert(_CitizenAlert alert) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null || uid.isEmpty) return;
    if (_myPosition == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Activa tu ubicacion para asistir.')),
      );
      return;
    }

    final helperName =
        (FirebaseAuth.instance.currentUser?.displayName?.trim().isNotEmpty == true)
            ? FirebaseAuth.instance.currentUser!.displayName!.trim()
            : 'Usuario';

    final meters = Geolocator.distanceBetween(
      _myPosition!.latitude,
      _myPosition!.longitude,
      alert.lat,
      alert.lng,
    );
    final distanceKm = meters / 1000;
    final etaMin = (distanceKm / 35 * 60).clamp(1, 180).round();

    final doc = _firestore.collection(_alertsCollection).doc(alert.id);
    await _firestore.runTransaction((tx) async {
      final snap = await tx.get(doc);
      if (!snap.exists) return;
      final data = snap.data() as Map<String, dynamic>;
      final raw = (data['helperMembers'] as List<dynamic>? ?? const []);
      final helpers = raw.map((entry) => Map<String, dynamic>.from(entry as Map)).toList();
      final nextHelper = <String, dynamic>{
        'uid': uid,
        'name': helperName,
        'distanceKm': distanceKm,
        'etaMin': etaMin,
        'lat': _myPosition!.latitude,
        'lng': _myPosition!.longitude,
        'acceptedAtMs': DateTime.now().millisecondsSinceEpoch,
        'updatedAtMs': DateTime.now().millisecondsSinceEpoch,
      };
      final idx = helpers.indexWhere((entry) => '${entry['uid']}' == uid);
      if (idx >= 0) {
        helpers[idx] = nextHelper;
      } else {
        helpers.add(nextHelper);
      }
      tx.update(doc, {
        'helperMembers': helpers,
        'helperUid': uid,
        'helperName': helperName,
        'helperDistanceKm': distanceKm,
        'helperEtaMin': etaMin,
        'helperAcceptedAtMs': DateTime.now().millisecondsSinceEpoch,
        'helperLat': _myPosition!.latitude,
        'helperLng': _myPosition!.longitude,
      });
    });

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$helperName va en camino. ETA aprox: $etaMin min.')),
    );
  }

  Future<void> _uploadAlertEvidence(_CitizenAlert alert, String note) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null || uid.isEmpty) return;

    final picker = ImagePicker();
    final picked = await picker.pickImage(source: ImageSource.gallery, imageQuality: 85, maxWidth: 1600);
    if (picked == null) return;

    final bytes = await picked.readAsBytes();
    final ts = DateTime.now().millisecondsSinceEpoch;
    final ext = picked.name.toLowerCase().endsWith('.png') ? 'png' : 'jpg';
    final ref = FirebaseStorage.instance
        .ref()
        .child('citizen_alert_evidence/${alert.id}/${uid}_$ts.$ext');

    await ref.putData(
      bytes,
      SettableMetadata(contentType: ext == 'png' ? 'image/png' : 'image/jpeg'),
    );

    final url = await ref.getDownloadURL();
    final doc = _firestore.collection(_alertsCollection).doc(alert.id);

    await _firestore.runTransaction((tx) async {
      final snap = await tx.get(doc);
      if (!snap.exists) return;
      final data = snap.data() as Map<String, dynamic>;
      final raw = (data['evidenceItems'] as List<dynamic>? ?? const []);
      final items = raw.map((e) => Map<String, dynamic>.from(e as Map)).toList();

      items.add({
        'url': url,
        'note': note,
        'uploadedByUid': uid,
        'uploadedByName': _currentNickname,
        'uploadedAtMs': ts,
      });

      tx.update(doc, {'evidenceItems': items});
    });

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Evidencia subida correctamente.')),
    );
  }

  Future<void> _approveAlert(_CitizenAlert alert) async {
    if (!_isAdmin) return;
    await _firestore.collection(_alertsCollection).doc(alert.id).update({
      'approvedByAdmin': true,
      'approvedAtMs': DateTime.now().millisecondsSinceEpoch,
      'approvedByUid': FirebaseAuth.instance.currentUser?.uid,
      'approvedByName': _currentNickname,
    });
  }

  Future<void> _setAlertPermanent(_CitizenAlert alert) async {
    if (!_isAdmin) return;
    final permanentMs = DateTime.now()
        .add(const Duration(days: 3650))
        .millisecondsSinceEpoch;
    await _firestore.collection(_alertsCollection).doc(alert.id).update({
      'isPermanent': true,
      'expiresAtMs': permanentMs,
      'permanentByUid': FirebaseAuth.instance.currentUser?.uid,
      'permanentByName': _currentNickname,
      'permanentAtMs': DateTime.now().millisecondsSinceEpoch,
    });
  }

  Future<void> _removeAlert(_CitizenAlert alert) async {
    if (!_isAdmin) return;
    await _firestore.collection(_alertsCollection).doc(alert.id).update({
      'status': 'closed',
      'closedByUid': FirebaseAuth.instance.currentUser?.uid,
      'closedByName': _currentNickname,
      'closedAtMs': DateTime.now().millisecondsSinceEpoch,
    });
  }

  Future<void> _removeAllActiveAlerts() async {
    if (!_isAdmin) return;
    final snap = await _firestore
        .collection(_alertsCollection)
        .where('status', isEqualTo: 'active')
        .get();
    if (snap.docs.isEmpty) return;

    final batch = _firestore.batch();
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final d in snap.docs) {
      batch.update(d.reference, {
        'status': 'closed',
        'closedByUid': FirebaseAuth.instance.currentUser?.uid,
        'closedByName': _currentNickname,
        'closedAtMs': now,
      });
    }
    await batch.commit();
  }

  String _relativeUntil(int expiresAtMs) {
    final left = expiresAtMs - DateTime.now().millisecondsSinceEpoch;
    if (left <= 0) return 'expirada';
    final min = (left / 60000).floor();
    if (min < 60) return 'vence en ${min}m';
    final h = min ~/ 60;
    final rem = min % 60;
    return 'vence en ${h}h ${rem}m';
  }

  String _alertVisibilityLabel(_CitizenAlert alert) {
    if (alert.recurringDaily &&
        alert.scheduleStartMinute != null &&
        alert.scheduleEndMinute != null) {
      return 'horario ${_fmtMinuteOfDay(alert.scheduleStartMinute!)}-${_fmtMinuteOfDay(alert.scheduleEndMinute!)}';
    }
    if (alert.isPermanent) return 'permanente';
    return _relativeUntil(alert.expiresAtMs);
  }

  String _fmtCompactDateTime(int millis) {
    if (millis <= 0) return 'sin hora';
    final dt = DateTime.fromMillisecondsSinceEpoch(millis);
    final day = dt.day.toString().padLeft(2, '0');
    final month = dt.month.toString().padLeft(2, '0');
    final hour = dt.hour.toString().padLeft(2, '0');
    final minute = dt.minute.toString().padLeft(2, '0');
    return '$day/$month $hour:$minute';
  }

  String _alertStateLabel(_CitizenAlert alert) {
    if (alert.isHelp && alert.helperMembers.isNotEmpty) return 'en ruta';
    final ageMinutes = ((DateTime.now().millisecondsSinceEpoch - alert.createdAtMs) / 60000).floor();
    if (ageMinutes <= 2) return 'nuevo';
    if (ageMinutes < 60) return 'hace ${ageMinutes}m';
    final hours = ageMinutes ~/ 60;
    if (hours < 24) return 'hace ${hours}h';
    final days = hours ~/ 24;
    return 'hace ${days}d';
  }

  double _alertMarkerBearing(_CitizenAlert alert, LatLng? reference) {
    final origin = reference ?? _mapCenter;
    final dy = alert.lat - origin.latitude;
    final dx = alert.lng - origin.longitude;
    return math.atan2(dx, dy);
  }

  String _bearingLabel(double radians) {
    final degrees = (radians * 180 / math.pi) % 360;
    final normalized = degrees < 0 ? degrees + 360 : degrees;
    if (normalized >= 337.5 || normalized < 22.5) return 'N';
    if (normalized < 67.5) return 'NE';
    if (normalized < 112.5) return 'E';
    if (normalized < 157.5) return 'SE';
    if (normalized < 202.5) return 'S';
    if (normalized < 247.5) return 'SO';
    if (normalized < 292.5) return 'O';
    return 'NO';
  }

  double? _distanceKmTo(double lat, double lng) {
    if (_myPosition == null) return null;
    final meters = Geolocator.distanceBetween(_myPosition!.latitude, _myPosition!.longitude, lat, lng);
    return meters / 1000;
  }

  void _openAlertDetails(_CitizenAlert alert) {
    final evidenceNoteCtrl = TextEditingController();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) {
        return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          stream: _firestore.collection(_alertsCollection).doc(alert.id).snapshots(),
          builder: (_, snap) {
            final live = snap.hasData && snap.data!.exists
                ? _CitizenAlert.fromSnapshot(snap.data!)
                : alert;
            final category = _categoryByKey(live.category);
            final risk = _riskLevelOf(live);
            final rep = _userReputation[live.createdByUid] ?? 0;
            final dist = _distanceKmTo(live.lat, live.lng);
            final stateLabel = _alertStateLabel(live);
            final compactDate = _fmtCompactDateTime(live.createdAtMs);
            final referencePoint = _myPosition == null
              ? null
              : LatLng(_myPosition!.latitude, _myPosition!.longitude);
            final bearingLabel = _bearingLabel(_alertMarkerBearing(live, referencePoint));
            final originLabel = live.createdByUid.isEmpty
                ? 'del sistema'
                : '${live.createdByName} (usuario)';
            final liveIcon = _alertIcon(live, category);
            final liveColor = _alertIconColor(live, category);

            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(liveIcon, color: liveColor),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            live.categoryLabel,
                            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    if (live.note.isNotEmpty)
                      Text(live.note, style: const TextStyle(color: Colors.black87)),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 10,
                      runSpacing: 6,
                      children: [
                        _DetailPill(icon: Icons.schedule, label: compactDate),
                        _DetailPill(icon: Icons.navigation, label: bearingLabel),
                        _DetailPill(icon: Icons.bolt, label: stateLabel),
                      ],
                    ),
                    if (dist != null) ...[
                      const SizedBox(height: 6),
                      Text('Distancia: ${dist.toStringAsFixed(1)} km'),
                    ],
                    const SizedBox(height: 4),
                    Text('Generada por: $originLabel'),
                    Text('Reputación: $rep'),
                    if (live.isPriority)
                      const Text(
                        'Alerta prioritaria',
                        style: TextStyle(fontWeight: FontWeight.w700, color: Color(0xFFC62828)),
                      ),
                    if (live.isPermanent)
                      const Text(
                        'Marcada como permanente por admin',
                        style: TextStyle(fontWeight: FontWeight.w700, color: Color(0xFF6A1B9A)),
                      ),
                    Text(
                      _riskLabel(risk),
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: _riskColor(risk),
                      ),
                    ),
                    Text(_alertVisibilityLabel(live)),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        FilledButton.icon(
                          onPressed: () => _voteAlert(live, confirm: true),
                          icon: const Icon(Icons.thumb_up_alt_outlined),
                          label: Text('Confirmar (${live.confirmCount})'),
                        ),
                        const SizedBox(width: 8),
                        OutlinedButton.icon(
                          onPressed: () => _voteAlert(live, confirm: false),
                          icon: const Icon(Icons.thumb_down_alt_outlined),
                          label: Text('Descartar (${live.discardCount})'),
                        ),
                      ],
                    ),
                    if (live.isHelp) ...[
                      const SizedBox(height: 10),
                      if (live.helperMembers.isEmpty)
                        FilledButton.icon(
                          onPressed: () => _assistAlert(live),
                          icon: const Icon(Icons.handshake),
                          label: const Text('Asistir'),
                        )
                      else
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: const Color(0xFFEFFAF1),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: const Color(0xFFBDE5C5)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: live.helperMembers
                                .map(
                                  (helper) => Padding(
                                    padding: const EdgeInsets.only(bottom: 6),
                                    child: Text(
                                      '${helper.name} va en camino. Distancia: '
                                      '${helper.distanceKm.toStringAsFixed(1)} km · ETA: ${helper.etaMin} min',
                                      style: const TextStyle(fontWeight: FontWeight.w600),
                                    ),
                                  ),
                                )
                                .toList(),
                          ),
                        ),
                    ],
                    const SizedBox(height: 10),
                    const Divider(height: 1),
                    const SizedBox(height: 8),
                    const Text(
                      'Evidencia del aviso',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 6),
                    if (live.evidenceItems.isEmpty)
                      const Text('Aún no hay evidencia subida.', style: TextStyle(color: Colors.black54)),
                    if (live.evidenceItems.isNotEmpty)
                      ...live.evidenceItems.map(
                        (ev) => Container(
                          width: double.infinity,
                          margin: const EdgeInsets.only(bottom: 6),
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF7F7F7),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: const Color(0xFFE0E0E0)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('${ev.uploadedByName} subió foto', style: const TextStyle(fontWeight: FontWeight.w600)),
                              Text('Fecha: ${DateTime.fromMillisecondsSinceEpoch(ev.uploadedAtMs)}', style: const TextStyle(fontSize: 12, color: Colors.black54)),
                              if (ev.note.isNotEmpty)
                                Text('Nota: ${ev.note}', style: const TextStyle(fontSize: 12)),
                              TextButton.icon(
                                onPressed: () => launchUrl(Uri.parse(ev.url), mode: LaunchMode.externalApplication),
                                icon: const Icon(Icons.photo_outlined),
                                label: const Text('Ver foto'),
                              ),
                            ],
                          ),
                        ),
                      ),
                    TextField(
                      controller: evidenceNoteCtrl,
                      maxLength: 180,
                      decoration: const InputDecoration(
                        labelText: 'Descripción de evidencia (opcional)',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                    FilledButton.icon(
                      onPressed: () async {
                        await _uploadAlertEvidence(live, evidenceNoteCtrl.text.trim());
                        if (mounted) evidenceNoteCtrl.clear();
                      },
                      icon: const Icon(Icons.upload_file),
                      label: const Text('Subir foto'),
                    ),
                    if (_isAdmin) ...[
                      const SizedBox(height: 10),
                      const Divider(height: 1),
                      const SizedBox(height: 8),
                      const Text(
                        'Acciones admin',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          OutlinedButton.icon(
                            onPressed: () => _approveAlert(live),
                            icon: const Icon(Icons.verified_outlined),
                            label: const Text('Aprobar'),
                          ),
                          OutlinedButton.icon(
                            onPressed: () => _setAlertPermanent(live),
                            icon: const Icon(Icons.push_pin_outlined),
                            label: const Text('Permanente'),
                          ),
                          OutlinedButton.icon(
                            onPressed: () => _removeAlert(live),
                            icon: const Icon(Icons.delete_outline),
                            label: const Text('Eliminar'),
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 10),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        onPressed: () => _openInGoogleMaps(live.lat, live.lng),
                        icon: const Icon(Icons.navigation_outlined),
                        label: const Text('Abrir en Google Maps'),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    ).whenComplete(() => evidenceNoteCtrl.dispose());
  }

  void _openAlertsPanel() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => SafeArea(
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.65,
          child: Column(
            children: [
              const SizedBox(height: 8),
              Row(
                children: [
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'Alertas ciudadanas activas',
                      style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                    ),
                  ),
                  if (_isAdmin && _activeAlerts.isNotEmpty)
                    TextButton.icon(
                      onPressed: () async {
                        final ok = await showDialog<bool>(
                              context: context,
                              builder: (_) => AlertDialog(
                                title: const Text('Eliminar todas las alertas'),
                                content: const Text('¿Seguro? Esta acción cerrará todas las alertas activas.'),
                                actions: [
                                  TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancelar')),
                                  FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Confirmar')),
                                ],
                              ),
                            ) ??
                            false;
                        if (!ok) return;
                        await _removeAllActiveAlerts();
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Todas las alertas activas fueron cerradas.')),
                          );
                        }
                      },
                      icon: const Icon(Icons.delete_sweep_outlined),
                      label: const Text('Eliminar todas'),
                    ),
                  const SizedBox(width: 8),
                ],
              ),
              const Divider(),
              Expanded(
                child: _activeAlerts.isEmpty
                    ? const Center(
                        child: Text('No hay alertas activas por ahora.'),
                      )
                    : ListView.separated(
                        itemCount: _activeAlerts.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (_, i) {
                          final a = _activeAlerts[i];
                          final c = _categoryByKey(a.category);
                          final itemIcon = _alertIcon(a, c);
                          final itemColor = _alertIconColor(a, c);
                          final dist = _distanceKmTo(a.lat, a.lng);
                          final stateLabel = _alertStateLabel(a);
                          return ListTile(
                            leading: Icon(
                              a.isPriority ? Icons.priority_high : itemIcon,
                              color: a.isPriority ? const Color(0xFFC62828) : itemColor,
                            ),
                            title: Text(a.categoryLabel),
                            subtitle: Text(
                              [
                                if (a.isPriority) 'PRIORITARIA',
                                if (dist != null) '${dist.toStringAsFixed(1)} km',
                                _fmtCompactDateTime(a.createdAtMs),
                                stateLabel,
                                _alertVisibilityLabel(a),
                                if (a.note.isNotEmpty) a.note,
                              ].join(' · '),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            onTap: () {
                              Navigator.of(context).pop();
                              _mapController.move(LatLng(a.lat, a.lng), 14.5);
                              _openAlertDetails(a);
                            },
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
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

    final myLatLng = _myPosition == null
        ? null
        : LatLng(_myPosition!.latitude, _myPosition!.longitude);

    final visibleStations = _visibleStationsForMap();

    final stationMarkersCarab = visibleStations
        .where((s) => s.institution == 'CARABINEROS')
        .map((s) => Marker(point: LatLng(s.lat, s.lng), width: 48, height: 48, child: GestureDetector(onTap: () => _openStationDetails(s), behavior: HitTestBehavior.opaque, child: Center(child: _stationPointMarker(s)))))
        .toList();

    final stationMarkersPdi = visibleStations
        .where((s) => s.institution == 'PDI')
        .map((s) => Marker(point: LatLng(s.lat, s.lng), width: 48, height: 48, child: GestureDetector(onTap: () => _openStationDetails(s), behavior: HitTestBehavior.opaque, child: Center(child: _stationPointMarker(s)))))
        .toList();

    final stationMarkersBenc = visibleStations
        .where((s) => s.institution == 'BENCINERA')
        .map((s) => Marker(point: LatLng(s.lat, s.lng), width: 48, height: 48, child: GestureDetector(onTap: () => _openStationDetails(s), behavior: HitTestBehavior.opaque, child: Center(child: _stationPointMarker(s)))))
        .toList();

    final stationMarkersPeaje = visibleStations
        .where((s) => s.institution == 'PEAJE')
        .map((s) => Marker(point: LatLng(s.lat, s.lng), width: 48, height: 48, child: GestureDetector(onTap: () => _openStationDetails(s), behavior: HitTestBehavior.opaque, child: Center(child: _stationPointMarker(s)))))
        .toList();

    final stationMarkersCrit = visibleStations
        .where((s) => s.institution == 'CRITICO')
        .map((s) => Marker(point: LatLng(s.lat, s.lng), width: 48, height: 48, child: GestureDetector(onTap: () => _openStationDetails(s), behavior: HitTestBehavior.opaque, child: Center(child: _stationPointMarker(s)))))
        .toList();

    final alertMarkers = _activeAlerts.map((a) {
      final c = _categoryByKey(a.category);
      final risk = _riskLevelOf(a);
      final riskColor = _riskColor(risk);
      final icon = _alertIcon(a, c);
      final color = _alertIconColor(a, c);
      final bearing = _alertMarkerBearing(a, myLatLng);
      final stateLabel = _alertStateLabel(a);
      final timeLabel = _fmtCompactDateTime(a.createdAtMs);

      return Marker(
        point: LatLng(a.lat, a.lng),
        width: 82,
        height: 92,
        child: GestureDetector(
          onTap: () => _openAlertDetails(a),
          behavior: HitTestBehavior.opaque,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                    boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4)],
                    border: Border.all(color: riskColor.withValues(alpha: 0.6), width: 2),
                  ),
                  child: Transform.rotate(
                    angle: bearing,
                    child: Icon(Icons.navigation, color: riskColor, size: 15),
                  ),
                ),
                const SizedBox(height: 2),
                Container(
                  constraints: const BoxConstraints(maxWidth: 78),
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.96),
                    borderRadius: BorderRadius.circular(999),
                    boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 4)],
                    border: Border.all(color: riskColor.withValues(alpha: 0.22)),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        stateLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.w700,
                          color: riskColor,
                        ),
                      ),
                      Text(
                        timeLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 8, color: Colors.black54, height: 1.0),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 2),
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                    boxShadow: const [
                      BoxShadow(color: Colors.black26, blurRadius: 6),
                    ],
                    border: Border.all(color: riskColor.withValues(alpha: 0.6), width: 2),
                  ),
                  child: Icon(icon, color: color == c.color ? riskColor : color, size: 19),
                ),
              ],
            ),
          ),
        ),
      );
    }).toList();

    final helperMarkers = _activeAlerts
        .expand(
          (a) => a.helperMembers
              .where((helper) => helper.lat != null && helper.lng != null)
              .map(
                (helper) => Marker(
                  point: LatLng(helper.lat!, helper.lng!),
                  width: 50,
                  height: 50,
                  child: GestureDetector(
                    onTap: () => _openAlertDetails(a),
                    behavior: HitTestBehavior.opaque,
                    child: const Center(
                      child: CircleAvatar(
                        radius: 18,
                        backgroundColor: Colors.green,
                        child: Icon(Icons.directions_car, color: Colors.white, size: 18),
                      ),
                    ),
                  ),
                ),
              ),
        )
        .toList();

    final alertRiskCircles = _activeAlerts
        .map((a) {
          final level = _riskLevelOf(a);
          final radius = switch (level) {
            _RiskLevel.high => 320.0,
            _RiskLevel.medium => 220.0,
            _RiskLevel.low => 130.0,
          };
          final color = _riskColor(level);
          return CircleMarker(
            point: LatLng(a.lat, a.lng),
            radius: radius,
            useRadiusInMeter: true,
            color: color.withValues(alpha: 0.10),
            borderColor: color.withValues(alpha: 0.28),
            borderStrokeWidth: 1,
          );
        })
        .toList();

    final zonePolygons = _geoZones
        .where((z) => z.points.length >= 3)
        .map(
          (z) => Polygon(
            points: z.points,
            color: z.color.withValues(alpha: 0.36),
            borderColor: z.color,
            borderStrokeWidth: 2,
          ),
        )
        .toList();

    final draftZoneMarkers = _zoneDraftPoints
        .map(
          (p) => Marker(
            point: p,
            width: 18,
            height: 18,
            child: Container(
              decoration: BoxDecoration(
                color: _zoneDraftColor,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2),
              ),
            ),
          ),
        )
        .toList();

    final zoneNameMarkers = _geoZones
        .where((z) => z.points.length >= 3)
        .map(
          (z) => Marker(
            point: z.labelPoint,
            width: 140,
            height: 28,
            child: Center(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _isAdmin ? () => _openZoneManageSheet(z) : null,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.92),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: z.color, width: 1.5),
                  ),
                  child: Text(
                    z.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      color: z.color,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),
          ),
        )
        .toList();

    final poiMarkers = _pois.map((p) {
      try {
        final lat = (p['lat'] as num).toDouble();
        final lng = (p['lng'] as num).toDouble();
        final cat = (p['category'] ?? 'otro') as String;
        IconData iconData = Icons.place;
        Color iconColor = Colors.blueGrey;
        switch (cat) {
          case 'centro_comercial':
            iconData = Icons.storefront;
            iconColor = Colors.deepPurple;
            break;
          case 'vulcanizacion':
            iconData = Icons.build;
            iconColor = Colors.orange;
            break;
          case 'parking':
            iconData = Icons.local_parking;
            iconColor = Colors.teal;
            break;
          default:
            iconData = Icons.place;
            iconColor = Colors.blueGrey;
        }

        return Marker(
          point: LatLng(lat, lng),
          width: 40,
          height: 40,
          child: GestureDetector(
            onTap: () => _showPoiDetails(p),
            behavior: HitTestBehavior.opaque,
            child: Center(
              child: Icon(iconData, size: 26, color: iconColor),
            ),
          ),
        );
      } catch (_) {
        return Marker(point: _mapCenter, width: 1, height: 1, child: const SizedBox.shrink());
      }
    }).toList();

    final markers = <Marker>[
      if (_layerVisible['carabineros'] == true) ...stationMarkersCarab,
      if (_layerVisible['pdi'] == true) ...stationMarkersPdi,
      if (_layerVisible['bencineras'] == true) ...stationMarkersBenc,
      if (_layerVisible['peajes'] == true) ...stationMarkersPeaje,
      if (_layerVisible['criticos'] == true) ...stationMarkersCrit,
      if ((_layerVisible['citizen'] == true) || (_layerVisible['rapidas'] == true)) ...alertMarkers,
      ...helperMarkers,
      if (_layerVisible['pois'] == true) ...poiMarkers,
      if (_layerVisible['zones'] == true) ...zoneNameMarkers,
      ...draftZoneMarkers,
      if (myLatLng != null)
        Marker(
          point: myLatLng,
          width: 24,
          height: 24,
          child: const Icon(Icons.my_location, size: 22, color: Colors.blue),
        ),
    ];

    return Stack(
      children: [
        Positioned.fill(
          child: FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _mapCenter,
              initialZoom: _mapZoom,
              minZoom: 4,
              maxZoom: 18,
              onMapReady: () {
                _focusInitial();
              },
              onPositionChanged: (position, hasGesture) {
                final center = position.center;
                final zoom = position.zoom;
                if (!mounted) return;
                setState(() {
                  _mapCenter = center;
                  _mapZoom = zoom;
                });
              },
              onTap: (_, point) async {
                if (_drawZoneMode && _isAdmin) {
                  setState(() {
                    _zoneDraftPoints = [..._zoneDraftPoints, point];
                  });
                  return;
                }
                if (_pickWazePointOnMap && _isAdmin) {
                  setState(() {
                    _pickWazePointOnMap = false;
                  });
                  await _fetchWazeAndPersistAt(point);
                  return;
                }
                if (!_pickPointOnMap || _pendingCategory == null) return;
                final category = _pendingCategory!;
                final note = _pendingNote;
                final publishConfig = _pendingPublishConfig;
                final customLabel = _pendingCustomLabel;
                final customIconKey = _pendingCustomIconKey;
                final pendingPhoto = _pendingCreatePhoto;
                final forcePriority = _pendingForcePriority;
                final forceApproved = _pendingForceApproved;
                setState(() {
                  _pickPointOnMap = false;
                  _pendingCategory = null;
                  _pendingNote = '';
                  _pendingPublishConfig = null;
                  _pendingCustomLabel = '';
                  _pendingCustomIconKey = null;
                  _pendingCreatePhoto = null;
                  _pendingForcePriority = false;
                  _pendingForceApproved = false;
                });
                if (publishConfig == null) return;
                await _createAlert(
                  category: category,
                  point: point,
                  note: note,
                  publishConfig: publishConfig,
                  customLabel: customLabel,
                  customIconKey: customIconKey,
                  initialPhoto: pendingPhoto,
                  forcePriority: forcePriority,
                  forceApproved: forceApproved,
                );
              },
            ),
            children: [
              TileLayer(
                urlTemplate:
                    'https://mt{s}.google.com/vt/lyrs=${_googleTileLayerCode(_mobileMapMode)}&x={x}&y={y}&z={z}',
                subdomains: const ['0', '1', '2', '3'],
                userAgentPackageName: 'com.lamano.clonewhatsapp',
              ),
              if (zonePolygons.isNotEmpty)
                PolygonLayer(polygons: zonePolygons),
              if (alertRiskCircles.isNotEmpty)
                CircleLayer(circles: alertRiskCircles),
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
                    CircleMarker(
                      point: myLatLng,
                      radius: 120 + (_scannerCtrl.value * 420),
                      useRadiusInMeter: true,
                      color: Colors.cyan.withValues(alpha: 0.06 * (1 - _scannerCtrl.value)),
                      borderColor: Colors.cyan.withValues(alpha: 0.28 * (1 - _scannerCtrl.value)),
                      borderStrokeWidth: 1,
                    ),
                  ],
                ),
            ],
          ),
        ),
        // Filter button (top) — opens modal to select visible layers
        Positioned(
          left: 8,
          right: 8,
          top: 8,
          child: SafeArea(
            child: Row(
              children: [
                FilledButton.icon(
                  onPressed: _openFiltersSheet,
                  icon: const Icon(Icons.filter_list),
                  label: const Text('Filtros'),
                ),
              ],
            ),
          ),
        ),
        Positioned(
          right: 12,
          top: 70,
          child: Material(
            color: Colors.white,
            shape: const CircleBorder(),
            elevation: 8,
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: _centerOnMyLocationFromButton,
              child: Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.black12),
                ),
                child: Transform.rotate(
                  angle: ((_hasHeading ? _headingDeg : 0) * math.pi) / 180,
                  child: const Icon(Icons.navigation, color: Color(0xFF37474F), size: 26),
                ),
              ),
            ),
          ),
        ),
        if (_proximityBannerTitle != null && _proximityBannerBody != null)
          Positioned(
            left: 12,
            right: 70,
            top: 18,
            child: Material(
              color: Colors.white,
              elevation: 10,
              borderRadius: BorderRadius.circular(14),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: _proximityBannerColor.withValues(alpha: 0.14),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(_proximityBannerIcon, size: 16, color: _proximityBannerColor),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _proximityBannerTitle!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _proximityBannerBody!,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 11, color: Colors.black87),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        if (_pickPointOnMap)
          Positioned(
            right: 12,
            bottom: 72,
            child: FloatingActionButton.small(
              heroTag: 'fab_cancel_pick',
              onPressed: () {
                setState(() {
                  _pickPointOnMap = false;
                  _pickWazePointOnMap = false;
                  _pendingCategory = null;
                  _pendingNote = '';
                  _pendingPublishConfig = null;
                  _pendingCustomLabel = '';
                  _pendingCustomIconKey = null;
                  _pendingCreatePhoto = null;
                  _pendingForcePriority = false;
                  _pendingForceApproved = false;
                });
              },
              tooltip: 'Cancelar marcado',
              child: const Icon(Icons.close),
            ),
          ),
        if (_pickWazePointOnMap)
          Positioned(
            right: 12,
            bottom: 72,
            child: FloatingActionButton.small(
              heroTag: 'fab_cancel_waze_pick',
              onPressed: () {
                setState(() {
                  _pickWazePointOnMap = false;
                });
              },
              tooltip: 'Cancelar selección Waze',
              child: const Icon(Icons.close),
            ),
          ),
        if (_isAdmin)
          Positioned(
            left: 12,
            top: 126,
            child: Material(
              color: Colors.black.withValues(alpha: 0.36),
              borderRadius: BorderRadius.circular(999),
              child: InkWell(
                borderRadius: BorderRadius.circular(999),
                onTap: _drawZoneMode ? null : _openZoneDrawSetupSheet,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _drawZoneMode ? Icons.draw : Icons.polyline,
                        size: 16,
                        color: Colors.white,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        _drawZoneMode ? 'Dibujando...' : 'Dibujar',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        if (_isAdmin)
          Positioned(
            left: 12,
            top: 168,
            child: Material(
              color: _pickWazePointOnMap
                  ? const Color(0xFFF59E0B).withValues(alpha: 0.92)
                  : Colors.black.withValues(alpha: 0.36),
              borderRadius: BorderRadius.circular(999),
              child: InkWell(
                borderRadius: BorderRadius.circular(999),
                onTap: _wazeLoading
                    ? null
                    : () {
                        if (_pickWazePointOnMap) {
                          setState(() => _pickWazePointOnMap = false);
                          return;
                        }
                        _openWazeAdminMode();
                      },
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _wazeLoading
                            ? Icons.hourglass_top
                            : (_pickWazePointOnMap ? Icons.place : Icons.traffic),
                        size: 16,
                        color: Colors.white,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        _wazeLoading
                          ? 'Waze...'
                          : (_pickWazePointOnMap ? 'Waze ${_wazeRadiusMeters}m: toca mapa' : 'Waze ${_wazeRadiusMeters}m'),
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        if (_isAdmin)
          Positioned(
            left: 12,
            top: 210,
            child: Material(
              color: Colors.black.withValues(alpha: 0.36),
              borderRadius: BorderRadius.circular(999),
              child: InkWell(
                borderRadius: BorderRadius.circular(999),
                onTap: _openZonesAdminSheet,
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.list_alt, size: 16, color: Colors.white),
                      SizedBox(width: 6),
                      Text(
                        'Zonas',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        if (_isAdmin && _drawZoneMode)
          Positioned(
            left: 12,
            right: 92,
            bottom: 18,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.42),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${_zoneDraftName.isEmpty ? 'Zona' : _zoneDraftName} · ${_zoneDraftPoints.length} pts',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 11,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: _undoZonePoint,
                    tooltip: 'Deshacer',
                    icon: const Icon(Icons.undo, color: Colors.white, size: 20),
                  ),
                  IconButton(
                    onPressed: _saveZoneDraft,
                    tooltip: 'Guardar',
                    icon: const Icon(Icons.check, color: Colors.white, size: 20),
                  ),
                  IconButton(
                    onPressed: () => _clearZoneDraft(exitMode: true),
                    tooltip: 'Cancelar',
                    icon: const Icon(Icons.close, color: Colors.white, size: 20),
                  ),
                ],
              ),
            ),
          ),
        Positioned(
          right: 14,
          bottom: 158,
          child: Material(
            color: Colors.white,
            elevation: 8,
            borderRadius: BorderRadius.circular(14),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<_MobileMapMode>(
                  value: _mobileMapMode,
                  isDense: true,
                  borderRadius: BorderRadius.circular(10),
                  icon: const Icon(Icons.layers_outlined),
                  items: _MobileMapMode.values
                      .map(
                        (mode) => DropdownMenuItem<_MobileMapMode>(
                          value: mode,
                          child: Text(_mobileMapModeLabel(mode)),
                        ),
                      )
                      .toList(),
                  onChanged: (mode) {
                    if (mode == null) return;
                    setState(() => _mobileMapMode = mode);
                  },
                ),
              ),
            ),
          ),
        ),
        Positioned(
          right: 14,
          bottom: 96,
          child: Material(
            color: Colors.white,
            elevation: 8,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: _openCreateAlertSheet,
              child: const SizedBox(
                width: 54,
                height: 54,
                child: Icon(Icons.add_alert, size: 30, color: ColorConstants.themeColor),
              ),
            ),
          ),
        ),
        Positioned(
          right: 14,
          bottom: 18,
          child: Material(
            color: Colors.white,
            elevation: 8,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: _openAlertsPanel,
              onLongPress: _openCreateAlertSheet,
              child: SizedBox(
                width: 62,
                height: 62,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    const Icon(Icons.warning_amber_rounded, size: 36, color: Color(0xFFF9A825)),
                    if (_activeAlerts.isNotEmpty)
                      Positioned(
                        top: 10,
                        right: 10,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(
                            color: const Color(0xFFD32F2F),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            '${_activeAlerts.length}',
                            style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w700),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

enum _MobileMapMode { roadmap, satellite, terrain }

enum _RiskLevel { low, medium, high }

class _DetailPill extends StatelessWidget {
  final IconData icon;
  final String label;

  const _DetailPill({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFFF3F6F7),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0xFFE0E5E7)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: Colors.black54),
          const SizedBox(width: 5),
          Text(
            label,
            style: const TextStyle(fontSize: 12, color: Colors.black87, fontWeight: FontWeight.w600),
          ),
        ],
      ),
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
  final String institution;
  final String address;
  final String brand;
  final String detailUrl;
  final Map<String, String> fuelPrices;

  const _Comisaria({
    required this.stationId,
    required this.name,
    required this.lat,
    required this.lng,
    required this.regionName,
    required this.comunaName,
    required this.institution,
    this.address = '',
    this.brand = '',
    this.detailUrl = '',
    this.fuelPrices = const {},
  });

  static double _toDouble(dynamic value) {
    if (value is num) return value.toDouble();
    final parsed = double.tryParse(value?.toString() ?? '');
    return parsed ?? 0;
  }

  factory _Comisaria.fromJson(Map<String, dynamic> json) {
    return _Comisaria(
      stationId: (json['stationId'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      lat: _toDouble(json['lat']),
      lng: _toDouble(json['lng']),
      regionName: (json['regionName'] ?? '').toString(),
      comunaName: (json['comunaName'] ?? '').toString(),
      institution: (json['institution'] ?? 'CARABINEROS').toString().toUpperCase(),
      address: (json['address'] ?? '').toString(),
      brand: (json['brand'] ?? '').toString(),
      detailUrl: (json['detailUrl'] ?? '').toString(),
      fuelPrices: ((json['fuelPrices'] as Map<String, dynamic>?) ?? const {})
          .map((k, v) => MapEntry(k, '$v')),
    );
  }
}

class _AlertCategory {
  final String key;
  final String label;
  final IconData icon;
  final Color color;
  final bool isHelp;
  final bool isPriorityTemplate;
  final int sortOrder;

  const _AlertCategory(
    this.key,
    this.label,
    this.icon,
    this.color, {
    this.isHelp = false,
    this.isPriorityTemplate = false,
    this.sortOrder = 0,
  });
}

class _AlertPublishConfig {
  final int startAtMs;
  final int expiresAtMs;
  final bool isPermanent;
  final bool recurringDaily;
  final int? scheduleStartMinute;
  final int? scheduleEndMinute;

  const _AlertPublishConfig({
    required this.startAtMs,
    required this.expiresAtMs,
    required this.isPermanent,
    this.recurringDaily = false,
    this.scheduleStartMinute,
    this.scheduleEndMinute,
  });
}

class _AlertVisualOption {
  final String key;
  final IconData icon;
  final Color color;

  const _AlertVisualOption(this.key, this.icon, this.color);
}

class _CitizenAlert {
  final String id;
  final String category;
  final String categoryLabel;
  final bool isHelp;
  final String note;
  final double lat;
  final double lng;
  final String createdByUid;
  final String createdByName;
  final int createdAtMs;
  final int startAtMs;
  final int expiresAtMs;
  final String status;
  final bool isPriority;
  final bool isPermanent;
  final bool recurringDaily;
  final int? scheduleStartMinute;
  final int? scheduleEndMinute;
  final bool approvedByAdmin;
  final int? approvedAtMs;
  final String? customIconKey;
  final List<String> confirmUids;
  final List<String> discardUids;
  final String? helperUid;
  final String? helperName;
  final double? helperDistanceKm;
  final int? helperEtaMin;
  final double? helperLat;
  final double? helperLng;
  final List<_HelperMember> helperMembers;
  final List<_AlertEvidence> evidenceItems;

  int get confirmCount => confirmUids.length;
  int get discardCount => discardUids.length;

  const _CitizenAlert({
    required this.id,
    required this.category,
    required this.categoryLabel,
    required this.isHelp,
    required this.note,
    required this.lat,
    required this.lng,
    required this.createdByUid,
    required this.createdByName,
    required this.createdAtMs,
    required this.startAtMs,
    required this.expiresAtMs,
    required this.status,
    required this.isPriority,
    required this.isPermanent,
    required this.recurringDaily,
    required this.scheduleStartMinute,
    required this.scheduleEndMinute,
    required this.approvedByAdmin,
    required this.approvedAtMs,
    required this.customIconKey,
    required this.confirmUids,
    required this.discardUids,
    required this.helperUid,
    required this.helperName,
    required this.helperDistanceKm,
    required this.helperEtaMin,
    required this.helperLat,
    required this.helperLng,
    required this.helperMembers,
    required this.evidenceItems,
  });

  factory _CitizenAlert.fromDoc(QueryDocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data();
    return _CitizenAlert._fromMap(doc.id, d);
  }

  factory _CitizenAlert.fromSnapshot(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? const <String, dynamic>{};
    return _CitizenAlert._fromMap(doc.id, d);
  }

  factory _CitizenAlert._fromMap(String id, Map<String, dynamic> d) {
    final rawHelpers = (d['helperMembers'] as List<dynamic>? ?? const []);
    final parsedHelpers = rawHelpers
        .map((entry) => _HelperMember.fromMap(Map<String, dynamic>.from(entry as Map)))
        .toList();
    final rawEvidence = (d['evidenceItems'] as List<dynamic>? ?? const []);
    final parsedEvidence = rawEvidence
        .map((entry) => _AlertEvidence.fromMap(Map<String, dynamic>.from(entry as Map)))
        .toList()
      ..sort((a, b) => b.uploadedAtMs.compareTo(a.uploadedAtMs));

    if (parsedHelpers.isEmpty && (d['helperUid'] != null || d['helperName'] != null)) {
      parsedHelpers.add(
        _HelperMember(
          uid: (d['helperUid'] ?? '').toString(),
          name: (d['helperName'] ?? 'Usuario').toString(),
          distanceKm: (d['helperDistanceKm'] as num?)?.toDouble() ?? 0,
          etaMin: (d['helperEtaMin'] as num?)?.toInt() ?? 0,
          lat: (d['helperLat'] as num?)?.toDouble(),
          lng: (d['helperLng'] as num?)?.toDouble(),
        ),
      );
    }

    return _CitizenAlert(
      id: id,
      category: (d['category'] ?? '').toString(),
      categoryLabel: (d['categoryLabel'] ?? 'Alerta').toString(),
      isHelp: d['isHelp'] == true,
      note: (d['note'] ?? '').toString(),
      lat: (d['lat'] as num).toDouble(),
      lng: (d['lng'] as num).toDouble(),
      createdByUid: (d['createdByUid'] ?? '').toString(),
      createdByName: (d['createdByName'] ?? 'Usuario').toString(),
      createdAtMs: (d['createdAtMs'] as num?)?.toInt() ?? 0,
      startAtMs: (d['startAtMs'] as num?)?.toInt() ?? ((d['createdAtMs'] as num?)?.toInt() ?? 0),
      expiresAtMs: (d['expiresAtMs'] as num?)?.toInt() ?? 0,
      status: (d['status'] ?? 'active').toString(),
      isPriority: d['isPriority'] == true,
      isPermanent: d['isPermanent'] == true,
      recurringDaily: d['recurringDaily'] == true,
      scheduleStartMinute: (d['scheduleStartMinute'] as num?)?.toInt(),
      scheduleEndMinute: (d['scheduleEndMinute'] as num?)?.toInt(),
      approvedByAdmin: d['approvedByAdmin'] == true,
      approvedAtMs: (d['approvedAtMs'] as num?)?.toInt(),
        customIconKey: (d['customIconKey'] ?? '').toString().isEmpty
          ? null
          : (d['customIconKey'] ?? '').toString(),
      confirmUids: (d['confirmUids'] as List<dynamic>? ?? const []).map((e) => '$e').toList(),
      discardUids: (d['discardUids'] as List<dynamic>? ?? const []).map((e) => '$e').toList(),
      helperUid: d['helperUid'] as String?,
      helperName: d['helperName'] as String?,
      helperDistanceKm: (d['helperDistanceKm'] as num?)?.toDouble(),
      helperEtaMin: (d['helperEtaMin'] as num?)?.toInt(),
      helperLat: (d['helperLat'] as num?)?.toDouble(),
      helperLng: (d['helperLng'] as num?)?.toDouble(),
      helperMembers: parsedHelpers,
      evidenceItems: parsedEvidence,
    );
  }
}

class _GeoZone {
  final String id;
  final String name;
  final Color color;
  final List<LatLng> points;
  final int createdAtMs;
  final List<Map<String, String>> schedules;

  LatLng get labelPoint {
    if (points.isEmpty) return const LatLng(-33.4489, -70.6693);
    var sumLat = 0.0;
    var sumLng = 0.0;
    for (final p in points) {
      sumLat += p.latitude;
      sumLng += p.longitude;
    }
    return LatLng(sumLat / points.length, sumLng / points.length);
  }

  const _GeoZone({
    required this.id,
    required this.name,
    required this.color,
    required this.points,
    required this.createdAtMs,
    this.schedules = const [],
  });

  static Color _colorFromHex(String raw) {
    final hex = raw.trim().replaceAll('#', '');
    if (hex.length == 6) {
      final value = int.tryParse(hex, radix: 16);
      if (value != null) return Color(0xFF000000 | value);
    }
    return const Color(0xFFD32F2F);
  }

  factory _GeoZone.fromDoc(QueryDocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data();
    final rawPoints = (d['points'] as List<dynamic>? ?? const []);
    final points = rawPoints
        .map((p) => Map<String, dynamic>.from(p as Map))
        .map(
          (p) => LatLng(
            (p['lat'] as num?)?.toDouble() ?? 0,
            (p['lng'] as num?)?.toDouble() ?? 0,
          ),
        )
        .where((p) => p.latitude != 0 || p.longitude != 0)
        .toList();

    return _GeoZone(
      id: doc.id,
      name: (d['name'] ?? 'Zona').toString(),
      color: _colorFromHex((d['color'] ?? '#D32F2F').toString()),
      points: points,
      createdAtMs: (d['createdAtMs'] as num?)?.toInt() ?? 0,
      schedules: (d['schedules'] as List<dynamic>? ?? const [])
          .map((s) => Map<String, String>.from(s as Map? ?? <String,String>{}))
          .map((m) => <String,String>{'start': (m['start'] ?? '').toString(), 'end': (m['end'] ?? '').toString(), 'risk': (m['risk'] ?? '').toString()})
          .toList(),
    );
  }
}

class _SafePlace {
  final String id;
  final String name;
  final double lat;
  final double lng;
  final int? radiusMeters;

  const _SafePlace({required this.id, required this.name, required this.lat, required this.lng, this.radiusMeters});

  factory _SafePlace.fromDoc(QueryDocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data();
    final loc = d['location'] as Map<String, dynamic>? ?? <String, dynamic>{};
    return _SafePlace(
      id: doc.id,
      name: (d['name'] ?? 'Lugar seguro').toString(),
      lat: (loc['lat'] as num?)?.toDouble() ?? 0.0,
      lng: (loc['lng'] as num?)?.toDouble() ?? 0.0,
      radiusMeters: (d['radiusMeters'] as num?)?.toInt(),
    );
  }
}

class _AlertEvidence {
  final String url;
  final String note;
  final String uploadedByUid;
  final String uploadedByName;
  final int uploadedAtMs;

  const _AlertEvidence({
    required this.url,
    required this.note,
    required this.uploadedByUid,
    required this.uploadedByName,
    required this.uploadedAtMs,
  });

  factory _AlertEvidence.fromMap(Map<String, dynamic> map) {
    return _AlertEvidence(
      url: (map['url'] ?? '').toString(),
      note: (map['note'] ?? '').toString(),
      uploadedByUid: (map['uploadedByUid'] ?? '').toString(),
      uploadedByName: (map['uploadedByName'] ?? 'Usuario').toString(),
      uploadedAtMs: (map['uploadedAtMs'] as num?)?.toInt() ?? 0,
    );
  }
}

class _HelperMember {
  final String uid;
  final String name;
  final double distanceKm;
  final int etaMin;
  final double? lat;
  final double? lng;

  const _HelperMember({
    required this.uid,
    required this.name,
    required this.distanceKm,
    required this.etaMin,
    required this.lat,
    required this.lng,
  });

  factory _HelperMember.fromMap(Map<String, dynamic> map) {
    return _HelperMember(
      uid: (map['uid'] ?? '').toString(),
      name: (map['name'] ?? 'Usuario').toString(),
      distanceKm: (map['distanceKm'] as num?)?.toDouble() ?? 0,
      etaMin: (map['etaMin'] as num?)?.toInt() ?? 0,
      lat: (map['lat'] as num?)?.toDouble(),
      lng: (map['lng'] as num?)?.toDouble(),
    );
  }
}
