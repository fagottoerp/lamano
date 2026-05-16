import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_chat_demo/constants/constants.dart';
import 'package:flutter_chat_demo/pages/song_picker_page.dart';
import 'package:flutter_chat_demo/providers/providers.dart';
import 'package:image_picker/image_picker.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:intl/intl.dart';

// ─────────────────────────────────────────────────────────────
//  STORIES PAGE — grid of user stories
// ─────────────────────────────────────────────────────────────
class StoriesPage extends StatefulWidget {
  const StoriesPage({super.key, required this.currentUserId, required this.currentNickname});
  final String currentUserId;
  final String currentNickname;

  @override
  State<StoriesPage> createState() => _StoriesPageState();
}

class _StoriesPageState extends State<StoriesPage> {
  bool _uploading = false;

  Future<void> _addStory() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xFF0D1F14),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 16),
          ListTile(
            leading: const Icon(Icons.text_fields, color: Color(0xFF00E65A)),
            title: const Text('Estado de texto', style: TextStyle(color: Colors.white)),
            onTap: () => Navigator.pop(context, 'text'),
          ),
          ListTile(
            leading: const Icon(Icons.photo_library, color: Color(0xFF00E65A)),
            title: const Text('Foto de galería', style: TextStyle(color: Colors.white)),
            onTap: () => Navigator.pop(context, 'gallery'),
          ),
          ListTile(
            leading: const Icon(Icons.camera_alt, color: Color(0xFF00E65A)),
            title: const Text('Tomar foto', style: TextStyle(color: Colors.white)),
            onTap: () => Navigator.pop(context, 'camera'),
          ),
          ListTile(
            leading: const Icon(Icons.library_music, color: Color(0xFF00E65A)),
            title: const Text('Canción (catálogo)', style: TextStyle(color: Colors.white)),
            onTap: () => Navigator.pop(context, 'song'),
          ),
          ListTile(
            leading: const Icon(Icons.music_note, color: Color(0xFF00E65A)),
            title: const Text('Audio del teléfono', style: TextStyle(color: Colors.white)),
            onTap: () => Navigator.pop(context, 'audio'),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
    if (choice == null) return;

    if (choice == 'text') {
      _addTextStory();
    } else if (choice == 'audio') {
      _addAudioStory();
    } else if (choice == 'song') {
      _pickSongFromCatalog();
    } else {
      _addImageStory(choice == 'camera' ? ImageSource.camera : ImageSource.gallery);
    }
  }

  Future<void> _pickSongFromCatalog() async {
    final picked = await Navigator.push<PickedSong>(
      context,
      MaterialPageRoute(builder: (_) => const SongPickerPage()),
    );
    if (picked == null) return;
    if (picked.previewUrl.isEmpty) {
      Fluttertoast.showToast(msg: 'Esa canción no tiene preview disponible');
      return;
    }
    setState(() => _uploading = true);
    try {
      final caption = '🎵 ${picked.trackName} — ${picked.artistName}';
      // No re-subimos: usamos el previewUrl directo de iTunes (CDN público).
      await _publishStory(
        audioUrl: picked.previewUrl,
        audioName: '${picked.trackName} — ${picked.artistName}',
        textContent: caption,
        imageUrl: picked.artworkUrl,
      );
    } catch (e) {
      Fluttertoast.showToast(msg: 'Error: $e');
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _addTextStory() async {
    String text = '';
    Color bg = const Color(0xFF1A3A2A);
    final picked = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF0D1F14),
        title: const Text('Nuevo estado', style: TextStyle(color: Color(0xFF00E65A))),
        content: TextField(
          autofocus: true,
          maxLines: 4,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            hintText: '¿Qué está pasando?',
            hintStyle: TextStyle(color: Colors.grey),
            enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Color(0xFF00E65A))),
            focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: Color(0xFF00E65A))),
          ),
          onChanged: (v) => text = v,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar', style: TextStyle(color: Colors.grey))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00E65A), foregroundColor: Colors.black),
            onPressed: () => Navigator.pop(context, text),
            child: const Text('Publicar'),
          ),
        ],
      ),
    );
    if (picked == null || picked.trim().isEmpty) return;
    await _publishStory(textContent: picked.trim());
  }

  Future<void> _addImageStory(ImageSource source) async {
    final picker = ImagePicker();
    final xfile = await picker.pickImage(source: source, imageQuality: 70);
    if (xfile == null) return;
    setState(() => _uploading = true);
    try {
      final chatProvider = context.read<ChatProvider>();
      final file = File(xfile.path);
      final fileName = 'story_${DateTime.now().millisecondsSinceEpoch}';
      final snapshot = await chatProvider.uploadFile(file, fileName);
      final url = await snapshot.ref.getDownloadURL();
      await _publishStory(imageUrl: url);
    } catch (e) {
      Fluttertoast.showToast(msg: 'Error subiendo imagen');
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _addAudioStory() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.audio,
        allowMultiple: false,
      );
      if (result == null || result.files.isEmpty) return;
      final picked = result.files.first;
      final path = picked.path;
      if (path == null) {
        Fluttertoast.showToast(msg: 'Archivo inválido');
        return;
      }
      // Limit to ~15MB to keep uploads sane.
      final file = File(path);
      final size = await file.length();
      if (size > 15 * 1024 * 1024) {
        Fluttertoast.showToast(msg: 'Archivo muy grande (máx 15 MB)');
        return;
      }
      String? caption;
      caption = await showDialog<String>(
        context: context,
        builder: (_) {
          String t = '';
          return AlertDialog(
            backgroundColor: const Color(0xFF0D1F14),
            title: const Text('Título (opcional)', style: TextStyle(color: Color(0xFF00E65A))),
            content: TextField(
              autofocus: true,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                hintText: 'Ej: 🎵 Mi canción favorita',
                hintStyle: TextStyle(color: Colors.grey),
                enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Color(0xFF00E65A))),
                focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: Color(0xFF00E65A))),
              ),
              onChanged: (v) => t = v,
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, ''), child: const Text('Sin título', style: TextStyle(color: Colors.grey))),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00E65A), foregroundColor: Colors.black),
                onPressed: () => Navigator.pop(context, t),
                child: const Text('Publicar'),
              ),
            ],
          );
        },
      );
      if (caption == null) return; // user dismissed
      setState(() => _uploading = true);
      final chatProvider = context.read<ChatProvider>();
      final ext = p.extension(path).isNotEmpty ? p.extension(path) : '.mp3';
      final fileName = 'story_audio_${DateTime.now().millisecondsSinceEpoch}$ext';
      final snapshot = await chatProvider.uploadFile(file, fileName);
      final url = await snapshot.ref.getDownloadURL();
      final displayName = picked.name;
      await _publishStory(
        audioUrl: url,
        audioName: displayName,
        textContent: caption.trim(),
      );
    } catch (e) {
      Fluttertoast.showToast(msg: 'Error subiendo audio: $e');
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _publishStory({String? textContent, String? imageUrl, String? audioUrl, String? audioName}) async {
    final expiresAt = DateTime.now().add(const Duration(hours: 24)).millisecondsSinceEpoch;
    await FirebaseFirestore.instance.collection('stories').add({
      'userId': widget.currentUserId,
      'nickname': widget.currentNickname,
      'textContent': textContent ?? '',
      'imageUrl': imageUrl ?? '',
      'audioUrl': audioUrl ?? '',
      'audioName': audioName ?? '',
      'createdAt': DateTime.now().millisecondsSinceEpoch,
      'expiresAt': expiresAt,
      'views': <String>[],
      'commentsCount': 0,
    });
    Fluttertoast.showToast(msg: '✅ Estado publicado (24 h)');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('stories')
            .where('expiresAt', isGreaterThan: DateTime.now().millisecondsSinceEpoch)
            .orderBy('expiresAt', descending: true)
            .snapshots(),
        builder: (_, snap) {
          if (!snap.hasData) {
            return const Center(
                child: CircularProgressIndicator(color: ColorConstants.themeColor));
          }
          final docs = snap.data!.docs;

          // Agrupar por usuario manteniendo orden por fecha (más reciente primero).
          final Map<String, List<QueryDocumentSnapshot>> byUser = {};
          for (final doc in docs) {
            final uid = (doc.data() as Map)['userId'] as String? ?? '';
            byUser.putIfAbsent(uid, () => []).add(doc);
          }

          final myStories = byUser.remove(widget.currentUserId) ?? [];

          // Recientes vs Vistos
          final List<MapEntry<String, List<QueryDocumentSnapshot>>> recent = [];
          final List<MapEntry<String, List<QueryDocumentSnapshot>>> seen = [];
          for (final entry in byUser.entries) {
            final allViewed = entry.value.every((d) {
              final views = (d.data() as Map)['views'] as List? ?? [];
              return views.contains(widget.currentUserId);
            });
            (allViewed ? seen : recent).add(entry);
          }

          return RefreshIndicator(
            color: ColorConstants.themeColor,
            onRefresh: () async => Future.delayed(const Duration(milliseconds: 300)),
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                _buildMyStatusTile(myStories),
                if (recent.isNotEmpty) ...[
                  _sectionHeader('Actualizaciones recientes'),
                  ...recent.map((e) => _buildUserTile(e.key, e.value, isRecent: true)),
                ],
                if (seen.isNotEmpty) ...[
                  _sectionHeader('Vistos'),
                  ...seen.map((e) => _buildUserTile(e.key, e.value, isRecent: false)),
                ],
                if (recent.isEmpty && seen.isEmpty && myStories.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 80, horizontal: 32),
                    child: Column(
                      children: const [
                        Icon(Icons.auto_awesome,
                            color: ColorConstants.greyColor, size: 56),
                        SizedBox(height: 16),
                        Text('No hay estados aún',
                            style: TextStyle(
                                color: ColorConstants.greyColor,
                                fontSize: 16,
                                fontWeight: FontWeight.w600)),
                        SizedBox(height: 8),
                        Text(
                          'Sé el primero en compartir un estado.\nCaduca a las 24 horas.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              color: ColorConstants.greyColor, fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 80),
              ],
            ),
          );
        },
      ),
      floatingActionButton: _uploading
          ? const FloatingActionButton(
              onPressed: null,
              backgroundColor: Color(0xFF00E65A),
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                    strokeWidth: 2.5, color: Colors.black),
              ),
            )
          : FloatingActionButton.extended(
              onPressed: _addStory,
              backgroundColor: const Color(0xFF00E65A),
              foregroundColor: Colors.black,
              icon: const Icon(Icons.add),
              label: const Text('Nuevo estado',
                  style: TextStyle(fontWeight: FontWeight.bold)),
            ),
    );
  }

  Widget _sectionHeader(String label) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
      color: const Color(0xFFF1F3F4),
      child: Text(
        label,
        style: const TextStyle(
          color: Color(0xFF075E54),
          fontWeight: FontWeight.bold,
          fontSize: 12,
          letterSpacing: 0.3,
        ),
      ),
    );
  }

  Widget _buildMyStatusTile(List<QueryDocumentSnapshot> myStories) {
    final hasStory = myStories.isNotEmpty;
    final latest = hasStory ? myStories.first.data() as Map<String, dynamic> : null;
    final imageUrl = latest?['imageUrl'] as String? ?? '';
    final lastTs = latest?['createdAt'] as int? ?? 0;
    final subtitle = hasStory
        ? 'Hace ${_timeAgo(lastTs)} · ${myStories.length} actualización${myStories.length == 1 ? '' : 'es'}'
        : 'Toca para añadir actualización de estado';

    return Container(
      color: Colors.white,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: hasStory
                    ? const LinearGradient(
                        colors: [Color(0xFF00E65A), Color(0xFF005A22)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      )
                    : null,
                color: hasStory ? null : const Color(0xFFE0E0E0),
              ),
              padding: const EdgeInsets.all(2.5),
              child: ClipOval(
                child: imageUrl.isNotEmpty
                    ? Image.network(imageUrl, fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) =>
                            _avatarFallback(widget.currentNickname))
                    : _avatarFallback(widget.currentNickname),
              ),
            ),
            if (!hasStory)
              Positioned(
                right: -2,
                bottom: -2,
                child: Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    color: const Color(0xFF00E65A),
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 2),
                  ),
                  child: const Icon(Icons.add, size: 14, color: Colors.black),
                ),
              ),
          ],
        ),
        title: const Text('Mi estado',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
        subtitle: Text(
          subtitle,
          style: const TextStyle(color: ColorConstants.greyColor, fontSize: 13),
        ),
        onTap: () {
          if (hasStory) {
            Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => StoryViewPage(
                        stories: myStories,
                        currentUserId: widget.currentUserId)));
          } else {
            _addStory();
          }
        },
      ),
    );
  }

  Widget _buildUserTile(String uid, List<QueryDocumentSnapshot> userStories,
      {required bool isRecent}) {
    final latest = userStories.first.data() as Map<String, dynamic>;
    final nick = latest['nickname'] as String? ?? 'Usuario';
    final imageUrl = latest['imageUrl'] as String? ?? '';
    final ts = latest['createdAt'] as int? ?? 0;

    return Container(
      color: Colors.white,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: isRecent
                ? const LinearGradient(
                    colors: [Color(0xFF00E65A), Color(0xFF005A22)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  )
                : null,
            border: isRecent
                ? null
                : Border.all(color: const Color(0xFFBDBDBD), width: 2),
          ),
          padding: const EdgeInsets.all(2.5),
          child: ClipOval(
            child: imageUrl.isNotEmpty
                ? Image.network(imageUrl, fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => _avatarFallback(nick))
                : _avatarFallback(nick),
          ),
        ),
        title: Text(nick,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
        subtitle: Text(
          'Hace ${_timeAgo(ts)}${userStories.length > 1 ? ' · ${userStories.length} actualizaciones' : ''}',
          style: const TextStyle(color: ColorConstants.greyColor, fontSize: 13),
        ),
        onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
                builder: (_) => StoryViewPage(
                    stories: userStories,
                    currentUserId: widget.currentUserId))),
      ),
    );
  }

  Widget _avatarFallback(String nick) {
    return Container(
      color: const Color(0xFF1A3A2A),
      alignment: Alignment.center,
      child: Text(
        nick.isNotEmpty ? nick[0].toUpperCase() : '?',
        style: const TextStyle(
            color: Color(0xFF00E65A),
            fontWeight: FontWeight.bold,
            fontSize: 22),
      ),
    );
  }

  String _timeAgo(int ts) {
    if (ts <= 0) return 'hace un momento';
    final dt = DateTime.fromMillisecondsSinceEpoch(ts);
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return 'unos segundos';
    if (diff.inMinutes < 60) return '${diff.inMinutes} min';
    if (diff.inHours < 24) return '${diff.inHours} h';
    return DateFormat('dd MMM').format(dt);
  }
}

