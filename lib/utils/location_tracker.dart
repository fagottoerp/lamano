import 'dart:async';
import 'dart:io' show Platform;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geolocator_android/geolocator_android.dart';
import 'package:geolocator_apple/geolocator_apple.dart';

/// Continuously tracks the user's GPS location and writes it to Firestore.
///
/// Writes to: users_locations/{userId} with
///   { lat, lng, accuracy, nickname, online, updatedAt, platform }
///
/// Robustness features:
///  - Foreground service on Android (sticky notification) so the OS does not
///    kill the location stream when the app goes to background / screen off.
///  - Background updates allowed on iOS.
///  - Heartbeat every [_heartbeatInterval] that re-writes `updatedAt` and
///    `online: true` even if the user has not moved, so the web panel can tell
///    the difference between "alive but quiet" and "dead/no signal".
///  - On stop() we mark offline. If the app crashes the heartbeat simply
///    stops and the web side falls back to offline by staleness (3 min).
class LocationTracker {
  LocationTracker._();
  static final LocationTracker instance = LocationTracker._();

  static const Duration _heartbeatInterval = Duration(seconds: 45);
  static const int _distanceFilterMeters = 15;

  StreamSubscription<Position>? _sub;
  Timer? _heartbeat;
  Position? _lastPos;
  String? _userId;
  String? _nickname;
  bool _running = false;

  bool get isRunning => _running;

  Future<void> start(String userId, String nickname) async {
    if (_running) return;

    // Foreground permission (must be granted before background can be requested).
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
      return;
    }

    _userId = userId;
    _nickname = nickname;
    _running = true;

    // Try to grab an initial position so we report online immediately, even
    // before the user moves enough to trigger the stream.
    try {
      final initial = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
      ).timeout(const Duration(seconds: 8));
      _lastPos = initial;
      await _write(userId, nickname, initial);
    } catch (_) {
      // No initial fix — heartbeat will still report online without coords.
      await _writePresenceOnly(userId, nickname);
    }

    _sub = Geolocator.getPositionStream(
      locationSettings: _buildSettings(nickname),
    ).listen(
      (pos) {
        _lastPos = pos;
        _write(userId, nickname, pos);
      },
      onError: (_) {},
      cancelOnError: false,
    );

    // Heartbeat keeps `updatedAt` fresh for the web panel even when standing
    // still. Reuses the last known position if we have one.
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(_heartbeatInterval, (_) async {
      if (!_running) return;
      final pos = _lastPos;
      if (pos != null) {
        await _write(userId, nickname, pos);
      } else {
        await _writePresenceOnly(userId, nickname);
      }
    });
  }

  Future<void> stop(String userId) async {
    _running = false;
    await _sub?.cancel();
    _sub = null;
    _heartbeat?.cancel();
    _heartbeat = null;
    _userId = null;
    _nickname = null;
    _lastPos = null;
    // Mark offline cleanly.
    try {
      await FirebaseFirestore.instance
          .collection('users_locations')
          .doc(userId)
          .set({
        'online': false,
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
      }, SetOptions(merge: true));
    } catch (_) {}
  }

  /// Platform-specific settings to keep the stream alive in background.
  LocationSettings _buildSettings(String nickname) {
    if (Platform.isAndroid) {
      return AndroidSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: _distanceFilterMeters,
        forceLocationManager: false,
        intervalDuration: const Duration(seconds: 20),
        foregroundNotificationConfig: ForegroundNotificationConfig(
          notificationTitle: 'Lamano activo',
          notificationText: 'Compartiendo tu ubicación con el equipo',
          notificationIcon: const AndroidResource(name: 'ic_launcher', defType: 'mipmap'),
          enableWakeLock: true,
          setOngoing: true,
        ),
      );
    }
    if (Platform.isIOS) {
      return AppleSettings(
        accuracy: LocationAccuracy.high,
        activityType: ActivityType.automotiveNavigation,
        distanceFilter: _distanceFilterMeters,
        pauseLocationUpdatesAutomatically: false,
        showBackgroundLocationIndicator: true,
        allowBackgroundLocationUpdates: true,
      );
    }
    return const LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: _distanceFilterMeters,
    );
  }

  Future<void> _write(String userId, String nickname, Position pos) async {
    try {
      await FirebaseFirestore.instance.collection('users_locations').doc(userId).set({
        'lat': pos.latitude,
        'lng': pos.longitude,
        'accuracy': pos.accuracy,
        'nickname': nickname,
        'online': true,
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
        'platform': Platform.operatingSystem,
      }, SetOptions(merge: true));
    } catch (_) {
      // Network blip — next heartbeat will retry.
    }
  }

  Future<void> _writePresenceOnly(String userId, String nickname) async {
    try {
      await FirebaseFirestore.instance.collection('users_locations').doc(userId).set({
        'nickname': nickname,
        'online': true,
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
        'platform': Platform.operatingSystem,
      }, SetOptions(merge: true));
    } catch (_) {}
  }
}
