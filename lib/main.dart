import 'dart:async';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' hide AuthProvider;
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:firebase_storage/firebase_storage.dart';
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


// ── Global navigator key so background handler can push routes ────────────────
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

// ── Background / terminated FCM handler ──────────────────────────────────────
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();

  if (message.data['type'] != 'incoming_call') return;

  final roomName   = message.data['room_name']   ?? '';
  final callerName = message.data['caller_name'] ?? 'Alguien';
  final isVideo    = message.data['is_video']    == 'true';

  if (roomName.isEmpty) return;

  // Show a high-priority fullScreenIntent notification.
  // The user tapping it will open the app; the app reads
  // FirebaseMessaging.instance.getInitialMessage() to detect it.
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

  final title = isVideo ? '📹 Videollamada entrante' : '📞 Llamada entrante';
  await plugin.show(
    id: 9999,
    title: title,
    body: '$callerName te está llamando',
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
        ongoing: true,
        autoCancel: false,
        actions: [
          const AndroidNotificationAction('decline', 'Rechazar',
              cancelNotification: true),
          const AndroidNotificationAction('accept', 'Aceptar',
              cancelNotification: true),
        ],
        additionalFlags: Int32List.fromList([4]), // FLAG_INSISTENT (ring loop)
      ),
    ),
    payload: 'call|$roomName|$callerName|${isVideo ? '1' : '0'}',
  );
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    if (kIsWeb) {
      await Firebase.initializeApp(
        options: const FirebaseOptions(
          apiKey: 'AIzaSyAtXdcOLOpZdnOxb1ojAc2z4EQmlshFIPo',
          appId: '1:494184473926:android:0c862d1af3199412bd7147',
          messagingSenderId: '494184473926',
          projectId: 'lamano-e4b6c',
          storageBucket: 'lamano-e4b6c.firebasestorage.app',
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
  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

  // Init foreground GPS task config (no-op if already configured)
  initForegroundTaskConfig();

  SharedPreferences prefs = await SharedPreferences.getInstance();
  runApp(MyApp(prefs: prefs));
}

class MyApp extends StatelessWidget {
  final SharedPreferences prefs;

  MyApp({required this.prefs});

  final _firebaseFirestore = FirebaseFirestore.instance;
  final _firebaseStorage = FirebaseStorage.instance;

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
            firebaseStorage: this._firebaseStorage,
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
            firebaseStorage: this._firebaseStorage,
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
    if (has) setState(() => _locked = true);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _setOnline(false);
    }
    if (state == AppLifecycleState.resumed) {
      _setOnline(true);
      _checkResumePin();
    }
  }

  Future<void> _checkResumePin() async {
    final has = await hasPinSet();
    if (has && mounted) setState(() => _locked = true);
  }

  @override
  Widget build(BuildContext context) {
    if (_locked) {
      return PinLockPage(
        mode: PinMode.verify,
        onSuccess: () => setState(() => _locked = false),
      );
    }
    return SplashPage();
  }
}
