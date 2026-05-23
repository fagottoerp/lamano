import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';

class ShiftOpenClosePage extends StatefulWidget {
  final String lamanoUserId;
  final VoidCallback? onStatusChanged;

  const ShiftOpenClosePage({
    super.key,
    required this.lamanoUserId,
    this.onStatusChanged,
  });

  @override
  State<ShiftOpenClosePage> createState() => _ShiftOpenClosePageState();
}

class _ShiftOpenClosePageState extends State<ShiftOpenClosePage> {
  final _picker = ImagePicker();

  bool _loading = true;
  bool _saving = false;
  bool _lockRequired = false;
  Map<String, dynamic>? _status;

  final _openCashCtrl = TextEditingController();
  final _openNoteCtrl = TextEditingController();
  final _closeCashCtrl = TextEditingController();
  final _closeNoteCtrl = TextEditingController();

  final List<_KgLine> _openItems = [
    _KgLine(),
  ];
  final List<_KgLine> _closeItems = [
    _KgLine(),
  ];

  final List<XFile> _openPhotos = [];
  final List<XFile> _closePhotos = [];

  @override
  void initState() {
    super.initState();
    _loadStatus();
  }

  @override
  void dispose() {
    _openCashCtrl.dispose();
    _openNoteCtrl.dispose();
    _closeCashCtrl.dispose();
    _closeNoteCtrl.dispose();
    for (final x in _openItems) {
      x.dispose();
    }
    for (final x in _closeItems) {
      x.dispose();
    }
    super.dispose();
  }

  Future<void> _loadStatus() async {
    setState(() => _loading = true);
    try {
      final uri = Uri.parse(
        'http://38.247.147.220/lamano/api_shift_status.php?user_id=${widget.lamanoUserId}',
      );
      final resp = await http.get(uri).timeout(const Duration(seconds: 20));
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      if (data['success'] == true) {
        _status = data;
        _lockRequired = data['lock_required'] == true;
      } else {
        _showMsg(data['message']?.toString() ?? 'No se pudo cargar estado');
      }
    } catch (e) {
      _showMsg('Error de red: $e');
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
      widget.onStatusChanged?.call();
    }
  }

  Future<void> _pickPhoto(List<XFile> target, {required bool camera}) async {
    final x = await _picker.pickImage(
      source: camera ? ImageSource.camera : ImageSource.gallery,
      imageQuality: 85,
      maxWidth: 1800,
    );
    if (x == null) return;
    setState(() => target.add(x));
  }

