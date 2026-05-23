import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';

class StickerService {
  static final _firestore = FirebaseFirestore.instance;
  static final _storage = FirebaseStorage.instance;
  static final _auth = FirebaseAuth.instance;

  /// Pick an image from [source], upload to Storage, save reference in Firestore.
  /// Returns the download URL or null if cancelled.
  static Future<String?> createStickerFromGallery({ImageSource source = ImageSource.gallery}) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return null;

    final picker = ImagePicker();
    final XFile? file = await picker.pickImage(
      source: source,
      imageQuality: 80,
      maxWidth: 512,
      maxHeight: 512,
    );
    if (file == null) return null;

    final fileName = '${DateTime.now().millisecondsSinceEpoch}.jpg';
    final ref = _storage.ref().child('stickers/$uid/$fileName');

    await ref.putFile(File(file.path));
    final url = await ref.getDownloadURL();

    // Save to Firestore
    await _firestore
        .collection('users')
        .doc(uid)
        .collection('stickers')
        .add({
      'url': url,
      'createdAt': FieldValue.serverTimestamp(),
    });

    return url;
  }

  /// Save a Giphy URL directly to the user's stickers (no upload needed).
  static Future<void> saveGiphySticker(String url) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return;
    // Avoid duplicates
    final existing = await _firestore
        .collection('users')
        .doc(uid)
        .collection('stickers')
        .where('url', isEqualTo: url)
        .limit(1)
        .get();
    if (existing.docs.isNotEmpty) return;
    await _firestore
        .collection('users')
        .doc(uid)
        .collection('stickers')
        .add({'url': url, 'createdAt': FieldValue.serverTimestamp()});
  }

  /// Stream of the current user's stickers (most recent first).
  static Stream<List<String>> myStickersStream() {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return Stream.value([]);

    return _firestore
        .collection('users')
        .doc(uid)
        .collection('stickers')
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snap) => snap.docs.map((d) => d['url'] as String).toList());
  }

  /// Delete a sticker by its download URL.
  static Future<void> deleteSticker(String url) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return;

    // Delete from Firestore
    final snap = await _firestore
        .collection('users')
        .doc(uid)
        .collection('stickers')
        .where('url', isEqualTo: url)
        .get();
    for (final doc in snap.docs) {
      await doc.reference.delete();
    }

    // Delete from Storage
    try {
      await _storage.refFromURL(url).delete();
    } catch (_) {}
  }
}
