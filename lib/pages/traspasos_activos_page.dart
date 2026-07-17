import 'dart:convert';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../constants/firestore_constants.dart';
import 'group_chat_page.dart';

class TraspasosActivosPage extends StatefulWidget {
  const TraspasosActivosPage({super.key});

  @override
  State<TraspasosActivosPage> createState() => _TraspasosActivosPageState();
}

class _TraspasosActivosPageState extends State<TraspasosActivosPage> {
  List<Map<String, dynamic>> _traspasos = [];
  bool _loading = true;
  String _userId = '';
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _loadUserId();
    // Refrescar cada 30 segundos
    _refreshTimer = Timer.periodic(const Duration(seconds: 30), (_) => _fetchTraspasos());
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadUserId() async {
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getString(FirestoreConstants.lamanoUserId) ?? '';
    if (mounted) {
      setState(() => _userId = id);
      if (id.isNotEmpty) _fetchTraspasos();
    }
  }

  Future<void> _fetchTraspasos() async {
    if (_userId.isEmpty) return;

    try {
      final url = Uri.parse('http://93.127.135.73/lamano/api_traspasos_activos.php?user_id=$_userId');
      final resp = await http.get(url).timeout(const Duration(seconds: 15));
      final data = jsonDecode(resp.body) as Map<String, dynamic>;

      if (data['success'] == true) {
        final traspasos = List<Map<String, dynamic>>.from(data['traspasos'] ?? []);
        if (mounted) {
          setState(() {
            _traspasos = traspasos;
            _loading = false;
          });
        }
      } else {
        if (mounted) setState(() => _loading = false);
      }
    } catch (e) {
      debugPrint('Error fetching traspasos: $e');
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _openTraspasoGroup(Map<String, dynamic> traspaso) async {
    final traspasoId = traspaso['id'];
    final groupId = 'traspaso-$traspasoId';

    // Verificar si el grupo existe en Firestore
    final groupDoc = await FirebaseFirestore.instance.collection('groups').doc(groupId).get();

    if (!groupDoc.exists) {
      // Crear grupo automáticamente
      if (mounted) {
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (_) => const AlertDialog(
            content: Row(
              children: [
                CircularProgressIndicator(),
                SizedBox(width: 16),
                Text('Creando grupo...'),
              ],
            ),
          ),
        );
      }

      try {
        final createUrl = Uri.parse('http://93.127.135.73/lamano/api_traspaso_create_group_v2.php');
        final createResp = await http.post(
          createUrl,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'traspaso_id': traspasoId}),
        ).timeout(const Duration(seconds: 20));

        if (mounted) Navigator.pop(context); // Cerrar loading

        final createData = jsonDecode(createResp.body) as Map<String, dynamic>;
        if (createData['success'] != true) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(createData['message'] ?? 'Error al crear grupo'),
                backgroundColor: Colors.red,
              ),
            );
          }
          return;
        }
      } catch (e) {
        if (mounted) {
          Navigator.pop(context); // Cerrar loading
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
          );
        }
        return;
      }
    }

    // Abrir el grupo
    if (!mounted) return;

    final estadoEmoji = _getEstadoEmoji(traspaso['estado']);
    final groupName = '$estadoEmoji Traspaso #$traspasoId: ${traspaso['origen_nombre']} → ${traspaso['destino_nombre']}';

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => GroupChatPage(
          arguments: GroupChatArguments(
            groupId: groupId,
            groupName: groupName,
          ),
        ),
      ),
    );
  }

  String _getEstadoEmoji(String? estado) {
    switch (estado) {
      case 'pendiente':
        return '⏳';
      case 'aceptado':
        return '✅';
      case 'en_transito':
        return '🚛';
      case 'recibido':
        return '📦';
      default:
        return '📋';
    }
  }

  Color _getEstadoColor(String? estado) {
    switch (estado) {
      case 'pendiente':
        return Colors.orange;
      case 'aceptado':
        return Colors.green;
      case 'en_transito':
        return Colors.blue;
      case 'recibido':
        return Colors.teal;
      default:
        return Colors.grey;
    }
  }

  String _getEstadoLabel(String? estado) {
    switch (estado) {
      case 'pendiente':
        return 'Pendiente';
      case 'aceptado':
        return 'Aceptado';
      case 'en_transito':
        return 'En Ruta';
      case 'recibido':
        return 'Completada';
      default:
        return estado ?? 'N/A';
    }
  }

  String _formatDate(String? dateStr) {
    if (dateStr == null || dateStr.isEmpty) return '-';
    try {
      final date = DateTime.parse(dateStr);
      return DateFormat('dd/MM/yyyy HH:mm').format(date);
    } catch (_) {
      return dateStr;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Traspasos Activos'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _fetchTraspasos,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _traspasos.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.inventory_2_outlined, size: 64, color: Colors.grey.shade400),
                      const SizedBox(height: 16),
                      Text(
                        'No tienes traspasos activos',
                        style: TextStyle(fontSize: 16, color: Colors.grey.shade600),
                      ),
                    ],
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _fetchTraspasos,
                  child: ListView.builder(
                    padding: const EdgeInsets.all(12),
                    itemCount: _traspasos.length,
                    itemBuilder: (ctx, i) {
                      final t = _traspasos[i];
                      final estado = t['estado'] as String?;
                      final estadoLabel = _getEstadoLabel(estado);
                      final estadoColor = _getEstadoColor(estado);
                      final estadoEmoji = _getEstadoEmoji(estado);
                      final traspasoId = t['id'];
                      final origenNombre = t['origen_nombre'] ?? '-';
                      final destinoNombre = t['destino_nombre'] ?? '-';
                      final totalProductos = t['total_productos'] ?? 0;
                      final totalPersonal = t['total_personal'] ?? 0;
                      final fechaViaje = t['fecha_viaje'] as String?;
                      final horaViaje = t['hora_viaje'] as String?;
                      final observaciones = t['observaciones'] as String?;

                      return Card(
                        margin: const EdgeInsets.only(bottom: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        elevation: 2,
                        child: InkWell(
                          onTap: () => _openTraspasoGroup(t),
                          borderRadius: BorderRadius.circular(12),
                          child: Padding(
                            padding: const EdgeInsets.all(14),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                // Header: Estado + ID
                                Row(
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                      decoration: BoxDecoration(
                                        color: estadoColor.withOpacity(0.15),
                                        borderRadius: BorderRadius.circular(8),
                                        border: Border.all(color: estadoColor),
                                      ),
                                      child: Text(
                                        '$estadoEmoji $estadoLabel',
                                        style: TextStyle(
                                          color: estadoColor,
                                          fontWeight: FontWeight.bold,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ),
                                    const Spacer(),
                                    Text(
                                      'Traspaso #$traspasoId',
                                      style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 14,
                                        color: Color(0xFF203152),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 12),

                                // Ruta: Origen → Destino
                                Row(
                                  children: [
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          const Text(
                                            'Origen',
                                            style: TextStyle(fontSize: 11, color: Colors.grey),
                                          ),
                                          const SizedBox(height: 2),
                                          Text(
                                            origenNombre,
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w600,
                                              fontSize: 13,
                                            ),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ],
                                      ),
                                    ),
                                    const Padding(
                                      padding: EdgeInsets.symmetric(horizontal: 8),
                                      child: Icon(Icons.arrow_forward, size: 20, color: Colors.blue),
                                    ),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.end,
                                        children: [
                                          const Text(
                                            'Destino',
                                            style: TextStyle(fontSize: 11, color: Colors.grey),
                                          ),
                                          const SizedBox(height: 2),
                                          Text(
                                            destinoNombre,
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w600,
                                              fontSize: 13,
                                            ),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            textAlign: TextAlign.right,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 12),

                                // Información adicional
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    _infoChip(Icons.inventory_2, '$totalProductos producto(s)'),
                                    _infoChip(Icons.people, '$totalPersonal persona(s)'),
                                  ],
                                ),

                                if (fechaViaje != null && fechaViaje.isNotEmpty) ...[
                                  const SizedBox(height: 8),
                                  Row(
                                    children: [
                                      const Icon(Icons.calendar_today, size: 14, color: Colors.grey),
                                      const SizedBox(width: 6),
                                      Text(
                                        '$fechaViaje ${horaViaje ?? ''}',
                                        style: const TextStyle(fontSize: 12, color: Colors.grey),
                                      ),
                                    ],
                                  ),
                                ],

                                if (observaciones != null && observaciones.isNotEmpty) ...[
                                  const SizedBox(height: 8),
                                  Text(
                                    observaciones,
                                    style: const TextStyle(fontSize: 12, color: Colors.black54),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],

                                const SizedBox(height: 12),

                                // Botón para abrir grupo
                                SizedBox(
                                  width: double.infinity,
                                  child: OutlinedButton.icon(
                                    icon: const Icon(Icons.chat_bubble_outline, size: 16),
                                    label: const Text('Abrir Grupo de Seguimiento'),
                                    style: OutlinedButton.styleFrom(
                                      foregroundColor: Colors.blue,
                                      side: const BorderSide(color: Colors.blue),
                                      padding: const EdgeInsets.symmetric(vertical: 10),
                                    ),
                                    onPressed: () => _openTraspasoGroup(t),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
    );
  }

  Widget _infoChip(IconData icon, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: Colors.grey.shade700),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(fontSize: 11, color: Colors.grey.shade700),
          ),
        ],
      ),
    );
  }
}
