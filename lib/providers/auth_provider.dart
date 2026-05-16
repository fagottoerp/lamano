import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_chat_demo/constants/constants.dart';
import 'package:flutter_chat_demo/models/models.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

enum Status {
  uninitialized,
  authenticated,
  authenticating,
  authenticateError,
  authenticateException,
  authenticateCanceled,
}

class AuthProvider extends ChangeNotifier {
  final GoogleSignIn googleSignIn;
  final FirebaseAuth firebaseAuth;
  final FirebaseFirestore firebaseFirestore;
  final SharedPreferences prefs;

  AuthProvider({
    required this.firebaseAuth,
    required this.googleSignIn,
    required this.prefs,
    required this.firebaseFirestore,
  });

  Status _status = Status.uninitialized;
  String _lastErrorMessage = "";

  Status get status => _status;
  String get lastErrorMessage => _lastErrorMessage;

  String? get userFirebaseId => prefs.getString(FirestoreConstants.id);

  Future<bool> isLoggedIn() async {
    try {
      final currentUser = firebaseAuth.currentUser;
      if (currentUser == null) {
        return false;
      }

      if (prefs.getString(FirestoreConstants.id)?.isNotEmpty == true) {
        return true;
      }

      await _syncLocalPrefsFromUid(currentUser.uid);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> handleSignIn() async {
    _status = Status.authenticating;
    notifyListeners();

    final googleUser = await googleSignIn.signIn();
    if (googleUser == null) {
      _status = Status.authenticateCanceled;
      notifyListeners();
      return false;
    }

    final googleAuth = await googleUser.authentication;
    final credential = GoogleAuthProvider.credential(
      accessToken: googleAuth.accessToken,
      idToken: googleAuth.idToken,
    );

    final firebaseUser = (await firebaseAuth.signInWithCredential(credential)).user;
    if (firebaseUser == null) {
      _status = Status.authenticateError;
      notifyListeners();
      return false;
    }

    await _ensureUserInFirestore(
      firebaseUser,
      fallbackNickname: firebaseUser.displayName ?? "",
      fallbackPhotoUrl: firebaseUser.photoURL ?? "",
    );

    _status = Status.authenticated;
    notifyListeners();
    return true;
  }

  Future<bool> handlePageSignIn(String username, String password) async {
    _status = Status.authenticating;
    _lastErrorMessage = "";
    notifyListeners();

    try {
      final response = await http.post(
        Uri.parse(AppConstants.pageLoginApiUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'username': username,
          'password': password,
        }),
      );

      if (response.statusCode != 200) {
        String message = 'Error de autenticacion (${response.statusCode})';
        try {
          final errorPayload = jsonDecode(response.body) as Map<String, dynamic>;
          message = (errorPayload['message'] ?? message).toString();
        } catch (_) {}
        _lastErrorMessage = message;
        _status = Status.authenticateError;
        notifyListeners();
        return false;
      }

      final payload = jsonDecode(response.body) as Map<String, dynamic>;
      final success = payload['success'] == true;
      if (!success) {
        _lastErrorMessage = (payload['message'] ?? 'Credenciales invalidas').toString();
        _status = Status.authenticateError;
        notifyListeners();
        return false;
      }

      final firebase = payload['firebase'] as Map<String, dynamic>?;
      final userData = payload['user'] as Map<String, dynamic>?;
      final email = (firebase?['email'] ?? '').toString();
      final firebasePassword = (firebase?['password'] ?? '').toString();
      final nickname = (userData?['name'] ?? username).toString();
      final rolNombre = (userData?['rol_nombre'] ?? '').toString();
      final lamanoUserId = (userData?['id'] ?? 0).toString();
      final motoboyPhone = (userData?['phone'] ?? '').toString();
      final rolId = (userData?['rol_id'] ?? 0).toString();

      if (email.isEmpty || firebasePassword.isEmpty) {
        _lastErrorMessage = 'Configuracion de login movil incompleta';
        _status = Status.authenticateError;
        notifyListeners();
        return false;
      }

      User? firebaseUser;
      try {
        firebaseUser = (await firebaseAuth.signInWithEmailAndPassword(email: email, password: firebasePassword)).user;
      } on FirebaseAuthException catch (e) {
        if (e.code == 'user-not-found' || e.code == 'invalid-credential') {
          firebaseUser = (await firebaseAuth.createUserWithEmailAndPassword(email: email, password: firebasePassword)).user;
        } else {
          rethrow;
        }
      }

      if (firebaseUser == null) {
        _lastErrorMessage = 'No se pudo iniciar sesion en Firebase';
        _status = Status.authenticateError;
        notifyListeners();
        return false;
      }

      await _ensureUserInFirestore(firebaseUser, fallbackNickname: nickname, fallbackPhotoUrl: "", rolNombre: rolNombre);
      if (lamanoUserId != '0' && lamanoUserId.isNotEmpty) {
        await prefs.setString(FirestoreConstants.lamanoUserId, lamanoUserId);
      }
      await prefs.setString(FirestoreConstants.motoboyPhone, motoboyPhone);
      await prefs.setString(FirestoreConstants.rolId, rolId);

      _status = Status.authenticated;
      notifyListeners();
      return true;
    } catch (e) {
      _lastErrorMessage = e.toString();
      _status = Status.authenticateException;
      notifyListeners();
      return false;
    }
  }

  void handleException() {
    _status = Status.authenticateException;
    notifyListeners();
  }

  Future<void> handleSignOut() async {
    _status = Status.uninitialized;
    await firebaseAuth.signOut();
    try {
      if (await googleSignIn.isSignedIn()) {
        await googleSignIn.disconnect();
        await googleSignIn.signOut();
      }
    } catch (_) {}
    await prefs.remove(FirestoreConstants.id);
    await prefs.remove(FirestoreConstants.nickname);
    await prefs.remove(FirestoreConstants.photoUrl);
    await prefs.remove(FirestoreConstants.aboutMe);
  }

  Future<void> _syncLocalPrefsFromUid(String uid) async {
    try {
      final snapshot = await firebaseFirestore.collection(FirestoreConstants.pathUserCollection).doc(uid).get();
      if (snapshot.exists) {
        final userChat = UserChat.fromDocument(snapshot);
        await prefs.setString(FirestoreConstants.id, userChat.id);
        await prefs.setString(FirestoreConstants.nickname, userChat.nickname);
        await prefs.setString(FirestoreConstants.photoUrl, userChat.photoUrl);
        await prefs.setString(FirestoreConstants.aboutMe, userChat.aboutMe);
        return;
      }
    } catch (_) {}

    await prefs.setString(FirestoreConstants.id, uid);
    await prefs.setString(FirestoreConstants.nickname, firebaseAuth.currentUser?.displayName ?? "");
    await prefs.setString(FirestoreConstants.photoUrl, firebaseAuth.currentUser?.photoURL ?? "");
  }

  Future<void> _ensureUserInFirestore(
    User firebaseUser, {
    required String fallbackNickname,
    required String fallbackPhotoUrl,
    String rolNombre = '',
  }) async {
    final userRef = firebaseFirestore.collection(FirestoreConstants.pathUserCollection).doc(firebaseUser.uid);
    final snapshot = await userRef.get();

    if (!snapshot.exists) {
      await userRef.set({
        FirestoreConstants.nickname: fallbackNickname,
        FirestoreConstants.photoUrl: fallbackPhotoUrl,
        FirestoreConstants.aboutMe: rolNombre,
        FirestoreConstants.id: firebaseUser.uid,
        FirestoreConstants.createdAt: DateTime.now().millisecondsSinceEpoch.toString(),
        FirestoreConstants.chattingWith: null,
      });
    } else {
      // Always sync nickname and role from backend on every login
      final updates = <String, dynamic>{};
      if (fallbackNickname.isNotEmpty) updates[FirestoreConstants.nickname] = fallbackNickname;
      updates[FirestoreConstants.aboutMe] = rolNombre; // always overwrite (empty = sin rol)
      await userRef.update(updates);
    }

    // Sync AFTER Firestore is updated so local prefs get the fresh role
    await _syncLocalPrefsFromUid(firebaseUser.uid);
  }
}
