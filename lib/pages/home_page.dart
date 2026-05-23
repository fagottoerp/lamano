import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_chat_demo/constants/constants.dart';
import 'package:flutter_chat_demo/models/models.dart';
import 'package:flutter_chat_demo/pages/pages.dart';
import 'package:flutter_chat_demo/providers/providers.dart';
import 'package:flutter_chat_demo/utils/app_updater.dart';
import 'package:flutter_chat_demo/utils/foreground_gps_service.dart';
import 'package:flutter_chat_demo/utils/location_tracker.dart';

import 'package:flutter_chat_demo/utils/panic_alert_service.dart';
import 'temp_chats_page.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'shift_open_close_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State createState() => HomePageState();
}

class HomePageState extends State<HomePage> with WidgetsBindingObserver {
  final _firebaseMessaging = FirebaseMessaging.instance;
  final _flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();
  final _androidChannel = AndroidNotificationChannel(
    'flutter_chat_urgent_v2',
    'Flutter chat urgent notifications',
    description: 'Used for urgent chat message alerts with sound.',
    importance: Importance.max,
    playSound: true,
    enableVibration: true,
    showBadge: true,
  );

  // Acumulador de mensajes por remitente para agrupar notificaciones
  // clave: senderId, valor: {name, messages: List<String>, notifId: int}
  final Map<String, Map<String, dynamic>> _pendingNotifs = {};
  static const String _notifGroupKey = 'com.lamano.chat.MSG_GROUP';
  int _selectedTab = 0;
  int _orderBadge = 0;
  bool _isMotoboy = false;
  bool _isAdmin = false;
  bool _isAgente = false; // agente o ejecutivo (pueden ver Chat Temporales)
  bool _isShiftUser = false;
  bool _shiftLocked = false;
  bool _mustStartShift = false;
  bool _showingShiftDialog = false;
  int _refreshKey = 0; // increment to force home rebuild

  late final _authProvider = context.read<AuthProvider>();
  late final _homeProvider = context.read<HomeProvider>();
  late final String _currentUserId;

  final _btnClearController = StreamController<bool>();
  StreamSubscription<String>? _tokenRefreshSubscription;
  PanicAlertService? _panicAlertService;
  DateTime? _lastGpsOffAlertSentAt;

