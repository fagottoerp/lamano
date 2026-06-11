import 'dart:async';
import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

/// Servicio de walkie-talkie por grupo usando Agora RTC
/// Cada grupo tiene su propia frecuencia (canal de Agora)
class GroupRadioService {
  static const String _agoraAppId = '41b0a5f3844441c3abf9e4c5fdc2eca9';
  static const String _tokenServerUrl = 'http://38.247.147.220/lamano/api_agora_token.php';
  
  // Singleton
  static final GroupRadioService _instance = GroupRadioService._internal();
  factory GroupRadioService() => _instance;
  GroupRadioService._internal();
  
  RtcEngine? _engine;
  String? _currentChannelName;
  String? _currentUserId;
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
      if (_engine != null) return true;

      _engine = createAgoraRtcEngine();
      await _engine!.initialize(const RtcEngineContext(
        appId: _agoraAppId,
        channelProfile: ChannelProfileType.channelProfileCommunication,
      ));

      // Configuración para walkie-talkie
      await _engine!.setClientRole(role: ClientRoleType.clientRoleBroadcaster);
      await _engine!.enableAudio();
      await _engine!.setAudioProfile(
        profile: AudioProfileType.audioProfileDefault,
        scenario: AudioScenarioType.audioScenarioChatroom,
      );
      
      // Configurar altavoz según estado inicial (por defecto activado)
      await _engine!.setEnableSpeakerphone(_isSpeakerEnabled);
      
      // Empezar muteado (PTT)
      await _engine!.muteLocalAudioStream(true);

      // Registrar event handlers
      _engine!.registerEventHandler(RtcEngineEventHandler(
        onJoinChannelSuccess: (RtcConnection connection, int elapsed) {
          debugPrint('[RADIO] Conectado al canal: ${connection.channelId}');
          _isConnected = true;
          _connectionController.add(true);
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
        onAudioRoutingChanged: (int routing) {
          // Forzar configuración de altavoz si el sistema cambia la ruta
          debugPrint('[RADIO] Ruta de audio cambiada a: $routing');
          if (_isConnected && _engine != null) {
            _engine!.setEnableSpeakerphone(_isSpeakerEnabled);
          }
        },
      ));

      // Habilitar indicador de volumen
      await _engine!.enableAudioVolumeIndication(
        interval: 500,
        smooth: 3,
        reportVad: true,
      );

      return true;
    } catch (e) {
      debugPrint('[RADIO] Error inicializando Agora: $e');
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
        if (!initialized) return false;
      }

      if (_isConnected && _currentChannelName != null) {
        await disconnect();
      }

      // Canal = groupChatId sanitizado
      final channelName = groupChatId.replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '');
      
      // Obtener token de Agora
      final token = await _fetchAgoraToken(channelName, userId);
      
      _currentChannelName = channelName;
      _currentUserId = userId;

      // Unirse al canal
      final options = ChannelMediaOptions(
        channelProfile: ChannelProfileType.channelProfileCommunication,
        clientRoleType: ClientRoleType.clientRoleBroadcaster,
        autoSubscribeAudio: true,
        publishMicrophoneTrack: true,
      );

      await _engine!.joinChannel(
        token: token,
        channelId: channelName,
        uid: int.tryParse(userId.hashCode.toString()) ?? 0,
        options: options,
      );

      // CRÍTICO: Forzar configuración de altavoz después de unirse
      // Esto asegura que se escuche correctamente según la preferencia del usuario
      await Future.delayed(const Duration(milliseconds: 500));
      await _engine!.setEnableSpeakerphone(_isSpeakerEnabled);
      debugPrint('[RADIO] Audio configurado: ${_isSpeakerEnabled ? "ALTAVOZ" : "AURICULAR"}');

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

      return true;
    } catch (e) {
      debugPrint('[RADIO] Error conectando: $e');
      return false;
    }
  }

  /// Desconectar del canal
  Future<void> disconnect() async {
    try {
      if (_engine != null && _isConnected) {
        await _engine!.leaveChannel();
      }

      if (_currentChannelName != null && _currentUserId != null) {
        // Remover de Firestore
        final groupId = _currentChannelName;
        await FirebaseFirestore.instance
            .collection('groups')
            .doc(groupId)
            .collection('radio_connected')
            .doc(_currentUserId)
            .delete();
      }

      _currentChannelName = null;
      _currentUserId = null;
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
      if (_currentChannelName != null && _currentUserId != null) {
        await FirebaseFirestore.instance
            .collection('groups')
            .doc(_currentChannelName)
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
      if (_currentChannelName != null && _currentUserId != null) {
        await FirebaseFirestore.instance
            .collection('groups')
            .doc(_currentChannelName)
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
        
        if (_currentChannelName != null && _currentUserId != null) {
          await FirebaseFirestore.instance
              .collection('groups')
              .doc(_currentChannelName)
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
        
        if (_currentChannelName != null && _currentUserId != null) {
          await FirebaseFirestore.instance
              .collection('groups')
              .doc(_currentChannelName)
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

  /// Obtener token de Agora desde servidor
  Future<String> _fetchAgoraToken(String channelName, String userId) async {
    try {
      final response = await http.post(
        Uri.parse(_tokenServerUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'channel_name': channelName,
          'uid': userId.hashCode.abs(),
          'role': 'publisher',
        }),
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return (data['token'] as String?) ?? '';
      }
    } catch (e) {
      debugPrint('[RADIO] Error obteniendo token: $e');
    }
    return ''; // Token vacío = modo test (solo desarrollo)
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
