import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

/// Singleton que expone el estado de conexión a internet en tiempo real.
///
/// Uso:
///   ConnectivityService.instance.online   // bool actual
///   ConnectivityService.instance.stream   // Stream<bool> para escuchar cambios
///
/// `online == false` significa "ninguna interfaz reporta conexión" (sin wifi
/// ni datos móviles). No garantiza que el servidor esté vivo, pero sirve para
/// avisar al motoboy que no confíe en la pantalla.
class ConnectivityService {
  ConnectivityService._() {
    _init();
  }
  static final ConnectivityService instance = ConnectivityService._();

  final _controller = StreamController<bool>.broadcast();
  bool _online = true;
  StreamSubscription<List<ConnectivityResult>>? _sub;

  bool get online => _online;
  Stream<bool> get stream => _controller.stream;

  Future<void> _init() async {
    try {
      final initial = await Connectivity().checkConnectivity();
      _update(initial);
    } catch (_) {
      // Si falla la primera lectura asumimos online para no bloquear la app.
      _online = true;
    }
    _sub = Connectivity().onConnectivityChanged.listen(_update);
  }

  void _update(List<ConnectivityResult> results) {
    final isOnline = results.any((r) => r != ConnectivityResult.none);
    if (isOnline != _online) {
      _online = isOnline;
      if (kDebugMode) {
        debugPrint('[Connectivity] online=$_online ($results)');
      }
      _controller.add(_online);
    }
  }

  void dispose() {
    _sub?.cancel();
    _controller.close();
  }
}
