import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import '../constants/constants.dart';
import '../services/group_radio_service.dart';

/// Widget de radio/walkie-talkie automático por grupo usando Agora
/// Genera una frecuencia única por groupChatId y permite PTT (Push-To-Talk)
class GroupRadioWidget extends StatefulWidget {
  final String groupChatId;
  final String groupName;
  final String currentUserId;
  final String currentUserName;

  const GroupRadioWidget({
    super.key,
    required this.groupChatId,
    required this.groupName,
    required this.currentUserId,
    required this.currentUserName,
  });

  @override
  State<GroupRadioWidget> createState() => _GroupRadioWidgetState();
}

class _GroupRadioWidgetState extends State<GroupRadioWidget> {
  final _radioService = GroupRadioService();
  bool _isConnected = false;
  bool _isPTT = false;
  bool _isAlwaysLive = false;
  List<String> _connectedUsers = [];
  String? _currentSpeaker;
  StreamSubscription? _connectionSub;
  StreamSubscription? _modeSub;
  StreamSubscription? _usersSub;
  Timer? _pttAutoStopTimer;

  String get _radioFrequency => GroupRadioService.getFrequency(widget.groupChatId);

  @override
  void initState() {
    super.initState();
    _connectionSub = _radioService.connectionStream.listen((connected) {
      if (mounted) {
        setState(() => _isConnected = connected);
      }
    });
    _modeSub = _radioService.modeStream.listen((alwaysLive) {
      if (mounted) {
        setState(() => _isAlwaysLive = alwaysLive);
      }
    });
    // Sincronizar estado actual
    _isConnected = _radioService.isConnected;
    _isAlwaysLive = _radioService.isAlwaysLiveMode;
    _listenForConnectedUsers();
  }

  @override
  void dispose() {
    _pttAutoStopTimer?.cancel();
    _connectionSub?.cancel();
    _modeSub?.cancel();
    _usersSub?.cancel();
    // NO llamar a _radioService.dispose() - mantener conexión activa
    super.dispose();
  }

  void _listenForConnectedUsers() {
    _usersSub = FirebaseFirestore.instance
        .collection('groups')
        .doc(widget.groupChatId)
        .collection('radio_connected')
        .snapshots()
        .listen((snap) {
      if (!mounted) return;

      final users = snap.docs.map((doc) {
        final data = doc.data();
        return data['name'] as String? ?? 'Usuario';
      }).toList();

      final speakers = snap.docs
          .where((doc) {
            final data = doc.data();
            return doc.id != widget.currentUserId && (data['speaking'] as bool? ?? false);
          })
          .map((doc) => (doc.data()['name'] as String?) ?? 'Usuario')
          .toList();

      setState(() {
        _connectedUsers = users;
        _currentSpeaker = speakers.isNotEmpty ? speakers.first : null;
      });
    });
  }

  Future<void> _toggleConnection() async {
    if (_isConnected) {
      await _disconnect();
    } else {
      await _connect();
    }
  }

