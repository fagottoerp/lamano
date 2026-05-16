import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';

/// Resultado seleccionado por el usuario al elegir una canción.
class PickedSong {
  final String trackName;
  final String artistName;
  final String previewUrl; // mp3/m4a 30s
  final String artworkUrl;
  final int trackTimeMs;

  PickedSong({
    required this.trackName,
    required this.artistName,
    required this.previewUrl,
    required this.artworkUrl,
    required this.trackTimeMs,
  });
}

/// Página estilo WhatsApp para buscar y seleccionar una canción.
/// Usa iTunes Search API (gratis, sin auth) que devuelve previews de 30s
/// con `previewUrl` (m4a) y `artworkUrl100` (carátula).
class SongPickerPage extends StatefulWidget {
  const SongPickerPage({super.key});

  @override
  State<SongPickerPage> createState() => _SongPickerPageState();
}

class _SongPickerPageState extends State<SongPickerPage> {
  final _searchController = TextEditingController();
  final _audioPlayer = AudioPlayer();
  Timer? _debounce;
  String _query = '';
  String _category = 'Populares';
  bool _loading = false;
  String? _error;
  List<Map<String, dynamic>> _results = [];

  // Categorías rápidas con queries pre-armadas.
  final Map<String, String> _categoryQueries = const {
    'Populares': 'top 2026',
    'Latina': 'reggaeton hits 2026',
    'Reggaetón': 'reggaeton',
    'Pop': 'pop hits',
    'Rock': 'rock',
    'Cumbia': 'cumbia',
    'Salsa': 'salsa',
    'Banda': 'banda mexicana',
    'Electrónica': 'electronic dance',
    'Hip-Hop': 'hip hop',
  };

  String? _previewingUrl;
  bool _previewPlaying = false;

