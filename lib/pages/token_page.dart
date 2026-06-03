import 'dart:io';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_chat_demo/constants/constants.dart';

class TokenPage extends StatefulWidget {
  final String userId;
  final String nickname;
  final String role;
  final String phone;

  const TokenPage({
    super.key,
    required this.userId,
    required this.nickname,
    required this.role,
    required this.phone,
  });

  @override
  State createState() => TokenPageState();
}

class TokenPageState extends State<TokenPage> {
  String? _fcmToken;
  String? _apnsToken;
  bool _isLoading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadTokens();
  }

  Future<void> _loadTokens() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final fcm = await FirebaseMessaging.instance.getToken();
      final apns = await FirebaseMessaging.instance.getAPNSToken();
      setState(() {
        _fcmToken = fcm;
        _apnsToken = apns;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
      });
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  void _copyToken() {
    final token = _fcmToken ?? 'No hay token disponible';
    Clipboard.setData(ClipboardData(text: token));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Token copiado al portapapeles')),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        boxShadow: [
          const BoxShadow(
            color: Color.fromRGBO(0, 0, 0, 0.03),
            blurRadius: 8,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
          ),
          const SizedBox(height: 6),
          SelectableText(
            value.isNotEmpty ? value : 'No disponible',
            style: const TextStyle(fontSize: 14),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Token de dispositivo'),
        centerTitle: true,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildInfoRow('Usuario', widget.nickname),
              _buildInfoRow('Rol', widget.role),
              _buildInfoRow('UID', widget.userId),
              _buildInfoRow('Teléfono', widget.phone),
              _buildInfoRow('Plataforma', Platform.operatingSystem),
              _buildInfoRow('FCM token', _fcmToken ?? ''),
              _buildInfoRow('APNS token', _apnsToken ?? ''),
              if (_error != null)
                Container(
                  margin: const EdgeInsets.symmetric(vertical: 12),
                  child: Text('Error: $_error', style: const TextStyle(color: Colors.red)),
                ),
              const SizedBox(height: 12),
              ElevatedButton.icon(
                icon: const Icon(Icons.copy),
                label: const Text('Copiar token FCM'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: ColorConstants.primaryColor,
                ),
                onPressed: _fcmToken != null ? _copyToken : null,
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                icon: const Icon(Icons.refresh),
                label: const Text('Actualizar información'),
                onPressed: _isLoading ? null : _loadTokens,
              ),
              if (_isLoading)
                const Padding(
                  padding: EdgeInsets.only(top: 16),
                  child: Center(child: CircularProgressIndicator()),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
