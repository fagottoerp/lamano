import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_chat_demo/pages/pages.dart';
import 'package:flutter_chat_demo/providers/auth_provider.dart';
import 'package:flutter_chat_demo/utils/app_updater.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';

class SplashPage extends StatefulWidget {
  SplashPage({super.key});

  @override
  SplashPageState createState() => SplashPageState();
}

class SplashPageState extends State<SplashPage> with SingleTickerProviderStateMixin {
  late AnimationController _glowController;
  late Animation<double> _glowAnim;
  int _dotCount = 0;
  Timer? _dotTimer;

  @override
  void initState() {
    super.initState();

    _glowController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat(reverse: true);

    _glowAnim = Tween<double>(begin: 0.4, end: 1.0).animate(
      CurvedAnimation(parent: _glowController, curve: Curves.easeInOut),
    );

    _dotTimer = Timer.periodic(const Duration(milliseconds: 400), (_) {
      if (mounted) setState(() => _dotCount = (_dotCount + 1) % 4);
    });

    Future.delayed(const Duration(milliseconds: 800), _checkUpdateThenSignIn);
  }

  @override
  void dispose() {
    _glowController.dispose();
    _dotTimer?.cancel();
    super.dispose();
  }

  void _checkUpdateThenSignIn() async {
    await AppUpdater.checkAndUpdate(context);
    if (!mounted) return;
    await _ensureLocationPermission();
    if (!mounted) return;
    _checkSignedIn();
  }

  /// Blocks until the user grants location permission and enables GPS service.
  Future<void> _ensureLocationPermission() async {
    while (true) {
      // 1. Check service enabled
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        if (!mounted) return;
        await _showBlockingDialog(
          title: '📍 GPS requerido',
          message:
              'La Mano necesita el GPS activado para proteger a todos los usuarios.\n\nActiva la ubicación en los ajustes de tu teléfono y regresa.',
          actionLabel: 'Abrir ajustes',
          onAction: () => Geolocator.openLocationSettings(),
        );
        continue;
      }

      // 2. Check permission
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied) {
        if (!mounted) return;
        await _showBlockingDialog(
          title: '📍 Permiso de ubicación',
          message:
              'La Mano requiere acceso a tu ubicación.\nEsto nos permite protegerte en caso de emergencia.',
          actionLabel: 'Conceder permiso',
          onAction: () => Geolocator.requestPermission(),
        );
        continue;
      }
      if (perm == LocationPermission.deniedForever) {
        if (!mounted) return;
        await _showBlockingDialog(
          title: '📍 Permiso bloqueado',
          message:
              'Has bloqueado el acceso a la ubicación.\nVe a Ajustes del teléfono → Permisos → Ubicación y actívala para La Mano.',
          actionLabel: 'Abrir ajustes',
          onAction: () => Geolocator.openAppSettings(),
        );
        continue;
      }
      // Permission granted
      return;
    }
  }

  Future<void> _showBlockingDialog({
    required String title,
    required String message,
    required String actionLabel,
    required Future<void> Function() onAction,
  }) async {
    if (!mounted) return;
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => WillPopScope(
        onWillPop: () async => false,
        child: AlertDialog(
          backgroundColor: const Color(0xFF0D1F14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: Color(0xFF00E65A), width: 1.5),
          ),
          title: Text(title,
              style: const TextStyle(
                  color: Color(0xFF00E65A), fontWeight: FontWeight.bold)),
          content: Text(message,
              style: const TextStyle(color: Colors.white70, fontSize: 14)),
          actions: [
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00E65A),
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
              ),
              onPressed: () async {
                Navigator.pop(context);
                await onAction();
              },
              child: Text(actionLabel),
            ),
          ],
        ),
      ),
    );
  }

  void _checkSignedIn() async {
    try {
      final authProvider = context.read<AuthProvider>();
      bool isLoggedIn = await authProvider.isLoggedIn();
      if (!mounted) return;
      if (isLoggedIn) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (context) => HomePage()),
        );
      } else {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (context) => LoginPage()),
        );
      }
    } catch (_) {
      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (context) => LoginPage()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final dots = '.' * _dotCount + ' ' * (3 - _dotCount);
    return Scaffold(
      backgroundColor: const Color(0xFF111827),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Glowing hand icon
            AnimatedBuilder(
              animation: _glowAnim,
              builder: (_, child) => Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF00E65A).withOpacity(_glowAnim.value * 0.6),
                      blurRadius: 40 * _glowAnim.value,
                      spreadRadius: 8 * _glowAnim.value,
                    ),
                  ],
                ),
                child: child,
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(28),
                child: Image.asset(
                  'images/app_icon.png',
                  width: 110,
                  height: 110,
                ),
              ),
            ),
            const SizedBox(height: 24),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFF0B1220),
                border: Border.all(color: const Color(0xFF00E65A), width: 2),
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Text(
                'LEVEL 01',
                style: TextStyle(
                  color: Color(0xFF00E65A),
                  fontSize: 16,
                  letterSpacing: 2,
                  fontWeight: FontWeight.w900,
                  fontFamily: 'monospace',
                ),
              ),
            ),
            const SizedBox(height: 40),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  '> CARGANDO MUNDO',
                  style: TextStyle(
                    color: Color(0xFF00E65A),
                    fontSize: 12,
                    letterSpacing: 2,
                    fontFamily: 'monospace',
                  ),
                ),
                Text(
                  dots,
                  style: const TextStyle(
                    color: Color(0xFF00E65A),
                    fontSize: 12,
                    letterSpacing: 2,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: 160,
              height: 2,
              child: AnimatedBuilder(
                animation: _glowAnim,
                builder: (_, __) => LinearProgressIndicator(
                  backgroundColor: const Color(0xFF001A0D),
                  valueColor: AlwaysStoppedAnimation<Color>(
                    Color.lerp(
                      const Color(0xFF004D1A),
                      const Color(0xFF00FF6A),
                      _glowAnim.value,
                    )!,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              '8-BIT MODE [${'█' * (_dotCount + 1)}${' ' * (3 - _dotCount)}]',
              style: TextStyle(
                color: const Color(0xFF00E65A).withOpacity(0.8),
                fontSize: 11,
                letterSpacing: 1,
                fontFamily: 'monospace',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

