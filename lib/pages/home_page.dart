import 'dart:async';

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
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

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
  int _selectedTab = 0;
  int _orderBadge = 0;
  bool _isMotoboy = false;
  bool _isAdmin = false;
  bool _isAgente = false; // agente o ejecutivo (pueden ver Chat Temporales)
  int _refreshKey = 0; // increment to force home rebuild

  late final _authProvider = context.read<AuthProvider>();
  late final _homeProvider = context.read<HomeProvider>();
  late final String _currentUserId;

  final _btnClearController = StreamController<bool>();
  StreamSubscription<String>? _tokenRefreshSubscription;
  PanicAlertService? _panicAlertService;

  List<MenuSetting> get _dynamicMenus => [
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
    _isMotoboy = role.toLowerCase().contains('motoboy');
    _isAdmin = rolId == '1' ||
      role.toLowerCase().contains('admin') ||
      _currentUserId == AppConstants.adminFirebaseUid;
    _isAgente = role.toLowerCase() == 'agente' || role.toLowerCase() == 'ejecutivo' || role.toLowerCase() == 'asociado' || _isAdmin;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      AppUpdater.checkAndUpdate(context);
      // Start continuous GPS tracking for admin panel
      final nickname = _authProvider.prefs.getString(FirestoreConstants.nickname) ?? 'Usuario';
      LocationTracker.instance.start(_currentUserId, nickname);
      startForegroundGps(_currentUserId, nickname);
      _checkGpsGate();
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
    _firebaseMessaging.requestPermission().then((settings) {
      print('notification permission status: ${settings.authorizationStatus}');
    });

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
      Fluttertoast.showToast(msg: err.toString());
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
    if (choice.title == 'Actualizar app') {
      AppUpdater.checkAndUpdate(context, force: true, showUpToDate: true);
    } else if (choice.title == 'Cerrar sesión') {
      _handleSignOut();
    } else {
      Navigator.push(context, MaterialPageRoute(builder: (_) => SettingsPage()));
    }
  }

  void _showNotificationWithPayload(RemoteNotification remoteNotification, String payload, {String senderName = ''}) async {
    final androidPlatformChannelSpecifics = AndroidNotificationDetails(
      _androidChannel.id,
      _androidChannel.name,
      channelDescription: _androidChannel.description,
      playSound: true,
      enableVibration: true,
      importance: Importance.max,
      priority: Priority.high,
      category: AndroidNotificationCategory.message,
      ticker: 'Nuevo mensaje',
    );
    final iOSPlatformChannelSpecifics = DarwinNotificationDetails();
    final platformChannelSpecifics = NotificationDetails(
      android: androidPlatformChannelSpecifics,
      iOS: iOSPlatformChannelSpecifics,
    );

    print(remoteNotification);

    // Use senderName if available, otherwise fall back to FCM title
    final displayTitle = senderName.isNotEmpty ? senderName : (remoteNotification.title ?? 'La Mano');
    final displayBody = remoteNotification.body ?? '';

    await _flutterLocalNotificationsPlugin.show(
      id: 0,
      title: displayTitle,
      body: displayBody,
      notificationDetails: platformChannelSpecifics,
      payload: payload,
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

  @override
  Widget build(BuildContext context) {
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
          // ── Refresh button (Inicio tab only) ──
          if (_selectedTab == 0)
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Refrescar',
              onPressed: () => setState(() => _refreshKey++),
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
    return BottomNavigationBar(
      currentIndex: _selectedTab,
      selectedItemColor: ColorConstants.primaryColor,
      unselectedItemColor: ColorConstants.greyColor,
      onTap: (index) {
        setState(() {
          _selectedTab = index;
          if (_isMotoboy && index == 3) _orderBadge = 0;
        });
      },
      items: [
        const BottomNavigationBarItem(
          icon: Icon(Icons.home_outlined),
          activeIcon: Icon(Icons.home),
          label: 'Inicio',
        ),
        const BottomNavigationBarItem(
          icon: Icon(Icons.auto_awesome_outlined),
          activeIcon: Icon(Icons.auto_awesome),
          label: 'Estados',
        ),
        const BottomNavigationBarItem(
          icon: Icon(Icons.chat_bubble_outline),
          activeIcon: Icon(Icons.chat_bubble),
          label: 'Chats',
        ),
        if (_isAgente)
          BottomNavigationBarItem(
            icon: const Icon(Icons.forum_outlined, color: Colors.black87),
            activeIcon: const Icon(Icons.forum, color: Colors.black),
            label: 'Chat Temp.',
          ),
        if (_isMotoboy)
          BottomNavigationBarItem(
            icon: _orderBadge > 0
                ? Stack(
                    clipBehavior: Clip.none,
                    children: [
                      const Icon(Icons.delivery_dining_outlined),
                      Positioned(
                        top: -4,
                        right: -6,
                        child: Container(
                          padding: const EdgeInsets.all(3),
                          decoration: const BoxDecoration(
                            color: Colors.red,
                            shape: BoxShape.circle,
                          ),
                          constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
                          child: Text(
                            '$_orderBadge',
                            style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                    ],
                  )
                : const Icon(Icons.delivery_dining_outlined),
            activeIcon: const Icon(Icons.delivery_dining),
            label: 'Mis Órdenes',
          ),
      ],
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
          color: Color(0xFF0D1F14),
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          border: Border(top: BorderSide(color: Color(0xFF00E65A), width: 1.5)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: const Color(0xFF00E65A),
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
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          // ── Chip changelog ────────────────────────────────
          Align(
            alignment: Alignment.centerRight,
            child: GestureDetector(
              onTap: _showChangelogModal,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFF1A3A2A),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: const Color(0xFF00E65A), width: 1),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.android, color: Color(0xFF00E65A), size: 14),
                    SizedBox(width: 4),
                    Text('APK La Mano · Beta',
                        style: TextStyle(
                            color: Color(0xFF00E65A),
                            fontSize: 11,
                            fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),

          // ── Grupos ────────────────────────────────────────
          Row(
            children: const [
              Icon(Icons.group_outlined, color: ColorConstants.primaryColor),
              SizedBox(width: 6),
              Text('Grupos',
                  style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: ColorConstants.primaryColor)),
            ],
          ),
          const SizedBox(height: 8),
          _buildGroupsSection(),

          // ── Panel alertas de pánico (solo admin, debajo de grupos) ──
          if (_isAdmin) ...[const SizedBox(height: 16), _buildPanicAlertsSection()],
        ],
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
                color: ColorConstants.greyColor2,
                borderRadius: BorderRadius.circular(12)),
            child: Text(
              'No se pudo cargar grupos: ${snapshot.error}',
              style: const TextStyle(color: Colors.red, fontSize: 12),
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
                color: ColorConstants.greyColor2,
                borderRadius: BorderRadius.circular(12)),
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
            final lastTs = (data['lastTimestamp'] as num?)?.toInt() ?? 0;
            final unread = ((data['unreadCounts'] as Map?)?[_currentUserId] as num?)?.toInt() ?? 0;
            final groupImage = (data['groupImage'] as String?) ?? '';
            final subtitleText = lastMessage.isNotEmpty
                ? lastMessage
                : (description.isNotEmpty ? description : '$memberCount miembros');
            return Card(
              margin: const EdgeInsets.only(bottom: 10),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              elevation: 1,
              child: ListTile(
                leading: CircleAvatar(
                  backgroundColor: ColorConstants.primaryColor,
                  backgroundImage: groupImage.isNotEmpty ? NetworkImage(groupImage) : null,
                  child: groupImage.isEmpty
                      ? Text(
                          name.isNotEmpty ? name[0].toUpperCase() : 'G',
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                        )
                      : null,
                ),
                title: Text(name,
                    style: TextStyle(
                        fontWeight: unread > 0 ? FontWeight.bold : FontWeight.w600,
                        color: ColorConstants.primaryColor)),
                subtitle: Text(
                  subtitleText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: unread > 0 ? Colors.black87 : ColorConstants.greyColor,
                    fontWeight: unread > 0 ? FontWeight.w600 : FontWeight.normal,
                    fontSize: 13,
                  ),
                ),
                trailing: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
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
                      )
                    else
                      const Icon(Icons.chevron_right, color: ColorConstants.greyColor),
                    if (unread > 0) ...[
                      const SizedBox(height: 4),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                        decoration: BoxDecoration(
                          color: ColorConstants.themeColor,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          unread > 99 ? '99+' : '$unread',
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.bold),
                        ),
                      ),
                    ],
                  ],
                ),
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