  Future<void> _showPickSheet(List<XFile> target) async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt),
              title: const Text('Tomar foto'),
              onTap: () {
                Navigator.pop(context);
                _pickPhoto(target, camera: true);
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('Elegir de galeria'),
              onTap: () {
                Navigator.pop(context);
                _pickPhoto(target, camera: false);
              },
            ),
          ],
        ),
      ),
    );
  }

  List<Map<String, dynamic>> _collectItems(List<_KgLine> lines) {
    final out = <Map<String, dynamic>>[];
    for (final l in lines) {
      final name = l.nameCtrl.text.trim();
      final kg = double.tryParse(l.kgCtrl.text.trim().replaceAll(',', '.')) ?? 0;
      if (name.isEmpty || kg <= 0) continue;
      out.add({'name': name, 'kg': kg});
    }
    return out;
  }

  Future<void> _submitOpen() async {
    final items = _collectItems(_openItems);
    if (items.isEmpty) {
      _showMsg('Debes ingresar al menos 1 item con nombre y kilos.');
      return;
    }
    if (_openPhotos.isEmpty) {
      _showMsg('Debes subir al menos 1 foto en la apertura.');
      return;
    }

    setState(() => _saving = true);
    try {
      final req = http.MultipartRequest(
        'POST',
        Uri.parse('http://38.247.147.220/lamano/api_shift_open.php'),
      );
      req.fields['user_id'] = widget.lamanoUserId;
      req.fields['opening_cash'] = _openCashCtrl.text.trim();
      req.fields['open_note'] = _openNoteCtrl.text.trim();
      req.fields['items_json'] = jsonEncode(items);

      for (final p in _openPhotos) {
        req.files.add(await http.MultipartFile.fromPath('open_photos[]', p.path));
      }

      final stream = await req.send().timeout(const Duration(seconds: 60));
      final body = await stream.stream.bytesToString();
      final data = jsonDecode(body) as Map<String, dynamic>;
      if (data['success'] == true) {
        _showMsg('Apertura guardada.');
        _openPhotos.clear();
        await _loadStatus();
      } else {
        _showMsg(data['message']?.toString() ?? 'Error al abrir turno');
      }
    } catch (e) {
      _showMsg('Error al abrir turno: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _submitClose() async {
    final items = _collectItems(_closeItems);
    if (items.isEmpty) {
      _showMsg('Debes ingresar al menos 1 item con nombre y kilos para cierre.');
      return;
    }
    if (_closePhotos.isEmpty) {
      _showMsg('Debes subir al menos 1 foto en el cierre.');
      return;
    }

    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Confirmar cierre'),
        content: const Text('Vas a cerrar el turno con estos datos. Continuar?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancelar')),
          ElevatedButton(onPressed: () => Navigator.pop(context, true), child: const Text('Cerrar turno')),
        ],
      ),
    );
    if (confirm != true) return;

    setState(() => _saving = true);
    try {
      final req = http.MultipartRequest(
        'POST',
        Uri.parse('http://38.247.147.220/lamano/api_shift_close.php'),
      );
      req.fields['user_id'] = widget.lamanoUserId;
      req.fields['closing_cash'] = _closeCashCtrl.text.trim();
      req.fields['close_note'] = _closeNoteCtrl.text.trim();
      req.fields['items_json'] = jsonEncode(items);

      for (final p in _closePhotos) {
        req.files.add(await http.MultipartFile.fromPath('close_photos[]', p.path));
      }

      final stream = await req.send().timeout(const Duration(seconds: 60));
      final body = await stream.stream.bytesToString();
      final data = jsonDecode(body) as Map<String, dynamic>;
      if (data['success'] == true) {
        final s = data['summary'] as Map<String, dynamic>? ?? {};
        final backendMsg = data['close_summary_message']?.toString().trim() ?? '';
        _showMsg(
          backendMsg.isNotEmpty
              ? 'Turno cerrado. $backendMsg'
              : 'Turno cerrado. Ordenes: ${s['orders_completed'] ?? 0}, Dinero: ${s['money_total'] ?? 0}, Gastos: ${s['expenses_total'] ?? 0}',
        );
        _closePhotos.clear();
        await _loadStatus();
      } else {
        _showMsg(data['message']?.toString() ?? 'Error al cerrar turno');
      }
    } catch (e) {
      _showMsg('Error al cerrar turno: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _showMsg(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg)),
    );
  }

  Widget _buildItemLines(List<_KgLine> lines) {
    return Column(
      children: [
        for (int i = 0; i < lines.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                Expanded(
                  flex: 5,
                  child: TextField(
                    controller: lines[i].nameCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Nombre',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 3,
                  child: TextField(
                    controller: lines[i].kgCtrl,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'Kilos',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  onPressed: lines.length == 1
                      ? null
                      : () {
                          setState(() {
                            lines[i].dispose();
                            lines.removeAt(i);
                          });
                        },
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: () => setState(() => lines.add(_KgLine())),
            icon: const Icon(Icons.add),
            label: const Text('Agregar item'),
          ),
        ),
      ],
    );
  }

  Widget _buildPhotos(List<XFile> photos) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (int i = 0; i < photos.length; i++)
              Stack(
                children: [
                  Container(
                    width: 92,
                    height: 92,
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey.shade300),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.image, color: Colors.green),
                  ),
                  Positioned(
                    right: -8,
                    top: -8,
                    child: IconButton(
                      icon: const Icon(Icons.cancel, color: Colors.red),
                      onPressed: () => setState(() => photos.removeAt(i)),
                    ),
                  ),
                ],
              ),
            OutlinedButton.icon(
              onPressed: () => _showPickSheet(photos),
              icon: const Icon(Icons.camera_alt),
              label: const Text('Agregar foto'),
            ),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    final openTurn = _status?['open_turn'] as Map<String, dynamic>?;
    final liveSummary = openTurn?['live_summary'] as Map<String, dynamic>?;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _status?['message']?.toString() ?? 'Apertura y cierre',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          if (_lockRequired)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(top: 10),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.red.shade50,
                border: Border.all(color: Colors.red.shade300),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text(
                'Debes cerrar el turno anterior para desbloquear el sistema.',
                style: TextStyle(fontWeight: FontWeight.w700, color: Colors.red),
              ),
            ),
          const SizedBox(height: 14),

          if (openTurn == null) ...[
            const Text('Apertura', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            TextField(
              controller: _openCashCtrl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'Inicio de caja (opcional)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _openNoteCtrl,
              decoration: const InputDecoration(
                labelText: 'Comentario (opcional)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            _buildItemLines(_openItems),
            const Text('Fotos de apertura (obligatorio):'),
            const SizedBox(height: 6),
            _buildPhotos(_openPhotos),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _saving ? null : _submitOpen,
                icon: const Icon(Icons.login),
                label: Text(_saving ? 'Guardando...' : 'Iniciar turno'),
              ),
            ),
          ] else ...[
            const Text('Cerrar turno', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text(
              'Iniciaste el turno a las ${DateTime.fromMillisecondsSinceEpoch(((openTurn['opened_at'] ?? 0) as int) * 1000).toLocal().toString().substring(11, 16)}. '
              'Ordenes completadas: ${liveSummary?['orders_completed'] ?? 0}. '
              'Dinero: ${liveSummary?['money_total'] ?? 0}. '
              'Gastos: ${liveSummary?['expenses_total'] ?? 0}.',
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _closeCashCtrl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'Caja al cierre (opcional)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _closeNoteCtrl,
              decoration: const InputDecoration(
                labelText: 'Comentario cierre (opcional)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            _buildItemLines(_closeItems),
            const Text('Fotos de cierre (obligatorio):'),
            const SizedBox(height: 6),
            _buildPhotos(_closePhotos),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _saving ? null : _submitClose,
                icon: const Icon(Icons.logout),
                label: Text(_saving ? 'Guardando...' : 'Cerrar turno'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _KgLine {
  final TextEditingController nameCtrl = TextEditingController();
  final TextEditingController kgCtrl = TextEditingController();

  void dispose() {
    nameCtrl.dispose();
    kgCtrl.dispose();
  }
}
