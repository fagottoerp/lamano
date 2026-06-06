import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/services.dart' show SystemSound, SystemSoundType;
import 'package:flutter_chat_demo/constants/constants.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

class MapaMundisPage extends StatefulWidget {
  const MapaMundisPage({super.key});

  @override
  State<MapaMundisPage> createState() => _MapaMundisPageState();
}

class _MapaMundisPageState extends State<MapaMundisPage>
  with SingleTickerProviderStateMixin {
  static const LatLng _chileCenter = LatLng(-35.6751, -71.5430);
  static const String _alertsCollection = 'citizen_alerts';

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

  final MapController _mapController = MapController();
  final Distance _distance = const Distance();
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FlutterLocalNotificationsPlugin _localNotif = FlutterLocalNotificationsPlugin();

  StreamSubscription<QuerySnapshot>? _alertsSub;
  StreamSubscription<Position>? _positionSub;
  Timer? _dispatchRotateTimer;
  late final AnimationController _scannerCtrl;

  List<_Comisaria> _allStations = const [];
  List<_CitizenAlert> _activeAlerts = const [];

  Position? _myPosition;
  bool _loading = true;
  String? _error;
  bool _focusedOnce = false;
  LatLng _mapCenter = _chileCenter;
  double _mapZoom = 5.2;

  bool _showNearestPanel = true;
  final Set<String> _expandedStations = <String>{};
  bool _pickPointOnMap = false;
  _AlertCategory? _pendingCategory;
  String _pendingNote = '';

  final Set<String> _notifiedNearAlerts = <String>{};
  final Set<String> _notifiedGlobalAlerts = <String>{};
  final Map<String, int> _userReputation = <String, int>{};
  int _dispatchIndex = 0;
  bool _alertsPrimed = false;

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

  @override
  void dispose() {
    _alertsSub?.cancel();
    _positionSub?.cancel();
    _dispatchRotateTimer?.cancel();
    _scannerCtrl.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    try {
      await _initLocalNotifications();

      final stationsFuture = _loadStations();
      final locationFuture = _resolveLocation();
      final results = await Future.wait([stationsFuture, locationFuture]);

      if (!mounted) return;
      setState(() {
        _allStations = results[0] as List<_Comisaria>;
        _myPosition = results[1] as Position?;
        if (_myPosition != null) {
          _mapCenter = LatLng(_myPosition!.latitude, _myPosition!.longitude);
          _mapZoom = 12.5;
        }
        _loading = false;
      });

      _focusInitial();
      _listenLiveAlerts();
      _startPositionTracking();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'No se pudo cargar el Mapa Mundis (GTA).';
      });
    }
  }

  Future<void> _initLocalNotifications() async {
    await _localNotif.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('app_icon'),
        iOS: DarwinInitializationSettings(),
      ),
    );
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
      setState(() => _myPosition = p);
      _maybeNotifyNearbyAlerts();
      _syncHelperLocationForActiveAlerts(p);
    });
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
    _alertsSub = _firestore
        .collection(_alertsCollection)
        .where('status', isEqualTo: 'active')
        .snapshots()
        .listen((snap) {
      final now = DateTime.now().millisecondsSinceEpoch;
      final alerts = snap.docs
          .map(_CitizenAlert.fromDoc)
          .where((a) => a.expiresAtMs > now)
          .toList()
        ..sort((a, b) => b.createdAtMs.compareTo(a.createdAtMs));

      if (!mounted) return;
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
    });
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
        : _chileCenter;
    final zoom = hasMe ? 12.5 : 5.2;

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
      _mapZoom = 13;
    });
    _mapController.move(me, 13);
  }

  List<_Comisaria> _visibleStationsForMap() {
    if (_allStations.isEmpty) return const [];
    final center = _mapCenter;
    final maxCount = switch (_mapZoom) {
      < 7.5 => 80,
      < 9.5 => 180,
      < 11.5 => 320,
      _ => 945,
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

    final myLat = _myPosition!.latitude;
    final myLng = _myPosition!.longitude;

    for (final alert in _activeAlerts) {
      if (_notifiedNearAlerts.contains(alert.id)) continue;

      final meters = Geolocator.distanceBetween(myLat, myLng, alert.lat, alert.lng);
      if (meters > 700) continue;

      final km = meters / 1000;
      final body = '${alert.categoryLabel} cerca (${km.toStringAsFixed(1)} km).';
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

      _notifiedNearAlerts.add(alert.id);
    }
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

  Future<void> _openInGoogleMaps(double lat, double lng) async {
    final uri = Uri.parse(
      'https://www.google.com/maps/search/?api=1&query=$lat,$lng',
    );
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  _AlertCategory _categoryByKey(String key) {
    return _categories.firstWhere(
      (c) => c.key == key,
      orElse: () => const _AlertCategory('otro', 'Alerta', Icons.warning, Colors.red),
    );
  }

  Future<void> _openCreateAlertSheet() async {
    final selected = await showModalBottomSheet<_AlertCategory>(
      context: context,
      isScrollControlled: true,
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
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
              SizedBox(
                height: 350,
                child: GridView.count(
                  crossAxisCount: 2,
                  childAspectRatio: 2.5,
                  children: _categories
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

  Future<void> _openCreateModeSheet(_AlertCategory category) async {
    final noteCtrl = TextEditingController();
    final mode = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (_) => Padding(
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
              controller: noteCtrl,
              maxLength: 140,
              decoration: InputDecoration(
                labelText: category.isHelp
                    ? 'Describe brevemente la ayuda'
                    : 'Detalle opcional de la alerta',
                border: const OutlineInputBorder(),
              ),
            ),
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
    );

    final note = noteCtrl.text.trim();
    noteCtrl.dispose();

    if (mode == null || !mounted) return;

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
      );
      return;
    }

    setState(() {
      _pendingCategory = category;
      _pendingNote = note;
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
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    final uid = user?.uid ?? '';
    final nickname =
        (user?.displayName?.trim().isNotEmpty == true) ? user!.displayName!.trim() : 'Usuario';

    final now = DateTime.now().millisecondsSinceEpoch;
    final expiresAt = now + const Duration(hours: 6).inMilliseconds;

    await _firestore.collection(_alertsCollection).add({
      'category': category.key,
      'categoryLabel': category.label,
      'isHelp': category.isHelp,
      'note': note,
      'lat': point.latitude,
      'lng': point.longitude,
      'createdByUid': uid,
      'createdByName': nickname,
      'createdAtMs': now,
      'expiresAtMs': expiresAt,
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
    });

    if (!mounted) return;
    SystemSound.play(SystemSoundType.alert);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Alerta publicada para toda la comunidad.')),
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

  String _relativeUntil(int expiresAtMs) {
    final left = expiresAtMs - DateTime.now().millisecondsSinceEpoch;
    if (left <= 0) return 'expirada';
    final min = (left / 60000).floor();
    if (min < 60) return 'vence en ${min}m';
    final h = min ~/ 60;
    final rem = min % 60;
    return 'vence en ${h}h ${rem}m';
  }

  double? _distanceKmTo(double lat, double lng) {
    if (_myPosition == null) return null;
    final meters = Geolocator.distanceBetween(_myPosition!.latitude, _myPosition!.longitude, lat, lng);
    return meters / 1000;
  }

  void _openAlertDetails(_CitizenAlert alert) {
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
            final originLabel = live.createdByUid.isEmpty
                ? 'del sistema'
                : '${live.createdByName} (usuario)';

            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(category.icon, color: category.color),
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
                    if (dist != null) ...[
                      const SizedBox(height: 6),
                      Text('Distancia: ${dist.toStringAsFixed(1)} km'),
                    ],
                    const SizedBox(height: 4),
                    Text('Generada por: $originLabel'),
                    Text('Reputación: $rep'),
                    Text(
                      _riskLabel(risk),
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: _riskColor(risk),
                      ),
                    ),
                    Text(_relativeUntil(live.expiresAtMs)),
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
    );
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
              const Text(
                'Alertas ciudadanas activas',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
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
                          final dist = _distanceKmTo(a.lat, a.lng);
                          return ListTile(
                            leading: Icon(c.icon, color: c.color),
                            title: Text(a.categoryLabel),
                            subtitle: Text(
                              [
                                if (dist != null) '${dist.toStringAsFixed(1)} km',
                                _relativeUntil(a.expiresAtMs),
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

    final nearest = _nearestStations();
    final myLatLng = _myPosition == null
        ? null
        : LatLng(_myPosition!.latitude, _myPosition!.longitude);

    final visibleStations = _visibleStationsForMap();

    final stationMarkers = visibleStations
        .map(
          (s) => Marker(
            point: LatLng(s.lat, s.lng),
            width: 28,
            height: 28,
            child: Image.asset('assets/carabineros_roundel.png', width: 24, height: 24),
          ),
        )
        .toList();

    final alertMarkers = _activeAlerts.map((a) {
      final c = _categoryByKey(a.category);
      final risk = _riskLevelOf(a);
      final riskColor = _riskColor(risk);
        final icon = a.isHelp
          ? (a.helperMembers.isEmpty
              ? Icons.help_center
              : Icons.handshake)
          : c.icon;
        final color = a.isHelp
          ? (a.helperMembers.isEmpty
              ? Colors.deepPurple
              : Colors.green)
          : c.color;

      return Marker(
        point: LatLng(a.lat, a.lng),
        width: 56,
        height: 56,
        child: GestureDetector(
          onTap: () => _openAlertDetails(a),
          behavior: HitTestBehavior.opaque,
          child: Center(
            child: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
                boxShadow: const [
                  BoxShadow(color: Colors.black26, blurRadius: 6),
                ],
                border: Border.all(color: riskColor.withValues(alpha: 0.6), width: 2),
              ),
              child: Icon(icon, color: color == c.color ? riskColor : color, size: 22),
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

    final markers = <Marker>[
      ...stationMarkers,
      ...alertMarkers,
      ...helperMarkers,
      if (myLatLng != null)
        Marker(
          point: myLatLng,
          width: 24,
          height: 24,
          child: const Icon(Icons.my_location, size: 22, color: Colors.blue),
        ),
    ];

    Widget actionTile({
      required IconData icon,
      required String label,
      required VoidCallback? onTap,
      bool highlight = false,
    }) {
      final enabled = onTap != null;
      final bgColor = highlight
          ? ColorConstants.themeColor.withValues(alpha: enabled ? 0.12 : 0.06)
          : const Color(0xFFF4F7F8);
      final borderColor = highlight
          ? ColorConstants.themeColor.withValues(alpha: enabled ? 0.28 : 0.14)
          : ColorConstants.divider;
      final iconColor = enabled
          ? (highlight ? ColorConstants.themeColor : const Color(0xFF47615A))
          : Colors.black26;
      final textColor = enabled ? ColorConstants.textPrimary : Colors.black38;

      return Expanded(
        child: SizedBox(
          height: 56,
          child: Material(
            color: bgColor,
            borderRadius: BorderRadius.circular(14),
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(14),
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: borderColor),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(icon, size: 18, color: iconColor),
                    const SizedBox(height: 4),
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: textColor,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Stack(
      children: [
        Column(
          children: [
            Container(
              width: double.infinity,
              color: Colors.white,
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.map, color: ColorConstants.themeColor, size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Mapa Mundis (GTA)',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: ColorConstants.textPrimary,
                          ),
                        ),
                      ),
                      Text(
                        '${visibleStations.length}/${_allStations.length} comisarías',
                        style: const TextStyle(fontSize: 11, color: Colors.black54),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      actionTile(
                        icon: Icons.add_alert,
                        label: 'Marcar alerta',
                        onTap: _openCreateAlertSheet,
                        highlight: true,
                      ),
                      const SizedBox(width: 8),
                      actionTile(
                        icon: Icons.my_location,
                        label: 'Mi ubicación',
                        onTap: myLatLng != null ? _goToMyLocation : null,
                      ),
                      const SizedBox(width: 8),
                      actionTile(
                        icon: Icons.notifications_active_outlined,
                        label: 'Alertas +${_activeAlerts.length}',
                        onTap: _openAlertsPanel,
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Expanded(
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
                    if (!_pickPointOnMap || _pendingCategory == null) return;
                    final category = _pendingCategory!;
                    final note = _pendingNote;
                    setState(() {
                      _pickPointOnMap = false;
                      _pendingCategory = null;
                      _pendingNote = '';
                    });
                    await _createAlert(
                      category: category,
                      point: point,
                      note: note,
                    );
                  },
                ),
                children: [
                  TileLayer(
                    urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                    userAgentPackageName: 'com.lamano.clonewhatsapp',
                  ),
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
            if (nearest.isNotEmpty && _showNearestPanel)
              Container(
                height: 150,
                color: Colors.white,
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(10, 6, 6, 0),
                      child: Row(
                        children: [
                          const Text(
                            'Comisarías cercanas',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: ColorConstants.textPrimary,
                            ),
                          ),
                          const Spacer(),
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            icon: const Icon(Icons.keyboard_arrow_down),
                            tooltip: 'Ocultar panel',
                            onPressed: () {
                              setState(() {
                                _showNearestPanel = false;
                              });
                            },
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.all(10),
                        itemBuilder: (_, i) {
                          final st = nearest[i];
                          final key = st.stationId.isEmpty ? '${st.lat},${st.lng}' : st.stationId;
                          final expanded = _expandedStations.contains(key);
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
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 180),
                              width: expanded ? 280 : 220,
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: const Color(0xFFF6F8FA),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: ColorConstants.divider),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          st.name,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w700,
                                            fontSize: 12,
                                          ),
                                        ),
                                      ),
                                      IconButton(
                                        visualDensity: VisualDensity.compact,
                                        iconSize: 18,
                                        tooltip: expanded ? 'Contraer' : 'Expandir',
                                        icon: Icon(
                                          expanded
                                              ? Icons.expand_less
                                              : Icons.expand_more,
                                        ),
                                        onPressed: () {
                                          setState(() {
                                            if (expanded) {
                                              _expandedStations.remove(key);
                                            } else {
                                              _expandedStations.add(key);
                                            }
                                          });
                                        },
                                      ),
                                    ],
                                  ),
                                  if (expanded) ...[
                                    const SizedBox(height: 4),
                                    Text(
                                      '${st.comunaName}, ${st.regionName}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontSize: 11,
                                        color: Colors.black54,
                                      ),
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
                                          onPressed: () => _openInGoogleMaps(st.lat, st.lng),
                                          icon: const Icon(Icons.navigation_outlined),
                                          tooltip: 'Abrir en Google Maps',
                                        ),
                                      ],
                                    ),
                                  ],
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
                ),
              ),
            if (nearest.isNotEmpty && !_showNearestPanel)
              Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.only(right: 10, bottom: 10),
                  child: FilledButton.icon(
                    onPressed: () {
                      setState(() {
                        _showNearestPanel = true;
                      });
                    },
                    icon: const Icon(Icons.keyboard_arrow_up),
                    label: const Text('Comisarías'),
                  ),
                ),
              ),
          ],
        ),
        if (_activeAlerts.isNotEmpty)
          Positioned(
            left: 10,
            right: 10,
            top: 54,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xE6000000),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.white24),
              ),
              child: Row(
                children: [
                  const Icon(Icons.sensors, color: Colors.cyanAccent, size: 16),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'DISPATCH: ${_activeAlerts[_dispatchIndex].categoryLabel} · ${_activeAlerts[_dispatchIndex].createdByName}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.2,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        if (_pickPointOnMap)
          Positioned(
            right: 12,
            bottom: 190,
            child: FloatingActionButton.small(
              heroTag: 'fab_cancel_pick',
              onPressed: () {
                setState(() {
                  _pickPointOnMap = false;
                  _pendingCategory = null;
                  _pendingNote = '';
                });
              },
              tooltip: 'Cancelar marcado',
              child: const Icon(Icons.close),
            ),
          ),
      ],
    );
  }
}

enum _RiskLevel { low, medium, high }

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

class _AlertCategory {
  final String key;
  final String label;
  final IconData icon;
  final Color color;
  final bool isHelp;

  const _AlertCategory(this.key, this.label, this.icon, this.color, {this.isHelp = false});
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
  final int expiresAtMs;
  final String status;
  final List<String> confirmUids;
  final List<String> discardUids;
  final String? helperUid;
  final String? helperName;
  final double? helperDistanceKm;
  final int? helperEtaMin;
  final double? helperLat;
  final double? helperLng;
  final List<_HelperMember> helperMembers;

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
    required this.expiresAtMs,
    required this.status,
    required this.confirmUids,
    required this.discardUids,
    required this.helperUid,
    required this.helperName,
    required this.helperDistanceKm,
    required this.helperEtaMin,
    required this.helperLat,
    required this.helperLng,
    required this.helperMembers,
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
      expiresAtMs: (d['expiresAtMs'] as num?)?.toInt() ?? 0,
      status: (d['status'] ?? 'active').toString(),
      confirmUids: (d['confirmUids'] as List<dynamic>? ?? const []).map((e) => '$e').toList(),
      discardUids: (d['discardUids'] as List<dynamic>? ?? const []).map((e) => '$e').toList(),
      helperUid: d['helperUid'] as String?,
      helperName: d['helperName'] as String?,
      helperDistanceKm: (d['helperDistanceKm'] as num?)?.toDouble(),
      helperEtaMin: (d['helperEtaMin'] as num?)?.toInt(),
      helperLat: (d['helperLat'] as num?)?.toDouble(),
      helperLng: (d['helperLng'] as num?)?.toDouble(),
      helperMembers: parsedHelpers,
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
