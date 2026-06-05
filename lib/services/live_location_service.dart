import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geolocator/geolocator.dart';
import '../constants/firestore_constants.dart';

/// Singleton service that keeps the live-location GPS stream alive
/// independently of which widget is currently on screen.
/// Like WhatsApp: the user controls start/stop explicitly; navigating
/// away from the chat does NOT stop sharing.
class LiveLocationService {
  LiveLocationService._();
  static final instance = LiveLocationService._();

  StreamSubscription<Position>? _positionSub;
  String? _activeDocId;
  String? _activeGroupId;
  String? _activeUserId;
  bool _isSharing = false;

  bool get isSharing => _isSharing;
  String? get activeDocId => _activeDocId;
  String? get activeGroupId => _activeGroupId;

  /// Start sharing live location for [groupId] / [userId].
  /// Returns the Firestore docId or null on error.
  Future<String?> start({
    required String userId,
    required String nickname,
    required String groupId,
  }) async {
    if (_isSharing) return _activeDocId; // already running

    final docId = '${groupId}_$userId';

    try {
      await FirebaseFirestore.instance
          .collection(FirestoreConstants.pathLiveLocations)
          .doc(docId)
          .set({
        'active': true,
        'lat': 0.0,
        'lng': 0.0,
        'fromId': userId,
        'chatId': groupId,
      });

      // Immediate first position
      try {
        final pos = await Geolocator.getCurrentPosition(
            desiredAccuracy: LocationAccuracy.high);
        await _updatePosition(docId, groupId, userId, nickname, pos);
      } catch (_) {}

      _positionSub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 5,
        ),
      ).listen(
        (pos) => _updatePosition(docId, groupId, userId, nickname, pos),
        onError: (_) {},
      );

      _activeDocId = docId;
      _activeGroupId = groupId;
      _activeUserId = userId;
      _isSharing = true;
      return docId;
    } catch (_) {
      return null;
    }
  }

  /// Stop sharing and mark the Firestore doc as inactive.
  Future<void> stop() async {
    await _positionSub?.cancel();
    _positionSub = null;

    if (_activeDocId != null) {
      try {
        await FirebaseFirestore.instance
            .collection(FirestoreConstants.pathLiveLocations)
            .doc(_activeDocId)
            .update({'active': false});
      } catch (_) {}
    }

    if (_activeGroupId != null && _activeUserId != null) {
      try {
        await FirebaseFirestore.instance
            .collection(FirestoreConstants.pathGroupLocations)
            .doc(_activeGroupId)
            .collection('members')
            .doc(_activeUserId)
            .delete();
      } catch (_) {}
    }

    _activeDocId = null;
    _activeGroupId = null;
    _activeUserId = null;
    _isSharing = false;
  }

  Future<void> _updatePosition(String docId, String groupId, String userId,
      String nickname, Position pos) async {
    await Future.wait([
      FirebaseFirestore.instance
          .collection(FirestoreConstants.pathLiveLocations)
          .doc(docId)
          .update({'lat': pos.latitude, 'lng': pos.longitude}),
      FirebaseFirestore.instance
          .collection(FirestoreConstants.pathGroupLocations)
          .doc(groupId)
          .collection('members')
          .doc(userId)
          .set({
        'lat': pos.latitude,
        'lng': pos.longitude,
        'name': nickname,
        'updatedAt': FieldValue.serverTimestamp(),
      }),
    ]).catchError((_) {});
  }
}
