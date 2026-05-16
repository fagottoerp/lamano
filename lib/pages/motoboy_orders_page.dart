import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_chat_demo/constants/app_constants.dart';
import 'package:flutter_chat_demo/constants/color_constants.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../constants/firestore_constants.dart';
import '../utils/connectivity_service.dart';
import '../utils/safe_json.dart';
import 'chat_page.dart';

class MotoboOrdersPage extends StatefulWidget {
  const MotoboOrdersPage({super.key});

  @override
  State<MotoboOrdersPage> createState() => _MotoboOrdersPageState();
}

class _MotoboOrdersPageState extends State<MotoboOrdersPage> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final _tabs = const ['Pendientes', 'Entregadas', 'Completadas'];
  final _tabKeys = const ['pendientes', 'entregadas', 'completadas'];
  int _refreshToken = 0;
  StreamSubscription<bool>? _connSub;
  bool _online = true;

  String _lamanoUserId = '';
  String _motoboyPhone = '';

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: _tabs.length, vsync: this);
    // Refresh automático al cambiar de tab (evita ver datos viejos al volver).
    _tabController.addListener(() {
      if (!_tabController.indexIsChanging && mounted) {
        setState(() => _refreshToken++);
      }
    });
    _online = ConnectivityService.instance.online;
    _connSub = ConnectivityService.instance.stream.listen((isOnline) {
      if (!mounted) return;
      setState(() {
        _online = isOnline;
        if (isOnline) _refreshToken++; // al recuperar conexión, refrescar
      });
    });
    _loadUserId();
  }

  Future<void> _loadUserId() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _lamanoUserId = prefs.getString(FirestoreConstants.lamanoUserId) ?? '';
      _motoboyPhone = prefs.getString(FirestoreConstants.motoboyPhone) ?? '';
    });
  }

  @override
  void dispose() {
    _connSub?.cancel();
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        if (!_online)
          Material(
            color: Colors.red.shade700,
            child: SafeArea(
              bottom: false,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: const [
                    Icon(Icons.wifi_off, color: Colors.white, size: 16),
                    SizedBox(width: 8),
                    Text(
                      'Sin conexión — los datos pueden estar desactualizados',
                      style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
            ),
          ),
        Material(
          color: Theme.of(context).scaffoldBackgroundColor,
          child: Row(
            children: [
              Expanded(
                child: TabBar(
                  controller: _tabController,
                  labelColor: ColorConstants.primaryColor,
                  unselectedLabelColor: ColorConstants.greyColor,
                  indicatorColor: ColorConstants.primaryColor,
                  tabs: _tabs.map((t) => Tab(text: t)).toList(),
                ),
              ),
              IconButton(
                tooltip: 'Actualizar',
                icon: const Icon(Icons.refresh),
                onPressed: () => setState(() => _refreshToken++),
              ),
            ],
          ),
        ),
        Expanded(
          child: _lamanoUserId.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : TabBarView(
                  controller: _tabController,
                  children: _tabKeys.map((key) => _OrdersList(
                    userId: _lamanoUserId,
                    tab: key,
                    motoboyPhone: _motoboyPhone,
                    refreshToken: _refreshToken,
                  )).toList(),
                ),
        ),
      ],
    );
  }
}

class _OrdersList extends StatefulWidget {
  final String userId;
  final String tab;
  final String motoboyPhone;
  final int refreshToken;
  const _OrdersList({
    required this.userId,
    required this.tab,
    required this.motoboyPhone,
    required this.refreshToken,
  });

  @override
  State<_OrdersList> createState() => _OrdersListState();
}

