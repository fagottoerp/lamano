import 'dart:async';
import 'dart:ui';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_background_service_android/flutter_background_service_android.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geolocator_android/geolocator_android.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// GPS background service that survives app close, screen off, and device reboot.
///
/// Architecture:
///  - flutter_background_service runs a Dart isolate as an Android foreground
///    service. The OS cannot kill foreground services without user action.
///  - On boot, Android restarts the foreground service automatically (declared
///    in AndroidManifest with RECEIVE_BOOT_COMPLETED).
///  - Updates Firestore users_locations/{userId} every [_updateInterval].

const String _prefKeyUserId   = 'bg_gps_user_id';
const String _prefKeyNickname = 'bg_gps_nickname';
const Duration _updateInterval = Duration(seconds: 30);

// ── Public API ────────────────────────────────────────────────────────────────

Future<void> initBackgroundGpsService() async {
  final service = FlutterBackgroundService();
  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: _onStart,
      autoStart: false,           // We start manually after login
      isForegroundMode: true,
      notificationChannelId: 'bg_location_channel',
      initialNotificationTitle: 'Lamano activo',
      initialNotificationContent: 'Rastreando tu ubicación',
      foregroundServiceNotificationId: 888,
      autoStartOnBoot: true,      // Restart after phone reboot
    ),
    iosConfiguration: IosConfiguration(
      autoStart: false,
      onForeground: _onStart,
      onBackground: _onIosBackground,
    ),
  );
}

Future<void> startBackgroundGps(String userId, String nickname) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_prefKeyUserId, userId);
  await prefs.setString(_prefKeyNickname, nickname);

  final service = FlutterBackgroundService();
  final running = await service.isRunning();
  if (!running) {
    await service.startService();
  }
}

Future<void> stopBackgroundGps(String userId) async {
  final service = FlutterBackgroundService();
  service.invoke('stop');

  // Mark offline in Firestore
  try {
    if (Firebase.apps.isNotEmpty) {
      await FirebaseFirestore.instance
          .collection('users_locations')
          .doc(userId)
          .set({
        'online': false,
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
      }, SetOptions(merge: true));
    }
  } catch (_) {}
}

// ── Background isolate entry point ───────────────────────────────────────────

@pragma('vm:entry-point')
Future<bool> _onIosBackground(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  return true;
}

@pragma('vm:entry-point')
void _onStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();

  // Make sure Firebase is initialized in this isolate
  try {
    await Firebase.initializeApp();
  } catch (_) {
    // Already initialized (e.g. if app is in foreground too)
  }

  if (service is AndroidServiceInstance) {
    service.on('setAsForeground').listen((_) {
      service.setAsForegroundService();
    });
    service.on('setAsBackground').listen((_) {
      service.setAsBackgroundService();
    });
  }

  service.on('stop').listen((_) async {
    await service.stopSelf();
  });

  // Main GPS loop
  Timer.periodic(_updateInterval, (timer) async {
    final prefs = await SharedPreferences.getInstance();
    final userId   = prefs.getString(_prefKeyUserId);
    final nickname = prefs.getString(_prefKeyNickname);

    if (userId == null || userId.isEmpty) return;

    // Update notification
    if (service is AndroidServiceInstance) {
      service.setForegroundNotificationInfo(
        title: 'Lamano activo',
        content: 'GPS activo · ${DateTime.now().hour}:${DateTime.now().minute.toString().padLeft(2,'0')}',
      );
    }

    // Request GPS position
    try {
      final perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
        return;
      }

      final pos = await Geolocator.getCurrentPosition(
        locationSettings: AndroidSettings(
          accuracy: LocationAccuracy.high,
          forceLocationManager: false,
        ),
      ).timeout(const Duration(seconds: 15));

      await FirebaseFirestore.instance
          .collection('users_locations')
          .doc(userId)
          .set({
        'lat': pos.latitude,
        'lng': pos.longitude,
        'accuracy': pos.accuracy,
        'nickname': nickname ?? '',
        'online': true,
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
        'platform': 'android',
      }, SetOptions(merge: true));
    } catch (_) {
      // No GPS fix or network blip — write presence-only so panel knows app is alive
      try {
        await FirebaseFirestore.instance
            .collection('users_locations')
            .doc(userId)
            .set({
          'online': true,
          'updatedAt': DateTime.now().millisecondsSinceEpoch,
        }, SetOptions(merge: true));
      } catch (_) {}
    }
  });
}
