import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../constants/app_constants.dart';
import '../constants/firestore_constants.dart';
import 'chat_page.dart';

/// Shows active orders (created by this agent/executive) that have a motoboy
/// assigned.  Tapping an order opens a Firebase chat with the motoboy using
/// customGroupChatId = 'order-{orderId}'.
class TempChatsPage extends StatefulWidget {
  const TempChatsPage({super.key});

  @override
  State<TempChatsPage> createState() => _TempChatsPageState();
}

class _TempChatsPageState extends State<TempChatsPage> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  List<Map<String, dynamic>> _orders = [];
  bool _loading = true;
  String? _error;
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _loadOrders();
    // Auto-refresh every 30 s so newly-assigned orders appear
    _refreshTimer = Timer.periodic(const Duration(seconds: 30), (_) => _loadOrders());
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadOrders() async {
    final prefs = await SharedPreferences.getInstance();
    final lamanoUserId = prefs.getString(FirestoreConstants.lamanoUserId) ?? '0';

    try {
      final uri = Uri.parse(
          '${AppConstants.agentOrdersChatApiUrl}?user_id=$lamanoUserId');
      final resp = await http.get(uri).timeout(const Duration(seconds: 12));
      if (!mounted) return;
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      if (data['success'] == true) {
        setState(() {
          _orders = List<Map<String, dynamic>>.from(data['orders'] ?? []);
          _loading = false;
          _error = null;
        });
      } else {
        setState(() {
          _error = data['message'] ?? 'Error al cargar órdenes';
          _loading = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Sin conexión. Reintenta.';
        _loading = false;
      });
    }
  }

  void _openChat(Map<String, dynamic> order) {
    final motoboyFirebaseUid = (order['motoboy_firebase_uid'] ?? '') as String;
    final motoboyName        = (order['motoboy_name']         ?? 'Motoboy') as String;
    final orderId            = order['order_id'] as int;
    final motoboyLamanoId    = (order['motoboy_id'] ?? 0).toString();
    final isGroup            = order['is_group'] == true;
    final motoboy2Uid        = (order['motoboy2_firebase_uid'] ?? '') as String;

    if (motoboyFirebaseUid.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('El motoboy aún no tiene sesión activa. Reintenta en un momento.'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    // Room shared between web and app: 'order-{id}'
    final customGroupChatId = 'order-$orderId';

    // For group orders, use motoboy2 uid as peerId so both receive messages
    // The room is shared so both will see all messages
    final effectivePeerId = (isGroup && motoboy2Uid.isNotEmpty) ? motoboy2Uid : motoboyFirebaseUid;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatPage(
          arguments: ChatPageArguments(
            peerId:            effectivePeerId,
            peerAvatar:        '',
            peerNickname:      isGroup ? '👥 $motoboyName · Orden #$orderId' : '$motoboyName · Orden #$orderId',
            customGroupChatId: customGroupChatId,
            peerLamanoId:      motoboyLamanoId,
          ),
        ),
      ),
    );
  }

  Color _stateColor(int state) {
    switch (state) {
      case 1: return Colors.blue;
      case 4: return Colors.orange;
      case 5: return Colors.green;
      default: return Colors.grey;
    }
  }

  String _stateLabel(int state) {
    switch (state) {
      case 1: return 'NUEVO';
      case 4: return 'ASIGNADO';
      case 5: return 'EN CAMINO';
      default: return 'ACTIVO';
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.wifi_off, size: 48, color: Colors.grey),
            const SizedBox(height: 12),
            Text(_error!, style: const TextStyle(color: Colors.grey)),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              onPressed: () { setState(() => _loading = true); _loadOrders(); },
              icon: const Icon(Icons.refresh),
              label: const Text('Reintentar'),
            ),
          ],
        ),
      );
    }

    if (_orders.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.chat_bubble_outline, size: 64, color: Colors.grey[300]),
            const SizedBox(height: 16),
            const Text(
              'No tienes órdenes activas\ncon motoboy asignado.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey, fontSize: 15),
            ),
            const SizedBox(height: 16),
            TextButton.icon(
              onPressed: () { setState(() => _loading = true); _loadOrders(); },
              icon: const Icon(Icons.refresh),
              label: const Text('Actualizar'),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadOrders,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: _orders.length,
        separatorBuilder: (_, __) => const Divider(height: 1, indent: 72),
        itemBuilder: (ctx, i) {
          final o = _orders[i];
          final state = (o['state'] ?? 0) as int;
          final motoboyName = (o['motoboy_name'] ?? 'Motoboy') as String;
          final orderId = (o['order_id'] ?? 0) as int;
          final isGroup = o['is_group'] == true;
          final hasUid = (o['motoboy_firebase_uid'] ?? '').toString().isNotEmpty;

          return ListTile(
            leading: CircleAvatar(
              backgroundColor: isGroup ? Colors.red.withOpacity(0.15) : _stateColor(state).withOpacity(0.15),
              child: Icon(
                isGroup ? Icons.group : Icons.person,
                color: isGroup ? Colors.red : _stateColor(state),
                size: 20,
              ),
            ),
            title: Text(
              isGroup ? '👥 $motoboyName' : motoboyName,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Orden #$orderId${isGroup ? ' · Entrega doble ⚠️' : ''}',
                  style: const TextStyle(fontSize: 12),
                ),
              ],
            ),
            trailing: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: _stateColor(state).withOpacity(0.1),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: _stateColor(state).withOpacity(0.4)),
                  ),
                  child: Text(
                    _stateLabel(state),
                    style: TextStyle(
                      fontSize: 10,
                      color: _stateColor(state),
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                if (!hasUid)
                  const Text('sin sesión', style: TextStyle(fontSize: 10, color: Colors.orange)),
              ],
            ),
            onTap: () => _openChat(o),
          );
        },
      ),
    );
  }
}
