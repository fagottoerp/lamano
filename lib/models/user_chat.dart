import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_chat_demo/constants/constants.dart';

class UserChat {
  final String id;
  final String photoUrl;
  final String nickname;
  final String aboutMe;
  final bool isOnline;
  final int lastSeen;

  const UserChat({
    required this.id,
    required this.photoUrl,
    required this.nickname,
    required this.aboutMe,
    this.isOnline = false,
    this.lastSeen = 0,
  });

  Map<String, String> toJson() {
    return {
      FirestoreConstants.nickname: nickname,
      FirestoreConstants.aboutMe: aboutMe,
      FirestoreConstants.photoUrl: photoUrl,
    };
  }

  factory UserChat.fromDocument(DocumentSnapshot doc) {
    String aboutMe = "";
    String photoUrl = "";
    String nickname = "";
    bool isOnline = false;
    int lastSeen = 0;
    try {
      aboutMe = doc.get(FirestoreConstants.aboutMe);
    } catch (_) {}
    try {
      photoUrl = doc.get(FirestoreConstants.photoUrl);
    } catch (_) {}
    try {
      nickname = doc.get(FirestoreConstants.nickname);
    } catch (_) {}
    try {
      final value = doc.get(FirestoreConstants.isOnline);
      if (value is bool) {
        isOnline = value;
      } else if (value is num) {
        isOnline = value != 0;
      }
    } catch (_) {}
    try {
      final value = doc.get(FirestoreConstants.lastSeen);
      if (value is num) {
        lastSeen = value.toInt();
      } else if (value is String) {
        lastSeen = int.tryParse(value) ?? 0;
      }
    } catch (_) {}
    return UserChat(
      id: doc.id,
      photoUrl: photoUrl,
      nickname: nickname,
      aboutMe: aboutMe,
      isOnline: isOnline,
      lastSeen: lastSeen,
    );
  }
}
