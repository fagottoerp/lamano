import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:fluttertoast/fluttertoast.dart';

import 'sticker_service.dart';

class SharedStickerShareService {
  SharedStickerShareService._();

  static final SharedStickerShareService instance = SharedStickerShareService._();

  static const MethodChannel _methodChannel = MethodChannel('com.lamano.app/shared_stickers');
  static const EventChannel _eventChannel = EventChannel('com.lamano.app/shared_stickers_events');

  final List<String> _pendingFiles = [];
  StreamSubscription? _eventSubscription;
  StreamSubscription<User?>? _authSubscription;
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    // Native share channels are currently implemented only on Android.
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return;
    }

    _authSubscription = FirebaseAuth.instance.authStateChanges().listen((user) {
      if (user != null) {
        unawaited(flushPendingImports());
      }
    });

    try {
      final initial = await _methodChannel.invokeMethod<List<dynamic>>('getInitialSharedFiles');
      if (initial != null && initial.isNotEmpty) {
        _pendingFiles.addAll(initial.map((e) => e.toString()).where((e) => e.isNotEmpty));
        unawaited(flushPendingImports());
      }
    } on MissingPluginException {
      return;
    } on PlatformException {
      return;
    }

    try {
      _eventSubscription = _eventChannel.receiveBroadcastStream().listen((dynamic event) {
        final files = _parseEvent(event);
        if (files.isEmpty) return;
        _pendingFiles.addAll(files);
        unawaited(flushPendingImports());
      }, onError: (_) {});
    } on MissingPluginException {
      return;
    } on PlatformException {
      return;
    }
  }

  Future<void> flushPendingImports() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || _pendingFiles.isEmpty) return;

    final pending = List<String>.from(_pendingFiles);
    _pendingFiles.clear();

    final zipFiles = pending.where((path) => path.toLowerCase().endsWith('.zip')).toList();
    final imageFiles = pending.where((path) => !_isZip(path)).toList();

    var imported = 0;
    for (final zip in zipFiles) {
      imported += await StickerService.importStickerPackFromZip(zip);
    }
    if (imageFiles.isNotEmpty) {
      imported += await StickerService.importSharedStickerFiles(imageFiles);
    }

    if (imported > 0) {
      Fluttertoast.showToast(msg: 'Stickers importados: $imported');
    }
  }

  List<String> _parseEvent(dynamic event) {
    if (event is String) {
      return event.isEmpty ? const [] : [event];
    }
    if (event is List) {
      return event.map((e) => e.toString()).where((e) => e.isNotEmpty).toList();
    }
    return const [];
  }

  bool _isZip(String path) => path.toLowerCase().endsWith('.zip');

  Future<void> dispose() async {
    await _eventSubscription?.cancel();
    await _authSubscription?.cancel();
    _eventSubscription = null;
    _authSubscription = null;
  }
}