// ─────────────────────────────────────────────────────────────
//  STORY VIEW PAGE — fullscreen with comments
// ─────────────────────────────────────────────────────────────
class StoryViewPage extends StatefulWidget {
  const StoryViewPage({super.key, required this.stories, required this.currentUserId});
  final List<QueryDocumentSnapshot> stories;
  final String currentUserId;

  @override
  State<StoryViewPage> createState() => _StoryViewPageState();
}

class _StoryViewPageState extends State<StoryViewPage> {
  int _index = 0;
  bool _showComments = false;
  final _commentController = TextEditingController();
  final _audioPlayer = AudioPlayer();
  String _currentAudioUrl = '';
  bool _audioPlaying = false;

  Map<String, dynamic> get _current => widget.stories[_index].data() as Map<String, dynamic>;
  String get _storyId => widget.stories[_index].id;

  @override
  void initState() {
    super.initState();
    _markViewed();
    _syncAudioForCurrent();
    _audioPlayer.playerStateStream.listen((state) {
      if (mounted) setState(() => _audioPlaying = state.playing);
    });
  }

  Future<void> _syncAudioForCurrent() async {
    final url = (_current['audioUrl'] as String?) ?? '';
    if (url == _currentAudioUrl) return;
    _currentAudioUrl = url;
    try {
      await _audioPlayer.stop();
      if (url.isNotEmpty) {
        await _audioPlayer.setUrl(url);
        await _audioPlayer.play();
      }
    } catch (_) {}
  }

