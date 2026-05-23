import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppUpdater {
  static const String _versionUrl =
      'http://38.247.147.220/lamano/version.json';
  static const String _prefsDismissedKey = 'update_dismissed_version';
  static DateTime? _lastCheckAt;
  static bool _checking = false;

  /// Checks for a new version and shows an update dialog if available.
  /// Call this from SplashPage before navigating.
  static Future<void> checkAndUpdate(
    BuildContext context, {
    bool force = false,
    bool showUpToDate = false,
  }) async {
    if (_checking) return;
    if (!force && _lastCheckAt != null) {
      final diff = DateTime.now().difference(_lastCheckAt!);
      if (diff.inSeconds < 20) return;
    }

    _checking = true;
    _lastCheckAt = DateTime.now();

    try {
      final cacheBust = DateTime.now().millisecondsSinceEpoch;
      final response = await http
          .get(Uri.parse('$_versionUrl?t=$cacheBust'))
          .timeout(const Duration(seconds: 6));

      if (response.statusCode != 200) {
        if (showUpToDate && context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No se pudo consultar actualizaciones.')),
          );
        }
        return;
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final latestVersion = data['version'] as String;
      final apkUrl = data['apk_url'] as String;
      final notes = (data['notes'] as String?) ?? '';

      final info = await PackageInfo.fromPlatform();
      if (!_isNewer(latestVersion, info.version)) {
        if (showUpToDate && context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Ya tienes la última versión (${info.version}).')),
          );
        }
        return;
      }

      // Don't show dialog again if user already dismissed this exact version
      if (!force) {
        final prefs = await SharedPreferences.getInstance();
        final dismissed = prefs.getString(_prefsDismissedKey) ?? '';
        if (dismissed == latestVersion) return;
      }

      if (!context.mounted) return;

      final confirm = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => AlertDialog(
          title: Text('Nueva versión v$latestVersion disponible'),
          content: Text(notes.isNotEmpty
              ? notes
              : 'Hay una actualización disponible. ¿Deseas instalarla ahora?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Después'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Actualizar'),
            ),
          ],
        ),
      );

      if (confirm != true) {
        // Remember that user dismissed this version
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_prefsDismissedKey, latestVersion);
        return;
      }
      if (!context.mounted) return;

      await _downloadAndInstall(context, apkUrl, latestVersion);
    } catch (_) {
      if (showUpToDate && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Error al verificar actualización.')),
        );
      }
    } finally {
      _checking = false;
    }
  }

  static Future<void> _downloadAndInstall(
      BuildContext context, String url, String version) async {
    // Show progress dialog
    double _progress = 0.0;
    final progressNotifier = ValueNotifier<double>(0.0);

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: const Text('Actualizando...'),
          content: ValueListenableBuilder<double>(
            valueListenable: progressNotifier,
            builder: (_, value, __) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                LinearProgressIndicator(value: value > 0 ? value : null),
                const SizedBox(height: 8),
                Text(value > 0
                    ? '${(value * 100).toStringAsFixed(0)}%'
                    : 'Descargando...'),
              ],
            ),
          ),
        ),
      ),
    );

    try {
      final dir = await getTemporaryDirectory();
      final savePath = '${dir.path}/lamano-update-v$version.apk';
      final file = File(savePath);

      final request = http.Request('GET', Uri.parse(url));
      final response = await http.Client().send(request);
      final total = response.contentLength ?? 0;
      int received = 0;

      final sink = file.openWrite();
      await for (final chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) {
          progressNotifier.value = received / total;
        }
      }
      await sink.close();

      if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
      progressNotifier.dispose();

      await OpenFilex.open(savePath);
    } catch (e) {
      progressNotifier.dispose();
      if (context.mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error al descargar: $e')),
        );
      }
    }
  }

  /// Returns true if [latest] is a higher semver than [current].
  static bool _isNewer(String latest, String current) {
    try {
      final l = _normalizeVersion(latest);
      final c = _normalizeVersion(current);
      final maxLen = l.length > c.length ? l.length : c.length;
      for (int i = 0; i < maxLen; i++) {
        final lv = i < l.length ? l[i] : 0;
        final cv = i < c.length ? c[i] : 0;
        if (lv > cv) return true;
        if (lv < cv) return false;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  static List<int> _normalizeVersion(String value) {
    final clean = value.trim().replaceAll(RegExp(r'[^0-9.]'), '');
    if (clean.isEmpty) return [0, 0, 0];
    final parts = clean.split('.');
    return parts.map((p) => int.tryParse(p) ?? 0).toList();
  }
}
