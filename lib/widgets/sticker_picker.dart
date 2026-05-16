import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../services/sticker_service.dart';
import '../constants/color_constants.dart';

/// WhatsApp-style sticker picker panel.
/// Callback [onStickerSelected] receives:
///  - the sticker identifier (asset name like "mimi1" or a https:// URL)
class StickerPicker extends StatefulWidget {
  final void Function(String sticker) onStickerSelected;
  const StickerPicker({Key? key, required this.onStickerSelected}) : super(key: key);

  @override
  State<StickerPicker> createState() => _StickerPickerState();
}

class _StickerPickerState extends State<StickerPicker> with SingleTickerProviderStateMixin {
  late TabController _tabController;

  // Built-in stickers (assets)
  static const List<String> _builtIn = [
    'mimi1', 'mimi2', 'mimi3',
    'mimi4', 'mimi5', 'mimi6',
    'mimi7', 'mimi8', 'mimi9',
  ];

  bool _uploading = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _addSticker(ImageSource source) async {
    setState(() => _uploading = true);
    try {
      final url = await StickerService.createStickerFromGallery(source: source);
      if (url != null) {
        widget.onStickerSelected(url);
      }
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 300,
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: ColorConstants.greyColor2, width: 0.5)),
      ),
      child: Column(
        children: [
          // Tab bar
          TabBar(
            controller: _tabController,
            indicatorColor: ColorConstants.themeColor,
            labelColor: ColorConstants.themeColor,
            unselectedLabelColor: Colors.grey,
            tabs: const [
              Tab(icon: Icon(Icons.person, size: 20), text: 'Mis Stickers'),
              Tab(icon: Icon(Icons.emoji_emotions, size: 20), text: 'Predeterminados'),
            ],
          ),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                // --- MIS STICKERS ---
                StreamBuilder<List<String>>(
                  stream: StickerService.myStickersStream(),
                  builder: (ctx, snap) {
                    final stickers = snap.data ?? [];
                    return GridView.builder(
                      padding: const EdgeInsets.all(8),
                      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 4,
                        crossAxisSpacing: 6,
                        mainAxisSpacing: 6,
                      ),
                      itemCount: stickers.length + 2, // +2 for camera & gallery buttons
                      itemBuilder: (ctx, i) {
                        // First cell = pick from gallery
                        if (i == 0) {
                          return _AddButton(
                            icon: Icons.photo_library,
                            label: 'Galería',
                            loading: _uploading,
                            onTap: () => _addSticker(ImageSource.gallery),
                          );
                        }
                        // Second cell = take photo
                        if (i == 1) {
                          return _AddButton(
                            icon: Icons.camera_alt,
                            label: 'Cámara',
                            loading: false,
                            onTap: () => _addSticker(ImageSource.camera),
                          );
                        }
                        final url = stickers[i - 2];
                        return GestureDetector(
                          onLongPress: () => _confirmDelete(url),
                          onTap: () => widget.onStickerSelected(url),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image.network(
                              url,
                              fit: BoxFit.cover,
                              loadingBuilder: (_, child, progress) =>
                                  progress == null ? child : const Center(child: CircularProgressIndicator(strokeWidth: 2)),
                              errorBuilder: (_, __, ___) =>
                                  const Icon(Icons.broken_image, color: Colors.grey),
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),

                // --- PREDETERMINADOS ---
                GridView.builder(
                  padding: const EdgeInsets.all(8),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 4,
                    crossAxisSpacing: 6,
                    mainAxisSpacing: 6,
                  ),
                  itemCount: _builtIn.length,
                  itemBuilder: (ctx, i) {
                    final name = _builtIn[i];
                    return GestureDetector(
                      onTap: () => widget.onStickerSelected(name),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.asset(
                          'images/$name.gif',
                          fit: BoxFit.cover,
                        ),
                      ),
                    );
                  },
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
            onPressed: () async {
              Navigator.pop(context);
              await StickerService.deleteSticker(url);
            },
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
