import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:file_picker/file_picker.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_chat_demo/constants/constants.dart';
import 'package:flutter_chat_demo/constants/alert_types.dart';
import 'package:flutter_chat_demo/pages/pages.dart';
import 'package:flutter_chat_demo/providers/providers.dart';
import 'package:flutter_chat_demo/utils/utilities.dart';
import 'package:flutter_chat_demo/widgets/widgets.dart';
import 'package:flutter_chat_demo/widgets/sticker_picker.dart';
import 'package:flutter_chat_demo/widgets/rainbow_text.dart';
import 'package:flutter_chat_demo/widgets/location_map_bubble.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:http/http.dart' as http;
import 'package:jitsi_meet_flutter_sdk/jitsi_meet_flutter_sdk.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

class GroupChatPage extends StatefulWidget {
  const GroupChatPage({super.key, required this.arguments});
  final GroupChatArguments arguments;

  @override
  State<GroupChatPage> createState() => _GroupChatPageState();
}

class _GroupChatPageState extends State<GroupChatPage> {
  late final String _currentUserId;
  late final String _currentNickname;
  late final String _currentRolId;

  List<QueryDocumentSnapshot> _listMessage = [];
  int _limit = 20;
  final _limitIncrement = 20;

  File? _imageFile;
  bool _isLoading = false;
  bool _isShowSticker = false;
  String _imageUrl = '';

  // Reply to message
  Map<String, dynamic>? _replyTo;

  // Typing indicators
  Map<String, bool> _typingUsers = {};
  StreamSubscription? _groupTypingSub;
  Timer? _typingTimer;

  // Mute
  int _mutedUntil = 0;

  // Disappearing messages
  int _disappearingSeconds = 0; // 0 = off
  Timer? _disappearTimer;
  final Map<String, double> _fadingMessages = {}; // msgId -> opacity (1.0→0.0)

  // Pinned message
  Map<String, dynamic>? _pinnedMessage;

  // Custom text color
  Color _myBubbleColor = ColorConstants.bgSent;

  // Video playback
  final Map<String, VideoPlayerController> _videoControllers = {};

  // Live location
  StreamSubscription<Position>? _liveLocationSub;
  bool _isSharingLiveLocation = false;
  String? _activeLiveLocationDocId;

  // Quick alerts
  bool _showAlertPanel = false;

  // KLK party overlay
  OverlayEntry? _partyOverlay;
  String? _lastKnownFirstMsgId;

  final _chatInputController = TextEditingController();
  final _listScrollController = ScrollController();
  final Map<String, GlobalKey> _messageKeys = {};
  final _focusNode = FocusNode();

  // @menciones
  List<Map<String, String>> _groupMembers = []; // [{uid, name, avatar}]
  List<Map<String, String>> _mentionSuggestions = [];
  bool _showMentionSuggestions = false;

  // Búsqueda en chat
  bool _searchMode = false;
  final _searchController = TextEditingController();
  String _searchQuery = '';

  // Editar mensaje
  String? _editingMessageId;
  String? _editingOriginalContent;