class _OrdersListState extends State<_OrdersList> with AutomaticKeepAliveClientMixin {
  List<Map<String, dynamic>> _orders = [];
  List<Map<String, dynamic>> _optimizedStops = [];
  int _optimizedNextIndex = 0;
  bool _optimizingRoute = false;
  bool _loading = true;
  String? _error;
  Timer? _autoRefreshTimer;
  // Last known motoboy position — updated on each fetch attempt
  Position? _lastPosition;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _fetch();
    if (widget.tab == 'pendientes') {
      _autoRefreshTimer = Timer.periodic(const Duration(seconds: 20), (_) {
        if (mounted) _fetch();
      });
    }
  }

  @override
  void didUpdateWidget(covariant _OrdersList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.refreshToken != widget.refreshToken) {
      _fetch();
    }
  }

  @override
  void dispose() {
    _autoRefreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _fetch() async {
    if (!ConnectivityService.instance.online) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = _orders.isEmpty ? 'Sin conexión a internet' : null;
        });
      }
      return;
    }
    setState(() { _loading = true; _error = null; });
    try {
      // Try to get current GPS position for proximity sort (best-effort, no UI block)
      if (widget.tab == 'pendientes') {
        try {
          final svc = await Geolocator.isLocationServiceEnabled();
          if (svc) {
            var perm = await Geolocator.checkPermission();
            if (perm == LocationPermission.denied) {
              perm = await Geolocator.requestPermission();
            }
            if (perm != LocationPermission.denied && perm != LocationPermission.deniedForever) {
              final pos = await Geolocator.getCurrentPosition(
                locationSettings: const LocationSettings(accuracy: LocationAccuracy.medium),
              ).timeout(const Duration(seconds: 5));
              _lastPosition = pos;
            }
          }
        } catch (_) { /* GPS is best-effort */ }
      }

      // Build URL with optional origin for server-side proximity sort
      final qp = <String, String>{
        'user_id': widget.userId,
        'tab': widget.tab,
      };
      if (_lastPosition != null && widget.tab == 'pendientes') {
        qp['origin_lat'] = _lastPosition!.latitude.toStringAsFixed(6);
        qp['origin_lng'] = _lastPosition!.longitude.toStringAsFixed(6);
      }
      final url = Uri.http('38.247.147.220', '/lamano/api_motoboy_orders.php', qp);
      final resp = await http.get(url).timeout(const Duration(seconds: 20));
      final data = SafeJson.asMap(resp.body);
      if (SafeJson.boolValue(data['success'])) {
        final fetchedOrders = SafeJson.asListOfMap(data['orders']);
        // Server already sorts by distance when origin is provided.
        // Fallback client-side sort by wait time if no GPS was sent.
        if (widget.tab == 'pendientes' && _lastPosition == null) {
          fetchedOrders.sort((a, b) {
            final aTs = (a['created_at'] as num?)?.toInt() ?? 0;
            final bTs = (b['created_at'] as num?)?.toInt() ?? 0;
            return aTs.compareTo(bTs);
          });
        }
        if (!mounted) return;
        setState(() {
          _orders = fetchedOrders;
          _loading = false;
        });
      } else {
        if (!mounted) return;
        setState(() {
          _error = SafeJson.stringValue(data['message'], fallback: 'Error del servidor');
          _loading = false;
        });
      }
    } on TimeoutException {
      if (!mounted) return;
      setState(() { _error = 'El servidor no responde. Reintentando...'; _loading = false; });
    } on SocketException {
      if (!mounted) return;
      setState(() { _error = 'Sin conexión a internet'; _loading = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _error = e.toString(); _loading = false; });
    }
  }

  String _formatDate(int ts) {
    if (ts <= 0) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch(ts * 1000);
    return DateFormat('dd/MM/yyyy HH:mm').format(dt);
  }

  String _formatMoney(dynamic val) {
    final n = (val is num) ? val.toDouble() : double.tryParse(val.toString()) ?? 0;
    return '\$${NumberFormat('#,###', 'es_CL').format(n.round())}';
  }

  int _waitMinutes(Map<String, dynamic> order) {
    final createdAt = (order['created_at'] as num?)?.toInt() ?? 0;
    if (createdAt <= 0) return 0;
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return (nowSec - createdAt) ~/ 60;
  }

  String _waitLabel(int minutes) {
    if (minutes < 60) return '${minutes}m';
    final h = minutes ~/ 60;
    final m = minutes % 60;
    return '${h}h ${m}m';
  }

  List<Map<String, dynamic>> _ordersWithAddressByWait() {
    final list = _orders.where((o) => (o['address']?.toString() ?? '').trim().isNotEmpty).toList();
    list.sort((a, b) {
      final aTs = (a['created_at'] as num?)?.toInt() ?? 0;
      final bTs = (b['created_at'] as num?)?.toInt() ?? 0;
      return aTs.compareTo(bTs);
    });
    return list;
  }

  Future<void> _startWazeRouteByWait(BuildContext context) async {
    final ordered = _ordersWithAddressByWait();
    if (ordered.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No hay direcciones para armar ruta')),
      );
      return;
    }

    final first = ordered.first;
    final firstId = (first['id'] as num?)?.toInt() ?? 0;
    final firstAddress = first['address']?.toString() ?? '';
    await _openWazeRoute(context, firstAddress);

    if (!context.mounted) return;
    final nextIds = ordered.skip(1).take(3).map((o) => '#${o['id']}').join(', ');
    final suffix = nextIds.isEmpty ? '' : ' · Luego: $nextIds';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Ruta por espera iniciada en orden #$firstId$suffix')),
    );
  }

  Future<Position?> _getCurrentPositionSafe(BuildContext context) async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Activa la ubicacion para optimizar la ruta')),
        );
      }
      return null;
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Permiso de ubicacion denegado, uso ruta por defecto')),
        );
      }
      return null;
    }

    try {
      return await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _startOptimizedGoogleRoute(BuildContext context) async {
    if (_optimizingRoute) return;
    setState(() => _optimizingRoute = true);

    try {
      final pos = await _getCurrentPositionSafe(context);
      final qp = <String, String>{'user_id': widget.userId, 'max': '20'};
      if (pos != null) {
        qp['origin_lat'] = pos.latitude.toStringAsFixed(6);
        qp['origin_lng'] = pos.longitude.toStringAsFixed(6);
      }

      final uri = Uri.http('38.247.147.220', '/lamano/api_motoboy_optimize_route.php', qp);
      final resp = await http.get(uri).timeout(const Duration(seconds: 30));
      final data = jsonDecode(resp.body);

      if (resp.statusCode < 200 || resp.statusCode >= 300 ||
          data is! Map<String, dynamic> || data['success'] != true) {
        throw Exception('No se pudo optimizar la ruta');
      }

      final stops = List<Map<String, dynamic>>.from(data['stops'] ?? []);
      if (stops.isEmpty) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No hay paradas disponibles para ruta')),
          );
        }
        return;
      }

      if (!mounted) return;
      setState(() {
        _optimizedStops = stops;
        _optimizedNextIndex = 0;
      });

      // Mostrar el modal de ruta con Waze + Google Maps para cada parada
      if (context.mounted) _showRouteModal(context);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error al optimizar: $e')),
        );
      }
      await _startWazeRouteByWait(context);
    } finally {
      if (mounted) setState(() => _optimizingRoute = false);
    }
  }

  /// Modal de ruta con progreso y botones Waze / Google Maps para cada parada.
  void _showRouteModal(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _RouteProgressSheet(
        stops: _optimizedStops,
        onOpenWaze: (stop) async {
          final address = stop['address']?.toString() ?? '';
          final lat = stop['lat'] as double?;
          final lng = stop['lng'] as double?;
          if (lat != null && lng != null) {
            final url = Uri.parse('https://waze.com/ul?ll=$lat,$lng&navigate=yes');
            await launchUrl(url, mode: LaunchMode.externalApplication);
          } else if (address.isNotEmpty) {
            await _openWazeRoute(context, address);
          }
        },
        onOpenGoogleMaps: (stop) async {
          final lat = stop['lat'] as double?;
          final lng = stop['lng'] as double?;
          final address = stop['address']?.toString() ?? '';
          final Uri url;
          if (lat != null && lng != null) {
            url = Uri.parse('https://www.google.com/maps/dir/?api=1&destination=$lat,$lng&travelmode=driving');
          } else {
            url = Uri.parse('https://www.google.com/maps/dir/?api=1&destination=${Uri.encodeComponent(address)}&travelmode=driving');
          }
          await launchUrl(url, mode: LaunchMode.externalApplication);
        },
      ),
    );
  }

  /// Abre Google Maps con TODAS las órdenes pendientes como paradas en orden
  /// óptimo. Google Maps soporta hasta 10 waypoints en la URL.
  Future<void> _openFullRouteGoogleMaps(BuildContext context) async {
    if (_optimizingRoute) return;
    setState(() => _optimizingRoute = true);

    try {
      // 1. Obtener posición actual (best-effort)
      Position? pos;
      try {
        final svc = await Geolocator.isLocationServiceEnabled();
        if (svc) {
          var perm = await Geolocator.checkPermission();
          if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
          if (perm != LocationPermission.denied && perm != LocationPermission.deniedForever) {
            pos = await Geolocator.getCurrentPosition(
              locationSettings: const LocationSettings(accuracy: LocationAccuracy.medium),
            ).timeout(const Duration(seconds: 5));
          }
        }
      } catch (_) {}

      // 2. Llamar al API de optimización
      final qp = <String, String>{'user_id': widget.userId, 'max': '9'};
      if (pos != null) {
        qp['origin_lat'] = pos.latitude.toStringAsFixed(6);
        qp['origin_lng'] = pos.longitude.toStringAsFixed(6);
      }
      final uri = Uri.http('38.247.147.220', '/lamano/api_motoboy_optimize_route.php', qp);
      final resp = await http.get(uri).timeout(const Duration(seconds: 30));
      final data = jsonDecode(resp.body) as Map<String, dynamic>;

      if (data['success'] != true) throw Exception('API error');

      final stops = List<Map<String, dynamic>>.from(data['stops'] ?? []);
      if (stops.isEmpty) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No hay direcciones para armar la ruta')),
          );
        }
        return;
      }

      // 3. Construir URL Google Maps multi-parada
      // Formato: /maps/dir/?api=1&origin=lat,lng&destination=lat,lng&waypoints=lat,lng|lat,lng&travelmode=driving
      // Google Maps acepta hasta 9 waypoints (10 paradas total incluyendo origin y destination)
      final coords = stops.map((s) {
        final lat = s['lat'] as double?;
        final lng = s['lng'] as double?;
        if (lat != null && lng != null) return '$lat,$lng';
        // Fallback: usar dirección codificada si no hay coords
        return Uri.encodeComponent(s['address']?.toString() ?? '');
      }).toList();

      String originStr;
      if (pos != null) {
        originStr = '${pos.latitude.toStringAsFixed(6)},${pos.longitude.toStringAsFixed(6)}';
      } else {
        originStr = coords.first;
        coords.removeAt(0);
      }

      final destination = coords.isNotEmpty ? coords.last : originStr;
      final waypoints = coords.length > 1
          ? coords.sublist(0, coords.length - 1).join('|')
          : null;

      final gmParams = <String, String>{
        'api': '1',
        'origin': originStr,
        'destination': destination,
        'travelmode': 'driving',
      };
      if (waypoints != null && waypoints.isNotEmpty) {
        gmParams['waypoints'] = waypoints;
      }

      final gmUrl = Uri.https('www.google.com', '/maps/dir/', gmParams);
      final opened = await launchUrl(gmUrl, mode: LaunchMode.externalApplication);

      if (!opened && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No se pudo abrir Google Maps')),
        );
      } else if (context.mounted) {
        // Guardar stops para navegar uno a uno si el user prefiere Waze
        if (mounted) setState(() { _optimizedStops = stops; _optimizedNextIndex = 0; });
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error al armar la ruta: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _optimizingRoute = false);
    }
  }

  Future<void> _openNextOptimizedStop(BuildContext context) async {
    if (_optimizedStops.isEmpty || _optimizedNextIndex >= _optimizedStops.length) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Ruta completada, no quedan paradas pendientes')),
        );
      }
      return;
    }

    final next = _optimizedStops[_optimizedNextIndex];
    final nextAddress = (next['address']?.toString() ?? '').trim();
    if (nextAddress.isEmpty) {
      if (mounted) {
        setState(() {
          _optimizedNextIndex += 1;
        });
      }
      return;
    }

    await _openWazeRoute(context, nextAddress);
    if (!mounted) return;

    final orderId = (next['order_id'] as num?)?.toInt() ?? (next['id'] as num?)?.toInt() ?? 0;
    setState(() {
      _optimizedNextIndex += 1;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Navegando a orden #$orderId (${_optimizedNextIndex}/${_optimizedStops.length})')),
    );
  }

  /// Abre el chat con quien asignó la orden.
  Future<void> _openOrderChat(BuildContext context, Map<String, dynamic> order) async {
    final orderId = (order['id'] as num?)?.toInt() ?? 0;
    final assignedById = (order['assigned_by_id'] as num?)?.toInt()
        ?? (order['created_by_id'] as num?)?.toInt()
        ?? 0;
    final assignedByName = (order['created_by_name'] ?? order['assigned_by_name'])?.toString().trim() ?? '';
    final displayName = assignedByName.isNotEmpty ? assignedByName : 'Operador';
    final myFirebaseUid = (await SharedPreferences.getInstance()).getString(FirestoreConstants.id) ?? '';
    if (assignedById <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No se encontró el asignador de esta orden')),
      );
      return;
    }

    // Get Firebase UID of the person who assigned the order
    try {
      final resp = await http.get(
        Uri.parse('http://38.247.147.220/lamano/api_firebase_uid.php?user_id=$assignedById'),
      ).timeout(const Duration(seconds: 10));

      if (resp.statusCode == 200) {
        final data = SafeJson.asMap(resp.body);
        final peerUid = SafeJson.stringValue(data['uid']);
        if (peerUid.isNotEmpty && orderId > 0 && context.mounted) {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => ChatPage(
                arguments: ChatPageArguments(
                  peerId: peerUid,
                  peerAvatar: '',
                  peerNickname: '$displayName · Orden #$orderId',
                  customGroupChatId: 'order-$orderId',
                  peerLamanoId: assignedById.toString(),
                ),
              ),
            ),
          );
          return;
        }
      }
    } catch (_) {}

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No se pudo conectar con el asignador')),
      );
    }
  }

  

  /// Llama al cliente mediante Twilio Proxy (número enmascarado).
  /// Twilio llama primero al motoboy, y cuando contesta lo conecta con el cliente.
  Future<void> _twilioCall(BuildContext context, String clientPhone, int orderId) async {
    String motoboyPhone = widget.motoboyPhone;

    // Si no tiene teléfono, pedir que lo ingrese él mismo
    if (motoboyPhone.isEmpty) {
      final controller = TextEditingController();
      final entered = await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (_) => AlertDialog(
          title: const Text('Tu número celular'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Twilio te llamará a ti primero y luego te conecta con el cliente.\n\n⚠️ El cliente solo verá el número de Twilio, nunca el tuyo.\n\nEsto se guarda y no se vuelve a pedir.'),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(
                  hintText: '+56912345678',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.phone),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, null), child: const Text('Cancelar')),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: const Text('Guardar'),
            ),
          ],
        ),
      );

      if (entered == null || entered.isEmpty) return;

      // Guardar localmente
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(FirestoreConstants.motoboyPhone, entered);
      motoboyPhone = entered;

      // Guardar en servidor también
      final userId = prefs.getString(FirestoreConstants.lamanoUserId) ?? '';
      if (userId.isNotEmpty) {
        http.post(
          Uri.parse('http://38.247.147.220/lamano/api_save_phone.php'),
          headers: {'Content-Type': 'application/json'},
          body: json.encode({'user_id': userId, 'phone': entered}),
        ).ignore();
      }
    }

    // Mostrar loading
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(
          children: [
            CircularProgressIndicator(),
            SizedBox(width: 16),
            Text('Iniciando llamada...'),
          ],
        ),
      ),
    );

    try {
      final resp = await http.post(
        Uri.parse('http://38.247.147.220/lamano/twilio_proxy_call.php'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'motoboy_phone': motoboyPhone,
          'client_phone': clientPhone,
          'order_id': orderId,
        }),
      ).timeout(const Duration(seconds: 20));

      if (context.mounted) Navigator.of(context, rootNavigator: true).pop();

      final data = SafeJson.asMap(resp.body);
      if (context.mounted) {
        if (SafeJson.boolValue(data['success'])) {
          // Mostrar diálogo prominente explicando que deben contestar
          showDialog(
            context: context,
            builder: (_) => AlertDialog(
              backgroundColor: const Color(0xFF1B5E20),
              title: const Row(
                children: [
                  Icon(Icons.phone_in_talk, color: Colors.white, size: 28),
                  SizedBox(width: 10),
                  Text('¡Tu teléfono va a sonar!', style: TextStyle(color: Colors.white, fontSize: 17)),
                ],
              ),
              content: const Text(
                'Twilio te está llamando ahora.\n\nCONTESTA la llamada entrante en tu teléfono — cuando lo hagas quedarás conectado con el cliente.\n\nEl cliente NO verá tu número real.',
                style: TextStyle(color: Colors.white, fontSize: 15, height: 1.5),
              ),
              actions: [
                ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.white, foregroundColor: Colors.green[900]),
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Entendido'),
                ),
              ],
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(data['message']?.toString() ?? 'Error al iniciar la llamada'),
              backgroundColor: Colors.red,
              duration: const Duration(seconds: 6),
            ),
          );
        }
      }
    } catch (e) {
      if (context.mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Color _stateColor(int state) {
    switch (state) {
      case 1: return Colors.orange;
      case 4: return Colors.blue;
      case 5: return Colors.indigo;
      case 6: return Colors.teal;
      case 3: return Colors.green;
      default: return Colors.grey;
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return Center(child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Error: $_error', textAlign: TextAlign.center),
        const SizedBox(height: 12),
        ElevatedButton(onPressed: _fetch, child: const Text('Reintentar')),
      ],
    ));
    if (_orders.isEmpty) return const Center(child: Text('Sin órdenes en esta sección'));

    final showRoutePlanner = widget.tab == 'pendientes' && _orders.length > 1;
    final listCount = _orders.length + (showRoutePlanner ? 1 : 0);

    return RefreshIndicator(
      onRefresh: _fetch,
      child: ListView.builder(
        padding: const EdgeInsets.all(10),
        itemCount: listCount,
        itemBuilder: (ctx, i) {
          if (showRoutePlanner && i == 0) {
            final ordered = _ordersWithAddressByWait();
            final first = ordered.isNotEmpty ? ordered.first : _orders.first;
            final firstId = (first['id'] as num?)?.toInt() ?? 0;
            final wait = _waitLabel(_waitMinutes(first));

            final hasNextOptimizedStop = _optimizedStops.isNotEmpty && _optimizedNextIndex < _optimizedStops.length;
            final nextStop = hasNextOptimizedStop ? _optimizedStops[_optimizedNextIndex] : null;
            final nextStopId = (nextStop?['order_id'] as num?)?.toInt() ?? (nextStop?['id'] as num?)?.toInt() ?? 0;

            return Card(
              margin: const EdgeInsets.only(bottom: 10),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              elevation: 2,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Ruta automática por tiempo de espera',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Primera parada sugerida: Orden #$firstId · espera $wait',
                      style: const TextStyle(fontSize: 12, color: Colors.black54),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.route, size: 16),
                        label: Text(_optimizingRoute ? 'Optimizando ruta...' : 'Optimizar ruta Google + abrir Waze'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.orange,
                          side: const BorderSide(color: Colors.orange),
                          padding: const EdgeInsets.symmetric(vertical: 8),
                        ),
                        onPressed: _optimizingRoute ? null : () => _startOptimizedGoogleRoute(context),
                      ),
                    ),
                    const SizedBox(height: 6),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        icon: const Icon(Icons.map, size: 16),
                        label: Text(_optimizingRoute
                            ? 'Calculando...'
                            : '🗺️ Ruta completa en Google Maps (${_orders.length} paradas)'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF1A73E8),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 10),
                        ),
                        onPressed: _optimizingRoute ? null : () => _openFullRouteGoogleMaps(context),
                      ),
                    ),
                    if (hasNextOptimizedStop) ...[
                      const SizedBox(height: 6),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.alt_route, size: 16),
                          label: Text('Siguiente parada Waze #$nextStopId'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: const Color(0xFF0ea5e9),
                            side: const BorderSide(color: Color(0xFF0ea5e9)),
                            padding: const EdgeInsets.symmetric(vertical: 8),
                          ),
                          onPressed: () => _openNextOptimizedStop(context),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            );
          }

          final idx = showRoutePlanner ? i - 1 : i;
          final o = _orders[idx];
          final state = (o['state'] as num).toInt();
          final address = o['address']?.toString() ?? '';
          final clientName = o['client_name']?.toString() ?? '';
          final phone = o['client_phone']?.toString() ?? '';
          final createdAt = (o['created_at'] as num?)?.toInt() ?? 0;

          return Card(
            margin: const EdgeInsets.only(bottom: 10),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            elevation: 2,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: _stateColor(state).withOpacity(0.15),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: _stateColor(state)),
                        ),
                        child: Text(
                          o['state_label']?.toString() ?? '',
                          style: TextStyle(color: _stateColor(state), fontWeight: FontWeight.bold, fontSize: 12),
                        ),
                      ),
                      const Spacer(),
                      Text(
                        'Orden #${o['id']}',
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  _infoRow(Icons.person, clientName),
                  if (phone.isNotEmpty)
                    _infoRow(Icons.phone, phone),
                  if (address.isNotEmpty)
                    _infoRow(Icons.location_on, address),
                  const SizedBox(height: 6),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Total: ${_formatMoney(o['grand_total'] ?? o['total'])}',
                          style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF203152))),
                      Text(_formatDate(createdAt), style: const TextStyle(fontSize: 11, color: Colors.grey)),
                    ],
                  ),
                  if (address.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        _mapBtn(Icons.map, 'Maps', Colors.blue, () {
                          final q = Uri.encodeComponent(address);
                          launchUrl(Uri.parse('https://www.google.com/maps/search/?api=1&query=$q'),
                              mode: LaunchMode.externalApplication);
                        }),
                        const SizedBox(width: 8),
                        _mapBtn(Icons.navigation, 'Waze', Colors.orange, () {
                          final q = Uri.encodeComponent(address);
                          launchUrl(Uri.parse('https://waze.com/ul?q=$q'),
                              mode: LaunchMode.externalApplication);
                        }),
                        if (phone.isNotEmpty) ...[
                          const SizedBox(width: 8),
                          _mapBtn(Icons.call, 'Llamar', Colors.green, () {
                            final orderId = (o['id'] as num?)?.toInt() ?? 0;
                            _twilioCall(context, phone, orderId);
                          }),
                              const SizedBox(width: 8),
                              _mapBtn(Icons.chat, 'WhatsApp', const Color(0xFF25D366), () {
                                final orderId = (o['id'] as num?)?.toInt() ?? 0;
                                _openWhatsApp(context, phone, orderId);
                              }),
                        ]
                      ],
                    ),
                  ],
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.visibility_outlined, size: 16),
                          label: const Text('Ver Orden'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: const Color(0xFF203152),
                            side: const BorderSide(color: Color(0xFF203152)),
                            padding: const EdgeInsets.symmetric(vertical: 8),
                          ),
                          onPressed: () => _showOrderDetail(context, o),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.inventory_2_outlined, size: 16),
                          label: const Text('Ver Productos'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.deepPurple,
                            side: const BorderSide(color: Colors.deepPurple),
                            padding: const EdgeInsets.symmetric(vertical: 8),
                          ),
                          onPressed: () => _showProductsDetail(context, o),
                        ),
                      ),
                    ],
                  ),
                  if (widget.tab == 'pendientes') ...[
                    const SizedBox(height: 6),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.chat_bubble_outline, size: 16),
                        label: Text('Chat temporal Orden #${o['id']}'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.teal,
                          side: const BorderSide(color: Colors.teal),
                          padding: const EdgeInsets.symmetric(vertical: 8),
                        ),
                        onPressed: () => _openOrderChat(context, o),
                      ),
                    ),
                    if (address.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.navigation, size: 16),
                          label: const Text('Seguir ruta Waze'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.orange,
                            side: const BorderSide(color: Colors.orange),
                            padding: const EdgeInsets.symmetric(vertical: 8),
                          ),
                          onPressed: () => _openWazeRoute(context, address),
                        ),
                      ),
                    ],
                    const SizedBox(height: 6),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        icon: const Icon(Icons.check_circle_outline, size: 16),
                        label: Text('Terminar Orden #${o['id']}'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF16a34a),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                        onPressed: () => _showTerminarModal(context, o),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _infoRow(IconData icon, String text) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Row(
      children: [
        Icon(icon, size: 14, color: ColorConstants.greyColor),
        const SizedBox(width: 6),
        Expanded(child: Text(text, style: const TextStyle(fontSize: 13), maxLines: 2, overflow: TextOverflow.ellipsis)),
      ],
    ),
  );

  Widget _mapBtn(IconData icon, String label, Color color, VoidCallback onTap) => GestureDetector(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withOpacity(0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600)),
        ],
      ),
    ),
  );

  Future<void> _openWhatsApp(BuildContext context, String phone, int orderId) async {
    final digits = phone.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.isEmpty) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Telefono invalido para WhatsApp')),
      );
      return;
    }

    final msg = Uri.encodeComponent('Hola, te contacto por tu orden #$orderId en La Mano.');
    final waUrl = Uri.parse('https://wa.me/$digits?text=$msg');
    final opened = await launchUrl(waUrl, mode: LaunchMode.externalApplication);
    if (!opened && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No se pudo abrir WhatsApp')),
      );
    }
  }

  Future<void> _openWazeRoute(BuildContext context, String address) async {
    final trimmed = address.trim();
    if (trimmed.isEmpty) return;

    final q = Uri.encodeComponent(trimmed);
    final wazeUrl = Uri.parse('https://waze.com/ul?q=$q&navigate=yes');
    final opened = await launchUrl(wazeUrl, mode: LaunchMode.externalApplication);
    if (!opened && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No se pudo abrir Waze')),
      );
    }
  }

  void _showOrderDetail(BuildContext context, Map<String, dynamic> o) {
    final address = o['address']?.toString() ?? '';
    final phone = o['client_phone']?.toString() ?? '';
    final state = (o['state'] as num).toInt();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.65,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        expand: false,
        builder: (_, sc) => ListView(
          controller: sc,
          padding: const EdgeInsets.all(20),
          children: [
            Center(child: Container(width: 40, height: 4, margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2)))),
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: _stateColor(state).withOpacity(0.15),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: _stateColor(state)),
                  ),
                  child: Text(o['state_label']?.toString() ?? '',
                      style: TextStyle(color: _stateColor(state), fontWeight: FontWeight.bold)),
                ),
                const Spacer(),
                Text('Orden #${o['id']}',
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Color(0xFF203152))),
              ],
            ),
            const Divider(height: 24),
            _detailRow(Icons.person, 'Cliente', o['client_name']?.toString() ?? '-'),
            if (phone.isNotEmpty) _detailRow(Icons.phone, 'Teléfono', phone),
            if (address.isNotEmpty) _detailRow(Icons.location_on, 'Dirección', address),
            _detailRow(Icons.shopping_cart_outlined, 'Subtotal', _formatMoney(o['total'])),
            _detailRow(Icons.delivery_dining, 'Delivery', _formatMoney(o['delivery_price'])),
            if ((o['extra_charge'] as num? ?? 0) > 0)
              _detailRow(Icons.add_circle_outline, 'Cobro extra', _formatMoney(o['extra_charge'])),
            _detailRow(Icons.attach_money, 'Total', _formatMoney(o['grand_total'] ?? o['total'])),
            _detailRow(Icons.access_time, 'Fecha', _formatDate((o['created_at'] as num?)?.toInt() ?? 0)),
            const SizedBox(height: 20),
            if (address.isNotEmpty) ...[
              Row(children: [
                Expanded(child: ElevatedButton.icon(
                  icon: const Icon(Icons.map, size: 16),
                  label: const Text('Google Maps'),
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.blue, foregroundColor: Colors.white),
                  onPressed: () {
                    final q = Uri.encodeComponent(address);
                    launchUrl(Uri.parse('https://www.google.com/maps/search/?api=1&query=$q'),
                        mode: LaunchMode.externalApplication);
                  },
                )),
                const SizedBox(width: 8),
                Expanded(child: ElevatedButton.icon(
                  icon: const Icon(Icons.navigation, size: 16),
                  label: const Text('Waze'),
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.orange, foregroundColor: Colors.white),
                  onPressed: () {
                    final q = Uri.encodeComponent(address);
                    launchUrl(Uri.parse('https://waze.com/ul?q=$q'), mode: LaunchMode.externalApplication);
                  },
                )),
              ]),
              const SizedBox(height: 8),
            ],
            if (phone.isNotEmpty)
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.call, size: 16),
                      label: const Text('Llamar al cliente'),
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.green, foregroundColor: Colors.white),
                      onPressed: () {
                        final orderId = (o['id'] as num?)?.toInt() ?? 0;
                        _twilioCall(context, phone, orderId);
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.chat, size: 16),
                      label: const Text('Cliente WhatsApp'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF25D366),
                        foregroundColor: Colors.white,
                      ),
                      onPressed: () {
                        final orderId = (o['id'] as num?)?.toInt() ?? 0;
                        _openWhatsApp(context, phone, orderId);
                      },
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  void _showProductsDetail(BuildContext context, Map<String, dynamic> o) {
    final products = List<Map<String, dynamic>>.from(o['products'] ?? []);
    final subtotal = (o['total'] as num).toDouble();
    final delivery = (o['delivery_price'] as num? ?? 0).toDouble();
    final extra = (o['extra_charge'] as num? ?? 0).toDouble();
    final grand = (o['grand_total'] as num? ?? subtotal + delivery + extra).toDouble();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.9,
        builder: (_, sc) => ListView(
          controller: sc,
          padding: const EdgeInsets.all(20),
          children: [
            Center(child: Container(width: 40, height: 4, margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2)))),
            Text('Productos — Orden #${o['id']}',
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Color(0xFF203152))),
            const Divider(height: 24),
            if (products.isEmpty)
              const Center(child: Text('Sin productos', style: TextStyle(color: Colors.grey)))
            else
              ...products.map((p) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  children: [
                    const Icon(Icons.circle, size: 8, color: Colors.grey),
                    const SizedBox(width: 10),
                    Expanded(child: Text(p['name']?.toString() ?? '',
                        style: const TextStyle(fontSize: 14))),
                    Text('x${p['quantity']}', style: const TextStyle(color: Colors.grey, fontSize: 13)),
                    const SizedBox(width: 12),
                    Text(_formatMoney(p['price']),
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                  ],
                ),
              )),
            const Divider(height: 24),
            _detailRow(Icons.shopping_cart_outlined, 'Subtotal', _formatMoney(subtotal)),
            _detailRow(Icons.delivery_dining, 'Delivery', _formatMoney(delivery)),
            if (extra > 0) _detailRow(Icons.add_circle_outline, 'Cobro extra', _formatMoney(extra)),
            _detailRow(Icons.attach_money, 'Total', _formatMoney(grand)),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget _detailRow(IconData icon, String label, String value) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: ColorConstants.greyColor),
        const SizedBox(width: 8),
        Text('$label: ', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
        Expanded(child: Text(value, style: const TextStyle(fontSize: 13))),
      ],
    ),
  );

  // ─────────────────────────────────────────────────────────────────────────
  // MODAL TERMINAR ORDEN
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _showTerminarModal(BuildContext context, Map<String, dynamic> order) async {
    final orderId    = (order['id'] as num).toInt();
    final paymentMethodId = (order['payment_method'] as num?)?.toInt() ?? 0;
    final isCreditOrder = paymentMethodId == 2 || paymentMethodId == 3;
    final baseTotal = (order['grand_total'] as num? ?? order['total'] as num? ?? 0).toDouble();
    final creditTotal = (order['credit_total_with_interest'] as num?)?.toDouble() ?? 0;
    final orderTotal = isCreditOrder && creditTotal > baseTotal ? creditTotal : baseTotal;

    // Load payment methods
    List<Map<String, dynamic>> paymentMethods = [];
    if (!isCreditOrder) {
      try {
        final resp = await http.get(
          Uri.parse('http://38.247.147.220/lamano/api_payment_methods.php?user_id=${widget.userId}'),
        ).timeout(const Duration(seconds: 10));
        final data = SafeJson.asMap(resp.body);
        if (SafeJson.boolValue(data['success'])) {
          paymentMethods = SafeJson.asListOfMap(data['methods']);
        }
      } catch (_) {}
    }

    if (!context.mounted) return;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => _TerminarOrderSheet(
        orderId: orderId,
        orderTotal: orderTotal,
        isCreditOrder: isCreditOrder,
        userId: widget.userId,
        paymentMethods: paymentMethods,
        onSuccess: () {
          _fetch();
        },
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// BOTTOM SHEET: TERMINAR ORDEN
// ═══════════════════════════════════════════════════════════════════════════

class _PaymentEntry {
  int methodId;
  double amount;
  XFile? voucher;
  final TextEditingController amountCtrl;

  _PaymentEntry({this.methodId = 0, this.amount = 0})
      : amountCtrl = TextEditingController(
          text: amount > 0 ? amount.toStringAsFixed(0) : '',
        );

  void dispose() {
    amountCtrl.dispose();
  }
}

class _PhotoEntry {
  final String label;
  final bool required;
  XFile? file;
  _PhotoEntry({required this.label, required this.required});
}

class _TerminarOrderSheet extends StatefulWidget {
  final int orderId;
  final double orderTotal;
  final bool isCreditOrder;
  final String userId;
  final List<Map<String, dynamic>> paymentMethods;
  final VoidCallback onSuccess;

  const _TerminarOrderSheet({
    required this.orderId,
    required this.orderTotal,
    required this.isCreditOrder,
    required this.userId,
    required this.paymentMethods,
    required this.onSuccess,
  });

  @override
  State<_TerminarOrderSheet> createState() => _TerminarOrderSheetState();
}

class _TerminarOrderSheetState extends State<_TerminarOrderSheet> {
  final _picker = ImagePicker();
  final _patenteCtrl    = TextEditingController();
  final _comentarioCtrl = TextEditingController();

  late List<_PhotoEntry> _photos;
  late List<_PaymentEntry> _payments;
  bool _submitting = false;

  static const _green = Color(0xFF16a34a);
  static const _lightGreen = Color(0xFFf0fdf4);

  @override
  void initState() {
    super.initState();
    _photos = [
      _PhotoEntry(label: 'Foto del cliente', required: true),
      _PhotoEntry(label: 'Foto de la casa',  required: false),
      _PhotoEntry(label: 'Foto del auto',    required: false),
      _PhotoEntry(label: 'Foto de patente',  required: false),
    ];
    _payments = [_PaymentEntry(
      methodId: widget.paymentMethods.isNotEmpty ? (widget.paymentMethods[0]['id'] as num).toInt() : 0,
      amount: widget.orderTotal,
    )];
  }

  @override
  void dispose() {
    for (final p in _payments) {
      p.dispose();
    }
    _patenteCtrl.dispose();
    _comentarioCtrl.dispose();
    super.dispose();
  }

  String _fmt(double v) => '\$${NumberFormat('#,###', 'es_CL').format(v.round())}';

  double get _totalPagado => _payments.fold(0, (s, e) => s + e.amount);
  double get _restante    => widget.orderTotal - _totalPagado;

  bool get _canSubmit {
    if (_photos[0].file == null) return false;
    if (widget.isCreditOrder) return true;
    if (_payments.isEmpty) return false;
    for (final p in _payments) {
      if (p.methodId <= 0 || p.amount <= 0) return false;
    }
    return ((_restante).abs() <= 1);
  }

  Future<void> _pickPhoto(int index, {bool camera = false}) async {
    final file = await _picker.pickImage(
      source: camera ? ImageSource.camera : ImageSource.gallery,
      imageQuality: 80,
      maxWidth: 1920,
    );
    if (file != null) setState(() => _photos[index].file = file);
  }

  void _showPickOptions(int index) {
    showModalBottomSheet(
      context: context,
      builder: (_) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.camera_alt),
            title: const Text('Tomar foto'),
            onTap: () { Navigator.pop(context); _pickPhoto(index, camera: true); },
          ),
          ListTile(
            leading: const Icon(Icons.photo_library),
            title: const Text('Elegir de galería'),
            onTap: () { Navigator.pop(context); _pickPhoto(index); },
          ),
        ]),
      ),
    );
  }

  Future<void> _pickVoucher(int index, {bool camera = false}) async {
    final file = await _picker.pickImage(
      source: camera ? ImageSource.camera : ImageSource.gallery,
      imageQuality: 80,
    );
    if (file != null) setState(() => _payments[index].voucher = file);
  }

  void _showVoucherOptions(int index) {
    showModalBottomSheet(
      context: context,
      builder: (_) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.camera_alt),
            title: const Text('Tomar foto'),
            onTap: () { Navigator.pop(context); _pickVoucher(index, camera: true); },
          ),
          ListTile(
            leading: const Icon(Icons.photo_library),
            title: const Text('Elegir de galería'),
            onTap: () { Navigator.pop(context); _pickVoucher(index); },
          ),
        ]),
      ),
    );
  }

  Future<void> _submit() async {
    if (!_canSubmit) return;
    setState(() => _submitting = true);

    try {
      final uri = Uri.parse('http://38.247.147.220/lamano/api_terminar_orden.php');
      final req  = http.MultipartRequest('POST', uri);

      req.fields['user_id']    = widget.userId;
      req.fields['order_id']   = widget.orderId.toString();
      req.fields['patente']    = _patenteCtrl.text.trim();
      req.fields['comentario'] = _comentarioCtrl.text.trim();

      // Evidence photos
      final photoKeys = ['end_file_client', 'end_file_casa', 'end_file_auto', 'end_file_patente'];
      for (int i = 0; i < _photos.length; i++) {
        final f = _photos[i].file;
        if (f != null) {
          req.files.add(await http.MultipartFile.fromPath(photoKeys[i], f.path));
        }
      }

      // Payment methods
      if (!widget.isCreditOrder) {
        for (int i = 0; i < _payments.length; i++) {
          final p = _payments[i];
          req.fields['payment_methods[$i][method_id]'] = p.methodId.toString();
          req.fields['payment_methods[$i][amount]']    = p.amount.toStringAsFixed(0);
          if (p.voucher != null) {
            req.files.add(await http.MultipartFile.fromPath('payment_methods[$i][file]', p.voucher!.path));
          }
        }
      }

      final streamed = await req.send().timeout(const Duration(seconds: 60));
      final respBody = await streamed.stream.bytesToString();

      if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
        throw Exception('Servidor ${streamed.statusCode}: $respBody');
      }

      final decoded = jsonDecode(respBody);
      if (decoded is! Map<String, dynamic>) {
        throw Exception('Respuesta invalida del servidor');
      }
      final data = decoded;

      if (!mounted) return;

      if (data['success'] == true) {
        Navigator.of(context).pop();
        widget.onSuccess();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Orden #${widget.orderId} marcada como entregada ✓'),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 4),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(data['message']?.toString() ?? 'Error al procesar la orden'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 6),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final progress = widget.orderTotal > 0
        ? (_totalPagado / widget.orderTotal).clamp(0.0, 1.0)
        : 0.0;

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.92,
      maxChildSize: 0.97,
      builder: (_, sc) => Column(
        children: [
          // ── HEADER ──────────────────────────────────────────────────────
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xFF16a34a), Color(0xFF15803d)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
            ),
            padding: const EdgeInsets.fromLTRB(20, 16, 16, 16),
            child: Row(
              children: [
                Container(
                  width: 40, height: 40,
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.check_circle_outline, color: Colors.white, size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Confirmar entrega',
                          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
                      Text('Orden #${widget.orderId}',
                          style: const TextStyle(color: Colors.white70, fontSize: 12)),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white70),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),

          // ── FINANCIAL SUMMARY ────────────────────────────────────────────
          if (!widget.isCreditOrder)
            Container(
              color: _lightGreen,
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Column(
                children: [
                  Row(
                    children: [
                      _summaryCol('Total orden', _fmt(widget.orderTotal), Colors.black87),
                      _summaryCol('Pagado',      _fmt(_totalPagado),      _green),
                      _summaryCol('Restante',    _fmt(_restante.abs()),   _restante > 1 ? Colors.red : _green),
                    ],
                  ),
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: progress,
                      minHeight: 6,
                      backgroundColor: Colors.grey[300],
                      valueColor: const AlwaysStoppedAnimation<Color>(_green),
                    ),
                  ),
                ],
              ),
            )
          else
            Container(
              color: const Color(0xFFeff6ff),
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Row(
                children: [
                  Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      color: const Color(0xFF2563eb).withOpacity(0.12),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.credit_card, size: 16, color: Color(0xFF2563eb)),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Orden a crédito',
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFF1e3a8a)),
                        ),
                        Text(
                          'Solo sube evidencias, patente y comentario.',
                          style: TextStyle(fontSize: 12, color: Colors.blueGrey.shade700),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

          // ── BODY ─────────────────────────────────────────────────────────
          Expanded(
            child: ListView(
              controller: sc,
              padding: const EdgeInsets.all(16),
              children: [

                // SECTION: Evidencias
                _sectionHeader(Icons.camera_alt_outlined, 'Evidencias de entrega', Colors.blue),
                const SizedBox(height: 10),
                ...List.generate(_photos.length, (i) => _photoRow(i)),
                const SizedBox(height: 16),

                // Patente + Comentario
                Row(children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _fieldLabel('Patente'),
                        TextField(
                          controller: _patenteCtrl,
                          decoration: _inputDeco('Ej: ABCD12'),
                          textCapitalization: TextCapitalization.characters,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _fieldLabel('Comentario'),
                        TextField(
                          controller: _comentarioCtrl,
                          decoration: _inputDeco('Detalle adicional...'),
                          maxLines: 3,
                        ),
                      ],
                    ),
                  ),
                ]),
                const SizedBox(height: 20),

                if (!widget.isCreditOrder) ...[
                  const Divider(),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      _sectionHeader(Icons.credit_card_outlined, 'Métodos de pago', const Color(0xFFca8a04)),
                      TextButton.icon(
                        onPressed: () => setState(() => _payments.add(_PaymentEntry(
                          methodId: widget.paymentMethods.isNotEmpty
                              ? (widget.paymentMethods[0]['id'] as num).toInt()
                              : 0,
                          amount: 0,
                        ))),
                        icon: const Icon(Icons.add, size: 16),
                        label: const Text('Agregar', style: TextStyle(fontSize: 13)),
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.blue,
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          side: const BorderSide(color: Colors.blue),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  ...List.generate(_payments.length, (i) => _paymentRow(i)),
                ],
                const SizedBox(height: 80),
              ],
            ),
          ),

          // ── FOOTER ───────────────────────────────────────────────────────
          Container(
            padding: EdgeInsets.fromLTRB(16, 10, 16, MediaQuery.of(context).viewInsets.bottom + 16),
            decoration: const BoxDecoration(
              color: Colors.white,
              boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 8, offset: Offset(0, -2))],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!_canSubmit)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      _photos[0].file == null
                          ? '📸 La foto del cliente es obligatoria'
                          : widget.isCreditOrder
                              ? 'Completa las evidencias para confirmar la entrega'
                              : _restante.abs() > 1
                              ? 'El monto pagado no coincide con el total de la orden'
                              : 'Completa todos los campos de pago',
                      style: const TextStyle(color: Color(0xFF92400e), fontSize: 12),
                      textAlign: TextAlign.center,
                    ),
                  ),
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: ElevatedButton.icon(
                    icon: _submitting
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.check_circle, size: 20),
                    label: Text(_submitting ? 'Enviando...' : 'Confirmar entrega',
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _canSubmit ? _green : Colors.grey,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    onPressed: (_canSubmit && !_submitting) ? _submit : null,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _summaryCol(String label, String value, Color valueColor) => Expanded(
    child: Column(
      children: [
        Text(label,
            style: const TextStyle(fontSize: 10, color: Colors.grey, fontWeight: FontWeight.w600,
                letterSpacing: 0.5)),
        const SizedBox(height: 2),
        Text(value,
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: valueColor)),
      ],
    ),
  );

  Widget _sectionHeader(IconData icon, String title, Color color) => Row(
    children: [
      Container(
        width: 28, height: 28,
        decoration: BoxDecoration(color: color.withOpacity(0.15), borderRadius: BorderRadius.circular(8)),
        child: Icon(icon, size: 16, color: color),
      ),
      const SizedBox(width: 8),
      Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Color(0xFF111827))),
    ],
  );

  Widget _photoRow(int index) {
    final photo = _photos[index];
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(photo.label,
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF374151))),
              if (photo.required)
                const Text(' *', style: TextStyle(color: Colors.red, fontSize: 12)),
              if (!photo.required)
                const Text(' (opcional)', style: TextStyle(color: Colors.grey, fontSize: 11)),
            ],
          ),
          const SizedBox(height: 4),
          GestureDetector(
            onTap: () => _showPickOptions(index),
            child: Container(
              width: double.infinity,
              height: photo.file != null ? 120 : 52,
              decoration: BoxDecoration(
                border: Border.all(
                    color: photo.file != null
                        ? _green
                        : (photo.required && photo.file == null ? Colors.red.shade200 : Colors.grey.shade300),
                    width: 2),
                borderRadius: BorderRadius.circular(10),
                color: photo.file != null ? Colors.transparent : Colors.grey.shade50,
              ),
              clipBehavior: Clip.antiAlias,
              child: photo.file != null
                  ? Stack(fit: StackFit.expand, children: [
                      Image.file(File(photo.file!.path), fit: BoxFit.cover),
                      Positioned(
                        top: 4, right: 4,
                        child: GestureDetector(
                          onTap: () => setState(() => _photos[index].file = null),
                          child: Container(
                            padding: const EdgeInsets.all(2),
                            decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(12)),
                            child: const Icon(Icons.close, color: Colors.white, size: 14),
                          ),
                        ),
                      ),
                    ])
                  : Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.upload_rounded, color: Colors.grey.shade400, size: 18),
                        const SizedBox(width: 6),
                        Text('Subir foto', style: TextStyle(color: Colors.grey.shade500, fontSize: 13)),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _paymentRow(int index) {
    final p = _payments[index];
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      elevation: 1,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('Método de pago #${index + 1}',
                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                const Spacer(),
                if (_payments.length > 1)
                  GestureDetector(
                    onTap: () => setState(() {
                      final removed = _payments.removeAt(index);
                      removed.dispose();
                    }),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.red.shade50,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: Colors.red.shade200),
                      ),
                      child: Text('Eliminar', style: TextStyle(color: Colors.red.shade700, fontSize: 11)),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Row(children: [
              // Method selector
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _fieldLabel('Método *'),
                    DropdownButtonFormField<int>(
                      value: widget.paymentMethods.any((m) => (m['id'] as num).toInt() == p.methodId) ? p.methodId : null,
                      decoration: _inputDeco('Selecciona'),
                      items: widget.paymentMethods.map((m) => DropdownMenuItem<int>(
                        value: (m['id'] as num).toInt(),
                        child: Text(m['name']?.toString() ?? '', style: const TextStyle(fontSize: 13)),
                      )).toList(),
                      onChanged: (v) => setState(() => _payments[index].methodId = v ?? 0),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              // Amount
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _fieldLabel('Monto *'),
                    TextField(
                      keyboardType: const TextInputType.numberWithOptions(decimal: false),
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: _inputDeco('0').copyWith(prefixText: '\$'),
                      controller: p.amountCtrl,
                      onChanged: (v) => setState(() => _payments[index].amount = double.tryParse(v) ?? 0),
                    ),
                  ],
                ),
              ),
            ]),
            const SizedBox(height: 10),
            // Voucher photo
            _fieldLabel('Comprobante (opcional)'),
            const SizedBox(height: 4),
            GestureDetector(
              onTap: () => _showVoucherOptions(index),
              child: Container(
                width: double.infinity,
                height: p.voucher != null ? 100 : 48,
                decoration: BoxDecoration(
                  border: Border.all(
                      color: p.voucher != null ? _green : Colors.grey.shade300, width: 2),
                  borderRadius: BorderRadius.circular(10),
                  color: Colors.grey.shade50,
                ),
                clipBehavior: Clip.antiAlias,
                child: p.voucher != null
                    ? Stack(fit: StackFit.expand, children: [
                        Image.file(File(p.voucher!.path), fit: BoxFit.cover),
                        Positioned(
                          top: 4, right: 4,
                          child: GestureDetector(
                            onTap: () => setState(() => _payments[index].voucher = null),
                            child: Container(
                              padding: const EdgeInsets.all(2),
                              decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(12)),
                              child: const Icon(Icons.close, color: Colors.white, size: 14),
                            ),
                          ),
                        ),
                      ])
                    : Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.upload_rounded, color: Colors.grey.shade400, size: 16),
                          const SizedBox(width: 6),
                          Text('Subir comprobante',
                              style: TextStyle(color: Colors.grey.shade500, fontSize: 12)),
                        ],
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _fieldLabel(String label) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Text(label,
        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Color(0xFF374151))),
  );

  InputDecoration _inputDeco(String hint) => InputDecoration(
    hintText: hint,
    hintStyle: const TextStyle(fontSize: 13, color: Colors.grey),
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(9),
        borderSide: const BorderSide(color: Color(0xFFd1d5db))),
    enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(9),
        borderSide: const BorderSide(color: Color(0xFFd1d5db))),
    focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(9),
        borderSide: const BorderSide(color: Color(0xFF16a34a))),
    isDense: true,
  );
}

