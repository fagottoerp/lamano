import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' show PlatformDispatcher;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' hide AuthProvider;
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_chat_demo/constants/app_constants.dart';
import 'package:flutter_chat_demo/constants/firestore_constants.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'constants/color_constants.dart';
import 'package:google_fonts/google_fonts.dart';
import 'pages/pages.dart';
import 'pages/pin_lock_page.dart';
import 'providers/providers.dart';
import 'utils/foreground_gps_service.dart';
import 'services/shared_sticker_share_service.dart';


// ── Global navigator key so background handler can push routes ────────────────
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

// ── Background / terminated FCM handler ──────────────────────────────────────
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();

  if (message.data['type'] != 'incoming_call') return;

  final roomName    = message.data['room_name']    ?? '';
  final callerName  = message.data['caller_name']  ?? 'Alguien';
  final isVideo     = message.data['is_video']     == 'true';
  final isGroupCall = message.data['is_group_call'] == 'true';
  final groupName   = message.data['group_name']   ?? '';
  // Use server-generated title/body when available
  final title = message.data['title'] as String? ??
      (isGroupCall
          ? (isVideo ? '📹 Videollamada grupal' : '📞 Llamada grupal')
          : (isVideo ? '📹 Videollamada entrante' : '📞 Llamada entrante'));
  final bodyText = message.data['body'] as String? ??
      (isGroupCall
          ? '$callerName inició una llamada'
          : '$callerName te está llamando');

  if (roomName.isEmpty) return;

  const channel = AndroidNotificationChannel(
    'incoming_call_v1',
    'Llamadas entrantes',
    description: 'Notificaciones de llamadas entrantes',
    importance: Importance.max,
    playSound: true,
    enableVibration: true,
  );

  final plugin = FlutterLocalNotificationsPlugin();
  await plugin.initialize(
    settings: const InitializationSettings(
      android: AndroidInitializationSettings('app_icon'),
    ),
  );
  await plugin
      .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(channel);

  // payload: call|roomName|callerName|isVideo|isGroupCall|groupName
  await plugin.show(
    id: 9999,
    title: title,
    body: bodyText,
    notificationDetails: NotificationDetails(
      android: AndroidNotificationDetails(
        'incoming_call_v1',
        'Llamadas entrantes',
        importance: Importance.max,
        priority: Priority.max,
        fullScreenIntent: true,
        category: AndroidNotificationCategory.call,
        visibility: NotificationVisibility.public,
        playSound: true,
        enableVibration: true,
        ongoing: false,
        autoCancel: true,
        onlyAlertOnce: true,
        timeoutAfter: 30000,
        actions: [
          const AndroidNotificationAction('decline', 'Rechazar',
              cancelNotification: true),
          const AndroidNotificationAction('accept', 'Aceptar',
              cancelNotification: true),
        ],
        additionalFlags: Int32List.fromList([4]),
      ),
    ),
    payload: 'call|$roomName|$callerName|${isVideo ? '1' : '0'}|${isGroupCall ? '1' : '0'}|$groupName',
  );
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    Zone.current.handleUncaughtError(
      details.exception,
      details.stack ?? StackTrace.current,
    );
  };

  PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    debugPrint('Uncaught platform error: $error');
    debugPrintStack(stackTrace: stack);
    return true;
  };

  try {
    if (kIsWeb) {
      await Firebase.initializeApp(
        options: const FirebaseOptions(
          apiKey: 'AIzaSyAueOUp_lUGkIRKsSo7u09_SH3lfPSQ4ws',
          appId: '1:415868449671:android:fa3739dfc955fd5c2e1922',
          messagingSenderId: '415868449671',
          projectId: 'chat-70137',
          storageBucket: 'chat-70137.firebasestorage.app',
        ),
      );
    } else {
      await Firebase.initializeApp();
    }
  } catch (e) {
    final msg = e.toString();
    final isDuplicateDefaultApp =
        msg.contains('duplicate-app') ||
        msg.contains('already exists') ||
        msg.contains('[DEFAULT]');
    if (!isDuplicateDefaultApp && Firebase.apps.isEmpty) {
      rethrow;
    }
  }

  // Register background FCM handler BEFORE runApp
  try {
    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
  } catch (e) {
    debugPrint('FCM background handler registration failed: $e');
  }

  // ── MIGRATION FIX: Clear old project data ──
  try {
    final currentProject = Firebase.app().options.projectId;
    if (currentProject != 'chat-70137') {
      debugPrint('⚠️ Wrong Firebase project detected: $currentProject');
      debugPrint('🔄 Clearing old data and forcing re-login...');
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();
      await FirebaseAuth.instance.signOut();
    }
  } catch (e) {
    debugPrint('Migration check failed: $e');
  }

  // Init foreground GPS task config (no-op if already configured)
  try {
    initForegroundTaskConfig();
  } catch (e) {
    debugPrint('Foreground task init failed: $e');
  }

  try {
    await SharedStickerShareService.instance.init();
  } catch (e) {
    debugPrint('Shared sticker service init failed: $e');
  }

  SharedPreferences prefs = await SharedPreferences.getInstance();
  runApp(MyApp(prefs: prefs));
}