  late final _chatProvider = context.read<ChatProvider>();
  late final _authProvider = context.read<AuthProvider>();

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_onFocusChange);
    _listScrollController.addListener(_scrollListener);
    _currentUserId = _authProvider.userFirebaseId ?? '';
    _currentNickname = _authProvider.prefs.getString(FirestoreConstants.nickname) ?? 'Usuario';
    _currentRolId = _authProvider.prefs.getString(FirestoreConstants.rolId) ?? '';
    _resetMyUnread();
    _loadMyBubbleColor();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _startGroupTypingStream();
      // Si rolId no está en prefs, cargarlo desde Firestore
      if (_currentRolId.isEmpty && _currentUserId.isNotEmpty) {
        FirebaseFirestore.instance
            .collection(FirestoreConstants.pathUserCollection)
            .doc(_currentUserId)
            .get()
            .then((doc) {
          final rolId = (doc.data()?['rol_id'] ?? '').toString();
          if (rolId.isNotEmpty && mounted) {
            _authProvider.prefs.setString(FirestoreConstants.rolId, rolId);
            setState(() => _currentRolId = rolId);
          }
        }).catchError((_) {});
      }
    });
    _mutedUntil = _authProvider.prefs.getInt('muted_until_${widget.arguments.groupId}') ?? 0;
    _loadDisappearingSetting();
    _loadGroupPinnedMessage();
  }

  void _loadGroupPinnedMessage() {
    FirebaseFirestore.instance
        .collection('groups')
        .doc(widget.arguments.groupId)
        .snapshots()
        .listen((snap) {
      if (!mounted) return;
      final pin = snap.data()?['pinnedMessage'];
      setState(() => _pinnedMessage = pin != null ? Map<String, dynamic>.from(pin) : null);
    });
  }

  Future<void> _toggleGroupPin(String messageId, String content) async {
    final ref = FirebaseFirestore.instance.collection('groups').doc(widget.arguments.groupId);
    if (_pinnedMessage != null && _pinnedMessage!['msgId'] == messageId) {
      await ref.update({'pinnedMessage': FieldValue.delete()});
    } else {
      await ref.set({'pinnedMessage': {'msgId': messageId, 'content': content}}, SetOptions(merge: true));
    }
  }

  Future<void> _loadDisappearingSetting() async {
    final doc = await FirebaseFirestore.instance
        .collection('groups')
        .doc(widget.arguments.groupId)
        .get();
    final secs = doc.data()?['disappearingSeconds'] as int? ?? 0;
    if (mounted) setState(() => _disappearingSeconds = secs);
    if (secs > 0) _startDisappearTimer();
  }

  void _startDisappearTimer() {
    _disappearTimer?.cancel();
    _disappearTimer = Timer.periodic(const Duration(seconds: 30), (_) => _processExpiredMessages());
  }

  Future<void> _processExpiredMessages() async {
    if (!mounted) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final toFade = <String>[];
    for (final doc in _listMessage) {
      final data = doc.data() as Map<String, dynamic>;
      final expiresAt = data['expiresAt'] as int? ?? 0;
      if (expiresAt > 0 && expiresAt <= now) {
        toFade.add(doc.id);
      }
    }
    if (toFade.isEmpty) return;

    // Start fade animation
    setState(() {
      for (final id in toFade) _fadingMessages[id] = 0.0;
    });

    // Wait for fade then delete from Firestore
    await Future.delayed(const Duration(milliseconds: 800));
    final groupId = widget.arguments.groupId;
    for (final id in toFade) {
      FirebaseFirestore.instance
          .collection(FirestoreConstants.pathMessageCollection)
          .doc(groupId)
          .collection(groupId)
          .doc(id)
          .delete()
          .catchError((_) {});
    }
    if (mounted) setState(() {
      for (final id in toFade) _fadingMessages.remove(id);
    });
  }

  void _showDisappearingDialog(bool isCreator) {
    if (!isCreator) {
      Fluttertoast.showToast(msg: 'Solo el administrador puede cambiar esto');
      return;
    }
    // 5 opciones de 10 min en 10 min hasta 1 hora, cada una con color distinto
    final options = [
      {'label': 'Desactivar',  'secs': 0,    'color': const Color(0xFF9E9E9E), 'icon': '🚫'},
      {'label': '10 minutos',  'secs': 600,  'color': const Color(0xFF4CAF50), 'icon': '🟢'},
      {'label': '20 minutos',  'secs': 1200, 'color': const Color(0xFF8BC34A), 'icon': '🟡'},
      {'label': '30 minutos',  'secs': 1800, 'color': const Color(0xFFFF9800), 'icon': '🟠'},
      {'label': '40 minutos',  'secs': 2400, 'color': const Color(0xFFFF5722), 'icon': '🔴'},
      {'label': '1 hora',      'secs': 3600, 'color': const Color(0xFFF44336), 'icon': '🔥'},
    ];
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Text('⏳', style: TextStyle(fontSize: 22)),
            SizedBox(width: 8),
            Text('Mensajes temporales', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Los mensajes se eliminarán automáticamente.\n⚠️ ¡Una vez activado no hay vuelta atrás!',
              style: TextStyle(fontSize: 12, color: Colors.grey),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            ...options.map((o) {
              final color = o['color'] as Color;
              final isSelected = (_disappearingSeconds == (o['secs'] as int));
              return Container(
                margin: const EdgeInsets.symmetric(vertical: 3),
                decoration: BoxDecoration(
                  color: isSelected ? color.withOpacity(0.15) : Colors.transparent,
                  border: Border.all(color: isSelected ? color : Colors.grey.shade300, width: isSelected ? 2 : 1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: RadioListTile<int>(
                  dense: true,
                  title: Row(
                    children: [
                      Text(o['icon'] as String, style: const TextStyle(fontSize: 18)),
                      const SizedBox(width: 8),
                      Text(
                        o['label'] as String,
                        style: TextStyle(
                          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                          color: isSelected ? color : null,
                        ),
                      ),
                    ],
                  ),
                  value: o['secs'] as int,
                  groupValue: _disappearingSeconds,
                  activeColor: color,
                  onChanged: (val) async {
                    Navigator.pop(context);
                    final secs = val ?? 0;
                    await FirebaseFirestore.instance
                        .collection('groups')
                        .doc(widget.arguments.groupId)
                        .update({'disappearingSeconds': secs});
                    setState(() => _disappearingSeconds = secs);
                    if (secs > 0) {
                      _startDisappearTimer();
                      Fluttertoast.showToast(msg: '⏳ Mensajes se eliminarán en: ${o['label']}');
                    } else {
                      _disappearTimer?.cancel();
                      Fluttertoast.showToast(msg: '✅ Mensajes temporales desactivados');
                    }
                  },
                ),
              );
            }),
          ],
        ),
      ),
    );
  }

  Future<void> _loadMyBubbleColor() async {
    final prefs = await SharedPreferences.getInstance();
    final colorValue = prefs.getInt('myBubbleColor');
    if (colorValue != null && mounted) setState(() => _myBubbleColor = Color(colorValue));
  }

  void _startGroupTypingStream() {
    _groupTypingSub?.cancel();
    _groupTypingSub = _chatProvider.getGroupTypingStream(widget.arguments.groupId).listen((snap) {
      if (!mounted) return;
      final now = DateTime.now().millisecondsSinceEpoch;
      final map = <String, bool>{};
      for (final doc in snap.docs) {
        if (doc.id == _currentUserId) continue;
        final data = doc.data() as Map<String, dynamic>;
        final isTyping = data['isTyping'] as bool? ?? false;
        final ts = data['ts'] as int? ?? 0;
        if (isTyping && now - ts < 10000) map[doc.id] = true;
      }
      setState(() => _typingUsers = map);
    });
  }

  void _onTypingChanged(String val) {
    _chatProvider.setTyping(widget.arguments.groupId, _currentUserId, val.isNotEmpty);
    _handleMentionInput(val);
    _typingTimer?.cancel();
    if (val.isNotEmpty) {
      _typingTimer = Timer(const Duration(seconds: 5), () {
        _chatProvider.setTyping(widget.arguments.groupId, _currentUserId, false);
      });
    }
  }

  Future<void> _resetMyUnread() async {
    if (_currentUserId.isEmpty) return;
    try {
      await FirebaseFirestore.instance
          .collection('groups')
          .doc(widget.arguments.groupId)
          .set({
        'unreadCounts': {_currentUserId: 0},
      }, SetOptions(merge: true));
    } catch (_) {}
    _markGroupMessagesRead();
  }

  Future<void> _markGroupMessagesRead() async {
    final groupId = widget.arguments.groupId;
    final snap = await FirebaseFirestore.instance
        .collection(FirestoreConstants.pathMessageCollection)
        .doc(groupId)
        .collection(groupId)
        .orderBy(FirestoreConstants.timestamp, descending: true)
        .limit(30)
        .get();
    final now = DateTime.now().millisecondsSinceEpoch;
    final batch = FirebaseFirestore.instance.batch();
    for (final doc in snap.docs) {
      final data = doc.data();
      final idFrom = data[FirestoreConstants.idFrom] as String? ?? '';
      if (idFrom == _currentUserId) continue; // no marcar los propios
      final readBy = Map<String, dynamic>.from(data['readBy'] as Map? ?? {});
      if (!readBy.containsKey(_currentUserId)) {
        batch.update(doc.reference, {'readBy.$_currentUserId': now});
      }
    }
    batch.commit().catchError((_) {});
  }

  void _showReadBySheet(String messageId) async {
    final groupId = widget.arguments.groupId;
    final doc = await FirebaseFirestore.instance
        .collection(FirestoreConstants.pathMessageCollection)
        .doc(groupId)
        .collection(groupId)
        .doc(messageId)
        .get();
    final readBy = Map<String, dynamic>.from(doc.data()?['readBy'] as Map? ?? {});
    if (!mounted) return;
    // Load member names
    if (_groupMembers.isEmpty) await _loadGroupMembers();
    showModalBottomSheet(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('Visto por', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            ),
            const Divider(height: 1),
            if (readBy.isEmpty)
              const Padding(padding: EdgeInsets.all(16), child: Text('Nadie ha leído este mensaje aún'))
            else
              ...readBy.entries.map((e) {
                final member = _groupMembers.firstWhere((m) => m['uid'] == e.key, orElse: () => {'uid': e.key, 'name': e.key, 'avatar': ''});
                final dt = DateTime.fromMillisecondsSinceEpoch(e.value as int? ?? 0);
                return ListTile(
                  leading: CircleAvatar(
                    backgroundImage: (member['avatar'] ?? '').isNotEmpty ? NetworkImage(member['avatar']!) : null,
                    backgroundColor: ColorConstants.greyColor2,
                    child: (member['avatar'] ?? '').isEmpty ? Text((member['name'] ?? '?')[0].toUpperCase()) : null,
                  ),
                  title: Text(member['name'] ?? e.key),
                  trailing: Text('${dt.hour.toString().padLeft(2,'0')}:${dt.minute.toString().padLeft(2,'0')}',
                      style: const TextStyle(color: Colors.grey, fontSize: 12)),
                );
              }),
          ],
        ),
      ),
    );
  }

  Widget _buildGroupTicks(Map<String, dynamic> readBy, List<String> memberUids) {
    // Remove own UID and sender
    final others = memberUids.where((uid) => uid != _currentUserId).toList();
    if (others.isEmpty) return const SizedBox.shrink();
    final allRead = others.every((uid) => readBy.containsKey(uid));
    final anyRead = readBy.isNotEmpty;
    if (allRead) return const Icon(Icons.done_all, size: 13, color: Colors.blue);
    if (anyRead) return const Icon(Icons.done_all, size: 13, color: Colors.grey);
    return const Icon(Icons.check, size: 13, color: Colors.grey);
  }

  Future<void> _changeGroupImage() async {
    try {
      final picker = ImagePicker();
      final xfile = await picker.pickImage(source: ImageSource.gallery, imageQuality: 75);
      if (xfile == null) return;
      Fluttertoast.showToast(msg: 'Subiendo imagen...');
      final fileName = 'group_${widget.arguments.groupId}_${DateTime.now().millisecondsSinceEpoch}';
      final snap = await _chatProvider.uploadFile(File(xfile.path), fileName);
      final url = await snap.ref.getDownloadURL();
      await FirebaseFirestore.instance
          .collection('groups')
          .doc(widget.arguments.groupId)
          .update({'groupImage': url});
      Fluttertoast.showToast(msg: '✅ Imagen actualizada', backgroundColor: Colors.green);
    } catch (e) {
      Fluttertoast.showToast(msg: 'Error: $e', backgroundColor: Colors.red);
    }
  }

  @override
  void dispose() {
    _stopGroupLiveLocation();
    _groupTypingSub?.cancel();
    _typingTimer?.cancel();
    _disappearTimer?.cancel();
    _chatProvider.setTyping(widget.arguments.groupId, _currentUserId, false);
    for (final c in _videoControllers.values) { c.dispose(); }
    _chatInputController.dispose();
    _listScrollController
      ..removeListener(_scrollListener)
      ..dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _scrollListener() {
    if (!_listScrollController.hasClients) return;
    if (_listScrollController.offset >= _listScrollController.position.maxScrollExtent &&
        !_listScrollController.position.outOfRange &&
        _limit <= _listMessage.length) {
      setState(() => _limit += _limitIncrement);
    }
  }

  void _scrollToMessage(String msgId) {
    final key = _messageKeys[msgId];
    if (key?.currentContext != null) {
      Scrollable.ensureVisible(
        key!.currentContext!,
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeInOut,
        alignment: 0.5,
      );
    }
  }

  void _onFocusChange() {
    if (_focusNode.hasFocus) {
      setState(() => _isShowSticker = false);
    }
  }

  Future<bool> _pickImage({ImageSource source = ImageSource.gallery}) async {
    final imagePicker = ImagePicker();
    final pickedXFile =
        await imagePicker.pickImage(source: source, imageQuality: 70).catchError((err) {
      Fluttertoast.showToast(msg: err.toString());
      return null;
    });
    if (pickedXFile != null) {
      setState(() {
        _imageFile = File(pickedXFile.path);
        _isLoading = true;
      });
      return true;
    }
    return false;
  }

  Future<void> _pickAndSendMultipleImages() async {
    final imagePicker = ImagePicker();
    List<XFile> pickedFiles = [];
    try {
      pickedFiles = await imagePicker.pickMultiImage(imageQuality: 70);
    } catch (e) {
      Fluttertoast.showToast(msg: e.toString());
      return;
    }
    if (pickedFiles.isEmpty) return;
    setState(() => _isLoading = true);
    for (final xfile in pickedFiles) {
      try {
        final fileName = DateTime.now().millisecondsSinceEpoch.toString();
        final snapshot = await _chatProvider.uploadFile(File(xfile.path), fileName);
        final url = await snapshot.ref.getDownloadURL();
        _onSendMessage(url, TypeMessage.image);
      } catch (e) {
        Fluttertoast.showToast(msg: 'Error al subir imagen');
      }
    }
    setState(() => _isLoading = false);
  }

  Future<void> _pickAndSendVideo() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.video);
    if (result == null || result.files.single.path == null) return;
    setState(() => _isLoading = true);
    try {
      final file = File(result.files.single.path!);
      final fileName = 'chat_videos/${_currentUserId}_${DateTime.now().millisecondsSinceEpoch}.mp4';
      final snap = await _chatProvider.uploadFile(file, fileName);
      final url = await snap.ref.getDownloadURL();
      _onSendMessage(url, TypeMessage.video);
    } catch (e) {
      Fluttertoast.showToast(msg: 'Error al subir video');
    }
    setState(() => _isLoading = false);
  }

  Future<void> _uploadFile() async {
    final fileName = DateTime.now().millisecondsSinceEpoch.toString();
    final uploadTask = _chatProvider.uploadFile(_imageFile!, fileName);
    try {
      final snapshot = await uploadTask;
      _imageUrl = await snapshot.ref.getDownloadURL();
      setState(() {
        _isLoading = false;
        _onSendMessage(_imageUrl, TypeMessage.image);
      });
    } on FirebaseException catch (e) {
      setState(() => _isLoading = false);
      Fluttertoast.showToast(msg: e.message ?? e.toString());
    }
  }

  void _onSendMessage(String content, int type) {
    if (content.trim().isEmpty) {
      Fluttertoast.showToast(msg: 'Nada que enviar', backgroundColor: ColorConstants.greyColor);
      return;
    }
    // Si estamos en modo edición, guardar edición en lugar de enviar nuevo
    if (_editingMessageId != null && type == TypeMessage.text) {
      _saveEdit();
      return;
    }
    _chatInputController.clear();
    final extras = <String, dynamic>{};
    if (_replyTo != null) {
      extras['replyTo'] = _replyTo;
      setState(() => _replyTo = null);
    }
    _chatProvider.setTyping(widget.arguments.groupId, _currentUserId, false);
    _typingTimer?.cancel();
    _sendGroupMessage(content, type, extras: extras.isNotEmpty ? extras : null);
    if (_listScrollController.hasClients) {
      _listScrollController.animateTo(0,
          duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
    }
  }

  void _sendGroupMessage(String content, int type, {Map<String, dynamic>? extras}) {
    final groupId = widget.arguments.groupId;
    final ts = DateTime.now().millisecondsSinceEpoch;
    final docRef = FirebaseFirestore.instance
        .collection(FirestoreConstants.pathMessageCollection)
        .doc(groupId)
        .collection(groupId)
        .doc(ts.toString());

    final data = <String, dynamic>{
      FirestoreConstants.idFrom: _currentUserId,
      FirestoreConstants.idTo: '',
      FirestoreConstants.timestamp: ts.toString(),
      FirestoreConstants.content: content,
      FirestoreConstants.type: type,
      'senderName': _currentNickname,
      'senderRolId': _currentRolId,
    };
    if (_disappearingSeconds > 0) {
      data['expiresAt'] = ts + (_disappearingSeconds * 1000);
    }
    // Initialize readBy — sender has already "read" their own message
    data['readBy'] = {_currentUserId: ts};
    if (extras != null) data.addAll(extras);

    FirebaseFirestore.instance.runTransaction((tx) async {
      tx.set(docRef, data);
    });

    // Metadata para lista de grupos: último mensaje + contadores de no-leídos.
    final preview = type == TypeMessage.text
        ? (content.length > 40 ? '${content.substring(0, 40)}...' : content)
        : type == TypeMessage.image
            ? '📷 Foto'
            : type == TypeMessage.location
                ? '📍 Ubicación'
                : type == TypeMessage.liveLocation
                    ? '📍 Ubicación en vivo'
                    : type == TypeMessage.audioCall
                        ? '📞 Llamada'
                        : type == TypeMessage.videoCall
                            ? '📹 Videollamada'
                            : type == TypeMessage.video
                                ? '🎥 Video'
                                : type == TypeMessage.alert
                                    ? () {
                                        try {
                                          final d = jsonDecode(content) as Map;
                                          final k = AlertKind.fromId((d['alertKind'] as num).toInt());
                                          return '${k.emoji} ${k.label}';
                                        } catch (_) { return '🚨 Alerta'; }
                                      }()
                            : '💬 Mensaje';

    () async {
      try {
        final groupRef = FirebaseFirestore.instance.collection('groups').doc(groupId);
        final snap = await groupRef.get();
        final members = ((snap.data()?['members'] as List?) ?? [])
            .map((e) => e.toString())
            .toList();
        final updates = <String, dynamic>{
          'lastMessage': '$_currentNickname: $preview',
          'lastTimestamp': ts,
          'lastSenderId': _currentUserId,
        };
        // Incrementar unread por cada miembro distinto al sender.
        // IMPORTANTE: usar update() (no set+merge) para que la notación
        // 'unreadCounts.$uid' se interprete como ruta anidada y NO como
        // un campo literal a nivel raíz.
        for (final uid in members) {
          if (uid == _currentUserId) continue;
          updates['unreadCounts.$uid'] = FieldValue.increment(1);
        }
        await groupRef.update(updates);
      } catch (_) {}
    }();
  }

  void _getSticker() {
    _focusNode.unfocus();
    setState(() => _isShowSticker = !_isShowSticker);
  }

  /// Efecto fiesta: emojis flotando + vibración al recibir KLK MANE ACTIVO
  void _triggerPartyEffect(String senderName) {
    // Vibración
    try { HapticFeedback.heavyImpact(); } catch (_) {}
    Future.delayed(const Duration(milliseconds: 150), () {
      try { HapticFeedback.heavyImpact(); } catch (_) {}
    });
    Future.delayed(const Duration(milliseconds: 300), () {
      try { HapticFeedback.heavyImpact(); } catch (_) {}
    });

    _partyOverlay?.remove();
    _partyOverlay = null;

    final overlay = Overlay.of(context);
    final size = MediaQuery.of(context).size;
    late OverlayEntry entry;
    entry = OverlayEntry(builder: (_) => _PartyOverlay(
      senderName: senderName,
      screenSize: size,
      onDone: () {
        entry.remove();
        if (_partyOverlay == entry) _partyOverlay = null;
      },
    ));
    overlay.insert(entry);
    _partyOverlay = entry;
  }

  /// Envía una alerta rápida con la ubicación actual del usuario al grupo
  /// y la registra en la colección global `alerts` para el mapa en tiempo real.
  Future<void> _sendQuickAlert(AlertKind kind) async {
    setState(() => _showAlertPanel = false);
    Fluttertoast.showToast(msg: 'Obteniendo ubicación...');

    Position? pos;
    try {
      final ok = await Geolocator.isLocationServiceEnabled();
      if (!ok) { Fluttertoast.showToast(msg: 'Activa el GPS'); return; }
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
        Fluttertoast.showToast(msg: 'Permiso de ubicación denegado'); return;
      }
      pos = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
    } catch (e) {
      Fluttertoast.showToast(msg: 'Error GPS: $e'); return;
    }

    final ts = DateTime.now().millisecondsSinceEpoch;
    final groupId = widget.arguments.groupId;
    final alertDocId = '${groupId}_${_currentUserId}_$ts';

    // Payload del mensaje de chat
    final payload = jsonEncode({
      'alertKind': kind.id,
      'lat': pos.latitude,
      'lng': pos.longitude,
      'senderName': _currentNickname,
      'ts': ts,
      'alertDocId': alertDocId,
    });

    // 1 – Enviar como mensaje al grupo
    _sendGroupMessage(payload, TypeMessage.alert);

    // 2 – Registrar en colección global `alerts` para el mapa
    await FirebaseFirestore.instance.collection('alerts').doc(alertDocId).set({
      'alertKind': kind.id,
      'lat': pos.latitude,
      'lng': pos.longitude,
      'groupId': groupId,
      'groupName': widget.arguments.groupName,
      'senderId': _currentUserId,
      'senderName': _currentNickname,
      'ts': ts,
      'expireAt': ts + 30 * 60 * 1000, // expira en 30 min
    });

    Fluttertoast.showToast(msg: '${kind.emoji} Alerta enviada');
  }

  Future<void> _startGroupLiveLocation() async {
    if (_isSharingLiveLocation) {
      await _stopGroupLiveLocation();
      return;
    }
    try {
      Fluttertoast.showToast(msg: 'Verificando GPS...');
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        Fluttertoast.showToast(msg: 'Activa el GPS del teléfono');
        return;
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.deniedForever ||
          permission == LocationPermission.denied) {
        Fluttertoast.showToast(msg: 'Permiso de ubicación denegado');
        return;
      }
    } catch (e) {
      Fluttertoast.showToast(msg: 'Error GPS: $e');
      return;
    }
    try {
      final groupId = widget.arguments.groupId;
      final docId = '${groupId}_$_currentUserId';
      await FirebaseFirestore.instance
          .collection(FirestoreConstants.pathLiveLocations)
          .doc(docId)
          .set({'active': true, 'lat': 0.0, 'lng': 0.0, 'fromId': _currentUserId, 'chatId': groupId});

      _sendGroupMessage(docId, TypeMessage.liveLocation);

      setState(() {
        _isSharingLiveLocation = true;
        _activeLiveLocationDocId = docId;
      });

      // Posición inicial INMEDIATA — sin esperar a que el usuario se mueva.
      // (El stream con distanceFilter:5 puede tardar en emitir el primer evento.)
      try {
        final initialPos = await Geolocator.getCurrentPosition(
            desiredAccuracy: LocationAccuracy.high);
        await Future.wait([
          FirebaseFirestore.instance
              .collection(FirestoreConstants.pathLiveLocations)
              .doc(docId)
              .update({'lat': initialPos.latitude, 'lng': initialPos.longitude}),
          FirebaseFirestore.instance
              .collection(FirestoreConstants.pathGroupLocations)
              .doc(groupId)
              .collection('members')
              .doc(_currentUserId)
              .set({
            'lat': initialPos.latitude,
            'lng': initialPos.longitude,
            'name': _currentNickname,
            'updatedAt': FieldValue.serverTimestamp(),
          }),
        ]);
      } catch (e) {
        // Si falla la posición inicial, igual seguimos con el stream.
        Fluttertoast.showToast(msg: 'No se pudo obtener posición inicial: $e');
      }

      _liveLocationSub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 5),
      ).listen((pos) {
        FirebaseFirestore.instance
            .collection(FirestoreConstants.pathLiveLocations)
            .doc(docId)
            .update({'lat': pos.latitude, 'lng': pos.longitude});
        // También publicar en el mapa del grupo (lo que lee GroupLiveMapPage).
        FirebaseFirestore.instance
            .collection(FirestoreConstants.pathGroupLocations)
            .doc(groupId)
            .collection('members')
            .doc(_currentUserId)
            .set({
          'lat': pos.latitude,
          'lng': pos.longitude,
          'name': _currentNickname,
          'updatedAt': FieldValue.serverTimestamp(),
        });
      }, onError: (e) {
        Fluttertoast.showToast(msg: 'Error GPS stream: $e');
      });

      Fluttertoast.showToast(msg: 'Compartiendo ubicación en vivo en el grupo...');
    } catch (e) {
      Fluttertoast.showToast(msg: 'Error al iniciar ubicación en vivo: $e');
    }
  }

  Future<void> _stopGroupLiveLocation() async {
    await _liveLocationSub?.cancel();
    _liveLocationSub = null;
    if (_activeLiveLocationDocId != null) {
      await FirebaseFirestore.instance
          .collection(FirestoreConstants.pathLiveLocations)
          .doc(_activeLiveLocationDocId)
          .update({'active': false}).catchError((_) {});
    }
    // Sacar al usuario del mapa del grupo.
    try {
      await FirebaseFirestore.instance
          .collection(FirestoreConstants.pathGroupLocations)
          .doc(widget.arguments.groupId)
          .collection('members')
          .doc(_currentUserId)
          .delete();
    } catch (_) {}
    if (mounted) {
      setState(() {
        _isSharingLiveLocation = false;
        _activeLiveLocationDocId = null;
      });
    }
  }

  Future<void> _sendGroupCallPush({
    required String roomName,
    required bool isVideo,
  }) async {
    try {
      final groupId = widget.arguments.groupId;
      final groupName = widget.arguments.groupName;

      // 1. Obtener lista de miembros del grupo
      final groupSnap = await FirebaseFirestore.instance
          .collection('groups')
          .doc(groupId)
          .get();
      final members = ((groupSnap.data()?['members'] as List?) ?? [])
          .map((e) => e.toString())
          .where((uid) => uid != _currentUserId)
          .toList();

      // 2. Para cada miembro, obtener pushToken y enviar FCM
      for (final uid in members) {
        final userSnap = await FirebaseFirestore.instance
            .collection(FirestoreConstants.pathUserCollection)
            .doc(uid)
            .get();
        final pushToken = userSnap.data()?['pushToken'] as String?;
        if (pushToken == null || pushToken.isEmpty) continue;

        http.post(
          Uri.parse('http://38.247.147.220/lamano/api_send_call_push.php'),
          headers: {'Content-Type': 'application/json'},
          body: json.encode({
            'push_token':  pushToken,
            'caller_name': '$_currentNickname (Grupo: $groupName)',
            'caller_uid':  _currentUserId,
            'room_name':   roomName,
            'is_video':    isVideo,
          }),
        ).timeout(const Duration(seconds: 10));
      }
    } catch (_) {
      // Push es best-effort
    }
  }

  Future<void> _startGroupJitsiCall({required bool videoMuted}) async {
    await Permission.microphone.request();
    if (!videoMuted) await Permission.camera.request();

    final groupId = widget.arguments.groupId;
    final groupName = widget.arguments.groupName;
    final roomName = 'grupo_${groupId}_${DateTime.now().millisecondsSinceEpoch}';
    final callType = videoMuted ? TypeMessage.audioCall : TypeMessage.videoCall;

    _sendGroupMessage(roomName, callType);
    _sendGroupCallPush(roomName: roomName, isVideo: !videoMuted);

    final jitsi = JitsiMeet();
    final myAvatar = _authProvider.prefs.getString(FirestoreConstants.photoUrl) ?? '';
    final options = JitsiMeetConferenceOptions(
      serverURL: 'https://jitsi.38.247.147.220.nip.io',
      room: roomName,
      configOverrides: {
        'startWithAudioMuted': false,
        'startWithVideoMuted': videoMuted,
        'subject': groupName,
        'defaultRemoteDisplayName': 'Participante',
        'enableLayerSuspension': true,
        'disableDeepLinking': true,
        'prejoinPageEnabled': false,
      },
      featureFlags: {
        'unsaferoomwarning.enabled': false,
        'prejoinpage.enabled': false,
        'tile-view.enabled': true,
        'filmstrip.enabled': true,
        'toolbox.alwaysVisible': false,
        'invite.enabled': false,
        'meeting-name.enabled': true,
        'pip.enabled': true,
      },
      userInfo: JitsiMeetUserInfo(
        displayName: _currentNickname,
        email: '',
        avatar: myAvatar.isNotEmpty ? myAvatar : null,
      ),
    );
    await jitsi.join(options);
  }

  Widget _buildGroupCallBubble(String roomName, {required bool isVideo}) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      constraints: const BoxConstraints(maxWidth: 220),
      decoration: BoxDecoration(
        color: const Color(0xFF1A3A2A),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF00E65A), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(isVideo ? Icons.videocam : Icons.call,
                  color: const Color(0xFF00E65A), size: 18),
              const SizedBox(width: 6),
              Text(
                isVideo ? 'Videollamada grupal' : 'Llamada grupal',
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ElevatedButton.icon(
            onPressed: () {
              final myAvatar2 = _authProvider.prefs.getString(FirestoreConstants.photoUrl) ?? '';
              final jitsi = JitsiMeet();
              jitsi.join(JitsiMeetConferenceOptions(
                serverURL: 'https://jitsi.38.247.147.220.nip.io',
                room: roomName,
                configOverrides: {
                  'startWithAudioMuted': false,
                  'startWithVideoMuted': !isVideo,
                  'subject': widget.arguments.groupName,
                  'defaultRemoteDisplayName': 'Participante',
                  'prejoinPageEnabled': false,
                  'disableDeepLinking': true,
                },
                featureFlags: {
                  'unsaferoomwarning.enabled': false,
                  'prejoinpage.enabled': false,
                  'tile-view.enabled': true,
                  'filmstrip.enabled': true,
                  'toolbox.alwaysVisible': false,
                  'invite.enabled': false,
                  'pip.enabled': true,
                },
                userInfo: JitsiMeetUserInfo(
                  displayName: _currentNickname,
                  email: '',
                  avatar: myAvatar2.isNotEmpty ? myAvatar2 : null,
                ),
              ));
            },
            icon: const Icon(Icons.meeting_room, size: 16),
            label: const Text('Unirse'),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00E65A),
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _shareLocation() async {
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        Fluttertoast.showToast(msg: 'Activa la ubicación del teléfono');
        return;
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        Fluttertoast.showToast(msg: 'No se concedió permiso de ubicación');
        return;
      }

      setState(() => _isLoading = true);
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
      );
      final payload = jsonEncode({
        'lat': position.latitude,
        'lng': position.longitude,
      });
      setState(() => _isLoading = false);
      _onSendMessage(payload, TypeMessage.location);
    } catch (_) {
      setState(() => _isLoading = false);
      Fluttertoast.showToast(msg: 'No se pudo obtener la ubicación');
    }
  }

  Map<String, double>? _parseLocationContent(String content) {
    try {
      final data = jsonDecode(content);
      if (data is Map<String, dynamic>) {
        final lat = (data['lat'] as num?)?.toDouble();
        final lng = (data['lng'] as num?)?.toDouble();
        if (lat != null && lng != null) {
          return {'lat': lat, 'lng': lng};
        }
      }
    } catch (_) {}
    return null;
  }

  Future<void> _openLocation(double lat, double lng) async {
    final uri = Uri.parse('https://www.google.com/maps/search/?api=1&query=$lat,$lng');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  Widget _buildLiveLocationBubble(String docId, {required bool isMe}) {
    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance
          .collection(FirestoreConstants.pathLiveLocations)
          .doc(docId)
          .snapshots(),
      builder: (_, snapshot) {
        final data = snapshot.data?.data() as Map<String, dynamic>?;
        final active = data?['active'] as bool? ?? false;
        final lat = (data?['lat'] as num?)?.toDouble();
        final lng = (data?['lng'] as num?)?.toDouble();
        final hasPos = lat != null && lng != null && (lat != 0.0 || lng != 0.0);

        return GestureDetector(
          onTap: hasPos ? () {
            final uri = Uri.parse('https://www.google.com/maps/search/?api=1&query=$lat,$lng');
            launchUrl(uri, mode: LaunchMode.externalApplication);
          } : null,
          child: Container(
            constraints: const BoxConstraints(maxWidth: 220),
            padding: const EdgeInsets.fromLTRB(15, 12, 15, 12),
            decoration: BoxDecoration(
              color: isMe ? ColorConstants.greyColor2 : ColorConstants.primaryColor,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(active ? Icons.location_on : Icons.location_off,
                        color: active ? Colors.green : (isMe ? Colors.grey : Colors.white70),
                        size: 18),
                    const SizedBox(width: 6),
                    Text(
                      active ? 'Ubicación en vivo' : 'Ubicación finalizada',
                      style: TextStyle(
                        color: isMe ? ColorConstants.primaryColor : Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
                if (active && hasPos) ...[
                  const SizedBox(height: 6),
                  Text(
                    'Lat: ${lat!.toStringAsFixed(5)}\nLng: ${lng!.toStringAsFixed(5)}',
                    style: TextStyle(color: isMe ? ColorConstants.primaryColor : Colors.white, fontSize: 11),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Toca para abrir en Maps',
                    style: TextStyle(color: isMe ? Colors.blue : Colors.white70, decoration: TextDecoration.underline, fontSize: 12),
                  ),
                ],
                if (!active)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      'El usuario dejó de compartir',
                      style: TextStyle(color: isMe ? Colors.grey : Colors.white60, fontSize: 11, fontStyle: FontStyle.italic),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildLocationBubble(String content, {required bool isMe}) {
    final location = _parseLocationContent(content);
    if (location == null) {
      return Container(
        padding: const EdgeInsets.fromLTRB(15, 10, 15, 10),
        constraints: const BoxConstraints(maxWidth: 220),
        decoration: BoxDecoration(
          color: isMe ? ColorConstants.greyColor2 : ColorConstants.primaryColor,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          'Ubicación no disponible',
          style: TextStyle(color: isMe ? ColorConstants.primaryColor : Colors.white),
        ),
      );
    }

    final lat = location['lat']!;
    final lng = location['lng']!;
    return Container(
      constraints: const BoxConstraints(maxWidth: 220),
      padding: const EdgeInsets.fromLTRB(15, 12, 15, 12),
      decoration: BoxDecoration(
        color: isMe ? ColorConstants.greyColor2 : ColorConstants.primaryColor,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.location_on,
                  color: isMe ? Colors.redAccent : Colors.white, size: 18),
              const SizedBox(width: 6),
              Text(
                'Ubicación compartida',
                style: TextStyle(
                  color: isMe ? ColorConstants.primaryColor : Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Lat: ${lat.toStringAsFixed(5)}\nLng: ${lng.toStringAsFixed(5)}',
            style: TextStyle(
              color: isMe ? ColorConstants.primaryColor : Colors.white,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 10),
          InkWell(
            onTap: () => _openLocation(lat, lng),
            child: Text(
              'Abrir en Maps',
              style: TextStyle(
                color: isMe ? Colors.blue : Colors.white70,
                decoration: TextDecoration.underline,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRichText(String text, Color textColor) {
    final urlRegex = RegExp(r'https?://[^\s]+');
    final spans = <TextSpan>[];
    int last = 0;
    for (final match in urlRegex.allMatches(text)) {
      if (match.start > last) {
        spans.add(TextSpan(text: text.substring(last, match.start), style: TextStyle(color: textColor)));
      }
      final url = text.substring(match.start, match.end);
      spans.add(TextSpan(
        text: url,
        style: const TextStyle(color: Colors.blue, decoration: TextDecoration.underline),
        recognizer: TapGestureRecognizer()
          ..onTap = () async {
            final uri = Uri.parse(url);
            if (await canLaunchUrl(uri)) {
              await launchUrl(uri, mode: LaunchMode.externalApplication);
            }
          },
      ));
      last = match.end;
    }
    if (last < text.length) {
      spans.add(TextSpan(text: text.substring(last), style: TextStyle(color: textColor)));
    }
    if (spans.isEmpty) return Text(text, style: TextStyle(color: textColor));
    return RichText(text: TextSpan(children: spans));
  }

  bool get _isMuted => _mutedUntil > DateTime.now().millisecondsSinceEpoch;

  String _formatDisappearDuration(int secs) {
    if (secs >= 604800) return '7 días';
    if (secs >= 86400) return '24 horas';
    if (secs >= 28800) return '8 horas';
    if (secs >= 3600) return '1 hora';
    return '${secs}s';
  }

  void _handleAppBarMenu(String val) async {
    if (val == 'members') {
      _showMembersSheet();
      return;
    }
    if (val == 'mute') {
      if (_isMuted) {
        setState(() => _mutedUntil = 0);
        await _authProvider.prefs.remove('muted_until_${widget.arguments.groupId}');
        Fluttertoast.showToast(msg: 'Notificaciones activadas');
      } else {
        _showMuteDialog();
      }
    }
    if (val == 'disappearing') {
      final doc = await FirebaseFirestore.instance
          .collection('groups')
          .doc(widget.arguments.groupId)
          .get();
      final createdBy = doc.data()?['createdBy'] as String? ?? '';
      final nick = _currentNickname.toLowerCase().trim();
      final canChange = createdBy == _currentUserId
          || _currentRolId == '1'
          || nick == 'jimmy'
          || nick == 'admin';
      _showDisappearingDialog(canChange);
    }
  }

  void _showMuteDialog() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Silenciar notificaciones'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final opt in [
              {'label': '1 hora', 'ms': 3600000},
              {'label': '8 horas', 'ms': 28800000},
              {'label': '24 horas', 'ms': 86400000},
              {'label': 'Siempre', 'ms': 9999999999999},
            ])
              ListTile(
                title: Text(opt['label'] as String),
                onTap: () async {
                  final until = DateTime.now().millisecondsSinceEpoch + (opt['ms'] as int);
                  setState(() => _mutedUntil = until);
                  await _authProvider.prefs.setInt('muted_until_${widget.arguments.groupId}', until);
                  Navigator.pop(context);
                  Fluttertoast.showToast(msg: 'Silenciado por ${opt['label']}');
                },
              ),
          ],
        ),
      ),
    );
  }

  // ── Cargar miembros del grupo ──────────────────────────────
  Future<void> _loadGroupMembers() async {
    final snap = await FirebaseFirestore.instance
        .collection('groups')
        .doc(widget.arguments.groupId)
        .get();
    final uids = ((snap.data()?['members'] as List?) ?? []).cast<String>();
    final List<Map<String, String>> members = [];
    for (final uid in uids) {
      final userSnap = await FirebaseFirestore.instance
          .collection(FirestoreConstants.pathUserCollection)
          .doc(uid)
          .get();
      final d = userSnap.data();
      if (d != null) {
        members.add({
          'uid': uid,
          'name': d[FirestoreConstants.nickname] as String? ?? uid,
          'avatar': d[FirestoreConstants.photoUrl] as String? ?? '',
        });
      }
    }
    if (mounted) setState(() => _groupMembers = members);
  }

  void _showMembersSheet() async {
    if (_groupMembers.isEmpty) await _loadGroupMembers();
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text('Miembros (${_groupMembers.length})',
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView.builder(
              itemCount: _groupMembers.length,
              itemBuilder: (_, i) {
                final m = _groupMembers[i];
                return ListTile(
                  leading: CircleAvatar(
                    backgroundImage: m['avatar']!.isNotEmpty ? NetworkImage(m['avatar']!) : null,
                    child: m['avatar']!.isEmpty ? Text(m['name']![0].toUpperCase()) : null,
                  ),
                  title: Text(m['name']!),
                  subtitle: m['uid'] == _currentUserId ? const Text('Tú', style: TextStyle(color: ColorConstants.primaryColor)) : null,
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  // ── @menciones ──────────────────────────────────────────────
  void _handleMentionInput(String text) {
    final cursor = _chatInputController.selection.baseOffset;
    if (cursor < 0) return;
    final before = text.substring(0, cursor > text.length ? text.length : cursor);
    final match = RegExp(r'@(\w*)$').firstMatch(before);
    if (match != null) {
      final query = match.group(1)!.toLowerCase();
      if (_groupMembers.isEmpty) _loadGroupMembers();
      final suggestions = _groupMembers
          .where((m) => m['name']!.toLowerCase().contains(query))
          .toList();
      setState(() {
        _mentionSuggestions = suggestions;
        _showMentionSuggestions = suggestions.isNotEmpty;
      });
    } else {
      setState(() => _showMentionSuggestions = false);
    }
  }

  void _insertMention(Map<String, String> member) {
    final text = _chatInputController.text;
    final cursor = _chatInputController.selection.baseOffset;
    final before = text.substring(0, cursor > text.length ? text.length : cursor);
    final after = cursor < text.length ? text.substring(cursor) : '';
    final newBefore = before.replaceFirst(RegExp(r'@\w*$'), '@${member['name']} ');
    _chatInputController.value = TextEditingValue(
      text: newBefore + after,
      selection: TextSelection.collapsed(offset: newBefore.length),
    );
    setState(() => _showMentionSuggestions = false);
  }

  // ── Editar mensaje ──────────────────────────────────────────
  void _startEditing(String messageId, String content) {
    setState(() {
      _editingMessageId = messageId;
      _editingOriginalContent = content;
    });
    _chatInputController.text = content;
    _chatInputController.selection = TextSelection.collapsed(offset: content.length);
    _focusNode.requestFocus();
    Navigator.pop(context);
  }

  Future<void> _saveEdit() async {
    if (_editingMessageId == null) return;
    final newContent = _chatInputController.text.trim();
    if (newContent.isEmpty) return;
    await FirebaseFirestore.instance
        .collection(FirestoreConstants.pathMessageCollection)
        .doc(widget.arguments.groupId)
        .collection(widget.arguments.groupId)
        .doc(_editingMessageId)
        .update({
      FirestoreConstants.content: newContent,
      'edited': true,
      'editedAt': DateTime.now().millisecondsSinceEpoch,
    });
    setState(() {
      _editingMessageId = null;
      _editingOriginalContent = null;
    });
    _chatInputController.clear();
  }

  // ── Reenviar mensaje ────────────────────────────────────────
  void _showForwardSheet(String content, int type) {
    Navigator.pop(context); // cierra el bottom sheet de reacciones
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => Column(
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('Reenviar a...', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView.builder(
              itemCount: _groupMembers.length,
              itemBuilder: (ctx, i) {
                final m = _groupMembers[i];
                if (m['uid'] == _currentUserId) return const SizedBox.shrink();
                return ListTile(
                  leading: CircleAvatar(
                    backgroundImage: m['avatar']!.isNotEmpty ? NetworkImage(m['avatar']!) : null,
                    child: m['avatar']!.isEmpty ? Text(m['name']![0].toUpperCase()) : null,
                  ),
                  title: Text(m['name']!),
                  onTap: () {
                    // Reenviar al chat individual con ese usuario
                    final chatId = _currentUserId.compareTo(m['uid']!) < 0
                        ? '${_currentUserId}-${m['uid']}'
                        : '${m['uid']!}-$_currentUserId';
                    FirebaseFirestore.instance
                        .collection(FirestoreConstants.pathMessageCollection)
                        .doc(chatId)
                        .collection(chatId)
                        .add({
                      FirestoreConstants.idFrom: _currentUserId,
                      FirestoreConstants.idTo: m['uid'],
                      FirestoreConstants.content: content,
                      FirestoreConstants.type: type,
                      FirestoreConstants.timestamp: DateTime.now().millisecondsSinceEpoch.toString(),
                      'forwarded': true,
                    });
                    Navigator.pop(context);
                    Fluttertoast.showToast(msg: 'Reenviado a ${m['name']}');
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  void _showReactionPicker(String messageId, String groupId) {
    const emojis = ['❤️', '👍', '😂', '😮', '😢', '👏'];
    bool _isOwner = false;
    String _deletedBy = '';
    String _msgContent = '';
    int _msgType = TypeMessage.text;
    try {
      final doc = _listMessage.firstWhere((d) => d.id == messageId);
      final data = doc.data() as Map<String, dynamic>;
      _isOwner = (data[FirestoreConstants.idFrom] as String? ?? '') == _currentUserId;
      _deletedBy = data['deletedBy'] as String? ?? '';
      _msgContent = data[FirestoreConstants.content] as String? ?? '';
      _msgType = data[FirestoreConstants.type] as int? ?? TypeMessage.text;
    } catch (_) {}
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Emoji reactions
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: emojis.map((e) => GestureDetector(
                  onTap: () {
                    Navigator.pop(context);
                    _chatProvider.toggleReaction(groupId, messageId, e, _currentUserId);
                  },
                  child: Text(e, style: const TextStyle(fontSize: 32)),
                )).toList(),
              ),
            ),
            const Divider(height: 1),
            // Fijar
            ListTile(
              leading: Icon(
                (_pinnedMessage != null && _pinnedMessage!['msgId'] == messageId) ? Icons.push_pin : Icons.push_pin_outlined,
                color: ColorConstants.primaryColor),
              title: Text(
                (_pinnedMessage != null && _pinnedMessage!['msgId'] == messageId) ? 'Desfijar mensaje' : 'Fijar mensaje',
                style: const TextStyle(fontSize: 14)),
              onTap: () {
                Navigator.pop(context);
                _toggleGroupPin(messageId, _msgContent);
              },
            ),
            // Reenviar
            if (_deletedBy.isEmpty) ...[
              ListTile(
                leading: const Icon(Icons.forward, color: ColorConstants.primaryColor),
                title: const Text('Reenviar', style: TextStyle(fontSize: 14)),
                onTap: () {
                  if (_groupMembers.isEmpty) _loadGroupMembers();
                  _showForwardSheet(_msgContent, _msgType);
                },
              ),
            ],
            // Editar (solo mensajes de texto propios)
            if (_isOwner && _deletedBy.isEmpty && _msgType == TypeMessage.text) ...[
              ListTile(
                leading: const Icon(Icons.edit_outlined, color: Colors.blue),
                title: const Text('Editar mensaje', style: TextStyle(fontSize: 14)),
                onTap: () => _startEditing(messageId, _msgContent),
              ),
            ],
            // Delete options (only if not already deleted)
            if (_deletedBy.isEmpty) ...[
              ListTile(
                leading: const Icon(Icons.delete_outline, color: Colors.orange),
                title: const Text('Eliminar mensaje', style: TextStyle(fontSize: 14)),
                subtitle: const Text('Queda visible como eliminado', style: TextStyle(fontSize: 11, color: Colors.grey)),
                onTap: () {
                  Navigator.pop(context);
                  _deleteMessage(messageId, groupId);
                },
              ),
            ],
            ListTile(
              leading: const Icon(Icons.delete_forever, color: Colors.red),
              title: const Text('Eliminar permanente', style: TextStyle(fontSize: 14, color: Colors.red)),
              subtitle: const Text('Se borra para siempre sin dejar rastro', style: TextStyle(fontSize: 11, color: Colors.grey)),
              onTap: () {
                Navigator.pop(context);
                _permanentDeleteMessage(messageId, groupId);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _deleteMessage(String messageId, String groupId) async {
    await FirebaseFirestore.instance
        .collection(FirestoreConstants.pathMessageCollection)
        .doc(groupId)
        .collection(groupId)
        .doc(messageId)
        .update({
      'deletedBy': _currentUserId,
      'deletedByName': _currentNickname,
      'deletedAt': DateTime.now().millisecondsSinceEpoch,
    });
  }

  Future<void> _permanentDeleteMessage(String messageId, String groupId) async {
    await FirebaseFirestore.instance
        .collection(FirestoreConstants.pathMessageCollection)
        .doc(groupId)
        .collection(groupId)
        .doc(messageId)
        .delete();
  }

  Widget _buildReactions(Map<String, dynamic> reactions) {
    if (reactions.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: 4,
      children: reactions.entries.map((entry) {
        final users = (entry.value as List?)?.length ?? 0;
        if (users == 0) return const SizedBox.shrink();
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: Colors.grey.shade300),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text('${entry.key} $users', style: const TextStyle(fontSize: 13)),
        );
      }).toList(),
    );
  }

  Widget _buildReplyBubble(Map<String, dynamic> replyTo, {VoidCallback? onTap}) {
    final content = replyTo['content'] as String? ?? '';
    final sender = replyTo['senderName'] as String? ?? 'Mensaje';
    final type = replyTo['type'] as int? ?? 0;
    final preview = type == TypeMessage.image ? '📷 Foto' : type == TypeMessage.video ? '🎥 Video' : type == TypeMessage.audio ? '🎤 Audio' : content.length > 60 ? '${content.substring(0, 60)}...' : content;
    return GestureDetector(
      onTap: onTap,
      child: Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      decoration: BoxDecoration(
        color: const Color(0xFFDCF8C6),
        border: const Border(left: BorderSide(color: Color(0xFF25D366), width: 3)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(sender, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: Color(0xFF075E54))),
          const SizedBox(height: 1),
          Text(preview, style: const TextStyle(fontSize: 11, color: Colors.black54), maxLines: 2, overflow: TextOverflow.ellipsis),
        ],
      ),
    ));
  }

  Widget _buildReplyPreviewBar() {
    if (_replyTo == null) return const SizedBox.shrink();
    final content = _replyTo!['content'] as String? ?? '';
    final sender = _replyTo!['senderName'] as String? ?? 'Mensaje';
    final type = _replyTo!['type'] as int? ?? 0;
    final preview = type == TypeMessage.image ? '📷 Foto' : type == TypeMessage.video ? '🎥 Video' : type == TypeMessage.audio ? '🎤 Audio' : content.length > 60 ? '${content.substring(0, 60)}...' : content;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
      color: const Color(0xFFE8F5E9),
      child: Row(
        children: [
          Container(width: 3, height: 36, color: const Color(0xFF25D366)),
          const SizedBox(width: 8),
          Expanded(child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(sender, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Color(0xFF075E54))),
              Text(preview, style: const TextStyle(fontSize: 12, color: Colors.black54), maxLines: 1, overflow: TextOverflow.ellipsis),
            ],
          )),
          GestureDetector(
            onTap: () => setState(() => _replyTo = null),
            child: const Icon(Icons.close, size: 18, color: Colors.grey),
          ),
        ],
      ),
    );
  }

  Widget _buildVideoBubble(String url) {
    if (!_videoControllers.containsKey(url)) {
      final ctrl = VideoPlayerController.networkUrl(Uri.parse(url));
      _videoControllers[url] = ctrl;
      ctrl.initialize().then((_) { if (mounted) setState(() {}); });
    }
    final ctrl = _videoControllers[url]!;
    return GestureDetector(
      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => FullVideoPage(url: url))),
      child: Container(
        width: 220,
        height: 160,
        decoration: BoxDecoration(color: Colors.black, borderRadius: BorderRadius.circular(8)),
        clipBehavior: Clip.hardEdge,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (ctrl.value.isInitialized)
              AspectRatio(aspectRatio: ctrl.value.aspectRatio, child: VideoPlayer(ctrl))
            else
              const Center(child: CircularProgressIndicator(color: Colors.white)),
            Center(
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: const BoxDecoration(color: Colors.black45, shape: BoxShape.circle),
                child: const Icon(Icons.play_arrow, color: Colors.white, size: 36),
              ),
            ),
            // Fullscreen hint
            Positioned(
              top: 6,
              right: 6,
              child: Icon(Icons.fullscreen, color: Colors.white70, size: 20),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDeletedBubble(String deletedByName, bool isMe) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      constraints: const BoxConstraints(maxWidth: 240),
      decoration: BoxDecoration(
        color: isMe ? const Color(0xFFE0E0E0) : const Color(0xFFF5F5F5),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.delete_outline, size: 14, color: Colors.grey),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              'Eliminado por $deletedByName',
              style: const TextStyle(fontSize: 12, color: Colors.grey, fontStyle: FontStyle.italic),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildItemMessage(int index, DocumentSnapshot? document) {
    if (document == null) return const SizedBox.shrink();
    final data = document.data() as Map<String, dynamic>;
    final idFrom = data[FirestoreConstants.idFrom] as String? ?? '';
    final content = data[FirestoreConstants.content] as String? ?? '';
    final type = data[FirestoreConstants.type] as int? ?? TypeMessage.text;
    final timestamp = data[FirestoreConstants.timestamp] as String? ?? '0';
    final senderName = data['senderName'] as String? ?? '';
    final reactions = Map<String, dynamic>.from(data['reactions'] as Map? ?? {});
    final replyTo = data['replyTo'] as Map<String, dynamic>?;
    final deletedByName = data['deletedByName'] as String? ?? '';
    final isDeleted = (data['deletedBy'] as String? ?? '').isNotEmpty;
    final readBy = Map<String, dynamic>.from(data['readBy'] as Map? ?? {});

    final isMe = idFrom == _currentUserId;
    final showSender = !isMe && (index == _listMessage.length - 1 ||
        (_listMessage[index + 1].get(FirestoreConstants.idFrom) != idFrom));
    final msgKey = _messageKeys.putIfAbsent(document.id, () => GlobalKey());

    // Filtro de búsqueda
    if (_searchQuery.isNotEmpty && !content.toLowerCase().contains(_searchQuery)) {
      return const SizedBox.shrink();
    }

    Widget _bubbleContent() {
      // If deleted, always show the deleted bubble
      if (isDeleted) return _buildDeletedBubble(deletedByName, isMe);
      final isEdited = data['edited'] == true;

      if (type == TypeMessage.text) {
        return Container(
          padding: const EdgeInsets.fromLTRB(15, 10, 15, 10),
          constraints: const BoxConstraints(maxWidth: 220),
          decoration: BoxDecoration(
            color: isMe ? _myBubbleColor : ColorConstants.bgReceived,
            borderRadius: BorderRadius.circular(8),
            boxShadow: const [BoxShadow(color: Color(0x14000000), blurRadius: 2, offset: Offset(0,1))],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (replyTo != null) _buildReplyBubble(replyTo, onTap: () => _scrollToMessage(replyTo['msgId'] ?? '')),
              _buildRichText(content, isMe ? ColorConstants.textPrimary : ColorConstants.textPrimary),
              if (isEdited)
                const Padding(
                  padding: EdgeInsets.only(top: 2),
                  child: Text('editado', style: TextStyle(fontSize: 10, color: Colors.grey, fontStyle: FontStyle.italic)),
                ),
            ],
          ),
        );
      } else if (type == TypeMessage.image) {
        return _buildImageBubble(content, isMe: isMe);
      } else if (type == TypeMessage.video) {
        return _buildVideoBubble(content);
      } else if (type == TypeMessage.location) {
        return LocationMapBubble(payload: content, isMe: isMe, live: false);
      } else if (type == TypeMessage.liveLocation) {
        return LocationMapBubble(payload: content, isMe: isMe, live: true);
      } else if (type == TypeMessage.videoCall || type == TypeMessage.audioCall) {
        return _buildGroupCallBubble(content, isVideo: type == TypeMessage.videoCall);
      } else if (type == TypeMessage.alert) {
        return _buildAlertBubble(content);
      } else {
        return _buildStickerBubble(content, isMe: isMe);
      }
    }

    Widget bubble = GestureDetector(
      onLongPress: () => _showReactionPicker(document.id, widget.arguments.groupId),
      onHorizontalDragEnd: (details) {
        if (details.primaryVelocity != null && details.primaryVelocity! > 200) {
          setState(() => _replyTo = {
            'content': content,
            'senderName': isMe ? _currentNickname : senderName,
            'msgId': document.id,
            'type': type,
          });
        }
      },
      child: Column(
        crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _bubbleContent(),
          if (reactions.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: _buildReactions(reactions),
            ),
        ],
      ),
    );

    if (isMe) {
      final memberUids = _groupMembers.map((m) => m['uid'] ?? '').whereType<String>().toList();
      return Container(
        key: msgKey,
        margin: const EdgeInsets.only(bottom: 10, right: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [bubble]),
            Padding(
              padding: const EdgeInsets.only(top: 3, right: 2),
              child: GestureDetector(
                onTap: () => _showReadBySheet(document.id),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      DateFormat('HH:mm').format(DateTime.fromMillisecondsSinceEpoch(int.tryParse(timestamp) ?? 0)),
                      style: const TextStyle(color: ColorConstants.greyColor, fontSize: 11),
                    ),
                    const SizedBox(width: 3),
                    _buildGroupTicks(readBy, memberUids.isEmpty
                        ? _groupMembers.map((m) => m['uid'] ?? '').whereType<String>().toList()
                        : memberUids),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    } else {
      return Container(
        key: msgKey,
        margin: const EdgeInsets.only(bottom: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (showSender)
                  const Icon(Icons.account_circle, size: 35, color: ColorConstants.greyColor)
                else
                  const SizedBox(width: 35),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (showSender)
                      Padding(
                        padding: const EdgeInsets.only(left: 4, bottom: 2),
                        child: (data['senderRolId'] as String? ?? '') == '1'
                            ? RainbowText(senderName, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold))
                            : Text(senderName, style: const TextStyle(color: ColorConstants.primaryColor, fontSize: 11, fontWeight: FontWeight.bold)),
                      ),
                    bubble,
                  ],
                ),
              ],
            ),
            if (showSender)
              Padding(
                padding: const EdgeInsets.only(left: 48, top: 4),
                child: Text(
                  DateFormat('dd MMM kk:mm').format(DateTime.fromMillisecondsSinceEpoch(int.tryParse(timestamp) ?? 0)),
                  style: const TextStyle(color: ColorConstants.greyColor, fontSize: 11, fontStyle: FontStyle.italic),
                ),
              ),
          ],
        ),
      );
    }
  }

  Widget _buildImageBubble(String url, {required bool isMe}) {
    return GestureDetector(
      onTap: () => Navigator.push(
          context, MaterialPageRoute(builder: (_) => FullPhotoPage(url: url))),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.network(url, width: 200, height: 200, fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => Image.asset('images/img_not_available.jpeg',
                width: 200, height: 200, fit: BoxFit.cover)),
      ),
    );
  }

  Widget _buildStickerBubble(String name, {required bool isMe}) {
    if (name.startsWith('http')) {
      return Image.network(name, width: 120, height: 120, fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => const Icon(Icons.broken_image));
    }
    return Image.asset('images/$name.gif', width: 120, height: 120, fit: BoxFit.cover);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ColorConstants.bgChat,
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(
          children: [
            StreamBuilder<DocumentSnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('groups')
                  .doc(widget.arguments.groupId)
                  .snapshots(),
              builder: (_, snap) {
                final data = snap.data?.data() as Map<String, dynamic>?;
                final img = (data?['groupImage'] as String?) ?? widget.arguments.groupImage;
                final createdBy = (data?['createdBy'] as String?) ?? '';
                final _nick = _currentNickname.toLowerCase().trim();
                final isCreator = createdBy == _currentUserId
                    || _currentRolId == '1'
                    || _nick == 'jimmy'
                    || _nick == 'admin';
                return GestureDetector(
                  onTap: isCreator ? _changeGroupImage : null,
                  child: Stack(
                    children: [
                      CircleAvatar(
                        radius: 18,
                        backgroundColor: ColorConstants.primaryColor,
                        backgroundImage: img.isNotEmpty ? NetworkImage(img) : null,
                        child: img.isEmpty
                            ? Text(
                                widget.arguments.groupName.isNotEmpty
                                    ? widget.arguments.groupName[0].toUpperCase()
                                    : 'G',
                                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                              )
                            : null,
                      ),
                      if (isCreator)
                        Positioned(
                          right: 0, bottom: 0,
                          child: Container(
                            padding: const EdgeInsets.all(2),
                            decoration: const BoxDecoration(
                              color: Colors.white,
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(Icons.camera_alt, size: 10, color: ColorConstants.primaryColor),
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
            const SizedBox(width: 10),
            Expanded(
              child: GestureDetector(
                onTap: _showMembersSheet,
                child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_searchMode)
                    TextField(
                      controller: _searchController,
                      autofocus: true,
                      style: const TextStyle(color: Colors.white),
                      decoration: const InputDecoration(
                        hintText: 'Buscar en el chat...',
                        hintStyle: TextStyle(color: Colors.white70),
                        border: InputBorder.none,
                      ),
                      onChanged: (v) => setState(() => _searchQuery = v.toLowerCase()),
                    )
                  else ...[
                  Text(widget.arguments.groupName,
                      style: const TextStyle(color: Colors.white),
                      overflow: TextOverflow.ellipsis),
                  if (_typingUsers.isNotEmpty)
                    const Text('escribiendo...', style: TextStyle(fontSize: 10, color: Colors.green, fontStyle: FontStyle.italic))
                  else if (widget.arguments.groupDescription.isNotEmpty)
                    Text(widget.arguments.groupDescription,
                        style: const TextStyle(color: ColorConstants.greyColor, fontSize: 11),
                        overflow: TextOverflow.ellipsis),
                  if (_isMuted)
                    const Text('🔇 silenciado', style: TextStyle(fontSize: 10, color: Colors.grey)),
                  ],
                ],
                ),
              ),
            ),
          ],
        ),
        centerTitle: false,
        actions: [
          IconButton(
            icon: const Icon(Icons.videocam),
            tooltip: 'Videollamada grupal',
            color: Colors.white,
            onPressed: () => _startGroupJitsiCall(videoMuted: false),
          ),
          IconButton(
            icon: const Icon(Icons.call),
            tooltip: 'Llamada grupal',
            color: Colors.white,
            onPressed: () => _startGroupJitsiCall(videoMuted: true),
          ),
          IconButton(
            icon: const Icon(Icons.map_outlined),
            tooltip: 'Mapa en vivo',
            color: Colors.white,
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => GroupLiveMapPage(
                  groupId: widget.arguments.groupId,
                  groupName: widget.arguments.groupName,
                  currentUserId: _currentUserId,
                  currentUserName: _currentNickname,
                ),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.search, color: Colors.white),
            tooltip: 'Buscar en el chat',
            onPressed: () => setState(() {
              _searchMode = !_searchMode;
              if (!_searchMode) _searchQuery = '';
            }),
          ),
          PopupMenuButton<String>(
            onSelected: _handleAppBarMenu,
            itemBuilder: (_) => [
              PopupMenuItem(value: 'members', child: Row(children: [
                const Icon(Icons.group, size: 18, color: Colors.grey),
                const SizedBox(width: 8),
                const Text('Ver miembros'),
              ])),
              PopupMenuItem(value: 'mute', child: Row(children: [
                Icon(_isMuted ? Icons.notifications_active : Icons.notifications_off, size: 18, color: Colors.grey),
                const SizedBox(width: 8),
                Text(_isMuted ? 'Activar notificaciones' : 'Silenciar'),
              ])),
              PopupMenuItem(value: 'disappearing', child: Row(children: [
                Icon(_disappearingSeconds > 0 ? Icons.timer : Icons.timer_off_outlined,
                    size: 18, color: _disappearingSeconds > 0 ? ColorConstants.themeColor : Colors.grey),
                const SizedBox(width: 8),
                Text(_disappearingSeconds > 0 ? 'Mensajes temporales ✓' : 'Mensajes temporales'),
              ])),
            ],
          ),
        ],
      ),
      body: SafeArea(
        child: PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) Navigator.pop(context);
          },
          child: Stack(
            children: [
              Column(
                children: [
                  if (_disappearingSeconds > 0)
                    Container(
                      width: double.infinity,
                      color: Colors.orange.shade50,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.timer_outlined, size: 14, color: Colors.orange),
                          const SizedBox(width: 6),
                          Text(
                            'Mensajes temporales activados · ${_formatDisappearDuration(_disappearingSeconds)}',
                            style: const TextStyle(fontSize: 12, color: Colors.orange),
                          ),
                        ],
                      ),
                    ),
                  if (_pinnedMessage != null)
                    GestureDetector(
                      onTap: () => _scrollToMessage(_pinnedMessage!['msgId'] ?? ''),
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                        decoration: BoxDecoration(
                          color: Colors.amber.shade50,
                          border: Border(bottom: BorderSide(color: Colors.amber.shade200)),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.push_pin, size: 14, color: Colors.amber),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _pinnedMessage!['content'] as String? ?? '',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 13, color: Colors.black87),
                              ),
                            ),
                            GestureDetector(
                              onTap: () => _toggleGroupPin(_pinnedMessage!['msgId'] ?? '', ''),
                              child: const Icon(Icons.close, size: 16, color: Colors.grey),
                            ),
                          ],
                        ),
                      ),
                    ),
                  _buildListMessage(),
                  if (_isShowSticker) _buildStickers(),
                  _buildInput(),
                ],
              ),
              Positioned(child: _isLoading ? LoadingView() : const SizedBox.shrink()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildListMessage() {
    return Flexible(
      child: StreamBuilder<QuerySnapshot>(
        stream: _chatProvider.getChatStream(widget.arguments.groupId, _limit),
        builder: (_, snapshot) {
          if (!snapshot.hasData) {
            return const Center(
                child: CircularProgressIndicator(color: ColorConstants.themeColor));
          }
          _listMessage = snapshot.data!.docs;

          // Detectar nuevo mensaje KLK MANE ACTIVO de otro usuario
          if (_listMessage.isNotEmpty) {
            final firstDoc = _listMessage.first;
            if (firstDoc.id != _lastKnownFirstMsgId) {
              final d = firstDoc.data() as Map<String, dynamic>;
              final type = (d[FirestoreConstants.type] as num?)?.toInt();
              final fromId = d[FirestoreConstants.idFrom] as String? ?? '';
              if (type == TypeMessage.alert && fromId != _currentUserId) {
                try {
                  final payload = jsonDecode(d[FirestoreConstants.content] as String);
                  final kind = (payload['alertKind'] as num?)?.toInt() ?? 3;
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (!mounted) return;
                    if (kind == 5) {
                      final name = payload['senderName'] as String? ?? 'Alguien';
                      _triggerPartyEffect(name);
                    } else {
                      // Alerta de tráfico/peligro — vibrar + toast
                      HapticFeedback.heavyImpact();
                      Future.delayed(const Duration(milliseconds: 200), () => HapticFeedback.heavyImpact());
                      Future.delayed(const Duration(milliseconds: 400), () => HapticFeedback.heavyImpact());
                      final alertDef = AlertKind.all.firstWhere((a) => a.id == kind, orElse: () => AlertKind.all[2]);
                      Fluttertoast.showToast(
                        msg: '${alertDef.emoji} ${alertDef.label} — ${payload['senderName'] ?? ''}',
                        backgroundColor: Colors.black87,
                        textColor: Colors.white,
                        toastLength: Toast.LENGTH_LONG,
                        gravity: ToastGravity.TOP,
                      );
                    }
                  });
                } catch (_) {}
              }
              _lastKnownFirstMsgId = firstDoc.id;
            }
          }
          if (_listMessage.isEmpty) {
            return const Center(child: Text('Sin mensajes aún...'));
          }
          return ColoredBox(
            color: ColorConstants.bgChat,
            child: ListView.builder(
            padding: const EdgeInsets.all(10),
            itemCount: _listMessage.length,
            reverse: true,
            controller: _listScrollController,
            itemBuilder: (_, index) {
              final doc = _listMessage[index];
              final msgId = doc.id;
              final isFading = _fadingMessages.containsKey(msgId);
              final child = _buildItemMessage(index, doc);
              if (isFading) {
                return AnimatedOpacity(
                  opacity: 0.0,
                  duration: const Duration(milliseconds: 700),
                  child: child,
                );
              }
              // Show timer badge if expiring within next 60s
              final data = doc.data() as Map<String, dynamic>;
              final expiresAt = data['expiresAt'] as int? ?? 0;
              final now = DateTime.now().millisecondsSinceEpoch;
              if (expiresAt > 0 && expiresAt - now < 60000) {
                return Stack(
                  children: [
                    child,
                    Positioned(
                      top: 4,
                      right: 4,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.orange.withOpacity(0.85),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Row(mainAxisSize: MainAxisSize.min, children: [
                          Icon(Icons.timer, size: 11, color: Colors.white),
                          SizedBox(width: 2),
                          Text('<1m', style: TextStyle(color: Colors.white, fontSize: 10)),
                        ]),
                      ),
                    ),
                  ],
                );
              }
              return child;
            },
          ),
          );
        },
      ),
    );
  }

  Widget _buildQuickAlertPanel() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: const BoxDecoration(
        color: ColorConstants.surfaceLight,
        border: Border(top: BorderSide(color: ColorConstants.divider, width: 1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Alerta rápida — se enviará con tu ubicación actual',
            style: TextStyle(color: ColorConstants.textSecondary, fontSize: 11),
          ),
          const SizedBox(height: 8),
          Row(
            children: AlertKind.all.map((kind) {
              return Expanded(
                child: GestureDetector(
                  onTap: () => _sendQuickAlert(kind),
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    decoration: BoxDecoration(
                      color: kind.color.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: kind.color.withValues(alpha: 0.4), width: 1),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(kind.emoji, style: const TextStyle(fontSize: 22)),
                        const SizedBox(height: 4),
                        Text(
                          kind.shortLabel,
                          style: TextStyle(
                            color: kind.color,
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  Widget _buildAlertBubble(String content) {
    Map<String, dynamic> data;
    try { data = jsonDecode(content) as Map<String, dynamic>; } catch (_) { data = {}; }
    final kind = AlertKind.fromId((data['alertKind'] as num?)?.toInt() ?? 3);
    final lat = (data['lat'] as num?)?.toDouble();
    final lng = (data['lng'] as num?)?.toDouble();
    final sender = data['senderName'] as String? ?? '';
    final ts = (data['ts'] as num?)?.toInt() ?? 0;
    final minsAgo = ts > 0 ? ((DateTime.now().millisecondsSinceEpoch - ts) / 60000).round() : 0;
    final timeLabel = minsAgo <= 0 ? 'ahora mismo' : 'hace $minsAgo min';
    final isKlk = kind.id == 5;

    // Bubble especial para KLK MANE ACTIVO
    if (isKlk) {
      return GestureDetector(
        onTap: () => _triggerPartyEffect(sender),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 260),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFFEC4899), Color(0xFFF97316), Color(0xFFEAB308)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(16),
            boxShadow: [BoxShadow(color: const Color(0xFFEC4899).withValues(alpha: 0.4), blurRadius: 12, offset: const Offset(0, 4))],
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('🎉🥳🎊', style: TextStyle(fontSize: 28)),
              const SizedBox(height: 6),
              const Text(
                'KLK MANE ACTIVO',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 16, letterSpacing: 1),
                textAlign: TextAlign.center,
              ),
              if (sender.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(sender, style: const TextStyle(color: Colors.white70, fontSize: 12)),
              ],
              const SizedBox(height: 4),
              Text(timeLabel, style: const TextStyle(color: Colors.white54, fontSize: 10)),
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Text('Toca para repetir 🎉', style: TextStyle(color: Colors.white, fontSize: 11)),
              ),
            ],
          ),
        ),
      );
    }

    return GestureDetector(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => GpsVivoPage(
            focusLat: lat,
            focusLng: lng,
            focusLabel: kind.label,
          ),
        ),
      ),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 260),
        decoration: BoxDecoration(
          color: kind.color.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: kind.color.withValues(alpha: 0.5), width: 1.5),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(kind.emoji, style: const TextStyle(fontSize: 22)),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    kind.label,
                    style: TextStyle(color: kind.color, fontWeight: FontWeight.bold, fontSize: 14),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            if (sender.isNotEmpty)
              Text('Reportado por $sender · $timeLabel',
                  style: const TextStyle(color: ColorConstants.textSecondary, fontSize: 11)),
            if (lat != null && lng != null) ...[
              const SizedBox(height: 6),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.map_outlined, size: 13, color: kind.color),
                  const SizedBox(width: 4),
                  Text('Ver en mapa',
                      style: TextStyle(color: kind.color, fontSize: 12, decoration: TextDecoration.underline)),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildInput() {
    return Container(
      decoration: const BoxDecoration(
        color: ColorConstants.cardWhite,
        border: Border(top: BorderSide(color: ColorConstants.divider, width: 1)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Reply preview bar
          if (_replyTo != null) _buildReplyPreviewBar(),
          // Edit mode bar
          if (_editingMessageId != null)
            Container(
              color: Colors.blue.shade50,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  const Icon(Icons.edit, size: 16, color: Colors.blue),
                  const SizedBox(width: 8),
                  Expanded(child: Text('Editando mensaje', style: const TextStyle(color: Colors.blue, fontSize: 13))),
                  GestureDetector(
                    onTap: () => setState(() {
                      _editingMessageId = null;
                      _editingOriginalContent = null;
                      _chatInputController.clear();
                    }),
                    child: const Icon(Icons.close, size: 18, color: Colors.blue),
                  ),
                ],
              ),
            ),
          // @mentions suggestions
          if (_showMentionSuggestions)
            Container(
              constraints: const BoxConstraints(maxHeight: 180),
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border(top: BorderSide(color: ColorConstants.divider)),
                boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 4)],
              ),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _mentionSuggestions.length,
                itemBuilder: (_, i) {
                  final m = _mentionSuggestions[i];
                  return ListTile(
                    dense: true,
                    leading: CircleAvatar(
                      radius: 16,
                      backgroundImage: m['avatar']!.isNotEmpty ? NetworkImage(m['avatar']!) : null,
                      child: m['avatar']!.isEmpty ? Text(m['name']![0].toUpperCase(), style: const TextStyle(fontSize: 12)) : null,
                    ),
                    title: Text('@${m['name']}', style: const TextStyle(fontSize: 14)),
                    onTap: () => _insertMention(m),
                  );
                },
              ),
            ),
          // Quick alert panel
          if (_showAlertPanel) _buildQuickAlertPanel(),
          // Icons row
          Row(
            children: [
              Material(
                color: ColorConstants.cardWhite,
                child: IconButton(
                  icon: const Icon(Icons.image),
                  tooltip: 'Foto de galería',
                  onPressed: () => _pickAndSendMultipleImages(),
                  color: ColorConstants.primaryColor,
                ),
              ),
              Material(
                color: Colors.white,
                child: IconButton(
                  icon: const Icon(Icons.videocam_outlined),
                  tooltip: 'Enviar video',
                  onPressed: _pickAndSendVideo,
                  color: ColorConstants.primaryColor,
                ),
              ),
              Material(
                color: Colors.white,
                child: IconButton(
                  icon: const Icon(Icons.camera_alt),
                  tooltip: 'Tomar foto',
                  onPressed: () => _pickImage(source: ImageSource.camera)
                      .then((ok) { if (ok) _uploadFile(); }),
                  color: ColorConstants.primaryColor,
                ),
              ),
              Material(
                color: Colors.white,
                child: IconButton(
                  icon: Icon(_isSharingLiveLocation ? Icons.location_off : Icons.my_location),
                  tooltip: _isSharingLiveLocation ? 'Detener mi ubicación' : 'Activar mi ubicación',
                  onPressed: _startGroupLiveLocation,
                  color: _isSharingLiveLocation ? Colors.red : ColorConstants.primaryColor,
                ),
              ),
              Material(
                color: Colors.white,
                child: IconButton(
                  icon: const Icon(Icons.face),
                  onPressed: _getSticker,
                  color: ColorConstants.primaryColor,
                ),
              ),
              Material(
                color: Colors.white,
                child: IconButton(
                  icon: Icon(
                    Icons.warning_amber_rounded,
                    color: _showAlertPanel ? Colors.red : ColorConstants.primaryColor,
                  ),
                  tooltip: 'Alertas rápidas',
                  onPressed: () {
                    _focusNode.unfocus();
                    setState(() => _showAlertPanel = !_showAlertPanel);
                  },
                ),
              ),
            ],
          ),
          // Text input row
          Container(
            decoration: const BoxDecoration(
                border: Border(top: BorderSide(color: ColorConstants.greyColor2, width: 0.5))),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    onTapOutside: (_) => Utilities.closeKeyboard(),
                    onChanged: _onTypingChanged,
                    onSubmitted: (_) => _onSendMessage(_chatInputController.text, TypeMessage.text),
                    style: const TextStyle(color: ColorConstants.primaryColor, fontSize: 15),
                    controller: _chatInputController,
                    decoration: const InputDecoration.collapsed(
                      hintText: 'Escribe un mensaje...',
                      hintStyle: TextStyle(color: ColorConstants.greyColor),
                    ),
                    focusNode: _focusNode,
                  ),
                ),
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: _chatInputController,
                  builder: (_, value, __) {
                    final hasText = value.text.trim().isNotEmpty;
                    return IconButton(
                      icon: Icon(hasText ? Icons.send : Icons.mic),
                      color: ColorConstants.primaryColor,
                      onPressed: hasText
                          ? () => _onSendMessage(_chatInputController.text, TypeMessage.text)
                          : null,
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStickers() {
    return StickerPicker(
      onStickerSelected: (sticker) {
        _onSendMessage(sticker, TypeMessage.sticker);
        setState(() => _isShowSticker = false);
      },
    );
  }
}

class GroupChatArguments {
  final String groupId;
  final String groupName;
  final String groupDescription;
  final String groupImage;

  const GroupChatArguments({
    required this.groupId,
    required this.groupName,
    this.groupDescription = '',
    this.groupImage = '',
  });
}

// ── Overlay de fiesta para KLK MANE ACTIVO ─────────────────────────────────
class _PartyOverlay extends StatefulWidget {
  const _PartyOverlay({required this.senderName, required this.screenSize, required this.onDone});
  final String senderName;
  final Size screenSize;
  final VoidCallback onDone;

  @override
  State<_PartyOverlay> createState() => _PartyOverlayState();
}

class _PartyOverlayState extends State<_PartyOverlay> with TickerProviderStateMixin {
  late final AnimationController _ctrl;
  final _rng = Random();
  final _emojis = ['🎉', '🥳', '🎊', '✨', '🎈', '💥', '⭐', '🎶'];
  final List<_Particle> _particles = [];

  @override
  void initState() {
    super.initState();
    for (int i = 0; i < 30; i++) {
      _particles.add(_Particle(
        x: _rng.nextDouble(),
        y: -_rng.nextDouble() * 0.3,
        vx: (_rng.nextDouble() - 0.5) * 0.006,
        vy: 0.004 + _rng.nextDouble() * 0.006,
        emoji: _emojis[_rng.nextInt(_emojis.length)],
        size: 20 + _rng.nextDouble() * 20,
        delay: _rng.nextDouble() * 0.5,
      ));
    }
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 2800))
      ..forward().whenComplete(() {
        if (mounted) widget.onDone();
      });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) {
        final t = _ctrl.value;
        return Stack(
          children: [
            // Fondo semi-transparente que desaparece
            if (t < 0.3)
              Positioned.fill(
                child: Opacity(
                  opacity: (0.3 - t) / 0.3 * 0.3,
                  child: const ColoredBox(color: Color(0xFF000000)),
                ),
              ),
            // Banner central
            if (t < 0.6)
              Center(
                child: Opacity(
                  opacity: t < 0.1 ? t / 0.1 : (0.6 - t) / 0.5,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEC4899),
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: const [BoxShadow(color: Color(0x44000000), blurRadius: 20)],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('🎉', style: TextStyle(fontSize: 40)),
                        Text(
                          'KLK MANE ACTIVO',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w900,
                            fontSize: 20,
                            letterSpacing: 1,
                          ),
                        ),
                        Text(
                          widget.senderName,
                          style: const TextStyle(color: Colors.white70, fontSize: 14),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            // Partículas de emojis
            ..._particles.map((p) {
              if (t < p.delay) return const SizedBox.shrink();
              final pt = (t - p.delay) / (1.0 - p.delay);
              final px = p.x + p.vx * pt * 100;
              final py = p.y + p.vy * pt * 100;
              final opacity = pt < 0.7 ? 1.0 : (1.0 - pt) / 0.3;
              return Positioned(
                left: px * widget.screenSize.width,
                top: py * widget.screenSize.height,
                child: Opacity(
                  opacity: opacity.clamp(0.0, 1.0),
                  child: Text(p.emoji, style: TextStyle(fontSize: p.size)),
                ),
              );
            }),
          ],
        );
      },
    );
  }
}

class _Particle {
  final double x, y, vx, vy, size, delay;
  final String emoji;
  const _Particle({required this.x, required this.y, required this.vx, required this.vy, required this.emoji, required this.size, required this.delay});
}