  @override
  void initState() {
    super.initState();
    _audioPlayer.playerStateStream.listen((state) {
      if (mounted) setState(() => _previewPlaying = state.playing);
    });
    _fetchCategory(_category);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _audioPlayer.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _fetchCategory(String cat) async {
    setState(() => _category = cat);
    final q = _categoryQueries[cat] ?? cat;
    await _doSearch(q);
  }

  void _onSearchChanged(String value) {
    _query = value;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 450), () {
      if (value.trim().isEmpty) {
        _fetchCategory(_category);
      } else {
        _doSearch(value);
      }
    });
  }

  Future<void> _doSearch(String term) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final uri = Uri.parse(
          'https://itunes.apple.com/search?term=${Uri.encodeQueryComponent(term)}&media=music&entity=song&limit=30&country=cl');
      final resp = await http.get(uri).timeout(const Duration(seconds: 12));
      if (resp.statusCode != 200) {
        throw 'HTTP ${resp.statusCode}';
      }
      final body = json.decode(resp.body) as Map<String, dynamic>;
      final results = (body['results'] as List? ?? [])
          .whereType<Map<String, dynamic>>()
          .where((m) => (m['previewUrl'] as String?)?.isNotEmpty == true)
          .toList();
      if (!mounted) return;
      setState(() => _results = results);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Error: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _togglePreview(String url) async {
    if (_previewingUrl == url && _previewPlaying) {
      await _audioPlayer.pause();
      return;
    }
    if (_previewingUrl == url && !_previewPlaying) {
      await _audioPlayer.play();
      return;
    }
    try {
      await _audioPlayer.stop();
      await _audioPlayer.setUrl(url);
      _previewingUrl = url;
      await _audioPlayer.play();
    } catch (_) {}
  }

  void _select(Map<String, dynamic> song) {
    _audioPlayer.stop();
    final picked = PickedSong(
      trackName: (song['trackName'] as String?) ?? '',
      artistName: (song['artistName'] as String?) ?? '',
      previewUrl: (song['previewUrl'] as String?) ?? '',
      artworkUrl:
          ((song['artworkUrl100'] as String?) ?? '').replaceAll('100x100', '300x300'),
      trackTimeMs: ((song['trackTimeMillis'] as num?) ?? 30000).toInt(),
    );
    Navigator.pop(context, picked);
  }

  String _fmtDuration(int ms) {
    final s = (ms ~/ 1000).clamp(0, 9999);
    final m = s ~/ 60;
    final r = s % 60;
    return '$m:${r.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D1F14),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0D1F14),
        iconTheme: const IconThemeData(color: Colors.white),
        title: const Text('Elegir canción',
            style: TextStyle(color: Color(0xFF00E65A), fontWeight: FontWeight.bold)),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: TextField(
              controller: _searchController,
              onChanged: _onSearchChanged,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: 'Buscar canciones o artistas',
                hintStyle: const TextStyle(color: Colors.white54),
                prefixIcon: const Icon(Icons.search, color: Colors.white54),
                filled: true,
                fillColor: const Color(0xFF1A3A2A),
                contentPadding: const EdgeInsets.symmetric(vertical: 0),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(28),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          SizedBox(
            height: 42,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: _categoryQueries.keys.map((cat) {
                final selected = cat == _category && _query.trim().isEmpty;
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(cat),
                    selected: selected,
                    onSelected: (_) {
                      _searchController.clear();
                      _query = '';
                      _fetchCategory(cat);
                    },
                    selectedColor: const Color(0xFF00E65A),
                    backgroundColor: const Color(0xFF1A3A2A),
                    labelStyle: TextStyle(
                      color: selected ? Colors.black : Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                    side: BorderSide.none,
                  ),
                );
              }).toList(),
            ),
          ),
          const SizedBox(height: 4),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator(color: Color(0xFF00E65A)))
                : _error != null
                    ? Center(
                        child: Text(_error!,
                            style: const TextStyle(color: Colors.redAccent)))
                    : _results.isEmpty
                        ? const Center(
                            child: Text('Sin resultados',
                                style: TextStyle(color: Colors.white54)))
                        : ListView.separated(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            itemCount: _results.length,
                            separatorBuilder: (_, __) =>
                                const Divider(color: Colors.white12, height: 1),
                            itemBuilder: (_, i) {
                              final s = _results[i];
                              final track = (s['trackName'] as String?) ?? '';
                              final artist = (s['artistName'] as String?) ?? '';
                              final art = (s['artworkUrl100'] as String?) ?? '';
                              final preview = (s['previewUrl'] as String?) ?? '';
                              final ms =
                                  ((s['trackTimeMillis'] as num?) ?? 30000).toInt();
                              final isThis = _previewingUrl == preview;
                              return ListTile(
                                onTap: () => _select(s),
                                contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 4),
                                leading: GestureDetector(
                                  onTap: () => _togglePreview(preview),
                                  child: Stack(
                                    alignment: Alignment.center,
                                    children: [
                                      ClipRRect(
                                        borderRadius: BorderRadius.circular(6),
                                        child: art.isNotEmpty
                                            ? Image.network(art,
                                                width: 48, height: 48, fit: BoxFit.cover,
                                                errorBuilder: (_, __, ___) =>
                                                    _artFallback())
                                            : _artFallback(),
                                      ),
                                      Container(
                                        width: 48,
                                        height: 48,
                                        color: Colors.black38,
                                        child: Icon(
                                          isThis && _previewPlaying
                                              ? Icons.pause
                                              : Icons.play_arrow,
                                          color: Colors.white,
                                          size: 26,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                title: Text(track,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w600)),
                                subtitle: Text(
                                  '$artist · ${_fmtDuration(ms)}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(color: Colors.white60),
                                ),
                                trailing: const Icon(Icons.arrow_forward_ios,
                                    color: Colors.white38, size: 18),
                              );
                            },
                          ),
          ),
        ],
      ),
    );
  }

  Widget _artFallback() => Container(
        width: 48,
        height: 48,
        color: const Color(0xFF1A3A2A),
        child: const Icon(Icons.music_note, color: Color(0xFF00E65A)),
      );
}