class MyApp extends StatelessWidget {
  final SharedPreferences prefs;

  MyApp({required this.prefs});

  final _firebaseFirestore = FirebaseFirestore.instance;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthProvider>(
          create: (_) => AuthProvider(
            firebaseAuth: FirebaseAuth.instance,
            googleSignIn: GoogleSignIn(),
            prefs: this.prefs,
            firebaseFirestore: this._firebaseFirestore,
          ),
        ),
        Provider<SettingProvider>(
          create: (_) => SettingProvider(
            prefs: this.prefs,
            firebaseFirestore: this._firebaseFirestore,
          ),
        ),
        Provider<HomeProvider>(
          create: (_) => HomeProvider(
            firebaseFirestore: this._firebaseFirestore,
          ),
        ),
        Provider<ChatProvider>(
          create: (_) => ChatProvider(
            prefs: this.prefs,
            firebaseFirestore: this._firebaseFirestore,
          ),
        ),
      ],
      child: MaterialApp(
        title: AppConstants.appTitle,
        navigatorKey: navigatorKey,
        theme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.light,
          scaffoldBackgroundColor: ColorConstants.bgApp,
          colorScheme: const ColorScheme.light(
            primary: ColorConstants.primaryColor,
            secondary: ColorConstants.accentGreen,
            surface: ColorConstants.cardWhite,
            onPrimary: Colors.white,
            onSurface: ColorConstants.textPrimary,
          ),
          appBarTheme: const AppBarTheme(
            backgroundColor: ColorConstants.primaryColor,
            foregroundColor: Colors.white,
            elevation: 0,
            centerTitle: true,
          ),
          cardTheme: CardThemeData(
            color: ColorConstants.cardWhite,
            elevation: 0,
            shadowColor: Color(0x18000000),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.all(Radius.circular(12)),
              side: BorderSide(color: ColorConstants.divider, width: 1),
            ),
          ),
          bottomNavigationBarTheme: const BottomNavigationBarThemeData(
            backgroundColor: ColorConstants.cardWhite,
            selectedItemColor: ColorConstants.primaryColor,
            unselectedItemColor: ColorConstants.greyColor,
            type: BottomNavigationBarType.fixed,
            elevation: 8,
          ),
          dividerColor: ColorConstants.divider,
          textTheme: GoogleFonts.poppinsTextTheme(
            ThemeData.light().textTheme.copyWith(
              bodyMedium: const TextStyle(color: ColorConstants.textPrimary),
              bodySmall: const TextStyle(color: ColorConstants.textSecondary),
            ),
          ),
        ),
        home: AppShell(),
        debugShowCheckedModeBanner: false,
      ),
    );
  }
}

/// Wrapper que gestiona el PIN lock sobre toda la app.
class AppShell extends StatefulWidget {
  const AppShell({Key? key}) : super(key: key);
  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WidgetsBindingObserver {
  bool _locked = false;
  PinMode _pinMode = PinMode.verify;
  bool _mustRelockOnResume = false;

  void _setOnline(bool online) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    FirebaseFirestore.instance.collection(FirestoreConstants.pathUserCollection).doc(uid).update({
      FirestoreConstants.isOnline: online,
      FirestoreConstants.lastSeen: DateTime.now().millisecondsSinceEpoch,
    }).catchError((_) {});
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkInitialPin();
    _setOnline(true);
  }

  @override
  void dispose() {
    _setOnline(false);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _checkInitialPin() async {
    final has = await hasPinSet();
    setState(() {
      _pinMode = has ? PinMode.verify : PinMode.setup;
      _locked = true; // always require PIN flow on startup; enforce setup when missing
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _setOnline(true);
        if (_mustRelockOnResume) {
          _mustRelockOnResume = false;
          _checkResumePin();
        }
        break;
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        _setOnline(false);
        _mustRelockOnResume = true;
        if (mounted) {
          setState(() => _locked = true);
        }
        break;
    }
  }

  Future<void> _checkResumePin() async {
    final has = await hasPinSet();
    if (!mounted) return;
    if (has) {
      setState(() {
        _pinMode = PinMode.verify;
        _locked = true;
      });
      return;
    }
    // If no PIN exists yet, force setup gate instead of leaving app unlocked.
    setState(() {
      _pinMode = PinMode.setup;
      _locked = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_locked) {
      return PinLockPage(
        mode: _pinMode,
        onSuccess: () => setState(() => _locked = false),
      );
    }
    return SplashPage();
  }
}