  Future<void> _connect() async {
    final success = await _radioService.connectToGroup(
      groupChatId: widget.groupChatId,
      userId: widget.currentUserId,
      userName: widget.currentUserName,
    );

    if (success && mounted) {

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('🔊 Conectado a radio ${_radioFrequency}'),
          backgroundColor: Colors.green,
          duration: const Duration(seconds: 2),
        ),
      );
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('❌ Error al conectar. Verifica permisos de micrófono.'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _disconnect() async {
    await _radioService.disconnect();
    if (mounted) {
      setState(() => _isPTT = false);
    }
  }

  Future<void> _startPTT() async {
    if (!_isConnected) return;

    await _radioService.startPTT();
    setState(() => _isPTT = true);

    // Auto-detener PTT después de 30 segundos (seguridad)
    _pttAutoStopTimer?.cancel();
    _pttAutoStopTimer = Timer(const Duration(seconds: 30), _stopPTT);
  }

  Future<void> _stopPTT() async {
    if (!_isConnected) return;

    _pttAutoStopTimer?.cancel();
    await _radioService.stopPTT();
    setState(() => _isPTT = false);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: _isConnected 
                        ? [Colors.green.shade600, Colors.green.shade800]
                        : [Colors.grey.shade700, Colors.grey.shade900],
                  ),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  _isConnected ? Icons.radio : Icons.radio_button_unchecked,
                  color: Colors.white,
                  size: 28,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Radio Walkie-Talkie',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Frecuencia: $_radioFrequency',
                      style: TextStyle(
                        fontSize: 16,
                        color: _isConnected ? Colors.green.shade700 : Colors.grey,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 2,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),

          // Estado: Conectado
          if (_isConnected) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.green.shade50,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.green.shade200),
              ),
              child: Row(
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: const BoxDecoration(
                      color: Colors.greenAccent,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Text(
                    'CONECTADO',
                    style: TextStyle(
                      color: Colors.green,
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  if (_connectedUsers.isNotEmpty)
                    Row(
                      children: [
                        const Icon(Icons.people, color: Colors.green, size: 18),
                        const SizedBox(width: 6),
                        Text(
                          '${_connectedUsers.length}',
                          style: const TextStyle(
                            color: Colors.green,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Indicador de quién habla
            if (_currentSpeaker != null)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.orange,
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: const [
                    BoxShadow(
                      color: Colors.orangeAccent,
                      blurRadius: 8,
                      spreadRadius: 2,
                    ),
                  ],
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.mic, color: Colors.white, size: 20),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        _currentSpeaker!,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),

            const SizedBox(height: 24),

            // Toggle de modo de transmisión
            Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: Colors.grey.shade200,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: GestureDetector(
                      onTap: () => _radioService.setAlwaysLiveMode(false),
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        decoration: BoxDecoration(
                          color: !_isAlwaysLive ? Colors.white : Colors.transparent,
                          borderRadius: BorderRadius.circular(10),
                          boxShadow: !_isAlwaysLive
                              ? [BoxShadow(color: Colors.black12, blurRadius: 4, spreadRadius: 1)]
                              : null,
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.touch_app,
                              size: 18,
                              color: !_isAlwaysLive ? ColorConstants.primaryColor : Colors.grey.shade600,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              'Mantener',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: !_isAlwaysLive ? FontWeight.bold : FontWeight.normal,
                                color: !_isAlwaysLive ? ColorConstants.primaryColor : Colors.grey.shade600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: GestureDetector(
                      onTap: () => _radioService.setAlwaysLiveMode(true),
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        decoration: BoxDecoration(
                          color: _isAlwaysLive ? Colors.white : Colors.transparent,
                          borderRadius: BorderRadius.circular(10),
                          boxShadow: _isAlwaysLive
                              ? [BoxShadow(color: Colors.black12, blurRadius: 4, spreadRadius: 1)]
                              : null,
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.mic,
                              size: 18,
                              color: _isAlwaysLive ? Colors.red.shade600 : Colors.grey.shade600,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              'Siempre en vivo',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: _isAlwaysLive ? FontWeight.bold : FontWeight.normal,
                                color: _isAlwaysLive ? Colors.red.shade600 : Colors.grey.shade600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Botón PTT (Push-To-Talk) - Solo en modo mantener - Solo en modo mantener
            if (!_isAlwaysLive)
              GestureDetector(
                onLongPressStart: (_) => _startPTT(),
                onLongPressEnd: (_) => _stopPTT(),
                onLongPressCancel: () => _stopPTT(),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: _isPTT 
                          ? [Colors.red.shade600, Colors.red.shade800]
                          : [Colors.grey.shade200, Colors.grey.shade300],
                    ),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: _isPTT ? Colors.redAccent : Colors.grey.shade400,
                      width: 3,
                    ),
                    boxShadow: [
                      if (_isPTT)
                        BoxShadow(
                          color: Colors.red.withOpacity(0.5),
                          blurRadius: 16,
                          spreadRadius: 4,
                        ),
                    ],
                  ),
                  child: Column(
                    children: [
                      Icon(
                        _isPTT ? Icons.mic : Icons.mic_none,
                        color: _isPTT ? Colors.white : Colors.grey.shade700,
                        size: 48,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        _isPTT ? '🔴 TRANSMITIENDO...' : 'MANTÉN PRESIONADO PARA HABLAR',
                        style: TextStyle(
                          color: _isPTT ? Colors.white : Colors.grey.shade700,
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              ),
            
            // Indicador de siempre en vivo
            if (_isAlwaysLive)
              Container(
                padding: const EdgeInsets.symmetric(vertical: 24),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Colors.red.shade600, Colors.red.shade800],
                  ),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: Colors.redAccent,
                    width: 3,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.red.withOpacity(0.5),
                      blurRadius: 16,
                      spreadRadius: 4,
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    const Icon(
                      Icons.mic,
                      color: Colors.white,
                      size: 48,
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      '🔴 TRANSMITIENDO EN VIVO',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Micrófono siempre activo',
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.9),
                        fontSize: 12,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 16),
          ],

          // Botón Conectar/Desconectar
          SizedBox(
            height: 56,
            child: ElevatedButton(
              onPressed: _toggleConnection,
              style: ElevatedButton.styleFrom(
                backgroundColor: _isConnected ? Colors.red.shade600 : Colors.green.shade600,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                elevation: 4,
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(_isConnected ? Icons.call_end : Icons.call, size: 24),
                  const SizedBox(width: 12),
                  Text(
                    _isConnected ? 'Desconectar' : 'Conectar a Radio',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          // Información
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.blue.shade50,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.blue.shade200),
            ),
            child: Row(
              children: [
                Icon(Icons.info_outline, size: 18, color: Colors.blue.shade700),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _isAlwaysLive
                        ? 'Tu micrófono está siempre activo. Los demás te escuchan constantemente.'
                        : 'Mantén presionado el botón del micrófono para hablar',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.blue.shade900,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
