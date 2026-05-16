import 'dart:convert';

/// Helpers para parsear JSON sin que la app crashee si el servidor responde
/// algo inesperado (HTML de error, array vacío, null, body vacío, etc.).
class SafeJson {
  /// Parsea body como Map. Si no es un Map, retorna `{}` y opcionalmente
  /// llena `error` con el detalle.
  static Map<String, dynamic> asMap(String? body) {
    if (body == null || body.trim().isEmpty) return const {};
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) {
        return decoded.map((k, v) => MapEntry(k.toString(), v));
      }
      return const {};
    } catch (_) {
      return const {};
    }
  }

  /// Parsea body y retorna List<Map>. Acepta tanto un array como un objeto
  /// con clave `orders`/`items`/`data` que contenga la lista.
  static List<Map<String, dynamic>> asListOfMap(
    dynamic value, {
    List<String> nestedKeys = const ['orders', 'items', 'data'],
  }) {
    dynamic raw = value;
    if (raw is String) {
      try {
        raw = jsonDecode(raw);
      } catch (_) {
        return const [];
      }
    }
    if (raw is List) {
      return _coerceList(raw);
    }
    if (raw is Map) {
      for (final key in nestedKeys) {
        final inner = raw[key];
        if (inner is List) return _coerceList(inner);
      }
    }
    return const [];
  }

  static List<Map<String, dynamic>> _coerceList(List raw) {
    final result = <Map<String, dynamic>>[];
    for (final item in raw) {
      if (item is Map<String, dynamic>) {
        result.add(item);
      } else if (item is Map) {
        result.add(item.map((k, v) => MapEntry(k.toString(), v)));
      }
    }
    return result;
  }

  /// Lectura tolerante de bool. Acepta true/false, "true"/"false", 1/0, "1"/"0".
  static bool boolValue(dynamic v, {bool fallback = false}) {
    if (v is bool) return v;
    if (v is num) return v != 0;
    if (v is String) {
      final s = v.trim().toLowerCase();
      if (s == 'true' || s == '1' || s == 'yes') return true;
      if (s == 'false' || s == '0' || s == 'no') return false;
    }
    return fallback;
  }

  /// Lectura tolerante de string.
  static String stringValue(dynamic v, {String fallback = ''}) {
    if (v == null) return fallback;
    return v.toString();
  }
}
