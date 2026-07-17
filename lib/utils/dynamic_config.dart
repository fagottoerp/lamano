import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Sistema de configuración dinámica - independiente de cambios de IP
/// 
/// FUNCIONAMIENTO:
/// 1. La app intenta cargar config desde múltiples fuentes (fallback)
/// 2. Una vez obtenida, se cachea localmente
/// 3. Si cambia la IP, la app sigue funcionando
class DynamicConfig {
  // Lista de URLs de bootstrap (en orden de prioridad)
  // Puedes usar dominio fijo, DuckDNS, o múltiples IPs
  static const List<String> _bootstrapUrls = [
    'https://lamano.duckdns.org/lamano/api_bootstrap_config.php',  // Opción 1: DNS dinámico (RECOMENDADO)
    'https://api.lamano.com/lamano/api_bootstrap_config.php',       // Opción 2: Dominio propio
    'http://93.127.135.73/lamano/api_bootstrap_config.php',         // Opción 3: IP actual (fallback)
  ];

  static const String _cacheKey = 'bootstrap_config';
  static const String _cacheTimestampKey = 'bootstrap_config_timestamp';
  static const int _cacheValidityHours = 24;

  static Map<String, dynamic>? _config;

  /// Obtiene la configuración del servidor
  /// Intenta desde caché primero, luego desde las URLs de bootstrap
  static Future<Map<String, dynamic>> getConfig() async {
    // 1. Intentar cargar desde caché
    final cached = await _loadFromCache();
    if (cached != null) {
      _config = cached;
      return cached;
    }

    // 2. Intentar cargar desde las URLs de bootstrap
    for (final url in _bootstrapUrls) {
      try {
        final response = await http
            .get(Uri.parse(url))
            .timeout(const Duration(seconds: 5));

        if (response.statusCode == 200) {
          final config = jsonDecode(response.body) as Map<String, dynamic>;
          await _saveToCache(config);
          _config = config;
          return config;
        }
      } catch (e) {
        // Intentar siguiente URL
        continue;
      }
    }

    // 3. Si todo falla, usar configuración por defecto
    return _getDefaultConfig();
  }

  /// Obtiene la URL base de la API
  static Future<String> getBaseUrl() async {
    final config = await getConfig();
    return config['base_api_url'] as String? ?? 'http://93.127.135.73/lamano';
  }

  /// Obtiene una URL de endpoint específica
  static Future<String> getEndpoint(String name) async {
    final config = await getConfig();
    final baseUrl = config['base_api_url'] as String;
    final endpoints = config['endpoints'] as Map<String, dynamic>?;
    final endpoint = endpoints?[name] as String? ?? '/api_$name.php';
    return '$baseUrl$endpoint';
  }

  /// Obtiene el dominio de Jitsi
  static Future<String> getJitsiDomain() async {
    final config = await getConfig();
    return config['jitsi_domain'] as String? ?? 'jitsi.93.127.135.73.nip.io';
  }

  /// Fuerza actualización de la configuración (útil para testing)
  static Future<void> refresh() async {
    await _clearCache();
    await getConfig();
  }

  // ── Métodos privados ─────────────────────────────────────────────────────

  static Future<Map<String, dynamic>?> _loadFromCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cached = prefs.getString(_cacheKey);
      final timestamp = prefs.getInt(_cacheTimestampKey) ?? 0;

      if (cached == null) return null;

      // Verificar si el caché sigue válido
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final age = now - timestamp;
      if (age > _cacheValidityHours * 3600) return null;

      return jsonDecode(cached) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  static Future<void> _saveToCache(Map<String, dynamic> config) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_cacheKey, jsonEncode(config));
      await prefs.setInt(_cacheTimestampKey, DateTime.now().millisecondsSinceEpoch ~/ 1000);
    } catch (_) {}
  }

  static Future<void> _clearCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_cacheKey);
      await prefs.remove(_cacheTimestampKey);
    } catch (_) {}
  }

  static Map<String, dynamic> _getDefaultConfig() {
    // Configuración por defecto si TODO falla
    return {
      'base_api_url': 'http://93.127.135.73/lamano',
      'version_check_url': 'http://93.127.135.73/lamano/version.json',
      'jitsi_domain': 'jitsi.93.127.135.73.nip.io',
      'endpoints': {},
    };
  }
}

/// Ejemplo de uso en app_constants.dart:
/// 
/// class AppConstants {
///   // En vez de URLs estáticas, usar métodos async:
///   
///   static Future<String> get loginUrl async => 
///     await DynamicConfig.getEndpoint('login');
///   
///   static Future<String> get motoboyOrdersUrl async => 
///     await DynamicConfig.getEndpoint('motoboy_orders');
///   
///   // O si prefieres cargar todo al inicio en SplashPage:
///   static late String loginUrl;
///   static late String motoboyOrdersUrl;
///   
///   static Future<void> initialize() async {
///     final baseUrl = await DynamicConfig.getBaseUrl();
///     loginUrl = '$baseUrl/api_mobile_login.php';
///     motoboyOrdersUrl = '$baseUrl/api_motoboy_orders.php';
///     // ...etc
///   }
/// }