  void _markViewed() {
    final doc = widget.stories[_index];
    final views = List<String>.from((_current['views'] as List? ?? []));
    if (!views.contains(widget.currentUserId)) {
      doc.reference.update({'views': FieldValue.arrayUnion([widget.currentUserId])});
    }
  }

  void _next() {
    if (_index < widget.stories.length - 1) {
      setState(() { _index++; _showComments = false; });
      _markViewed();
      _syncAudioForCurrent();
    } else {
      Navigator.pop(context);
    }
  }

  void _prev() {
    if (_index > 0) {
      setState(() { _index--; _showComments = false; });
      _syncAudioForCurrent();
    }
  }

  Future<void> _sendComment() async {
    final text = _commentController.text.trim();
    if (text.isEmpty) return;
    _commentController.clear();
    await FirebaseFirestore.instance
        .collection('stories')
        .doc(_storyId)
        .collection('comments')
        .add({
      'userId': widget.currentUserId,
      'text': text,
      'createdAt': DateTime.now().millisecondsSinceEpoch,
    });
    await widget.stories[_index].reference.update({'commentsCount': FieldValue.increment(1)});
  }

  Future<void> _deleteStory() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('¿Eliminar estado?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancelar')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Eliminar', style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (ok == true) {
      await widget.stories[_index].reference.delete();
      if (mounted) Navigator.pop(context);
    }
  }

  @override
  void dispose() {
    _commentController.dispose();
    _audioPlayer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final d = _current;
    final imageUrl  = d['imageUrl'] as String? ?? '';
    final textContent = d['textContent'] as String? ?? '';
    final audioUrl = d['audioUrl'] as String? ?? '';
    final audioName = d['audioName'] as String? ?? '';
    final nick = d['nickname'] as String? ?? '';
    final createdAt = d['createdAt'] as int? ?? 0;
    final views = (d['views'] as List? ?? []).length;
    final commentsCount = d['commentsCount'] as int? ?? 0;
    final isOwner = d['userId'] == widget.currentUserId;
    final media = MediaQuery.of(context);
    final safeTop = media.padding.top;
    final safeBottom = media.padding.bottom;
    final keyboardInset = media.viewInsets.bottom;
    final commentsHeight = keyboardInset > 0
        ? media.size.height * 0.72
        : media.size.height * 0.5;
    final timeStr = createdAt > 0
        ? DateFormat('dd MMM · HH:mm').format(DateTime.fromMillisecondsSinceEpoch(createdAt))
        : '';

    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTapUp: (d) {
          if (_showComments) return;
          final x = d.globalPosition.dx;
          final w = media.size.width;
          if (x < w / 3) {
            _prev();
          } else {
            _next();
          }
        },
        child: Stack(
          children: [
            // Background
            if (imageUrl.isNotEmpty)
              Positioned.fill(
                child: Image.network(
                  imageUrl,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Container(
                    color: const Color(0xFF0D1F14),
                    alignment: Alignment.center,
                    child: const Icon(Icons.broken_image_outlined,
                        color: Colors.white54, size: 42),
                  ),
                ),
              )
            else if (audioUrl.isNotEmpty)
              Positioned.fill(
                child: Container(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      colors: [Color(0xFF005A22), Color(0xFF0D1F14)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                  ),
                  alignment: Alignment.center,
                  child: const Icon(Icons.music_note,
                      color: Color(0xFF00E65A), size: 120),
                ),
              )
            else
              Positioned.fill(
                child: Container(
                  color: const Color(0xFF0D1F14),
                  alignment: Alignment.center,
                  padding: const EdgeInsets.all(32),
                  child: Text(
                    textContent,
                    style: const TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.bold),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),

            // Overlay del reproductor de música (si hay audio)
            if (audioUrl.isNotEmpty)
              Positioned(
                left: 16, right: 16,
                bottom: safeBottom + 110,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.55),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Row(
                    children: [
                      IconButton(
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        icon: Icon(_audioPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled,
                            color: const Color(0xFF00E65A), size: 38),
                        onPressed: () {
                          if (_audioPlaying) {
                            _audioPlayer.pause();
                          } else {
                            _audioPlayer.play();
                          }
                        },
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (textContent.isNotEmpty)
                              Text(textContent,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 14)),
                            if (audioName.isNotEmpty)
                              Text(audioName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      color: Colors.white70, fontSize: 12)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Positioned.fill(
                child: Container(
                  color: const Color(0xFF0D1F14),
                  alignment: Alignment.center,
                  padding: const EdgeInsets.all(32),
                  child: Text(
                    textContent,
                    style: const TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.bold),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),

            // Progress bar
            Positioned(
              top: safeTop + 4,
              left: 8, right: 8,
              child: Row(
                children: List.generate(widget.stories.length, (i) => Expanded(
                  child: Container(
                    height: 3,
                    margin: const EdgeInsets.symmetric(horizontal: 2),
                    decoration: BoxDecoration(
                      color: i <= _index ? const Color(0xFF00E65A) : Colors.white30,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                )),
              ),
            ),

            // Header
            Positioned(
              top: safeTop + 16,
              left: 12, right: 12,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  CircleAvatar(
                    radius: 18,
                    backgroundColor: const Color(0xFF00E65A),
                    child: Text(nick.isNotEmpty ? nick[0].toUpperCase() : '?',
                        style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(nick, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                        Text(timeStr, style: const TextStyle(color: Colors.white70, fontSize: 11)),
                      ],
                    ),
                  ),
                  if (isOwner) ...[
                    Text('👁 $views', style: const TextStyle(color: Colors.white70, fontSize: 12)),
                    IconButton(
                      icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                      onPressed: _deleteStory,
                    ),
                  ],
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),

            // Comment button
            if (!_showComments)
              Positioned(
                bottom: safeBottom + 24, left: 0, right: 0,
                child: Center(
                  child: GestureDetector(
                    onTap: () => setState(() => _showComments = true),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(color: const Color(0xFF00E65A), width: 1),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.comment_outlined, color: Color(0xFF00E65A), size: 18),
                          const SizedBox(width: 6),
                          Text('$commentsCount comentarios',
                              style: const TextStyle(color: Colors.white, fontSize: 13)),
                        ],
                      ),
                    ),
                  ),
                ),
              ),

            // Comments panel
            if (_showComments)
              Positioned(
                bottom: 0, left: 0, right: 0,
                child: Container(
                  height: commentsHeight,
                  decoration: const BoxDecoration(
                    color: Color(0xEE0D1F14),
                    borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
                    border: Border(top: BorderSide(color: Color(0xFF00E65A), width: 1)),
                  ),
                  child: SafeArea(
                    top: false,
                    child: Column(
                      children: [
                        const SizedBox(height: 8),
                        GestureDetector(
                          onTap: () => FocusScope.of(context).unfocus(),
                          child: Container(
                            width: 40,
                            height: 4,
                            decoration: BoxDecoration(
                              color: const Color(0xFF00E65A),
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Row(
                            children: [
                              const Expanded(
                                child: Text('Comentarios',
                                    style: TextStyle(
                                        color: Color(0xFF00E65A),
                                        fontWeight: FontWeight.bold)),
                              ),
                              IconButton(
                                onPressed: () => setState(() => _showComments = false),
                                icon: const Icon(Icons.close, color: Colors.white70, size: 20),
                              ),
                            ],
                          ),
                        ),
                        const Divider(color: Color(0xFF1A4A2A), height: 1),
                        Expanded(
                          child: StreamBuilder<QuerySnapshot>(
                            stream: FirebaseFirestore.instance
                                .collection('stories')
                                .doc(_storyId)
                                .collection('comments')
                                .orderBy('createdAt')
                                .snapshots(),
                            builder: (_, snap) {
                              if (!snap.hasData) {
                                return const Center(
                                  child: CircularProgressIndicator(color: Color(0xFF00E65A)),
                                );
                              }
                              final comments = snap.data!.docs;
                              if (comments.isEmpty) {
                                return const Center(
                                  child: Text('Sin comentarios aún',
                                      style: TextStyle(color: Colors.grey)),
                                );
                              }
                              return ListView.builder(
                                keyboardDismissBehavior:
                                    ScrollViewKeyboardDismissBehavior.onDrag,
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                itemCount: comments.length,
                                itemBuilder: (_, i) {
                                  final c = comments[i].data() as Map<String, dynamic>;
                                  final uid = c['userId'] as String? ?? '';
                                  final text = c['text'] as String? ?? '';
                                  final ts = c['createdAt'] as int? ?? 0;
                                  final ago = ts > 0
                                      ? DateFormat('HH:mm').format(
                                          DateTime.fromMillisecondsSinceEpoch(ts))
                                      : '';
                                  return Padding(
                                    padding: const EdgeInsets.symmetric(vertical: 4),
                                    child: Row(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        CircleAvatar(
                                          radius: 14,
                                          backgroundColor: const Color(0xFF1A3A2A),
                                          child: Text(
                                            uid.isNotEmpty ? uid[0].toUpperCase() : '?',
                                            style: const TextStyle(
                                                color: Color(0xFF00E65A), fontSize: 12),
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Text(text,
                                                  style: const TextStyle(
                                                      color: Colors.white, fontSize: 13)),
                                              Text(ago,
                                                  style: const TextStyle(
                                                      color: Colors.grey, fontSize: 10)),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                },
                              );
                            },
                          ),
                        ),
                        Padding(
                          padding: EdgeInsets.fromLTRB(
                            12,
                            8,
                            12,
                            keyboardInset > 0 ? keyboardInset + 12 : safeBottom + 12,
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: _commentController,
                                  minLines: 1,
                                  maxLines: 3,
                                  textInputAction: TextInputAction.send,
                                  onSubmitted: (_) => _sendComment(),
                                  style: const TextStyle(color: Colors.white),
                                  decoration: InputDecoration(
                                    hintText: 'Escribe un comentario...',
                                    hintStyle: const TextStyle(color: Colors.grey),
                                    filled: true,
                                    fillColor: const Color(0xFF1A3A2A),
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(20),
                                      borderSide: BorderSide.none,
                                    ),
                                    contentPadding: const EdgeInsets.symmetric(
                                        horizontal: 16, vertical: 10),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              GestureDetector(
                                onTap: _sendComment,
                                child: Container(
                                  width: 40,
                                  height: 40,
                                  decoration: const BoxDecoration(
                                      color: Color(0xFF00E65A), shape: BoxShape.circle),
                                  child: const Icon(Icons.send, color: Colors.black, size: 18),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
