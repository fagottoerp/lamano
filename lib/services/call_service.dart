import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:http/http.dart' as http;
import '../constants/app_constants.dart';

/// Firestore collection: calls/{callId}
/// Fields:
///   channelName  – Agora channel (= callId)
///   callerId     – Firebase UID of caller
///   callerName   – Display name of caller
///   calleeId     – Firebase UID of callee
///   isVideo      – bool
///   status       – 'ringing' | 'accepted' | 'declined' | 'ended'
///   createdAt    – Timestamp
class CallService {
  static final _db = FirebaseFirestore.instance;
  static const _col = 'calls';

  /// Initiate a call and notify the callee via FCM push.
  /// Returns the callId (= Agora channel name).
  static Future<String> startCall({
    required String callerId,
    required String callerName,
    required String calleeId,
    required bool isVideo,
  }) async {
    final doc = _db.collection(_col).doc();
    final callId = doc.id;

    await doc.set({
      'channelName': callId,
      'callerId': callerId,
      'callerName': callerName,
      'calleeId': calleeId,
      'isVideo': isVideo,
      'status': 'ringing',
      'createdAt': FieldValue.serverTimestamp(),
    });

    // Fetch callee push token
    final userDoc = await _db.collection('users').doc(calleeId).get();
    final pushToken = userDoc.data()?['pushToken'] as String?;

    if (pushToken != null && pushToken.isNotEmpty) {
      await _sendCallPush(
        pushToken: pushToken,
        callId: callId,
        callerName: callerName,
        callerId: callerId,
        isVideo: isVideo,
      );
    }

    return callId;
  }

  /// Accept an incoming call.
  static Future<void> acceptCall(String callId) async {
    await _db.collection(_col).doc(callId).update({'status': 'accepted'});
  }

  /// Decline an incoming call.
  static Future<void> declineCall(String callId) async {
    await _db.collection(_col).doc(callId).update({'status': 'declined'});
  }

  /// End an ongoing call (both sides).
  static Future<void> endCall(String callId) async {
    await _db.collection(_col).doc(callId).update({'status': 'ended'});
  }

  /// Listen to a call document status changes.
  static Stream<DocumentSnapshot<Map<String, dynamic>>> watchCall(String callId) {
    return _db.collection(_col).doc(callId).snapshots();
  }

  // ── Private ────────────────────────────────────────────────────────────────

  static Future<void> _sendCallPush({
    required String pushToken,
    required String callId,
    required String callerName,
    required String callerId,
    required bool isVideo,
  }) async {
    try {
      await http.post(
        Uri.parse(AppConstants.callPushApiUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'push_token': pushToken,
          'caller_name': callerName,
          'caller_uid': callerId,
          'room_name': callId,  // reused as Agora channel name
          'is_video': isVideo,
        }),
      );
    } catch (_) {
      // Push is best-effort; call proceeds via Firestore signaling anyway
    }
  }
}
