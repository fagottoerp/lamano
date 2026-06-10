import 'dart:io';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_chat_demo/constants/constants.dart';
import 'package:flutter_chat_demo/models/models.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;

class ChatProvider {
  final SharedPreferences prefs;
  final FirebaseFirestore firebaseFirestore;

  ChatProvider({required this.firebaseFirestore, required this.prefs});

  /// Upload file to own server (replaces Firebase Storage)
  Future<String> uploadFile(File file, String type) async {
    final userId = prefs.getString(FirestoreConstants.id) ?? 'unknown';
    
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('http://38.247.147.220/lamano/api_upload_chat_file.php'),
    );
    
    request.fields['userId'] = userId;
    request.fields['type'] = type; // image, video, audio, file
    request.files.add(await http.MultipartFile.fromPath('file', file.path));
    
    final response = await request.send();
    final responseBody = await response.stream.bytesToString();
    
    if (response.statusCode != 200) {
      throw Exception('Upload failed: $responseBody');
    }
    
    final json = jsonDecode(responseBody);
    return json['url'] as String;
  }

  Future<void> updateDataFirestore(String collectionPath, String docPath, Map<String, dynamic> dataNeedUpdate) {
    return firebaseFirestore.collection(collectionPath).doc(docPath).update(dataNeedUpdate);
  }

  Stream<QuerySnapshot> getChatStream(String groupChatId, int limit) {
    return firebaseFirestore
        .collection(FirestoreConstants.pathMessageCollection)
        .doc(groupChatId)
        .collection(groupChatId)
        .orderBy(FirestoreConstants.timestamp, descending: true)
        .limit(limit)
        .snapshots();
  }

  Stream<QuerySnapshot> getRecentChats(String userId) {
    return firebaseFirestore
        .collection('user_conversations')
        .doc(userId)
        .collection('chats')
        .orderBy('lastTimestamp', descending: true)
        .limit(50)
        .snapshots();
  }

  void sendMessage(String content, int type, String groupChatId, String currentUserId, String peerId, {Map<String, dynamic>? extras}) {
    final documentReference = firebaseFirestore
        .collection(FirestoreConstants.pathMessageCollection)
        .doc(groupChatId)
        .collection(groupChatId)
        .doc(DateTime.now().millisecondsSinceEpoch.toString());

    final messageChat = MessageChat(
      idFrom: currentUserId,
      idTo: peerId,
      timestamp: DateTime.now().millisecondsSinceEpoch.toString(),
      content: content,
      type: type,
    );

    final data = messageChat.toJson();
    data['status'] = 'sent';
    if (extras != null) data.addAll(extras);

    firebaseFirestore.runTransaction((transaction) async {
      transaction.set(documentReference, data);
    });

    // Enviar push notification desde servidor PHP
    final senderName = prefs.getString(FirestoreConstants.nickname) ?? 'Yo';
    _sendPushNotification(groupChatId, currentUserId, peerId, type, content, senderName);

    // Keep last-message metadata for recent chats list
    final preview = type == 0
        ? (content.length > 40 ? '${content.substring(0, 40)}...' : content)
        : type == 1 ? '📷 Foto' : type == 3 ? '📍 Ubicación' : type == 4 ? '📍 Ubicación en vivo' : type == 5 ? '🎤 Audio' : '💬 Mensaje';
    final ts = DateTime.now().millisecondsSinceEpoch;
    // Write for both participants so both can see the conversation
    for (final uid in [currentUserId, peerId]) {
      final otherId = uid == currentUserId ? peerId : currentUserId;
      final label = uid == currentUserId ? 'Tú: $preview' : '$senderName: $preview';
      final isReceiver = uid == peerId;
      firebaseFirestore
          .collection('user_conversations')
          .doc(uid)
          .collection('chats')
          .doc(otherId)
          .set({
        'groupChatId': groupChatId,
        'peerId': otherId,
        'lastMessage': label,
        'lastTimestamp': ts,
        if (isReceiver) 'unreadCount': FieldValue.increment(1),
      }, SetOptions(merge: true));
    }
  }

  /// Toggle a reaction emoji on a message.
  Future<void> toggleReaction(String groupChatId, String messageId, String emoji, String userId) async {
    final ref = firebaseFirestore
        .collection(FirestoreConstants.pathMessageCollection)
        .doc(groupChatId)
        .collection(groupChatId)
        .doc(messageId);
    await firebaseFirestore.runTransaction((tx) async {
      final snap = await tx.get(ref);
      final data = snap.data() ?? {};
      final reactions = Map<String, dynamic>.from(data['reactions'] as Map? ?? {});
      final users = List<String>.from(reactions[emoji] as List? ?? []);
      if (users.contains(userId)) {
        users.remove(userId);
      } else {
        users.add(userId);
      }
      if (users.isEmpty) {
        reactions.remove(emoji);
      } else {
        reactions[emoji] = users;
      }
      tx.update(ref, {'reactions': reactions});
    });
  }

  /// Set typing indicator for current user in a chat room.
  Future<void> setTyping(String groupChatId, String userId, bool isTyping) async {
    try {
      await firebaseFirestore
          .collection('typing')
          .doc(groupChatId)
          .collection('users')
          .doc(userId)
          .set({'isTyping': isTyping, 'ts': DateTime.now().millisecondsSinceEpoch}, SetOptions(merge: true));
    } catch (_) {}
  }

  /// Stream typing status of a specific user in a room.
  Stream<DocumentSnapshot> getTypingStream(String groupChatId, String userId) {
    return firebaseFirestore
        .collection('typing')
        .doc(groupChatId)
        .collection('users')
        .doc(userId)
        .snapshots();
  }

  /// Stream all typing users in a group room.
  Stream<QuerySnapshot> getGroupTypingStream(String groupChatId) {
    return firebaseFirestore
        .collection('typing')
        .doc(groupChatId)
        .collection('users')
        .snapshots();
  }

  /// Enviar push notification vía servidor PHP
  void _sendPushNotification(String groupChatId, String idFrom, String idTo, int type, String content, String senderName) {
    // Fire and forget - no bloqueamos la UI
    http.post(
      Uri.parse('http://38.247.147.220/lamano/api_send_message_push.php'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({
        'groupChatId': groupChatId,
        'idFrom': idFrom,
        'idTo': idTo,
        'type': type,
        'content': content,
        'senderName': senderName,
      }),
    ).timeout(const Duration(seconds: 5)).catchError((_) {
      // Ignorar errores - la push es best-effort
    });
  }
}

