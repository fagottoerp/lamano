import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geolocator_android/geolocator_android.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _prefKeyUserId   = 'fg_gps_user_id';
const String _prefKeyNickname = 'fg_gps_nickname';

// ── Public API ────────────────────────────────────────────────────────────────

void initForegroundTaskConfig() {
  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'lamano_gps_channel',
      channelName: 'GPS activo',
      channelDescription: 'Rastreando tu ubicación en tiempo real',
      channelImportance: NotificationChannelImportance.LOW,
      priority: NotificationPriority.LOW,
    ),
    iosNotificationOptions: const IOSNotificationOptions(
      showNotification: true,
      playSound: false,
    ),
    foregroundTaskOptions: ForegroundTaskOptions(
      eventAction: ForegroundTaskEventAction.repeat(30000), // 30s
      autoRunOnBoot: true,
      autoRunOnMyPackageReplaced: true,
      allowWakeLock: true,
      allowWifiLock: true,
    ),
  );
}

Future<void> startForegroundGps(String userId, String nickname) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_prefKeyUserId, userId);
  await prefs.setString(_prefKeyNickname, nickname);

  if (await FlutterForegroundTask.isRunningService) {
    FlutterForegroundTask.updateService(
      notificationTitle: 'Lamano activo',
      notificationText: 'GPS rastreando a $nickname',
    );
    return;
  }

  await FlutterForegroundTask.startService(
    serviceId: 777,
    notificationTitle: 'Lamano activo',
    notificationText: 'GPS rastreando a $nickname',
    callback: startForegroundCallback,
  );
}

Future<void> stopForegroundGps(String userId) async {
  await FlutterForegroundTask.stopService();
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

// ── Task handler (runs in background isolate) ─────────────────────────────────

@pragma('vm:entry-point')
void startForegroundCallback() {
  FlutterForegroundTask.setTaskHandler(_GpsTaskHandler());
}

class _GpsTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    try {
      if (Firebase.apps.isEmpty) await Firebase.initializeApp();
    } catch (_) {}
  }

  @override
  void onRepeatEvent(DateTime timestamp) async {
    await _sendLocation();
  }

  @override
  Future<void> onDestroy(DateTime timestamp) async {
    // Mark offline when service is destroyed
    final prefs = await SharedPreferences.getInstance();
    final userId = prefs.getString(_prefKeyUserId);
    if (userId != null && userId.isNotEmpty) {
      try {
        await FirebaseFirestore.instance
            .collection('users_locations')
            .doc(userId)
            .set({'online': false, 'updatedAt': DateTime.now().millisecondsSinceEpoch},
                SetOptions(merge: true));
      } catch (_) {}
    }
  }

  Future<void> _sendLocation() async {
    final prefs = await SharedPreferences.getInstance();
    final userId   = prefs.getString(_prefKeyUserId);
    final nickname = prefs.getString(_prefKeyNickname) ?? '';
    if (userId == null || userId.isEmpty) return;

    try {
      if (Firebase.apps.isEmpty) await Firebase.initializeApp();

      final perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) return;

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
        'nickname': nickname,
        'online': true,
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
        'platform': 'android',
      }, SetOptions(merge: true));

      FlutterForegroundTask.updateService(
        notificationText: '📍 ${pos.latitude.toStringAsFixed(4)}, ${pos.longitude.toStringAsFixed(4)}',
      );
    } catch (_) {
      // No fix — just keep presence alive
      try {
        await FirebaseFirestore.instance
            .collection('users_locations')
            .doc(userId)
            .set({
          'nickname': nickname,
          'online': true,
          'updatedAt': DateTime.now().millisecondsSinceEpoch,
        }, SetOptions(merge: true));
      } catch (_) {}
    }
  }
}
