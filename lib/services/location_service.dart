import 'dart:async';
import 'dart:isolate';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:geolocator/geolocator.dart';

// ─── Callback que corre en el isolate del ForegroundTask ───────────────────
@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(_LocationTaskHandler());
}

class _LocationTaskHandler extends TaskHandler {
  String _uid = '';
  String _nickname = '';
  StreamSubscription<Position>? _posSub;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    _uid      = await FlutterForegroundTask.getData<String>(key: 'uid')      ?? '';
    _nickname = await FlutterForegroundTask.getData<String>(key: 'nickname') ?? '';
    _startTracking();
  }

  void _startTracking() {
    _posSub?.cancel();
    _posSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 20, // actualizar solo si mueve +20 metros
      ),
    ).listen((pos) async {
      if (_uid.isEmpty) return;
      try {
        await FirebaseFirestore.instance
            .collection('motoboy_locations')
            .doc(_uid)
            .set({
          'uid':       _uid,
          'nickname':  _nickname,
          'lat':       pos.latitude,
          'lng':       pos.longitude,
          'accuracy':  pos.accuracy,
          'speed':     pos.speed,
          'updatedAt': FieldValue.serverTimestamp(),
          'online':    true,
        }, SetOptions(merge: true));
      } catch (_) {}
    });
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    // Keepalive — el stream ya está activo
  }

  @override
  Future<void> onDestroy(DateTime timestamp) async {
    _posSub?.cancel();
    // Marcar offline al salir
    if (_uid.isNotEmpty) {
      try {
        await FirebaseFirestore.instance
            .collection('motoboy_locations')
            .doc(_uid)
            .update({'online': false, 'updatedAt': FieldValue.serverTimestamp()});
      } catch (_) {}
    }
  }

  @override
  void onReceiveData(Object data) {}
}

// ─── API pública ─────────────────────────────────────────────────────────────
class LocationService {
  static bool _initialized = false;

  static void _init() {
    if (_initialized) return;
    _initialized = true;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId:   'location_tracking',
        channelName: 'Rastreo de ubicación',
        channelDescription: 'La Mano está rastreando tu ubicación activa',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        iconData: const NotificationIconData(
          resType: ResourceType.mipmap,
          resPrefix: ResourcePrefix.ic,
          name: 'launcher',
        ),
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: true,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(60000), // keepalive cada 1 min
        autoRunOnBoot: true,
        autoRunOnMyPackageReplaced: true,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
  }

  /// Pide permisos y arranca el servicio en segundo plano.
  static Future<bool> start({
    required String uid,
    required String nickname,
  }) async {
    _init();

    // Verificar/pedir permiso de ubicación
    LocationPermission perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.deniedForever) return false;

    // Guardar datos para el isolate
    await FlutterForegroundTask.saveData(key: 'uid',      value: uid);
    await FlutterForegroundTask.saveData(key: 'nickname', value: nickname);

    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.restartService();
    } else {
      await FlutterForegroundTask.startService(
        serviceId:           100,
        notificationTitle:   '📍 La Mano activo',
        notificationText:    'Rastreando tu ubicación',
        callback:            startCallback,
      );
    }
    return true;
  }

  /// Detiene el servicio y marca al motoboy como offline.
  static Future<void> stop(String uid) async {
    await FlutterForegroundTask.stopService();
    if (uid.isNotEmpty) {
      try {
        await FirebaseFirestore.instance
            .collection('motoboy_locations')
            .doc(uid)
            .update({'online': false, 'updatedAt': FieldValue.serverTimestamp()});
      } catch (_) {}
    }
  }

  /// Stream en tiempo real de todos los motoboys online.
  static Stream<QuerySnapshot> onlineMotoboysStream() {
    return FirebaseFirestore.instance
        .collection('motoboy_locations')
        .where('online', isEqualTo: true)
        .snapshots();
  }
}
