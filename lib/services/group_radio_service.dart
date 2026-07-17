import 'dart:async';
import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

/// Servicio de walkie-talkie por grupo usando Agora RTC
/// Cada grupo tiene su propia frecuencia (canal de Agora)
class GroupRadioService {
  static const String _agoraAppId = '41b0a5f3844441c3abf9e4c5fdc2eca9';
  static const String _tokenServerUrl = 'http://93.127.135.73/lamano/api_agora_token.php';
  
  // Singleton
  static final GroupRadioService _instance = GroupRadioService._internal();
  factory GroupRadioService() => _instance;
  GroupRadioService._internal();
  
  RtcEngine? _engine;
  String? _currentChannelName;    // canal Agora (sanitizado)
  String? _currentGroupChatId;   // groupChatId original para Firestore
  String? _currentUserId;
  String? _currentUserName;
  bool _isConnected = false;
  bool _isMuted = true; // PTT: empezar muteado
  bool _alwaysLiveMode = false; // false = PTT, true = siempre en vivo
  bool _isSpeakerEnabled = true; // Altavoz por defecto activado
  
  final _speakersController = StreamController<List<String>>.broadcast();
  Stream<List<String>> get speakersStream => _speakersController.stream;
  
  final _connectionController = StreamController<bool>.broadcast();
  Stream<bool> get connectionStream => _connectionController.stream;
  
  final _modeController = StreamController<bool>.broadcast();
  Stream<bool> get modeStream => _modeController.stream;
  
  final _speakerModeController = StreamController<bool>.broadcast();
  Stream<bool> get speakerModeStream => _speakerModeController.stream;
  
  bool get isAlwaysLiveMode => _alwaysLiveMode;
  bool get isConnected => _isConnected;
  bool get isSpeakerEnabled => _isSpeakerEnabled;

  /// Obtener frecuencia única basada en groupChatId
  static String getFrequency(String groupChatId) {
    final hash = groupChatId.hashCode.abs();
    final part1 = (hash % 9) + 1;
    final part2 = ((hash ~/ 10) % 9) + 1;
    final part3 = ((hash ~/ 100) % 9) + 1;
    return '$part1.$part2.$part3';
  }

  /// Inicializar Agora RTC Engine
  Future<bool> initialize() async {
    try {
      if (_engine != null) {
        return true;
      }

      _engine = createAgoraRtcEngine();
      await _engine!.initialize(const RtcEngineContext(
        appId: _agoraAppId,
        channelProfile: ChannelProfileType.channelProfileLiveBroadcasting,
      ));

      await _engine!.enableAudio();
      
      // Empezar muteado (PTT)
      await _engine!.muteLocalAudioStream(true);

      // Registrar event handlers
      _engine!.registerEventHandler(RtcEngineEventHandler(
        onError: (ErrorCodeType err, String msg) {
          debugPrint('[RADIO] ❌ Error Agora: $err - $msg');
        },
        onJoinChannelSuccess: (RtcConnection connection, int elapsed) {
          debugPrint('[RADIO] ✅ Conectado al canal: ${connection.channelId}');
          _isConnected = true;
          _connectionController.add(true);
          // Aplicar altavoz DESPUÉS de que el canal esté conectado (momento correcto)
          _engine?.setEnableSpeakerphone(_isSpeakerEnabled);
          debugPrint('[RADIO] Audio: ${_isSpeakerEnabled ? "ALTAVOZ 🔊" : "AURICULAR 📞"}');
        },
        onUserJoined: (RtcConnection connection, int remoteUid, int elapsed) {
          debugPrint('[RADIO] Usuario unido: $remoteUid');
        },
        onUserOffline: (RtcConnection connection, int remoteUid, UserOfflineReasonType reason) {
          debugPrint('[RADIO] Usuario salió: $remoteUid');
        },
        onAudioVolumeIndication: (RtcConnection connection, List<AudioVolumeInfo> speakers, int speakerNumber, int totalVolume) {
          // Detectar quién está hablando
          final activeSpeakers = speakers
              .where((s) => s.volume != null && s.volume! > 50)
              .map((s) => s.uid.toString())
              .toList();
          _speakersController.add(activeSpeakers);
        },
        onLeaveChannel: (RtcConnection connection, RtcStats stats) {
          debugPrint('[RADIO] Desconectado del canal');
          _isConnected = false;
          _connectionController.add(false);
        },
      ));

      // Habilitar indicador de volumen
      await _engine!.enableAudioVolumeIndication(
        interval: 500,
        smooth: 3,
        reportVad: true,
      );

      debugPrint('[RADIO] ✅ Engine inicializado correctamente');
      return true;
    } catch (e, stackTrace) {
      debugPrint('[RADIO] ❌ ERROR al inicializar: $e');
      debugPrint('[RADIO] Stack: $stackTrace');
      return false;
    }
  }

