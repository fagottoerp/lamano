import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:geolocator/geolocator.dart';

/// Listens to physical volume-key events from the native EventChannel.
/// - Double-tap or long-press Volume-Down → ALERTA_POLICIAL
/// - Double-tap or long-press Volume-Up   → ALERTA_ROBO
class PanicAlertService {
  static const _channel = EventChannel('com.lamano.app/volume_keys');

  static const alertTypePolice = 'ALERTA_POLICIAL';
  static const alertTypeRobo = 'ALERTA_ROBO';

  StreamSubscription<dynamic>? _sub;

  final String userId;
  final String userName;
  final FlutterLocalNotificationsPlugin localNotif;

  /// Debounce: ignore repeated triggers within 8 seconds
  DateTime? _lastTrigger;
  static const _debounceSec = 8;

  PanicAlertService({
    required this.userId,
    required this.userName,
    required this.localNotif,
  });

  void start() {
    _sub?.cancel();
    _sub = _channel.receiveBroadcastStream().listen((event) {
      final ev = event as String? ?? '';
      if (ev == 'double_down' || ev == 'long_down') {
        _trigger(alertTypePolice);
      } else if (ev == 'double_up' || ev == 'long_up') {
        _trigger(alertTypeRobo);
      }
    });
  }

  void stop() {
    _sub?.cancel();
    _sub = null;
  }

  Future<void> _trigger(String type) async {
    final now = DateTime.now();
    if (_lastTrigger != null &&
        now.difference(_lastTrigger!).inSeconds < _debounceSec) {
      return;
    }
    _lastTrigger = now;

    final isPolice = type == alertTypePolice;
    final label = isPolice ? '🚨 ALERTA POLICIAL' : '🔴 ALERTA ROBO';

    Fluttertoast.showToast(
      msg: '$label ENVIADA',
      backgroundColor: isPolice ? const Color(0xFF1565C0) : const Color(0xFFB71C1C),
      textColor: Colors.white,
      toastLength: Toast.LENGTH_LONG,
    );

    // Get GPS location (best effort)
    double? lat;
    double? lng;
    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
      ).timeout(const Duration(seconds: 8));
      lat = pos.latitude;
      lng = pos.longitude;
    } catch (_) {}

    // Write to Firestore — Cloud Function fans out push to admins
    try {
      await FirebaseFirestore.instance.collection('panic_alerts').add({
        'type': type,
        'userId': userId,
        'userName': userName,
        'lat': lat,
        'lng': lng,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'active': true,
      });
    } catch (e) {
      Fluttertoast.showToast(msg: 'Error enviando alerta: $e');
    }

    // Local full-screen notification
    final body = lat != null
        ? 'Lat: ${lat.toStringAsFixed(5)}, Lng: ${lng?.toStringAsFixed(5)}'
        : 'Ubicacion no disponible';

    await localNotif.show(
      id: 9001,
      title: label,
      body: '${userName.isNotEmpty ? "$userName · " : ""}$body',
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          'panic_alert_v1',
          'Alertas de panico',
          channelDescription: 'Notificaciones de emergencia',
          importance: Importance.max,
          priority: Priority.max,
          fullScreenIntent: true,
          category: AndroidNotificationCategory.alarm,
        ),
      ),
    );
  }
}
