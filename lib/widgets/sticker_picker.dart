import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:image_picker/image_picker.dart';
import '../services/sticker_service.dart';
import '../constants/color_constants.dart';

class StickerPicker extends StatefulWidget {
  final void Function(String sticker) onStickerSelected;
  const StickerPicker({Key? key, required this.onStickerSelected}) : super(key: key);

  @override
  State<StickerPicker> createState() => _StickerPickerState();
}

class _StickerPickerState extends State<StickerPicker> {
  bool _uploading = false;
  bool _importingPack = false;

  @override
  void dispose() {
    super.dispose();
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

  Future<void> _importZipPack() async {
    setState(() => _importingPack = true);
    try {
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['zip'],
        allowMultiple: false,
      );

      if (picked == null || picked.files.isEmpty) return;
      final path = picked.files.first.path;
      if (path == null || path.isEmpty) {
        Fluttertoast.showToast(msg: 'No se pudo leer el paquete ZIP');
        return;
      }

      final imported = await StickerService.importStickerPackFromZip(path);
      if (imported <= 0) {
        Fluttertoast.showToast(msg: 'No se encontraron stickers validos para importar');
      } else {
        Fluttertoast.showToast(msg: 'Stickers importados: $imported');
      }
    } catch (_) {
      Fluttertoast.showToast(msg: 'Error al importar paquete de stickers');
    } finally {
      if (mounted) setState(() => _importingPack = false);
    }
  }

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
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
            child: Row(
              children: [
                const Icon(Icons.sticky_note_2_outlined, size: 18, color: ColorConstants.themeColor),
                const SizedBox(width: 6),
                const Expanded(
                  child: Text(
                    'Mis stickers',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: ColorConstants.textPrimary),
                  ),
                ),
                TextButton.icon(
                  onPressed: _importingPack ? null : _importZipPack,
                  icon: _importingPack
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.archive_outlined, size: 16),
                  label: const Text('Importar ZIP'),
                  style: TextButton.styleFrom(foregroundColor: ColorConstants.themeColor),
                ),
              ],
            ),
          ),
          Expanded(
            child: StreamBuilder<List<String>>(
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
                  itemCount: stickers.length + 2,
                  itemBuilder: (ctx, i) {
                    if (i == 0) {
                      return _AddButton(
                        icon: Icons.photo_library,
                        label: 'Galeria',
                        loading: _uploading,
                        onTap: () => _addSticker(ImageSource.gallery),
                      );
                    }
                    if (i == 1) {
                      return _AddButton(
                        icon: Icons.camera_alt,
                        label: 'Camara',
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
                          loadingBuilder: (_, child, p) =>
                              p == null ? child : const Center(child: CircularProgressIndicator(strokeWidth: 2)),
                          errorBuilder: (_, __, ___) => const Icon(Icons.broken_image, color: Colors.grey),
                        ),
                      ),
                    );
                  },
                );
              },
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
