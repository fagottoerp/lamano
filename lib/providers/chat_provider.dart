import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter_chat_demo/constants/constants.dart';
import 'package:flutter_chat_demo/models/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ChatProvider {
  final SharedPreferences prefs;
  final FirebaseFirestore firebaseFirestore;
  final FirebaseStorage firebaseStorage;

  ChatProvider({required this.firebaseFirestore, required this.prefs, required this.firebaseStorage});

  UploadTask uploadFile(File image, String fileName) {
    Reference reference = firebaseStorage.ref().child(fileName);
    UploadTask uploadTask = reference.putFile(image);
    return uploadTask;
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

    FirebaseFirestore.instance.runTransaction((transaction) async {
      transaction.set(documentReference, data);
    });

    // Keep last-message metadata for recent chats list
    final senderName = prefs.getString(FirestoreConstants.nickname) ?? 'Yo';
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
}

