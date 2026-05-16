import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:file_picker/file_picker.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_chat_demo/constants/constants.dart';
import 'package:flutter_chat_demo/pages/pages.dart';
import 'package:flutter_chat_demo/providers/providers.dart';
import 'package:flutter_chat_demo/utils/utilities.dart';
import 'package:flutter_chat_demo/widgets/widgets.dart';
import 'package:flutter_chat_demo/widgets/sticker_picker.dart';
import 'package:flutter_chat_demo/widgets/location_map_bubble.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:http/http.dart' as http;
import 'package:jitsi_meet_flutter_sdk/jitsi_meet_flutter_sdk.dart';
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

  List<QueryDocumentSnapshot> _listMessage = [];
  int _limit = 20;
  final _limitIncrement = 20;

  File? _imageFile;
  bool _isLoading = false;
  bool _isShowSticker = false;
  String _imageUrl = '';

  // Active call banner
  String? _activeCallRoom;
  bool _activeCallIsVideo = false;
  String _activeCallSender = '';

  // Reply to message
  Map<String, dynamic>? _replyTo;

  // Typing indicators
  Map<String, bool> _typingUsers = {};
  StreamSubscription? _groupTypingSub;
  Timer? _typingTimer;

  // Mute
  int _mutedUntil = 0;

  // Custom text color
  Color _myBubbleColor = const Color(0xFFE8E8E8);

  // Video playback
  final Map<String, VideoPlayerController> _videoControllers = {};

  // Live location
  StreamSubscription<Position>? _liveLocationSub;
  bool _isSharingLiveLocation = false;
  String? _activeLiveLocationDocId;

  final _chatInputController = TextEditingController();
  final _listScrollController = ScrollController();
  final _focusNode = FocusNode();

  late final _chatProvider = context.read<ChatProvider>();
  late final _authProvider = context.read<AuthProvider>();

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_onFocusChange);
    _listScrollController.addListener(_scrollListener);
    _currentUserId = _authProvider.userFirebaseId ?? '';
    _currentNickname = _authProvider.prefs.getString(FirestoreConstants.nickname) ?? 'Usuario';
    _resetMyUnread();
    _loadMyBubbleColor();
    WidgetsBinding.instance.addPostFrameCallback((_) => _startGroupTypingStream());
    _mutedUntil = _authProvider.prefs.getInt('muted_until_${widget.arguments.groupId}') ?? 0;
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
    };
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

  void _handleAppBarMenu(String val) async {
    if (val == 'mute') {
      if (_isMuted) {
        setState(() => _mutedUntil = 0);
        await _authProvider.prefs.remove('muted_until_${widget.arguments.groupId}');
        Fluttertoast.showToast(msg: 'Notificaciones activadas');
      } else {
        _showMuteDialog();
      }
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

  void _showReactionPicker(String messageId, String groupId) {
    const emojis = ['❤️', '👍', '😂', '😮', '😢', '👏'];
    showModalBottomSheet(
      context: context,
      builder: (_) => Container(
        padding: const EdgeInsets.all(16),
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
    );
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

  Widget _buildReplyBubble(Map<String, dynamic> replyTo) {
    final content = replyTo['content'] as String? ?? '';
    final sender = replyTo['senderName'] as String? ?? 'Mensaje';
    final type = replyTo['type'] as int? ?? 0;
    final preview = type == TypeMessage.image ? '📷 Foto' : type == TypeMessage.video ? '🎥 Video' : type == TypeMessage.audio ? '🎤 Audio' : content.length > 60 ? '${content.substring(0, 60)}...' : content;
    return Container(
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
    );
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
      onTap: () { ctrl.value.isPlaying ? ctrl.pause() : ctrl.play(); setState(() {}); },
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
              child: AnimatedOpacity(
                opacity: ctrl.value.isPlaying ? 0.0 : 1.0,
                duration: const Duration(milliseconds: 300),
                child: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: const BoxDecoration(color: Colors.black45, shape: BoxShape.circle),
                  child: const Icon(Icons.play_arrow, color: Colors.white, size: 36),
                ),
              ),
            ),
          ],
        ),
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

    final isMe = idFrom == _currentUserId;
    final showSender = !isMe && (index == _listMessage.length - 1 ||
        (_listMessage[index + 1].get(FirestoreConstants.idFrom) != idFrom));

    Widget _bubbleContent() {
      if (type == TypeMessage.text) {
        return Container(
          padding: const EdgeInsets.fromLTRB(15, 10, 15, 10),
          constraints: const BoxConstraints(maxWidth: 220),
          decoration: BoxDecoration(
            color: isMe ? _myBubbleColor : ColorConstants.primaryColor,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (replyTo != null) _buildReplyBubble(replyTo),
              _buildRichText(content, isMe ? ColorConstants.primaryColor : Colors.white),
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
      return Container(
        margin: const EdgeInsets.only(bottom: 10, right: 10),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [bubble],
        ),
      );
    } else {
      return Container(
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
                        child: Text(senderName, style: const TextStyle(color: ColorConstants.primaryColor, fontSize: 11, fontWeight: FontWeight.bold)),
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
                final isCreator = createdBy == _currentUserId;
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
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(widget.arguments.groupName,
                      style: const TextStyle(color: ColorConstants.primaryColor),
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
              ),
            ),
          ],
        ),
        centerTitle: false,
        actions: [
          IconButton(
            icon: const Icon(Icons.videocam),
            tooltip: 'Videollamada grupal',
            color: ColorConstants.primaryColor,
            onPressed: () => _startGroupJitsiCall(videoMuted: false),
          ),
          IconButton(
            icon: const Icon(Icons.call),
            tooltip: 'Llamada grupal',
            color: ColorConstants.primaryColor,
            onPressed: () => _startGroupJitsiCall(videoMuted: true),
          ),
          IconButton(
            icon: const Icon(Icons.map_outlined),
            tooltip: 'Mapa en vivo',
            color: ColorConstants.primaryColor,
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
          PopupMenuButton<String>(
            onSelected: _handleAppBarMenu,
            itemBuilder: (_) => [
              PopupMenuItem(value: 'mute', child: Row(children: [
                Icon(_isMuted ? Icons.notifications_active : Icons.notifications_off, size: 18, color: Colors.grey),
                const SizedBox(width: 8),
                Text(_isMuted ? 'Activar notificaciones' : 'Silenciar'),
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
                  _buildListMessage(),
                  if (_isShowSticker) _buildStickers(),
                  if (_activeCallRoom != null) _buildActiveCallBanner(),
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
          if (_listMessage.isEmpty) {
            return const Center(child: Text('Sin mensajes aún...'));
          }
          // Detect active call from most recent call message (< 30 min)
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            String? foundRoom;
            bool foundIsVideo = false;
            String foundSender = '';
            final cutoff = DateTime.now().millisecondsSinceEpoch - 30 * 60 * 1000;
            for (final doc in _listMessage) {
              final d = doc.data() as Map<String, dynamic>;
              final type = d[FirestoreConstants.type] as int? ?? 0;
              if (type == TypeMessage.audioCall || type == TypeMessage.videoCall) {
                final ts = (d['timestamp'] as Timestamp?)?.millisecondsSinceEpoch ?? 0;
                if (ts > cutoff) {
                  foundRoom = d[FirestoreConstants.content] as String? ?? '';
                  foundIsVideo = type == TypeMessage.videoCall;
                  foundSender = d[FirestoreConstants.idFrom] == _currentUserId
                      ? 'Tú'
                      : (d['senderName'] as String? ?? 'Alguien');
                }
                break; // messages are reverse order, first call = latest
              }
            }
            if (foundRoom != _activeCallRoom || foundSender != _activeCallSender) {
              setState(() {
                _activeCallRoom = foundRoom;
                _activeCallIsVideo = foundIsVideo;
                _activeCallSender = foundSender;
              });
            }
          });
          return ListView.builder(
            padding: const EdgeInsets.all(10),
            itemCount: _listMessage.length,
            reverse: true,
            controller: _listScrollController,
            itemBuilder: (_, index) => _buildItemMessage(index, _listMessage[index]),
          );
        },
      ),
    );
  }

  Widget _buildActiveCallBanner() {
    return GestureDetector(
      onTap: () {
        final myAvatar = _authProvider.prefs.getString(FirestoreConstants.photoUrl) ?? '';
        final jitsi = JitsiMeet();
        jitsi.join(JitsiMeetConferenceOptions(
          serverURL: 'https://jitsi.38.247.147.220.nip.io',
          room: _activeCallRoom!,
          configOverrides: {
            'startWithAudioMuted': false,
            'startWithVideoMuted': !_activeCallIsVideo,
            'subject': widget.arguments.groupName,
            'prejoinPageEnabled': false,
          },
          featureFlags: {
            'unsaferoomwarning.enabled': false,
            'prejoinpage.enabled': false,
            'tile-view.enabled': true,
            'pip.enabled': true,
            'invite.enabled': false,
          },
          userInfo: JitsiMeetUserInfo(
            displayName: _currentNickname,
            email: '',
            avatar: myAvatar.isNotEmpty ? myAvatar : null,
          ),
        ));
      },
      child: Container(
        color: const Color(0xFF075E54),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            const Icon(Icons.circle, color: Color(0xFF25D366), size: 10),
            const SizedBox(width: 8),
            Icon(
              _activeCallIsVideo ? Icons.videocam : Icons.mic,
              color: Colors.white,
              size: 18,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '$_activeCallSender ${_activeCallIsVideo ? 'inició una videollamada' : 'inició una llamada de voz'}',
                    style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w500),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const Text(
                    'Chat de voz en curso · Toca para unirte',
                    style: TextStyle(color: Color(0xFFB2DFDB), fontSize: 10),
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xFF25D366),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Text('Unirse', style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
            ),
            const SizedBox(width: 4),
            GestureDetector(
              onTap: () => setState(() => _activeCallRoom = null),
              child: const Icon(Icons.close, color: Colors.white54, size: 18),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInput() {
    return Container(
      decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: ColorConstants.greyColor2, width: 0.5)),
          color: Colors.white),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Reply preview bar
          if (_replyTo != null) _buildReplyPreviewBar(),
          // Icons row
          Row(
            children: [
              Material(
                color: Colors.white,
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
