import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'package:archive/archive.dart';
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

  /// Importa un paquete ZIP (formato tipo WhatsApp contents.json + imágenes)
  /// y guarda los stickers en la colección del usuario.
  static Future<int> importStickerPackFromZip(String zipPath, {int maxStickers = 30}) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return 0;

    final zipFile = File(zipPath);
    if (!zipFile.existsSync()) return 0;

    final bytes = await zipFile.readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes, verify: true);

    final imageEntries = <ArchiveFile>[];
    final imageByName = <String, ArchiveFile>{};
    final contentEntries = <ArchiveFile>[];

    for (final entry in archive.files) {
      if (!entry.isFile) continue;
      final normalized = entry.name.toLowerCase();
      if (normalized.endsWith('contents.json') || normalized.endsWith('.json')) {
        contentEntries.add(entry);
      }
      if (_isSupportedStickerImage(normalized)) {
        imageEntries.add(entry);
        imageByName[_baseName(normalized)] = entry;
      }
    }

    final orderedFromManifest = _extractManifestStickerOrder(contentEntries, imageByName);
    final candidateEntries = orderedFromManifest.isNotEmpty ? orderedFromManifest : imageEntries;
    if (candidateEntries.isEmpty) return 0;

    var imported = 0;
    for (final entry in candidateEntries.take(maxStickers)) {
      final uploaded = await _uploadArchiveSticker(uid: uid, entry: entry);
      if (uploaded != null) imported++;
    }

    return imported;
  }

  /// Importa un conjunto de archivos compartidos directamente como stickers.
  static Future<int> importSharedStickerFiles(List<String> filePaths, {int maxStickers = 30}) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return 0;

    var imported = 0;
    for (final path in filePaths.take(maxStickers)) {
      final result = await importStickerFile(path, uid: uid, source: 'shared_file');
      if (result != null) imported++;
    }
    return imported;
  }

  /// Importa un único archivo de imagen o sticker al usuario actual.
  static Future<String?> importStickerFile(
    String filePath, {
    String? uid,
    String source = 'manual_import',
  }) async {
    final userId = uid ?? _auth.currentUser?.uid;
    if (userId == null) return null;

    final file = File(filePath);
    if (!file.existsSync()) return null;

    final ext = _fileExtension(filePath);
    if (!_isSupportedStickerImage(ext)) return null;

    try {
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) return null;

      final name = 'shared_${DateTime.now().millisecondsSinceEpoch}_${_safeFileName(_baseName(filePath))}';
      final ref = _storage.ref().child('stickers/$userId/$name$ext');
      await ref.putData(bytes, SettableMetadata(contentType: _mimeTypeForExt(ext)));
      final url = await ref.getDownloadURL();

      await _firestore
          .collection('users')
          .doc(userId)
          .collection('stickers')
          .add({
        'url': url,
        'createdAt': FieldValue.serverTimestamp(),
        'source': source,
      });
      return url;
    } catch (_) {
      return null;
    }
  }

  static Future<String?> _uploadArchiveSticker({
    required String uid,
    required ArchiveFile entry,
  }) async {
    try {
      final raw = entry.content;
      if (raw == null) return null;

      final bytes = raw is Uint8List ? raw : Uint8List.fromList(raw as List<int>);
      if (bytes.isEmpty) return null;

      final ext = _fileExtension(entry.name);
      final name = 'pack_${DateTime.now().millisecondsSinceEpoch}_${_safeFileName(_baseName(entry.name))}';
      final path = 'stickers/$uid/$name$ext';
      final ref = _storage.ref().child(path);

      final metadata = SettableMetadata(contentType: _mimeTypeForExt(ext));
      await ref.putData(bytes, metadata);
      final url = await ref.getDownloadURL();

      await _firestore
          .collection('users')
          .doc(uid)
          .collection('stickers')
          .add({
        'url': url,
        'createdAt': FieldValue.serverTimestamp(),
        'source': 'zip_import',
      });

      return url;
    } catch (_) {
      return null;
    }
  }

  static List<ArchiveFile> _extractManifestStickerOrder(
    List<ArchiveFile> manifests,
    Map<String, ArchiveFile> imageByName,
  ) {
    final ordered = <ArchiveFile>[];
    final seen = <String>{};

    for (final manifest in manifests) {
      try {
        final raw = manifest.content;
        if (raw == null) continue;
        final bytes = raw is Uint8List ? raw : Uint8List.fromList(raw as List<int>);
        final decoded = jsonDecode(utf8.decode(bytes));
        if (decoded is! Map<String, dynamic>) continue;

        final packs = decoded['sticker_packs'];
        if (packs is! List) continue;

        for (final pack in packs) {
          if (pack is! Map<String, dynamic>) continue;
          final stickers = pack['stickers'];
          if (stickers is! List) continue;
          for (final s in stickers) {
            if (s is! Map<String, dynamic>) continue;
            final imageFile = (s['image_file'] ?? '').toString();
            if (imageFile.isEmpty) continue;
            final key = _baseName(imageFile.toLowerCase());
            final matched = imageByName[key];
            if (matched == null) continue;
            if (seen.add(matched.name)) ordered.add(matched);
          }
        }
      } catch (_) {
        // Skip malformed manifest and continue with best effort.
      }
    }

    return ordered;
  }

  static bool _isSupportedStickerImage(String nameOrExt) {
    final value = nameOrExt.toLowerCase();
    return value.endsWith('.webp') ||
        value.endsWith('.png') ||
        value.endsWith('.jpg') ||
        value.endsWith('.jpeg') ||
        value.endsWith('.gif');
  }

  static String _baseName(String path) {
    final normalized = path.replaceAll('\\\\', '/');
    final index = normalized.lastIndexOf('/');
    return index >= 0 ? normalized.substring(index + 1) : normalized;
  }

  static String _fileExtension(String path) {
    final base = _baseName(path).toLowerCase();
    final idx = base.lastIndexOf('.');
    if (idx < 0) return '.webp';
    return base.substring(idx);
  }

  static String _safeFileName(String input) {
    final withoutExt = input.replaceAll(RegExp(r'\.[^./\\]+$'), '');
    return withoutExt.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
  }

  static String _mimeTypeForExt(String ext) {
    switch (ext.toLowerCase()) {
      case '.png':
        return 'image/png';
      case '.jpg':
      case '.jpeg':
        return 'image/jpeg';
      case '.gif':
        return 'image/gif';
      case '.webp':
      default:
        return 'image/webp';
    }
  }
}
