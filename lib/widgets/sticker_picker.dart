import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:giphy_flutter_sdk/giphy_flutter_sdk.dart';
import 'package:giphy_flutter_sdk/giphy_grid_view.dart';
import 'package:giphy_flutter_sdk/dto/giphy_content_request.dart';
import 'package:giphy_flutter_sdk/dto/giphy_media_type.dart';
import 'package:giphy_flutter_sdk/dto/giphy_rendition.dart';
import 'package:giphy_flutter_sdk/dto/giphy_theme.dart';
import 'package:giphy_flutter_sdk/dto/giphy_media.dart';
import '../services/sticker_service.dart';
import '../constants/color_constants.dart';

const _kGiphyApiKey = 'X8nOqtlMMY8MoOelMMrGr8C463M0NeX6';

class StickerPicker extends StatefulWidget {
  final void Function(String sticker) onStickerSelected;
  const StickerPicker({Key? key, required this.onStickerSelected}) : super(key: key);

  @override
  State<StickerPicker> createState() => _StickerPickerState();
}

class _StickerPickerState extends State<StickerPicker>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final TextEditingController _searchCtrl = TextEditingController();
  String _searchQuery = '';
  bool _uploading = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    GiphyFlutterSDK.configure(apiKey: _kGiphyApiKey);
  }

  @override
  void dispose() {
    _tabController.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _handleMediaSelect(GiphyMedia media) {
    final url = media.images?.fixedWidth?.webPUrl ??
        media.images?.fixedWidth?.gifUrl ??
        media.images?.original?.gifUrl ?? '';
    if (url.isNotEmpty && mounted) {
      widget.onStickerSelected(url);
      StickerService.saveGiphySticker(url);
    }
  }

  GiphyContentRequest get _currentRequest {
    if (_searchQuery.trim().isNotEmpty) {
      return GiphyContentRequest.search(
        mediaType: GiphyMediaType.sticker,
        searchQuery: _searchQuery.trim(),
      );
    }
    return GiphyContentRequest.trending(mediaType: GiphyMediaType.sticker);
  }

  Future<void> _addSticker(ImageSource source) async {
    setState(() => _uploading = true);
    try {
      final url = await StickerService.createStickerFromGallery(source: source);
      if (url != null) widget.onStickerSelected(url);
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  static const List<String> _builtIn = [
    'mimi1', 'mimi2', 'mimi3',
    'mimi4', 'mimi5', 'mimi6',
    'mimi7', 'mimi8', 'mimi9',
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 360,
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: ColorConstants.greyColor2, width: 0.5)),
      ),
      child: Column(
        children: [
          TabBar(
            controller: _tabController,
            indicatorColor: ColorConstants.themeColor,
            labelColor: ColorConstants.themeColor,
            unselectedLabelColor: Colors.grey,
            tabs: const [
              Tab(icon: Icon(Icons.gif_box, size: 20), text: 'Giphy'),
              Tab(icon: Icon(Icons.person, size: 20), text: 'Mis Stickers'),
              Tab(icon: Icon(Icons.emoji_emotions, size: 20), text: 'Predeterminados'),
            ],
          ),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                // ── Tab 0: Giphy GridView embebido ───────────────────────
                Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                      child: TextField(
                        controller: _searchCtrl,
                        decoration: InputDecoration(
                          hintText: 'Buscar stickers en Giphy...',
                          prefixIcon: const Icon(Icons.search, size: 20),
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(vertical: 8),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(20)),
                          suffixIcon: _searchQuery.isNotEmpty
                              ? IconButton(
                                  icon: const Icon(Icons.clear, size: 18),
                                  onPressed: () {
                                    _searchCtrl.clear();
                                    setState(() => _searchQuery = '');
                                  },
                                )
                              : null,
                        ),
                        onChanged: (v) => setState(() => _searchQuery = v),
                      ),
                    ),
                    Expanded(
                      child: GiphyGridView(
                        content: _currentRequest,
                        renditionType: GiphyRendition.fixedWidth,
                        spanCount: 3,
                        cellPadding: 4,
                        theme: GiphyTheme.fromPreset(preset: GiphyThemePreset.light),
                        onMediaSelect: _handleMediaSelect,
                      ),
                    ),
                  ],
                ),

                // ── Tab 1: Mis Stickers ───────────────────────────────────
                StreamBuilder<List<String>>(
                  stream: StickerService.myStickersStream(),
                  builder: (ctx, snap) {
                    final stickers = snap.data ?? [];
                    return GridView.builder(
                      padding: const EdgeInsets.all(8),
                      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 4, crossAxisSpacing: 6, mainAxisSpacing: 6,
                      ),
                      itemCount: stickers.length + 2,
                      itemBuilder: (ctx, i) {
                        if (i == 0) return _AddButton(icon: Icons.photo_library, label: 'Galería', loading: _uploading, onTap: () => _addSticker(ImageSource.gallery));
                        if (i == 1) return _AddButton(icon: Icons.camera_alt, label: 'Cámara', loading: false, onTap: () => _addSticker(ImageSource.camera));
                        final url = stickers[i - 2];
                        return GestureDetector(
                          onLongPress: () => _confirmDelete(url),
                          onTap: () => widget.onStickerSelected(url),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image.network(url, fit: BoxFit.cover,
                              loadingBuilder: (_, child, p) => p == null ? child : const Center(child: CircularProgressIndicator(strokeWidth: 2)),
                              errorBuilder: (_, __, ___) => const Icon(Icons.broken_image, color: Colors.grey)),
                          ),
                        );
                      },
                    );
                  },
                ),
                GridView.builder(
                  padding: const EdgeInsets.all(8),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 4, crossAxisSpacing: 6, mainAxisSpacing: 6,
                  ),
                  itemCount: _builtIn.length,
                  itemBuilder: (ctx, i) => GestureDetector(
                    onTap: () => widget.onStickerSelected(_builtIn[i]),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.asset('images/${_builtIn[i]}.gif', fit: BoxFit.cover),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _confirmDelete(String url) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Eliminar sticker'),
        content: const Text('¿Eliminar este sticker de tu colección?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
          TextButton(
            onPressed: () async { Navigator.pop(context); await StickerService.deleteSticker(url); },
            child: const Text('Eliminar', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }
}

class _AddButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool loading;
  final VoidCallback onTap;
  const _AddButton({required this.icon, required this.label, required this.loading, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: loading ? null : onTap,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.grey.shade100,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.grey.shade300),
        ),
        child: loading
            ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
            : Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, color: ColorConstants.themeColor, size: 28),
                  const SizedBox(height: 4),
                  Text(label, style: const TextStyle(fontSize: 10, color: Colors.grey)),
                ],
              ),
      ),
    );
  }
}