// ─── Route progress bottom sheet ─────────────────────────────────────────────

class _RouteProgressSheet extends StatefulWidget {
  const _RouteProgressSheet({
    required this.stops,
    required this.onOpenWaze,
    required this.onOpenGoogleMaps,
  });

  final List<Map<String, dynamic>> stops;
  final Future<void> Function(Map<String, dynamic> stop) onOpenWaze;
  final Future<void> Function(Map<String, dynamic> stop) onOpenGoogleMaps;

  @override
  State<_RouteProgressSheet> createState() => _RouteProgressSheetState();
}

class _RouteProgressSheetState extends State<_RouteProgressSheet> {
  int _current = 0;

  @override
  Widget build(BuildContext context) {
    final total = widget.stops.length;
    final done = _current;
    final remaining = total - done;
    final stop = done < total ? widget.stops[done] : null;
    final orderId = stop != null
        ? ((stop['order_id'] as num?)?.toInt() ?? (stop['id'] as num?)?.toInt() ?? 0)
        : 0;
    final address = stop?['address']?.toString() ?? '';
    final clientName = stop?['client_name']?.toString() ?? '';

    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Handle bar
          Container(
            width: 40, height: 4,
            margin: const EdgeInsets.only(bottom: 16),
            decoration: BoxDecoration(
              color: Colors.grey.shade300,
              borderRadius: BorderRadius.circular(2),
            ),
          ),

          // Header
          Row(
            children: [
              const Icon(Icons.route, color: Color(0xFF16a34a), size: 22),
              const SizedBox(width: 8),
              Text(
                'Ruta óptima · $remaining paradas restantes',
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Progress bar
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: total > 0 ? done / total : 0,
              minHeight: 8,
              backgroundColor: Colors.grey.shade200,
              valueColor: const AlwaysStoppedAnimation(Color(0xFF16a34a)),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('$done entregadas', style: const TextStyle(fontSize: 11, color: Colors.grey)),
                Text('$total total', style: const TextStyle(fontSize: 11, color: Colors.grey)),
              ],
            ),
          ),
          const SizedBox(height: 8),

          if (stop == null) ...[
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Column(
                children: [
                  Icon(Icons.check_circle, color: Color(0xFF16a34a), size: 48),
                  SizedBox(height: 8),
                  Text('¡Todas las entregas completadas!',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                ],
              ),
            ),
          ] else ...[
            // Current stop card
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFFf0fdf4),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFF86efac)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: const Color(0xFF16a34a),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text('Parada ${done + 1} de $total',
                          style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
                    ),
                    const SizedBox(width: 8),
                    Text('Orden #$orderId', style: const TextStyle(fontWeight: FontWeight.bold)),
                  ]),
                  if (clientName.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Row(children: [
                      const Icon(Icons.person, size: 14, color: Colors.grey),
                      const SizedBox(width: 4),
                      Text(clientName, style: const TextStyle(fontSize: 13)),
                    ]),
                  ],
                  const SizedBox(height: 6),
                  Row(children: [
                    const Icon(Icons.location_on, size: 14, color: Colors.grey),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(address,
                          style: const TextStyle(fontSize: 13),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis),
                    ),
                  ]),
                ],
              ),
            ),
            const SizedBox(height: 14),

            // Navigation buttons
            Row(children: [
              Expanded(
                child: ElevatedButton.icon(
                  icon: Image.network(
                    'https://www.waze.com/favicon.ico',
                    width: 18, height: 18,
                    errorBuilder: (_, __, ___) => const Icon(Icons.navigation, size: 18),
                  ),
                  label: const Text('Waze', style: TextStyle(fontWeight: FontWeight.bold)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF09D3D3),
                    foregroundColor: Colors.black87,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  onPressed: () => widget.onOpenWaze(stop),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.map, size: 18),
                  label: const Text('Google Maps', style: TextStyle(fontWeight: FontWeight.bold)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF1A73E8),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  onPressed: () => widget.onOpenGoogleMaps(stop),
                ),
              ),
            ]),
            const SizedBox(height: 10),

            // Mark delivered → next stop
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.check, size: 18, color: Color(0xFF16a34a)),
                label: Text(
                  done + 1 < total
                      ? '✅ Entregado · ir a parada ${done + 2}'
                      : '✅ Última entrega completada',
                  style: const TextStyle(color: Color(0xFF16a34a), fontWeight: FontWeight.bold),
                ),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Color(0xFF16a34a)),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                onPressed: () => setState(() => _current++),
              ),
            ),
          ],

          // Remaining stops list
          if (total > 1 && done < total) ...[
            const SizedBox(height: 16),
            const Align(
              alignment: Alignment.centerLeft,
              child: Text('Próximas paradas:', style: TextStyle(fontSize: 12, color: Colors.grey)),
            ),
            const SizedBox(height: 6),
            ...widget.stops.skip(done + 1).take(4).toList().asMap().entries.map((e) {
              final idx = done + 1 + e.key;
              final s = e.value;
              final sId = (s['order_id'] as num?)?.toInt() ?? (s['id'] as num?)?.toInt() ?? 0;
              return Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(children: [
                  Container(
                    width: 20, height: 20,
                    decoration: BoxDecoration(
                      color: Colors.grey.shade200,
                      shape: BoxShape.circle,
                    ),
                    child: Center(
                      child: Text('${idx + 1}',
                          style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '#$sId · ${s['address']?.toString() ?? ''}',
                      style: const TextStyle(fontSize: 12, color: Colors.black54),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ]),
              );
            }),
          ],
        ],
      ),
    );
  }
}