  /// Conectar al canal de radio del grupo
  Future<bool> connectToGroup({
    required String groupChatId,
    required String userId,
    required String userName,
  }) async {
    try {
      if (_engine == null) {
        final initialized = await initialize();
        if (!initialized) {
          debugPrint('[RADIO] ❌ Fallo al inicializar engine');
          return false;
        }
      }

      if (_isConnected && _currentChannelName != null) {
        await disconnect();
      }

      // Canal = groupChatId sanitizado
      final channelName = groupChatId.replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '');
      
      // UID debe ser consistente y positivo para Agora (0-2147483647)
      final agoraUid = userId.hashCode.abs() % 2147483647;
      
      // Obtener token de Agora
      final token = await _fetchAgoraToken(channelName, agoraUid);
      
      _currentChannelName = channelName;
      _currentGroupChatId = groupChatId;  // guardar original para Firestore
      _currentUserId = userId;
      _currentUserName = userName;

      // Unirse al canal
      final options = ChannelMediaOptions(
        channelProfile: ChannelProfileType.channelProfileLiveBroadcasting,
        clientRoleType: ClientRoleType.clientRoleBroadcaster,
        autoSubscribeAudio: true,
        publishMicrophoneTrack: true,
      );

      await _engine!.joinChannel(
        token: token ?? '',
        channelId: channelName,
        uid: agoraUid,
        options: options,
      );

      // Registrar en Firestore
      await FirebaseFirestore.instance
          .collection('groups')
          .doc(groupChatId)
          .collection('radio_connected')
          .doc(userId)
          .set({
        'uid': userId,
        'name': userName,
        'connectedAt': FieldValue.serverTimestamp(),
        'speaking': false,
      });

      debugPrint('[RADIO] ✅ Conexión completada (canal: $channelName, uid: $agoraUid)');
      // Mantener CPU/audio activo cuando pantalla se bloquea
      _startRadioWakeLock(userName);
      // Notificar en el chat del grupo
      await _sendRadioSystemMessage(groupChatId, userId, userName);
      return true;
    } catch (e, stackTrace) {
      debugPrint('[RADIO] ❌ ERROR: $e');
      debugPrint('[RADIO] Stack: $stackTrace');
      return false;
    }
  }

  /// Desconectar del canal
  Future<void> disconnect() async {
    _stopRadioWakeLock();
    try {
      if (_engine != null && _isConnected) {
        await _engine!.leaveChannel();
      }

      if (_currentGroupChatId != null && _currentUserId != null) {
        // Remover de Firestore usando groupChatId original
        final groupId = _currentGroupChatId!;
        final uid = _currentUserId!;
        final uname = _currentUserName ?? '';
        await FirebaseFirestore.instance
            .collection('groups')
            .doc(groupId)
            .collection('radio_connected')
            .doc(uid)
            .delete();

        // Notificar desconexión en el chat
        await _sendRadioSystemMessage(groupId, uid, uname, connected: false);
      }

      _currentChannelName = null;
      _currentGroupChatId = null;
      _currentUserId = null;
      _currentUserName = null;
      _isConnected = false;
      _isMuted = true;
      _connectionController.add(false);
    } catch (e) {
      debugPrint('[RADIO] Error desconectando: $e');
    }
  }

  /// Activar PTT (Push-To-Talk) - Desmutear micrófono
  Future<void> startPTT() async {
    if (_engine == null || !_isConnected) return;

    try {
      await _engine!.muteLocalAudioStream(false);
      _isMuted = false;

      // Marcar como hablando en Firestore
      if (_currentGroupChatId != null && _currentUserId != null) {
        await FirebaseFirestore.instance
            .collection('groups')
            .doc(_currentGroupChatId)
            .collection('radio_connected')
            .doc(_currentUserId)
            .update({
          'speaking': true,
          'speakingAt': FieldValue.serverTimestamp(),
        });
      }

      debugPrint('[RADIO] PTT activado');
    } catch (e) {
      debugPrint('[RADIO] Error activando PTT: $e');
    }
  }

  /// Desactivar PTT - Mutear micrófono
  Future<void> stopPTT() async {
    if (_engine == null || !_isConnected) return;

    try {
      await _engine!.muteLocalAudioStream(true);
      _isMuted = true;

      // Quitar marca de hablando en Firestore
      if (_currentGroupChatId != null && _currentUserId != null) {
        await FirebaseFirestore.instance
            .collection('groups')
            .doc(_currentGroupChatId)
            .collection('radio_connected')
            .doc(_currentUserId)
            .update({'speaking': false});
      }

      debugPrint('[RADIO] PTT desactivado');
    } catch (e) {
      debugPrint('[RADIO] Error desactivando PTT: $e');
    }
  }

  /// Cambiar a modo siempre en vivo
  Future<void> setAlwaysLiveMode(bool enabled) async {
    _alwaysLiveMode = enabled;
    _modeController.add(enabled);
    
    if (!_isConnected || _engine == null) return;

    try {
      if (enabled) {
        // Modo siempre en vivo: desmutear y mantener
        await _engine!.muteLocalAudioStream(false);
        _isMuted = false;
        
        if (_currentGroupChatId != null && _currentUserId != null) {
          await FirebaseFirestore.instance
              .collection('groups')
              .doc(_currentGroupChatId)
              .collection('radio_connected')
              .doc(_currentUserId)
              .update({
            'speaking': true,
            'alwaysLive': true,
            'speakingAt': FieldValue.serverTimestamp(),
          });
        }
        debugPrint('[RADIO] Modo siempre en vivo activado');
      } else {
        // Volver a modo PTT: mutear
        await _engine!.muteLocalAudioStream(true);
        _isMuted = true;
        
        if (_currentGroupChatId != null && _currentUserId != null) {
          await FirebaseFirestore.instance
              .collection('groups')
              .doc(_currentGroupChatId)
              .collection('radio_connected')
              .doc(_currentUserId)
              .update({
            'speaking': false,
            'alwaysLive': false,
          });
        }
        debugPrint('[RADIO] Modo PTT activado');
      }
    } catch (e) {
      debugPrint('[RADIO] Error cambiando modo: $e');
    }
  }

  /// Alternar entre altavoz y auricular
  Future<void> toggleSpeaker() async {
    try {
      // Cambiar estado (persiste incluso si no está conectado)
      _isSpeakerEnabled = !_isSpeakerEnabled;
      _speakerModeController.add(_isSpeakerEnabled);
      
      // Aplicar cambio si está conectado
      if (_engine != null && _isConnected) {
        await _engine!.setEnableSpeakerphone(_isSpeakerEnabled);
        debugPrint('[RADIO] Altavoz ${_isSpeakerEnabled ? "ACTIVADO" : "DESACTIVADO"} - Audio por ${_isSpeakerEnabled ? "altavoz" : "auricular"}');
      } else {
        debugPrint('[RADIO] Preferencia guardada: ${_isSpeakerEnabled ? "altavoz" : "auricular"} (se aplicará al conectar)');
      }
    } catch (e) {
      debugPrint('[RADIO] Error alternando altavoz: $e');
    }
  }

  /// Envía mensaje del sistema al chat del grupo avisando que alguien entró/salió del radio.
  /// Inserta un mensaje real en la colección `messages` del grupo y actualiza radio_status.
  Future<void> _sendRadioSystemMessage(String groupChatId, String userId, String userName, {bool connected = true}) async {
    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      final groupRef = FirebaseFirestore.instance.collection('groups').doc(groupChatId);

      // Debounce: no enviar mensajes del mismo usuario más seguido que 5 min
      final snap = await groupRef.get();
      final data = snap.data() as Map<String, dynamic>?;
      final radio = data?['radio_status'] as Map<String, dynamic>?;
      final lastSeen = radio != null ? (radio['lastSeen'] as int? ?? 0) : 0;
      final lastUser = radio?['lastUserId'] as String? ?? '';
      const debounceMs = 5 * 60 * 1000; // 5 minutos
      if (lastUser == userId && (now - lastSeen < debounceMs)) {
        debugPrint('[RADIO] Saltando mensaje sistema (debounce 5min)');
        // Igual actualizar connectedCount
        final connectedSnap = await groupRef.collection('radio_connected').get();
        await groupRef.set({
          'radio_status': {
            'connectedCount': connectedSnap.docs.length,
            'active': connected,
          }
        }, SetOptions(merge: true));
        return;
      }

      // Contar usuarios conectados actualmente
      final connectedSnap = await groupRef.collection('radio_connected').get();
      final connectedCount = connectedSnap.docs.length;

      // Actualizar radio_status en el documento del grupo
      await groupRef.set({
        'radio_status': {
          'lastUserId': userId,
          'lastUserName': userName,
          'lastSeen': now,
          'active': connected,
          'connectedCount': connectedCount,
        }
      }, SetOptions(merge: true));

      // Insertar mensaje de sistema en el chat del grupo
      final action = connected ? 'se conectó a' : 'se desconectó de';
      final emoji = connected ? '📻🟢' : '📻⚪';
      String content = '$emoji $userName $action la radio';
      if (connected && connectedCount > 0) {
        content += '\n👥 $connectedCount usuario${connectedCount > 1 ? 's' : ''} en línea';
      }

      final messageRef = groupRef.collection('messages').doc();
      await messageRef.set({
        'idFrom': 'system',
        'content': content,
        'timestamp': now.toString(),
        'type': 0,
        'isSystemMessage': true,
      });

      debugPrint('[RADIO] Mensaje de sistema enviado: $content');
    } catch (e) {
      debugPrint('[RADIO] Error enviando mensaje radio: $e');
    }
  }

  /// Inicia notificación de foreground para mantener audio activo al bloquear pantalla
  void _startRadioWakeLock(String userName) {
    try {
      FlutterForegroundTask.updateService(
        notificationTitle: '📻 Radio activo',
        notificationText: 'Conectado - el audio continúa aunque bloquees la pantalla',
      );
    } catch (_) {}
  }

  /// Detiene el wake lock del radio
  void _stopRadioWakeLock() {
    try {
      FlutterForegroundTask.updateService(
        notificationTitle: 'Servicio en segundo plano',
        notificationText: 'Actualizando estado de la app',
      );
    } catch (_) {}
  }

  /// Obtener token de Agora desde servidor
  Future<String?> _fetchAgoraToken(String channelName, int uid) async {
    try {
      final response = await http.post(
        Uri.parse(_tokenServerUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'channel_name': channelName,
          'uid': uid,
          'role': 'publisher',
        }),
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final token = data['token'] as String?;
        if (token != null && token.isNotEmpty) {
          debugPrint('[RADIO] Token obtenido correctamente');
          return token;
        }
      }
    } catch (e) {
      debugPrint('[RADIO] Error obteniendo token: $e');
    }
    debugPrint('[RADIO] ⚠️ Sin token - verificar servidor');
    return null; // null es correcto para joinChannel sin token
  }

  /// Limpiar recursos
  Future<void> dispose() async {
    await disconnect();
    await _speakersController.close();
    await _connectionController.close();
    await _modeController.close();
    await _speakerModeController.close();
    if (_engine != null) {
      await _engine!.release();
      _engine = null;
    }
  }
}