  List<MenuSetting> get _dynamicMenus => [
    if (_isShiftUser) MenuSetting(title: 'Apertura y cierre', icon: Icons.manage_history),
    MenuSetting(title: 'Actualizar app', icon: Icons.system_update_alt),
    MenuSetting(title: 'Configuración', icon: Icons.settings),
    MenuSetting(title: 'Cerrar sesión', icon: Icons.exit_to_app),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (_authProvider.userFirebaseId?.isNotEmpty == true) {
      _currentUserId = _authProvider.userFirebaseId!;
      _setUserPresence(true);
    } else {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => LoginPage()),
        (_) => false,
      );
    }
    _registerNotification();
    _configLocalNotification();
    final role = _authProvider.prefs.getString(FirestoreConstants.aboutMe) ?? '';
    final rolId = _authProvider.prefs.getString(FirestoreConstants.rolId) ?? '';
    final lamanoUserId = _authProvider.prefs.getString(FirestoreConstants.lamanoUserId) ?? '';
    _isMotoboy = role.toLowerCase().contains('motoboy');
    _isAdmin = rolId == '1' ||
      role.toLowerCase().contains('admin') ||
      _currentUserId == AppConstants.adminFirebaseUid;
    _isAgente = role.toLowerCase() == 'agente' || role.toLowerCase() == 'ejecutivo' || role.toLowerCase() == 'asociado' || _isAdmin;
    _isShiftUser = lamanoUserId == '106';

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      AppUpdater.checkAndUpdate(context);
      // Start continuous GPS tracking for admin panel
      final nickname = _authProvider.prefs.getString(FirestoreConstants.nickname) ?? 'Usuario';
      LocationTracker.instance.start(_currentUserId, nickname);
      startForegroundGps(_currentUserId, nickname);
      _checkGpsGate();
      if (_isShiftUser) {
        _checkShiftLock();
      }
      // Start panic alert listener (volume buttons)
      final panicNickname = _authProvider.prefs.getString(FirestoreConstants.nickname) ?? 'Usuario';
      _panicAlertService = PanicAlertService(
        userId: _currentUserId,
        userName: panicNickname,
        localNotif: _flutterLocalNotificationsPlugin,
      );
      _panicAlertService!.start();
    });
  }

  void _registerNotification() {
    _firebaseMessaging.requestPermission(
      alert: true,
      announcement: false,
      badge: true,
      carPlay: false,
      criticalAlert: false,
      provisional: false,
      sound: true,
    ).then((settings) {
      print('notification permission status: ${settings.authorizationStatus}');
    });

    _firebaseMessaging.setForegroundNotificationPresentationOptions(
      alert: true,
      badge: true,
      sound: true,
    );

    FirebaseMessaging.onMessage.listen((message) {
      print('onMessage: $message');
      final sentAtRaw = message.data['sentAtMs'];
      final dispatchedAtRaw = message.data['dispatchedAtMs'];
      final sentAtMs = int.tryParse(sentAtRaw?.toString() ?? '');
      final dispatchedAtMs = int.tryParse(dispatchedAtRaw?.toString() ?? '');
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      if (sentAtMs != null) {
        print('push_latency_total_ms: ${nowMs - sentAtMs}');
      }
      if (dispatchedAtMs != null) {
        print('push_latency_fcm_ms: ${nowMs - dispatchedAtMs}');
      }

      // ── Incoming call push while app is in FOREGROUND ───────────────────
      if (message.data['type'] == 'incoming_call') {
        _showIncomingCallScreen(
          roomName:   message.data['room_name']   ?? '',
          callerName: message.data['caller_name'] ?? 'Alguien',
          callerUid:  message.data['caller_uid']  ?? '',
          isVideo:    message.data['is_video']    == 'true',
        );
        return;
      }

      if (message.notification != null) {
        final idFrom = message.data['idFrom'] ?? '';
        final groupChatId = message.data['groupChatId'] ?? '';
        final senderName = message.data['senderName'] as String? ?? '';
        // If from admin → it's an order notification → increment badge on Mis Órdenes tab
        if (_isMotoboy && idFrom == AppConstants.adminFirebaseUid && _selectedTab != 3) {
          setState(() => _orderBadge++);
        }
        _showNotificationWithPayload(
          message.notification!,
          '$idFrom|$groupChatId|$senderName',
          senderName: senderName,
          // En grupos: agrupar por groupChatId. En chats 1:1: agrupar por idFrom.
          senderId: groupChatId.isNotEmpty ? groupChatId : idFrom,
        );
      }
      return;
    });

    _syncPushToken();

    _tokenRefreshSubscription?.cancel();
    _tokenRefreshSubscription = _firebaseMessaging.onTokenRefresh.listen((token) {
      print('push token refreshed: $token');
      _homeProvider.updateDataFirestore(
        FirestoreConstants.pathUserCollection,
        _currentUserId,
        {'pushToken': token},
      );
    });
  }

  Future<void> _syncPushToken() async {
    try {
      final token = await _firebaseMessaging.getToken();
      print('push token sync: $token');
      if (token != null && token.isNotEmpty) {
        await _homeProvider.updateDataFirestore(
          FirestoreConstants.pathUserCollection,
          _currentUserId,
          {'pushToken': token},
        );
      }
    } catch (err) {
      final msg = err.toString();
      // On iOS sideload/no-signing builds APNS token may be unavailable.
      // Suppress this non-critical warning to avoid noisy toast in production UI.
      if (Platform.isIOS &&
          (msg.contains('apns-token-not-set') ||
              msg.contains('APNS token has not been set'))) {
        print('push token skipped on iOS (APNS unavailable): $msg');
        return;
      }
      Fluttertoast.showToast(msg: msg);
    }
  }

  void _configLocalNotification() {
    final initializationSettingsAndroid = AndroidInitializationSettings('app_icon');
    final initializationSettingsIOS = DarwinInitializationSettings();
    final initializationSettings = InitializationSettings(
      android: initializationSettingsAndroid,
      iOS: initializationSettingsIOS,
    );
    _flutterLocalNotificationsPlugin.initialize(
      settings: initializationSettings,
      onDidReceiveNotificationResponse: (NotificationResponse response) {
        final payload = response.payload ?? '';
        if (payload.startsWith('call|')) {
          final parts = payload.split('|');
          if (parts.length >= 4) {
            final roomName   = parts[1];
            final callerName = parts[2];
            final isVideo    = parts[3] == '1';
            if (response.actionId == 'accept' || response.actionId == null) {
              _showIncomingCallScreen(
                roomName: roomName, callerName: callerName,
                callerUid: '', isVideo: isVideo,
              );
            }
          }
          return;
        }
        if (payload.isNotEmpty) _navigateToChatFromPayload(payload);
      },
    );

      _flutterLocalNotificationsPlugin
        .resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()
        ?.requestPermissions(alert: true, badge: true, sound: true);

      _flutterLocalNotificationsPlugin
        .resolvePlatformSpecificImplementation<MacOSFlutterLocalNotificationsPlugin>()
        ?.requestPermissions(alert: true, badge: true, sound: true);
    _flutterLocalNotificationsPlugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(_androidChannel);

    // Create incoming-call notification channel
    const callChannel = AndroidNotificationChannel(
      'incoming_call_v1',
      'Llamadas entrantes',
      description: 'Notificaciones de llamadas entrantes',
      importance: Importance.max,
      playSound: true,
      enableVibration: true,
    );
    _flutterLocalNotificationsPlugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(callChannel);

    // Handle notification tap when app was in background (notification tray)
    FirebaseMessaging.onMessageOpenedApp.listen((message) {
      if (message.data['type'] == 'incoming_call') {
        _showIncomingCallScreen(
          roomName:   message.data['room_name']   ?? '',
          callerName: message.data['caller_name'] ?? 'Alguien',
          callerUid:  message.data['caller_uid']  ?? '',
          isVideo:    message.data['is_video']    == 'true',
        );
        return;
      }
      final idFrom = message.data['idFrom'] ?? '';
      final groupChatId = message.data['groupChatId'] ?? '';
      final senderName = message.data['senderName'] as String? ?? '';
      if (idFrom.isNotEmpty && groupChatId.isNotEmpty) {
        _navigateToChatFromPayload('$idFrom|$groupChatId|$senderName');
      }
    });

    // Handle notification tap when app was TERMINATED
    FirebaseMessaging.instance.getInitialMessage().then((message) {
      if (message == null) return;
      if (message.data['type'] == 'incoming_call') {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _showIncomingCallScreen(
            roomName:   message.data['room_name']   ?? '',
            callerName: message.data['caller_name'] ?? 'Alguien',
            callerUid:  message.data['caller_uid']  ?? '',
            isVideo:    message.data['is_video']    == 'true',
          );
        });
      }
    });

  }

  void _showIncomingCallScreen({
    required String roomName,
    required String callerName,
    required String callerUid,
    required bool isVideo,
  }) {
    if (!mounted || roomName.isEmpty) return;
    // Cancel ongoing call notification if any
    _flutterLocalNotificationsPlugin.cancel(id: 9999);
    // Limpiar acumulador de notificaciones (el usuario abrió la app)
    _pendingNotifs.clear();
    _flutterLocalNotificationsPlugin.cancelAll();
    Navigator.of(context).push(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => IncomingCallPage(
        args: IncomingCallArgs(
          roomName:   roomName,
          callerName: callerName,
          callerUid:  callerUid,
          isVideo:    isVideo,
        ),
      ),
    ));
  }

  void _navigateToChatFromPayload(String payload) {
    // payload format: "idFrom|groupChatId|senderName"
    final parts = payload.split('|');
    if (parts.length < 2) return;
    final peerId = parts[0];
    final groupChatId = parts[1];
    final senderName = parts.length > 2 ? parts[2] : '';
    if (peerId.isEmpty || peerId == _currentUserId) return;

    // Detect group notification: group IDs are Firestore auto-IDs (no '-').
    // 1-on-1 IDs are always "uid-uid" (contain '-').
    // Order chats start with "order-" — also open as 1-on-1 (ChatPage).
    final isGroup = groupChatId.isNotEmpty &&
        !groupChatId.contains('-') &&
        !groupChatId.startsWith('order-');

    if (isGroup) {
      // Look up group name then open GroupChatPage
      FirebaseFirestore.instance.collection('groups').doc(groupChatId).get().then((snap) {
        if (!mounted) return;
        final groupName = snap.exists
            ? (snap.data()?['name'] as String? ?? 'Grupo')
            : 'Grupo';
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => GroupChatPage(
              arguments: GroupChatArguments(
                groupId: groupChatId,
                groupName: groupName,
              ),
            ),
          ),
        );
      }).catchError((_) {});
      return;
    }

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatPage(
          arguments: ChatPageArguments(
            peerId: peerId,
            peerAvatar: '',
            peerNickname: senderName.isNotEmpty ? senderName : 'Chat',
            customGroupChatId: groupChatId.isNotEmpty ? groupChatId : null,
          ),
        ),
      ),
    );
  }

  void _onItemMenuPress(MenuSetting choice) {
    if (choice.title == 'Apertura y cierre') {
      final lamanoUserId = _authProvider.prefs.getString(FirestoreConstants.lamanoUserId) ?? '';
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ShiftOpenClosePage(
            lamanoUserId: lamanoUserId,
            onStatusChanged: _checkShiftLock,
          ),
        ),
      );
    } else if (choice.title == 'Actualizar app') {
      AppUpdater.checkAndUpdate(context, force: true, showUpToDate: true);
    } else if (choice.title == 'Cerrar sesión') {
      _handleSignOut();
    } else {
      Navigator.push(context, MaterialPageRoute(builder: (_) => SettingsPage()));
    }
  }

  Future<void> _checkShiftLock() async {
    if (!_isShiftUser || !mounted) return;
    try {
      final lamanoUserId = _authProvider.prefs.getString(FirestoreConstants.lamanoUserId) ?? '';
      if (lamanoUserId.isEmpty) return;
      final uri = Uri.parse('http://38.247.147.220/lamano/api_shift_status.php?user_id=$lamanoUserId');
      final resp = await http.get(uri).timeout(const Duration(seconds: 12));
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      if (!mounted) return;
      final locked = data['lock_required'] == true;
      final todayStarted = data['today_started'] == true;
      final mustStart = !todayStarted;
      setState(() {
        _shiftLocked = locked;
        _mustStartShift = mustStart;
      });
      if (mustStart || locked) {
        _showShiftLockDialog(lamanoUserId, mustStart: mustStart);
      }
    } catch (_) {}
  }

  void _showShiftLockDialog(String lamanoUserId, {bool mustStart = false}) {
    if (!mounted) return;
    if (_showingShiftDialog) return;
    _showingShiftDialog = true;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: Text(mustStart ? 'Inicio de turno requerido' : 'Cierre pendiente'),
        content: Text(mustStart
            ? 'Debes iniciar turno para poder navegar en la aplicación.'
            : 'Debes cerrar el turno anterior para seguir usando el sistema.'),
        actions: [
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ShiftOpenClosePage(
                    lamanoUserId: lamanoUserId,
                    onStatusChanged: _checkShiftLock,
                  ),
                ),
              );
            },
            child: const Text('Ir a Apertura/Cierre'),
          ),
        ],
      ),
    ).whenComplete(() {
      _showingShiftDialog = false;
    });
  }

  void _showNotificationWithPayload(RemoteNotification remoteNotification, String payload, {String senderName = '', String senderId = ''}) async {
    final displayTitle = senderName.isNotEmpty ? senderName : (remoteNotification.title ?? 'La Mano');
    final displayBody = remoteNotification.body ?? '';
    final isGroup = senderId.isNotEmpty && senderId != (senderId.contains('|') ? '' : senderId) || senderId.length > 28;
    // En grupos mostramos "Nombre: mensaje", en 1:1 solo el mensaje
    final notifTitle = remoteNotification.title ?? displayTitle;
    final bodyLine = (senderName.isNotEmpty && notifTitle != senderName)
        ? '$senderName: $displayBody'  // grupo: "Juan: hola"
        : displayBody;                  // 1:1: solo el mensaje
    final key = senderId.isNotEmpty ? senderId : displayTitle;

    // Acumular mensajes de este remitente
    if (!_pendingNotifs.containsKey(key)) {
      _pendingNotifs[key] = {
        'name': displayTitle,
        'messages': <String>[],
        'notifId': key.hashCode.abs() % 100000 + 1,
      };
    }
    (_pendingNotifs[key]!['messages'] as List<String>).add(bodyLine);

    final msgs = _pendingNotifs[key]!['messages'] as List<String>;
    final notifId = _pendingNotifs[key]!['notifId'] as int;
    final count = msgs.length;

    // Notificación individual del remitente (InboxStyle con todos sus mensajes)
    final inboxStyle = InboxStyleInformation(
      msgs,
      contentTitle: displayTitle,
      summaryText: count > 1 ? '$count mensajes' : null,
    );

    final androidDetails = AndroidNotificationDetails(
      _androidChannel.id,
      _androidChannel.name,
      channelDescription: _androidChannel.description,
      playSound: true,
      enableVibration: true,
      importance: Importance.max,
      priority: Priority.high,
      category: AndroidNotificationCategory.message,
      ticker: 'Nuevo mensaje',
      styleInformation: inboxStyle,
      groupKey: _notifGroupKey,
      setAsGroupSummary: false,
    );

    await _flutterLocalNotificationsPlugin.show(
      id: notifId,
      title: displayTitle,
      body: count > 1 ? '$count mensajes nuevos' : bodyLine,
      notificationDetails: NotificationDetails(
        android: androidDetails,
        iOS: const DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
          sound: 'default',
        ),
      ),
      payload: payload,
    );

    // Notificación resumen del grupo (agrupa todas en el panel de notificaciones)
    final totalMsgs = _pendingNotifs.values.fold<int>(
      0, (sum, v) => sum + (v['messages'] as List<String>).length,
    );
    final totalConvs = _pendingNotifs.length;

    final summaryDetails = AndroidNotificationDetails(
      _androidChannel.id,
      _androidChannel.name,
      channelDescription: _androidChannel.description,
      importance: Importance.min,
      priority: Priority.low,
      groupKey: _notifGroupKey,
      setAsGroupSummary: true,
      styleInformation: InboxStyleInformation(
        _pendingNotifs.entries.map((e) => '${e.value['name']}: ${(e.value['messages'] as List<String>).last}').toList(),
        contentTitle: 'La Mano',
        summaryText: '$totalMsgs mensajes de $totalConvs conversación${totalConvs > 1 ? 'es' : ''}',
      ),
    );

    await _flutterLocalNotificationsPlugin.show(
      id: 0, // ID fijo para el resumen
      title: 'La Mano',
      body: '$totalMsgs mensajes nuevos',
      notificationDetails: NotificationDetails(
        android: summaryDetails,
        iOS: const DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
          sound: 'default',
        ),
      ),
    );
  }

  Future<void> _handleSignOut() async {
    await _setUserPresence(false);
    await _authProvider.handleSignOut();
    await Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => LoginPage()),
      (_) => false,
    );
  }

  Future<void> _setUserPresence(bool isOnline) async {
    if (_authProvider.userFirebaseId?.isNotEmpty != true) return;
    try {
      await _homeProvider.updateDataFirestore(
        FirestoreConstants.pathUserCollection,
        _currentUserId,
        {
          FirestoreConstants.isOnline: isOnline,
          FirestoreConstants.lastSeen: DateTime.now().millisecondsSinceEpoch,
        },
      );
    } catch (_) {}
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_authProvider.userFirebaseId?.isNotEmpty != true) return;
    switch (state) {
      case AppLifecycleState.resumed:
        _setUserPresence(true);
        _syncPushToken();
        _checkGpsGate();
        break;
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        _setUserPresence(false);
        break;
    }
  }

  Future<void> _checkGpsGate() async {
    if (!mounted) return;
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (serviceEnabled) {
      final perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.always ||
          perm == LocationPermission.whileInUse) {
        return; // GPS OK
      }
    }
    await _notifyGpsDisabled();
    if (!mounted) return;
    // Show non-dismissible dialog
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => WillPopScope(
        onWillPop: () async => false,
        child: AlertDialog(
          backgroundColor: const Color(0xFF1A1A2E),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Row(
            children: [
              Text('📍 ', style: TextStyle(fontSize: 24)),
              Text('GPS Requerido',
                  style: TextStyle(
                      color: Colors.greenAccent,
                      fontWeight: FontWeight.bold)),
            ],
          ),
          content: const Text(
            'La Mano requiere acceso a tu ubicación GPS para funcionar.\n\nActiva el GPS y concede el permiso para continuar.',
            style: TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(
              onPressed: () async {
                final perm = await Geolocator.checkPermission();
                if (perm == LocationPermission.denied) {
                  await Geolocator.requestPermission();
                } else {
                  await Geolocator.openLocationSettings();
                }
                if (context.mounted) Navigator.of(context).pop();
              },
              child: const Text('Activar GPS',
                  style: TextStyle(
                      color: Colors.greenAccent,
                      fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _notifyGpsDisabled() async {
    final now = DateTime.now();
    if (_lastGpsOffAlertSentAt != null && now.difference(_lastGpsOffAlertSentAt!).inMinutes < 5) {
      return;
    }

    final lamanoUserId = _authProvider.prefs.getString(FirestoreConstants.lamanoUserId) ?? '';
    if (lamanoUserId.isEmpty) return;

    final nickname = _authProvider.prefs.getString(FirestoreConstants.nickname) ?? 'Usuario';

    try {
      await http.post(
        Uri.parse('http://38.247.147.220/lamano/api_gps_off_alert.php'),
        body: {
          'user_id': lamanoUserId,
          'user_name': nickname,
        },
      ).timeout(const Duration(seconds: 10));
      _lastGpsOffAlertSentAt = now;
    } catch (_) {
      // best-effort only
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isShiftUser && _mustStartShift) {
      final lamanoUserId = _authProvider.prefs.getString(FirestoreConstants.lamanoUserId) ?? '';
      return Scaffold(
        appBar: AppBar(
          title: const Text('Inicio de turno requerido', style: TextStyle(color: ColorConstants.primaryColor)),
          centerTitle: true,
        ),
        body: ShiftOpenClosePage(
          lamanoUserId: lamanoUserId,
          onStatusChanged: _checkShiftLock,
        ),
      );
    }

    final appBarTitles = _isMotoboy
        ? ['Inicio', 'Estados', 'Chats', 'Mis Órdenes']
        : _isAgente
            ? ['Inicio', 'Estados', 'Chats', 'Chat Temporales']
            : ['Inicio', 'Estados', 'Chats'];
    return Scaffold(
      appBar: AppBar(
        title: Text(
          appBarTitles[_selectedTab],
          style: TextStyle(color: ColorConstants.primaryColor),
        ),
        centerTitle: true,
        actions: [
          if (_isShiftUser && _shiftLocked)
            const Padding(
              padding: EdgeInsets.only(right: 8),
              child: Center(
                child: Icon(Icons.lock_clock, color: Colors.redAccent),
              ),
            ),
          // ── Refresh button (Inicio tab only) ──
          if (_selectedTab == 0)
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Refrescar',
              onPressed: () => setState(() => _refreshKey++),
            ),
          if (_isAdmin)
            IconButton(
              icon: const Icon(Icons.my_location, color: Color(0xFF1565C0)),
              tooltip: 'GPS Vivo',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const GpsVivoPage()),
              ),
            ),
          if (_isAdmin)
            IconButton(
              icon: const Icon(Icons.group_add_outlined),
              tooltip: 'Administrar grupos',
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const AdminGroupManagePage()),
              ),
            ),
          IconButton(
            icon: const Icon(Icons.people_outline),
            tooltip: 'Contactos',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const ContactsPage()),
            ),
          ),
          _buildPopupMenu(),
        ],
      ),
      body: _isMotoboy
          ? IndexedStack(
              index: _selectedTab,
              children: [
                _buildHomeBody(),
                _buildStoriesTab(),
                const RecentChatsPage(),
                const MotoboOrdersPage(),
              ],
            )
          : _isAgente
              ? IndexedStack(
                  index: _selectedTab,
                  children: [
                    _buildHomeBody(),
                    _buildStoriesTab(),
                    const RecentChatsPage(),
                    const TempChatsPage(),
                  ],
                )
              : IndexedStack(
                  index: _selectedTab,
                  children: [
                    _buildHomeBody(),
                    _buildStoriesTab(),
                    const RecentChatsPage(),
                  ],
                ),
      bottomNavigationBar: _buildBottomNav(),
    );
  }

  Widget _buildBottomNav() {
    final items = [
      {'icon': Icons.home_outlined, 'active': Icons.home, 'label': 'Inicio'},
      {'icon': Icons.auto_awesome_outlined, 'active': Icons.auto_awesome, 'label': 'Estados'},
      {'icon': Icons.chat_bubble_outline, 'active': Icons.chat_bubble, 'label': 'Chats'},
      if (_isAgente) {'icon': Icons.forum_outlined, 'active': Icons.forum, 'label': 'Chat Temp.'},
      if (_isMotoboy) {'icon': Icons.delivery_dining_outlined, 'active': Icons.delivery_dining, 'label': 'Mis Órdenes'},
    ];

    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          decoration: const BoxDecoration(
            color: ColorConstants.cardWhite,
            border: Border(top: BorderSide(color: ColorConstants.divider, width: 1)),
          ),
          child: SafeArea(
            top: false,
            child: SizedBox(
              height: 60,
              child: Row(
                children: List.generate(items.length, (i) {
                  final item = items[i];
                  final isActive = _selectedTab == i;
                  final badgeCount = (_isMotoboy && i == items.length - 1) ? _orderBadge : 0;
                  return Expanded(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () {
                        if (_isShiftUser && _mustStartShift) {
                          final lamanoUserId = _authProvider.prefs.getString(FirestoreConstants.lamanoUserId) ?? '';
                          _showShiftLockDialog(lamanoUserId, mustStart: true);
                          return;
                        }
                        setState(() {
                          _selectedTab = i;
                          if (_isMotoboy && i == items.length - 1) _orderBadge = 0;
                        });
                      },
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // Active indicator dot
                            AnimatedContainer(
                              duration: const Duration(milliseconds: 200),
                              width: isActive ? 20 : 0,
                              height: 3,
                              margin: const EdgeInsets.only(bottom: 4),
                              decoration: BoxDecoration(
                                color: ColorConstants.themeColor,
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                            Stack(
                              clipBehavior: Clip.none,
                              children: [
                                Icon(
                                  isActive
                                      ? item['active'] as IconData
                                      : item['icon'] as IconData,
                                  color: isActive
                                      ? ColorConstants.themeColor
                                      : ColorConstants.greyColor,
                                  size: 22,
                                ),
                                if (badgeCount > 0)
                                  Positioned(
                                    top: -4,
                                    right: -8,
                                    child: Container(
                                      padding: const EdgeInsets.all(3),
                                      decoration: const BoxDecoration(
                                        color: Colors.red,
                                        shape: BoxShape.circle,
                                      ),
                                      constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
                                      child: Text(
                                        '$badgeCount',
                                        style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold),
                                        textAlign: TextAlign.center,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 2),
                            Text(
                              item['label'] as String,
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
                                color: isActive ? ColorConstants.themeColor : ColorConstants.greyColor,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                }),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// -------------------------------------------------------
  ///  CHANGELOG MODAL
  /// -------------------------------------------------------
  void _showChangelogModal() {
    final changelog = [
      _ChangelogEntry(
        version: 'v3.10.10',
        date: 'Mayo 2026',
        items: [
          '🔔 Notificaciones push en grupos (igual que chats 1 a 1)',
          '🟢 Badges de no leídos estilo WhatsApp en lista de grupos',
          '💰 Dashboard: panel "Facturado" reemplaza "Otros pagos" (suma total + delivery de entregadas)',
          '📸 Finalizar orden ahora exige motoboy asignado + foto/comprobante subido',
          '💳 Crédito se descuenta al crear la orden (con re-chequeo anti-carrera) y se restaura al cancelar/anular',
          '🛠️ Estabilidad y correcciones varias',
        ],
      ),
      _ChangelogEntry(
        version: 'v3.9.0',
        date: 'Mayo 2026',
        items: [
          '🗺️ GPS Vivo en grupos — todos los miembros visibles en el mapa',
          '📞 Videollamadas y llamadas grupales Jitsi',
          '🛡️ Panel admin: mapa GPS en tiempo real de todos los usuarios',
          '📍 Localización de fondo siempre activa',
          '📋 Registro de cambios (esto que estás leyendo)',
        ],
      ),
      _ChangelogEntry(
        version: 'v3.8.0',
        date: 'Mayo 2026',
        items: [
          '📞 Llamadas anónimas Twilio para TODOS los usuarios',
          '🎨 Rediseño oscuro / deep-web (La Mano)',
          '💬 Notificación de llamada entrante en el chat',
          '🟢 Icono y splash screen de La Mano',
        ],
      ),
      _ChangelogEntry(
        version: 'v3.7.0',
        date: 'Abril 2026',
        items: [
          '📹 Videollamadas Jitsi auto-alojadas',
          '🔇 Llamadas de audio Jitsi',
          '🗺️ GPS en tiempo real en grupos',
          '📦 Motoboys: llamadas anónimas Twilio',
        ],
      ),
    ];

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.8),
        decoration: const BoxDecoration(
          color: ColorConstants.cardWhite,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          border: Border(top: BorderSide(color: ColorConstants.primaryColor, width: 2)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: ColorConstants.primaryColor,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 16),
            const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.terminal, color: Color(0xFF00E65A), size: 20),
                SizedBox(width: 8),
                Text(
                  'LA MANO — Registro de cambios',
                  style: TextStyle(
                    color: Color(0xFF00E65A),
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 2,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Divider(color: Color(0xFF1A4A2A)),
            Flexible(
              child: ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: changelog.length,
                itemBuilder: (_, i) {
                  final entry = changelog[i];
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                            decoration: BoxDecoration(
                              color: const Color(0xFF00E65A),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              entry.version,
                              style: const TextStyle(
                                  color: Colors.black,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            entry.date,
                            style: const TextStyle(color: Color(0xFF5A8A6A), fontSize: 12),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      ...entry.items.map((item) => Padding(
                            padding: const EdgeInsets.only(bottom: 5, left: 4),
                            child: Text(
                              item,
                              style: const TextStyle(color: Color(0xFFCCFFDD), fontSize: 13),
                            ),
                          )),
                      const SizedBox(height: 16),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// -------------------------------------------------------
  ///  HOME BODY — Noticias + Grupos
  /// -------------------------------------------------------
  Widget _buildHomeBody() {
    return Container(
      color: ColorConstants.bgApp,
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(14),
          children: [
            // ── Chip changelog ────────────────────────────────
            Align(
              alignment: Alignment.centerRight,
              child: GestureDetector(
                onTap: _showChangelogModal,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: ColorConstants.surfaceLight,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: ColorConstants.primaryColor, width: 1),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.android, color: ColorConstants.primaryColor, size: 14),
                      SizedBox(width: 4),
                      Text('APK La Mano · Beta',
                          style: TextStyle(
                              color: ColorConstants.primaryColor,
                              fontSize: 11,
                              fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),

            // ── Burbujas de estados ───────────────────────────
            _buildStatusBubblesRow(),
            const SizedBox(height: 16),

            // ── Grupos ────────────────────────────────────────
            Row(
              children: const [
                Icon(Icons.group_outlined, color: ColorConstants.themeColor, size: 18),
                SizedBox(width: 6),
                Text('Grupos',
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: ColorConstants.textPrimary,
                        letterSpacing: 0.3)),
              ],
            ),
            const SizedBox(height: 10),
            _buildGroupsSection(),

            // ── Panel alertas de pánico (solo admin, debajo de grupos) ──
            if (_isAdmin) ...[const SizedBox(height: 16), _buildPanicAlertsSection()],
          ],
        ),
      ),
    );
  }

  Widget _buildStoriesTab() {
    return SafeArea(
      child: StoriesPage(
        currentUserId: _currentUserId,
        currentNickname: _authProvider.prefs.getString(FirestoreConstants.nickname) ?? 'Usuario',
      ),
    );
  }

  Widget _buildStatusBubblesRow() {
    final now = DateTime.now().millisecondsSinceEpoch;
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('stories')
          .where('expiresAt', isGreaterThan: now)
          .orderBy('expiresAt', descending: true)
          .snapshots(),
      builder: (_, snap) {
        // Agrupar: mis stories + otros usuarios (max 4)
        List<QueryDocumentSnapshot> myStoriesDocs = [];
        final Map<String, Map<String, dynamic>> byUser = {};
        if (snap.hasData) {
          for (final doc in snap.data!.docs) {
            final d = doc.data() as Map<String, dynamic>;
            final uid = d['userId'] as String? ?? '';
            if (uid == _currentUserId) {
              myStoriesDocs.add(doc);
            } else {
              byUser.putIfAbsent(uid, () => d);
            }
          }
        }

        final entries = byUser.entries.take(4).toList();
        final hasAnyStory = myStoriesDocs.isNotEmpty || entries.isNotEmpty;

        if (!hasAnyStory) {
          // Sin estados: botón de subir
          return GestureDetector(
            onTap: () => setState(() => _selectedTab = 1),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: ColorConstants.surfaceLight,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: ColorConstants.divider),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: const [
                  Icon(Icons.add_circle_outline, color: ColorConstants.themeColor, size: 20),
                  SizedBox(width: 8),
                  Text('Subir estado', style: TextStyle(color: ColorConstants.themeColor, fontWeight: FontWeight.w600, fontSize: 13)),
                ],
              ),
            ),
          );
        }

        return SizedBox(
          height: 84,
          child: Row(
            children: [
              // Burbuja "Mi estado" — anillo verde si tengo stories, "+" si no
              GestureDetector(
                onTap: () {
                  if (myStoriesDocs.isNotEmpty) {
                    Navigator.push(context, MaterialPageRoute(
                      builder: (_) => StoryViewPage(stories: myStoriesDocs, currentUserId: _currentUserId),
                    ));
                  } else {
                    setState(() => _selectedTab = 1);
                  }
                },
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      width: 52,
                      height: 52,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: myStoriesDocs.isNotEmpty
                            ? const LinearGradient(
                                colors: [Color(0xFF00E65A), Color(0xFF00B347)],
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight)
                            : null,
                        border: myStoriesDocs.isEmpty
                            ? Border.all(color: ColorConstants.divider, width: 1.5)
                            : null,
                        color: myStoriesDocs.isEmpty ? ColorConstants.surfaceLight : null,
                      ),
                      padding: const EdgeInsets.all(2.5),
                      child: CircleAvatar(
                        backgroundColor: ColorConstants.primaryColor.withOpacity(0.15),
                        child: myStoriesDocs.isEmpty
                            ? const Icon(Icons.add, color: ColorConstants.themeColor, size: 22)
                            : Text(
                                (_authProvider.prefs.getString(FirestoreConstants.nickname) ?? 'Y').isNotEmpty
                                    ? (_authProvider.prefs.getString(FirestoreConstants.nickname) ?? 'Y')[0].toUpperCase()
                                    : 'Y',
                                style: const TextStyle(color: ColorConstants.primaryColor, fontWeight: FontWeight.bold, fontSize: 18)),
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text('Mi estado', style: TextStyle(fontSize: 10, color: ColorConstants.greyColor)),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              // Burbujas de usuarios con estados
              ...entries.map((e) {
                final uid = e.key;
                final data = e.value;
                final nickname = data['nickname'] as String? ?? 'Usuario';
                final allDocs = snap.data!.docs.where((d) => (d.data() as Map)['userId'] == uid).toList();
                final allViewed = allDocs.every((d) {
                  final views = (d.data() as Map)['views'] as List? ?? [];
                  return views.contains(_currentUserId);
                });
                // Get avatar from users collection via StreamBuilder would be complex;
                // use initials avatar instead
                final initials = nickname.isNotEmpty ? nickname[0].toUpperCase() : '?';
                return Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: GestureDetector(
                    onTap: () {
                      Navigator.push(context, MaterialPageRoute(
                        builder: (_) => StoryViewPage(stories: allDocs, currentUserId: _currentUserId),
                      ));
                    },
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          width: 52,
                          height: 52,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: allViewed
                                ? null
                                : const LinearGradient(
                                    colors: [Color(0xFF00E65A), Color(0xFF00B347)],
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight),
                            border: allViewed
                                ? Border.all(color: ColorConstants.greyColor, width: 2)
                                : null,
                            color: allViewed ? ColorConstants.surfaceLight : null,
                          ),
                          padding: const EdgeInsets.all(2.5),
                          child: CircleAvatar(
                            backgroundColor: ColorConstants.primaryColor.withOpacity(0.15),
                            child: Text(initials,
                                style: const TextStyle(
                                    color: ColorConstants.primaryColor,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 18)),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          nickname.length > 7 ? '${nickname.substring(0, 6)}…' : nickname,
                          style: const TextStyle(fontSize: 10, color: ColorConstants.textPrimary),
                        ),
                      ],
                    ),
                  ),
                );
              }),
            ],
          ),
        );
      },
    );
  }

  Widget _buildStoriesSection() {
    return SizedBox(
      height: 96,
      child: StoriesPage(
        currentUserId: _currentUserId,
        currentNickname: _authProvider.prefs.getString(FirestoreConstants.nickname) ?? 'Usuario',
      ),
    );
  }

  Widget _buildAnnouncementsSection() {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('announcements')
          .orderBy('timestamp', descending: true)
          .limit(20)
          .snapshots(),
      builder: (_, snapshot) {
        if (!snapshot.hasData) {
          return const Center(
              child: CircularProgressIndicator(color: ColorConstants.themeColor));
        }
        final docs = snapshot.data!.docs;
        if (docs.isEmpty) {
          return Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
                color: ColorConstants.greyColor2,
                borderRadius: BorderRadius.circular(12)),
            child: const Text(
              'No hay anuncios por ahora.\nLos administradores publicarán noticias aquí.',
              style: TextStyle(color: ColorConstants.greyColor, fontSize: 13),
              textAlign: TextAlign.center,
            ),
          );
        }
        return Column(
          children: docs.map((doc) {
            final data = doc.data() as Map<String, dynamic>;
            final title = data['title'] as String? ?? '';
            final body = data['body'] as String? ?? '';
            final ts = data['timestamp'] as int? ?? 0;
            final author = data['authorName'] as String? ?? '';
            final pinned = data['pinned'] as bool? ?? false;
            final date = ts > 0
                ? DateTime.fromMillisecondsSinceEpoch(ts)
                : null;
            return Card(
              margin: const EdgeInsets.only(bottom: 10),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              elevation: pinned ? 3 : 1,
              child: ListTile(
                leading: Icon(
                    pinned ? Icons.push_pin : Icons.article_outlined,
                    color: pinned ? Colors.orange : ColorConstants.primaryColor),
                title: Text(title,
                    style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        color: ColorConstants.primaryColor)),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (body.isNotEmpty) Text(body, maxLines: 3, overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 4),
                    Text(
                      '${author.isNotEmpty ? '$author · ' : ''}${date != null ? '${date.day}/${date.month}/${date.year}' : ''}',
                      style: const TextStyle(fontSize: 11, color: ColorConstants.greyColor),
                    ),
                  ],
                ),
                isThreeLine: true,
              ),
            );
          }).toList(),
        );
      },
    );
  }

  // ── Panel de alertas de pánico ────────────────────────────────────────────
  Widget _buildPanicAlertsSection() {
    return KeyedSubtree(
      key: ValueKey('panic_$_refreshKey'),
      child: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('panic_alerts')
            .orderBy('timestamp', descending: true)
            .limit(20)
            .snapshots(),
        builder: (_, snapshot) {
          final docs = snapshot.data?.docs ?? [];

          return Container(
            decoration: BoxDecoration(
              color: const Color(0xFF1A0A0A),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.red.shade800, width: 1.5),
            ),
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header
                Row(
                  children: [
                    const Icon(Icons.warning_amber_rounded, color: Colors.redAccent, size: 20),
                    const SizedBox(width: 6),
                    const Expanded(
                      child: Text(
                        'ALERTAS DE EMERGENCIA',
                        style: TextStyle(
                          color: Colors.redAccent,
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                          letterSpacing: 1,
                        ),
                      ),
                    ),
                    if (docs.isNotEmpty)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.red,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          '${docs.length}',
                          style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                        ),
                      ),
                  ],
                ),
                const Divider(color: Colors.red, height: 14),

                if (!snapshot.hasData)
                  const Center(child: Padding(
                    padding: EdgeInsets.all(8),
                    child: CircularProgressIndicator(color: Colors.red, strokeWidth: 2),
                  ))
                else if (docs.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      '✅  Sin alertas activas',
                      style: TextStyle(color: Colors.white54, fontSize: 13),
                    ),
                  )
                else
                  ...docs.map((doc) {
                    final data = doc.data() as Map<String, dynamic>;
                    final type = data['type'] as String? ?? '';
                    final userName = data['userName'] as String? ?? 'Usuario';
                    final ts = data['timestamp'] as int? ?? 0;
                    final lat = (data['lat'] as num?)?.toDouble();
                    final lng = (data['lng'] as num?)?.toDouble();
                    final hasGps = lat != null && lng != null;
                    final isPolice = type == 'ALERTA_POLICIAL';
                    final dt = ts > 0 ? DateTime.fromMillisecondsSinceEpoch(ts) : null;
                    final timeStr = dt != null
                        ? '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}'
                        : '';

                    return GestureDetector(
                      onTap: hasGps
                          ? () async {
                              final uri = Uri.parse(
                                  'https://www.google.com/maps/search/?api=1&query=$lat,$lng');
                              if (await canLaunchUrl(uri)) {
                                await launchUrl(uri, mode: LaunchMode.externalApplication);
                              }
                            }
                          : null,
                      child: Container(
                        margin: const EdgeInsets.only(bottom: 6),
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: isPolice ? const Color(0xFF0D1B3E) : const Color(0xFF3E0D0D),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: isPolice ? const Color(0xFF1565C0) : const Color(0xFFB71C1C),
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              isPolice ? Icons.local_police : Icons.gpp_bad,
                              color: isPolice ? Colors.blue[300] : Colors.red[300],
                              size: 22,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    isPolice ? '🚨 ALERTA POLICIAL' : '🔴 ALERTA ROBO',
                                    style: TextStyle(
                                      color: isPolice ? Colors.blue[200] : Colors.red[200],
                                      fontWeight: FontWeight.bold,
                                      fontSize: 11,
                                    ),
                                  ),
                                  Row(
                                    children: [
                                      Text(userName,
                                          style: const TextStyle(
                                              color: Colors.white,
                                              fontWeight: FontWeight.w600,
                                              fontSize: 12)),
                                      if (timeStr.isNotEmpty) ...[
                                        const SizedBox(width: 6),
                                        Text(timeStr,
                                            style: const TextStyle(
                                                color: Colors.white54, fontSize: 10)),
                                      ],
                                      if (hasGps) ...[
                                        const SizedBox(width: 6),
                                        const Icon(Icons.location_on,
                                            size: 12, color: Colors.greenAccent),
                                      ] else ...[
                                        const SizedBox(width: 6),
                                        const Text('Sin GPS',
                                            style: TextStyle(
                                                color: Colors.white38, fontSize: 10)),
                                      ],
                                    ],
                                  ),
                                ],
                              ),
                            ),
                            // Delete button
                            IconButton(
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                              icon: const Icon(Icons.check_circle_outline,
                                  color: Colors.greenAccent, size: 18),
                              tooltip: 'Marcar atendida',
                              onPressed: () {
                                FirebaseFirestore.instance
                                    .collection('panic_alerts')
                                    .doc(doc.id)
                                    .delete()
                                    .catchError((_) {});
                              },
                            ),
                          ],
                        ),
                      ),
                    );
                  }).toList(),
              ],
            ),
          );
        },
      ),
    );
  }

  String _formatChatTime(int ts) {
    if (ts <= 0) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch(ts);
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return 'ahora';
    if (diff.inHours < 1) return '${diff.inMinutes}m';
    if (diff.inHours < 24) return '${diff.inHours}h';
    if (diff.inDays < 7) return '${diff.inDays}d';
    return '${dt.day}/${dt.month}';
  }

  Widget _buildGroupsSection() {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('groups')
          .where('members', arrayContains: _currentUserId)
          .snapshots(),
      builder: (_, snapshot) {
        if (snapshot.hasError) {
          return Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
                color: ColorConstants.cardWhite,
                borderRadius: BorderRadius.circular(16)),
            child: Text(
              'No se pudo cargar grupos: ${snapshot.error}',
              style: const TextStyle(color: Colors.redAccent, fontSize: 12),
            ),
          );
        }
        if (!snapshot.hasData) {
          return const Center(
              child: CircularProgressIndicator(color: ColorConstants.themeColor));
        }
        final docs = [...snapshot.data!.docs]
          ..sort((a, b) {
            final da = a.data() as Map<String, dynamic>;
            final db = b.data() as Map<String, dynamic>;
            final ta = (da['lastTimestamp'] as num?)?.toInt() ??
                (da['createdAt'] as num?)?.toInt() ?? 0;
            final tb = (db['lastTimestamp'] as num?)?.toInt() ??
                (db['createdAt'] as num?)?.toInt() ?? 0;
            return tb.compareTo(ta);
          });
        if (docs.isEmpty) {
          return Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
                color: ColorConstants.cardWhite,
                borderRadius: BorderRadius.circular(16)),
            child: const Text(
              'No perteneces a ningún grupo aún.\nUn administrador puede agregarte.',
              style: TextStyle(color: ColorConstants.greyColor, fontSize: 13),
              textAlign: TextAlign.center,
            ),
          );
        }
        return Column(
          children: docs.map((doc) {
            final data = doc.data() as Map<String, dynamic>;
            final name = data['name'] as String? ?? 'Grupo';
            final description = data['description'] as String? ?? '';
            final memberCount = (data['members'] as List?)?.length ?? 0;
            final lastMessage = data['lastMessage'] as String? ?? '';
            final lastSenderName = data['lastSenderName'] as String? ?? '';
            final lastTs = (data['lastTimestamp'] as num?)?.toInt() ?? 0;
            final unread = ((data['unreadCounts'] as Map?)?[_currentUserId] as num?)?.toInt() ?? 0;
            final groupImage = (data['groupImage'] as String?) ?? '';

            final subtitleText = lastMessage.isNotEmpty
                ? (lastSenderName.isNotEmpty ? '$lastSenderName: $lastMessage' : lastMessage)
                : (description.isNotEmpty ? description : '$memberCount miembros');

            // Color avatar basado en nombre del grupo
            final avatarColors = [
              ColorConstants.policeBlue, ColorConstants.motoboyGreen,
              ColorConstants.trafficOrange, ColorConstants.accidentYellow,
              ColorConstants.dangerRed,
            ];
            final avatarColor = avatarColors[name.length % avatarColors.length];

            return GestureDetector(
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => GroupChatPage(
                    arguments: GroupChatArguments(
                      groupId: doc.id,
                      groupName: name,
                      groupDescription: description,
                      groupImage: groupImage,
                    ),
                  ),
                ),
              ),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: ColorConstants.cardWhite,
                  borderRadius: BorderRadius.circular(16),
                  border: unread > 0
                      ? Border.all(color: ColorConstants.primaryColor.withValues(alpha: 0.4), width: 1)
                      : Border.all(color: ColorConstants.divider, width: 1),
                ),
                child: Row(
                  children: [
                    // Avatar
                    Stack(
                      clipBehavior: Clip.none,
                      children: [
                        CircleAvatar(
                          radius: 26,
                          backgroundColor: avatarColor.withOpacity(0.15),
                          backgroundImage: groupImage.isNotEmpty ? NetworkImage(groupImage) : null,
                          child: groupImage.isEmpty
                              ? Text(
                                  name.isNotEmpty ? name[0].toUpperCase() : 'G',
                                  style: TextStyle(
                                      color: avatarColor,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 18),
                                )
                              : null,
                        ),
                        // Online dot
                        Positioned(
                          bottom: 0,
                          right: 0,
                          child: Container(
                            width: 12,
                            height: 12,
                            decoration: BoxDecoration(
                              color: ColorConstants.motoboyGreen,
                              shape: BoxShape.circle,
                              border: Border.all(color: ColorConstants.cardWhite, width: 2),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(width: 12),
                    // Content
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  name,
                                  style: TextStyle(
                                    fontWeight: unread > 0 ? FontWeight.bold : FontWeight.w600,
                                    color: ColorConstants.textPrimary,
                                    fontSize: 14,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if (lastTs > 0)
                                Text(
                                  _formatChatTime(lastTs),
                                  style: TextStyle(
                                    color: unread > 0
                                        ? ColorConstants.themeColor
                                        : ColorConstants.greyColor,
                                    fontSize: 11,
                                    fontWeight: unread > 0 ? FontWeight.bold : FontWeight.normal,
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 3),
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  subtitleText,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: unread > 0
                                        ? ColorConstants.textSecondary
                                        : ColorConstants.greyColor,
                                    fontSize: 12,
                                    fontWeight: unread > 0 ? FontWeight.w500 : FontWeight.normal,
                                  ),
                                ),
                              ),
                              if (unread > 0) ...[
                                const SizedBox(width: 6),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: ColorConstants.themeColor,
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Text(
                                    unread > 99 ? '99+' : '$unread',
                                    style: const TextStyle(
                                        color: Colors.black,
                                        fontSize: 11,
                                        fontWeight: FontWeight.bold),
                                  ),
                                ),
                              ],
                            ],
                          ),
                          const SizedBox(height: 5),
                          // Members badge
                          Row(
                            children: [
                              Icon(Icons.people_outline,
                                  size: 11, color: ColorConstants.greyColor),
                              const SizedBox(width: 3),
                              Text(
                                '$memberCount miembros',
                                style: const TextStyle(
                                    fontSize: 10, color: ColorConstants.greyColor),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          }).toList(),
        );
      },
    );
  }

  // -------------------------------------------------------

  Widget _buildPopupMenu() {
    return PopupMenuButton<MenuSetting>(
      onSelected: _onItemMenuPress,
      itemBuilder: (_) {
        return _dynamicMenus.map(
          (choice) {
            return PopupMenuItem<MenuSetting>(
                value: choice,
                child: Row(
                  children: [
                    Icon(
                      choice.icon,
                      color: ColorConstants.primaryColor,
                    ),
                    SizedBox(
                      width: 10,
                    ),
                    Text(
                      choice.title,
                      style: TextStyle(color: ColorConstants.primaryColor),
                    ),
                  ],
                ));
          },
        ).toList();
      },
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _panicAlertService?.stop();
    _setUserPresence(false);
    LocationTracker.instance.stop(_currentUserId);
    stopForegroundGps(_currentUserId);
    _btnClearController.close();
    _tokenRefreshSubscription?.cancel();
    super.dispose();
  }
}

class _ChangelogEntry {
  final String version;
  final String date;
  final List<String> items;
  const _ChangelogEntry({required this.version, required this.date, required this.items});
}
