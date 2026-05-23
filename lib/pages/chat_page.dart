import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:file_picker/file_picker.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_chat_demo/constants/constants.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_chat_demo/models/models.dart';
import 'package:flutter_chat_demo/pages/pages.dart';
import 'package:flutter_chat_demo/providers/providers.dart';
import 'package:flutter_chat_demo/utils/utilities.dart';
import 'package:flutter_chat_demo/widgets/widgets.dart';
import 'package:flutter_chat_demo/widgets/sticker_picker.dart';
import 'package:flutter_chat_demo/widgets/rainbow_text.dart';
import 'package:flutter_chat_demo/widgets/location_map_bubble.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' hide Path;
import 'package:fluttertoast/fluttertoast.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:just_audio/just_audio.dart';
import 'package:jitsi_meet_flutter_sdk/jitsi_meet_flutter_sdk.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

class ChatPage extends StatefulWidget {
  const ChatPage({super.key, required this.arguments});

  final ChatPageArguments arguments;

  @override
  ChatPageState createState() => ChatPageState();
}

class ChatPageState extends State<ChatPage> {
  late final String _currentUserId;

  List<QueryDocumentSnapshot> _listMessage = [];
  int _limit = 20;
  final _limitIncrement = 20;
  String _groupChatId = "";
  bool _autoGreetingSent = false; // prevent duplicate greeting
  bool _viewerIsAgente = false;   // true if current user can see GPS
  bool _gpsBannerExpanded = true;   // toggle hide/show GPS map banner
  Map<String, dynamic>? _motoGps; // live GPS data from Firestore
  StreamSubscription<DocumentSnapshot>? _gpsSub;

  File? _imageFile;
  bool _isLoading = false;
  bool _isShowSticker = false;
  String _imageUrl = "";

  // Live location
  StreamSubscription<Position>? _liveLocationSub;
  String? _activeLiveLocationDocId;
  bool _isSharingLiveLocation = false;

  // Audio recording
  final _audioRecorder = AudioRecorder();
  bool _isRecording = false;
  String? _recordingPath;
  int _recordSeconds = 0;
  Timer? _recordTimer;

  // Audio playback
  final _audioPlayer = AudioPlayer();
  String? _playingUrl;

  // Incoming call detection
  String? _lastShownCallId;
  bool _callDialogVisible = false;

  // Reply to message
  Map<String, dynamic>? _replyTo; // {content, senderName, msgId, type}

  // Peer is admin (rainbow name)
  bool _peerIsAdmin = false;

  // Typing indicator
  bool _peerTyping = false;
  StreamSubscription<DocumentSnapshot>? _typingSub;
  StreamSubscription<DocumentSnapshot>? _peerPresenceSub;
  Timer? _typingTimer;

  // Mute
  int _mutedUntil = 0; // epoch ms, 0 = not muted

  // Block
  bool _isBlocked = false; // current user blocked peer
  bool _blockedByPeer = false; // peer blocked current user

  // Pinned message
  Map<String, dynamic>? _pinnedMessage;

  // Custom text color (own bubbles)
  Color _myBubbleColor = const Color(0xFFE8E8E8); // default grey

  // Video playback state
  final Map<String, VideoPlayerController> _videoControllers = {};
  final Map<String, GlobalKey> _messageKeys = {};

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
    _readLocal();
    _loadMyBubbleColor();
  }

  Future<void> _loadMyBubbleColor() async {
    final prefs = await SharedPreferences.getInstance();
    final colorValue = prefs.getInt('myBubbleColor');
    if (colorValue != null && mounted) {
      setState(() => _myBubbleColor = Color(colorValue));
    }
  }

  Future<void> _markMessagesRead() async {
    if (_groupChatId.isEmpty) return;
    // Mark peer's messages as 'read' so they can show blue ticks on their side
    final snap = await FirebaseFirestore.instance
        .collection(FirestoreConstants.pathMessageCollection)
        .doc(_groupChatId)
        .collection(_groupChatId)
        .where(FirestoreConstants.idFrom, isEqualTo: widget.arguments.peerId)
        .where('status', isLessThan: 'read')
        .limit(50)
        .get();
    final batch = FirebaseFirestore.instance.batch();
    for (final doc in snap.docs) {
      batch.update(doc.reference, {'status': 'read'});
    }
    if (snap.docs.isNotEmpty) batch.commit().catchError((_) {});
  }

  Future<void> _markMyMessagesDelivered() async {
    if (_groupChatId.isEmpty) return;
    final snap = await FirebaseFirestore.instance
        .collection(FirestoreConstants.pathMessageCollection)
        .doc(_groupChatId)
        .collection(_groupChatId)
        .where(FirestoreConstants.idFrom, isEqualTo: _currentUserId)
        .where('status', isEqualTo: 'sent')
        .limit(50)
        .get();
    final batch = FirebaseFirestore.instance.batch();
    for (final doc in snap.docs) {
      batch.update(doc.reference, {'status': 'delivered'});
    }
    if (snap.docs.isNotEmpty) batch.commit().catchError((_) {});
  }

  Widget _buildTicks(String? status) {
    if (status == null || status == 'sent') {
      return const Icon(Icons.check, size: 13, color: Colors.grey);
    } else if (status == 'delivered') {
      return const Icon(Icons.done_all, size: 13, color: Colors.grey);
    } else {
      // read
      return const Icon(Icons.done_all, size: 13, color: Colors.blue);
    }
  }

  Future<void> _togglePin(String messageId, String content) async {
    final ref = FirebaseFirestore.instance
        .collection(FirestoreConstants.pathMessageCollection)
        .doc(_groupChatId);
    if (_pinnedMessage != null && _pinnedMessage!['msgId'] == messageId) {
      await ref.set({'pinnedMessage': null}, SetOptions(merge: true));
      setState(() => _pinnedMessage = null);
    } else {
      final pin = {'msgId': messageId, 'content': content};
      await ref.set({'pinnedMessage': pin}, SetOptions(merge: true));
      setState(() => _pinnedMessage = pin);
    }
  }

  void _loadPinnedMessage() {
    FirebaseFirestore.instance
        .collection(FirestoreConstants.pathMessageCollection)
        .doc(_groupChatId)
        .snapshots()
        .listen((snap) {
      if (!mounted) return;
      final pin = snap.data()?['pinnedMessage'];
      setState(() => _pinnedMessage = pin != null ? Map<String, dynamic>.from(pin) : null);
    });
  }

  void _startTypingStream() {
    _typingSub?.cancel();
    _typingSub = _chatProvider.getTypingStream(_groupChatId, widget.arguments.peerId).listen((snap) {
      if (!mounted) return;
      final data = snap.data() as Map<String, dynamic>?;
      final isTyping = data?['isTyping'] as bool? ?? false;
      final ts = data?['ts'] as int? ?? 0;
      final fresh = DateTime.now().millisecondsSinceEpoch - ts < 10000;
      setState(() => _peerTyping = isTyping && fresh);
    });
  }

  void _onTypingChanged(String val) {
    _chatProvider.setTyping(_groupChatId, _currentUserId, val.isNotEmpty);
    _typingTimer?.cancel();
    if (val.isNotEmpty) {
      _typingTimer = Timer(const Duration(seconds: 5), () {
        _chatProvider.setTyping(_groupChatId, _currentUserId, false);
      });
    }
  }

  @override
  void dispose() {
    _stopLiveLocation();
    _recordTimer?.cancel();
    _gpsSub?.cancel();
    _typingSub?.cancel();
    _peerPresenceSub?.cancel();
    _typingTimer?.cancel();
    _chatProvider.setTyping(_groupChatId, _currentUserId, false);
    for (final c in _videoControllers.values) { c.dispose(); }
    _audioRecorder.dispose();
    _audioPlayer.dispose();
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
      setState(() {
        _limit += _limitIncrement;
      });
    }
  }

  void _onFocusChange() {
    if (_focusNode.hasFocus) {
      // Hide sticker when keyboard appear
      setState(() {
        _isShowSticker = false;
      });
    }
  }

  void _readLocal() {
    if (_authProvider.userFirebaseId?.isNotEmpty == true) {
      _currentUserId = _authProvider.userFirebaseId!;
    } else {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => LoginPage()),
        (_) => false,
      );
    }
    String peerId = widget.arguments.peerId;
    if (widget.arguments.customGroupChatId?.isNotEmpty == true) {
      _groupChatId = widget.arguments.customGroupChatId!;
    } else if (_currentUserId.compareTo(peerId) > 0) {
      _groupChatId = '$_currentUserId-$peerId';
    } else {
      _groupChatId = '$peerId-$_currentUserId';
    }

    _chatProvider.updateDataFirestore(
      FirestoreConstants.pathUserCollection,
      _currentUserId,
      {FirestoreConstants.chattingWith: peerId},
    );
    // Mark all incoming messages as read
    _markMessagesRead();
    // Load pinned message
    _loadPinnedMessage();
    // Watch peer presence to auto-mark our messages as delivered
    _peerPresenceSub = FirebaseFirestore.instance
        .collection(FirestoreConstants.pathUserCollection)
        .doc(peerId)
        .snapshots()
        .listen((snap) {
      final online = snap.data()?[FirestoreConstants.isOnline] as bool? ?? false;
      if (online) _markMyMessagesDelivered();
    });

    // Determine if viewer can see GPS (agente/ejecutivo/asociado/admin, not motoboy)
    final role = (_authProvider.prefs.getString(FirestoreConstants.aboutMe) ?? '').toLowerCase();
    final rolId = _authProvider.prefs.getString(FirestoreConstants.rolId) ?? '';
    _viewerIsAgente = (role == 'agente' || role == 'ejecutivo' || role == 'asociado' ||
        role.contains('admin') || rolId == '1') && !role.contains('motoboy');

    // Subscribe to live GPS for order chats (only for agente/admin viewers)
    if (_groupChatId.startsWith('order-') && peerId.isNotEmpty && _viewerIsAgente) {
      _gpsSub = FirebaseFirestore.instance
          .collection('users_locations')
          .doc(peerId)
          .snapshots()
          .listen((snap) {
        if (!mounted) return;
        if (snap.exists) {
          setState(() => _motoGps = snap.data());
        }
      });
    }

    // Auto-greeting for order chats (opened by agente/ejecutivo)
    if (_groupChatId.startsWith('order-') && !_autoGreetingSent) {
      Future.delayed(const Duration(milliseconds: 1800), () {
        if (!mounted || _autoGreetingSent) return;
        if (_listMessage.isEmpty) {
          _autoGreetingSent = true;
          const greeting =
              '👋 Hola, soy quien creó tu orden. Te guiaré en el proceso de ruta '
              'y podré ver tu ubicación para ayudarte. Siempre estaré atento. 🗺️';
          _chatProvider.sendMessage(
            greeting,
            0,
            _groupChatId,
            _currentUserId,
            widget.arguments.peerId,
          );
        }
      });
    }
    // Start typing indicator stream
    WidgetsBinding.instance.addPostFrameCallback((_) => _startTypingStream());
    // Load mute setting
    _mutedUntil = _authProvider.prefs.getInt('muted_until_$_groupChatId') ?? 0;
    // Load block state
    _loadBlockState();
  }

  Future<void> _loadBlockState() async {
    final myDoc = await FirebaseFirestore.instance
        .collection(FirestoreConstants.pathUserCollection)
        .doc(_currentUserId)
        .get();
    final blockedList = List<String>.from(myDoc.data()?['blockedUsers'] as List? ?? []);
    final peerId = widget.arguments.peerId;

    // Check if peer blocked me
    final peerDoc = await FirebaseFirestore.instance
        .collection(FirestoreConstants.pathUserCollection)
        .doc(peerId)
        .get();
    final peerBlockedList = List<String>.from(peerDoc.data()?['blockedUsers'] as List? ?? []);

    if (mounted) {
      setState(() {
        _isBlocked = blockedList.contains(peerId);
        _blockedByPeer = peerBlockedList.contains(_currentUserId);
      });
    }
  }

  Future<void> _toggleBlock() async {
    final peerId = widget.arguments.peerId;
    final ref = FirebaseFirestore.instance
        .collection(FirestoreConstants.pathUserCollection)
        .doc(_currentUserId);
    if (_isBlocked) {
      await ref.update({'blockedUsers': FieldValue.arrayRemove([peerId])});
      setState(() => _isBlocked = false);
      Fluttertoast.showToast(msg: 'Usuario desbloqueado');
    } else {
      await ref.update({'blockedUsers': FieldValue.arrayUnion([peerId])});
      setState(() => _isBlocked = true);
      Fluttertoast.showToast(msg: 'Usuario bloqueado');
    }
  }

  Future<bool> _pickImage({ImageSource source = ImageSource.gallery}) async {
    final imagePicker = ImagePicker();
    final pickedXFile = await imagePicker.pickImage(source: source, imageQuality: 70).catchError((err) {
      Fluttertoast.showToast(msg: err.toString());
      return null;
    });
    if (pickedXFile != null) {
      final imageFile = File(pickedXFile.path);
      setState(() {
        _imageFile = imageFile;
        _isLoading = true;
      });
      return true;
    } else {
      return false;
    }
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
        final fileName = 'chat_images/${_currentUserId}_${DateTime.now().millisecondsSinceEpoch}.jpg';
        final snapshot = await _chatProvider.uploadFile(File(xfile.path), fileName);
        if (snapshot.state == TaskState.success) {
          final url = await snapshot.ref.getDownloadURL();
          _onSendMessage(url, TypeMessage.image);
        }
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
      if (snap.state == TaskState.success) {
        final url = await snap.ref.getDownloadURL();
        _onSendMessage(url, TypeMessage.video);
      }
    } catch (e) {
      Fluttertoast.showToast(msg: 'Error al subir video');
    }
    setState(() => _isLoading = false);
  }

  Future<void> _makeCall() async {
    final lamanoId = widget.arguments.peerLamanoId;
    if (lamanoId == null || lamanoId.isEmpty) {
      Fluttertoast.showToast(msg: 'No hay número de teléfono disponible');
      return;
    }
    try {
      final resp = await http
          .get(Uri.parse('http://38.247.147.220/lamano/api_get_phone.php?user_id=$lamanoId'))
          .timeout(const Duration(seconds: 8));
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final phone = data['phone'] as String? ?? '';
      if (phone.isEmpty) {
        Fluttertoast.showToast(msg: 'El usuario no tiene teléfono registrado');
        return;
      }
      final uri = Uri(scheme: 'tel', path: phone);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri);
      } else {
        Fluttertoast.showToast(msg: 'No se puede iniciar la llamada');
      }
    } catch (_) {
      Fluttertoast.showToast(msg: 'Error al obtener el teléfono');
    }
  }

  Future<void> _twilioCall() async {
    // 1. Obtener mi propio teléfono guardado
    String myPhone = _authProvider.prefs.getString(FirestoreConstants.motoboyPhone) ?? '';

    // 2. Si no lo tenemos, pedirlo
    if (myPhone.isEmpty) {
      final controller = TextEditingController();
      final entered = await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (_) => AlertDialog(
          title: const Row(children: [
            Icon(Icons.phone, color: Colors.green),
            SizedBox(width: 8),
            Text('Tu número celular'),
          ]),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Twilio te llamará a ti primero y luego te conecta con la otra persona.\n\n'
                '⚠️ Ninguno ve el número real del otro — solo el número de La Mano.\n\n'
                'Solo se pide una vez.',
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(
                  hintText: '+56912345678',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.phone),
                  labelText: 'Tu número',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, null), child: const Text('Cancelar')),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: const Text('Guardar y llamar'),
            ),
          ],
        ),
      );
      if (entered == null || entered.isEmpty) return;
      await _authProvider.prefs.setString(FirestoreConstants.motoboyPhone, entered);
      myPhone = entered;
    }

    // 3. Obtener el teléfono del destinatario desde el servidor
    final lamanoId = widget.arguments.peerLamanoId;
    if (lamanoId == null || lamanoId.isEmpty) {
      Fluttertoast.showToast(msg: 'No se puede obtener el teléfono del contacto');
      return;
    }

    setState(() => _isLoading = true);
    try {
      final resp = await http
          .get(Uri.parse('http://38.247.147.220/lamano/api_get_phone.php?user_id=$lamanoId'))
          .timeout(const Duration(seconds: 10));
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final peerPhone = (data['phone'] as String? ?? '').trim();

      setState(() => _isLoading = false);

      if (peerPhone.isEmpty) {
        Fluttertoast.showToast(msg: '${widget.arguments.peerNickname} no tiene teléfono registrado');
        return;
      }

      // 4. Confirmar antes de llamar
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Row(children: [
            Icon(Icons.phone, color: Colors.green),
            SizedBox(width: 8),
            Text('Llamada anónima'),
          ]),
          content: Text(
            'Twilio llamará a tu teléfono y te conectará con ${widget.arguments.peerNickname}.\n\n'
            'Ninguno verá el número real del otro.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancelar')),
            ElevatedButton.icon(
              onPressed: () => Navigator.pop(context, true),
              icon: const Icon(Icons.call),
              label: const Text('Llamar'),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.green, foregroundColor: Colors.white),
            ),
          ],
        ),
      );
      if (confirmed != true) return;

      // 5. Iniciar llamada via Twilio
      setState(() => _isLoading = true);
      final callResp = await http.post(
        Uri.parse('http://38.247.147.220/lamano/twilio_user_call.php'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'caller_phone': myPhone, 'callee_phone': peerPhone}),
      ).timeout(const Duration(seconds: 20));
      setState(() => _isLoading = false);

      final result = jsonDecode(callResp.body) as Map<String, dynamic>;
      if (result['success'] == true) {
        showDialog(
          context: context,
          builder: (_) => AlertDialog(
            title: const Row(children: [
              Icon(Icons.phone_in_talk, color: Colors.green),
              SizedBox(width: 8),
              Text('Llamada en camino'),
            ]),
            content: const Text(
              'Tu teléfono sonará en segundos.\n\n'
              '1. Contesta la llamada de Twilio\n'
              '2. Espera mientras conecta con el otro usuario\n\n'
              '✅ Ninguno ve el número real del otro.',
            ),
            actions: [
              ElevatedButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Entendido'),
              ),
            ],
          ),
        );
      } else {
        Fluttertoast.showToast(msg: result['message'] ?? 'Error al iniciar llamada');
      }
    } catch (e) {
      setState(() => _isLoading = false);
      Fluttertoast.showToast(msg: 'Error: $e');
    }
  }

  void _getSticker() {
    // Hide keyboard when sticker appear
    _focusNode.unfocus();
    setState(() {
      _isShowSticker = !_isShowSticker;
    });
  }

  // ── Live Location ──────────────────────────────────────────
  Future<void> _toggleLiveLocation() async {
    try {
      if (_isSharingLiveLocation) {
        await _stopLiveLocation();
        return;
      }
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
      if (permission == LocationPermission.deniedForever) {
        Fluttertoast.showToast(msg: 'Permiso de ubicación denegado permanentemente. Ve a Ajustes de la app.');
        return;
      }
      if (permission == LocationPermission.denied) {
        Fluttertoast.showToast(msg: 'Permiso de ubicación denegado');
        return;
      }
    } catch (e) {
      Fluttertoast.showToast(msg: 'Error GPS: $e');
      return;
    }
    try {

    // Create live location doc in Firestore
    final docId = '${_groupChatId}_$_currentUserId';
    await FirebaseFirestore.instance
        .collection(FirestoreConstants.pathLiveLocations)
        .doc(docId)
        .set({'active': true, 'lat': 0.0, 'lng': 0.0, 'fromId': _currentUserId, 'chatId': _groupChatId});

    // Send a message of type liveLocation (content = docId)
    _onSendMessage(docId, TypeMessage.liveLocation);

    setState(() {
      _isSharingLiveLocation = true;
      _activeLiveLocationDocId = docId;
    });

    _liveLocationSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 5),
    ).listen((pos) {
      FirebaseFirestore.instance
          .collection(FirestoreConstants.pathLiveLocations)
          .doc(docId)
          .update({'lat': pos.latitude, 'lng': pos.longitude});
    }, onError: (e) {
      Fluttertoast.showToast(msg: 'Error GPS stream: $e');
    });

    Fluttertoast.showToast(msg: 'Compartiendo ubicación en vivo...');
    } catch (e) {
      Fluttertoast.showToast(msg: 'Error al iniciar ubicación en vivo: $e');
    }
  }

  Future<void> _stopLiveLocation() async {
    await _liveLocationSub?.cancel();
    _liveLocationSub = null;
    if (_activeLiveLocationDocId != null) {
      await FirebaseFirestore.instance
          .collection(FirestoreConstants.pathLiveLocations)
          .doc(_activeLiveLocationDocId)
          .update({'active': false});
    }
    if (mounted) {
      setState(() {
        _isSharingLiveLocation = false;
        _activeLiveLocationDocId = null;
      });
    }
    // Silencioso — el tracking de fondo continúa sin avisar al usuario
  }

  // ── Audio recording ──────────────────────────────────
  Future<void> _startRecording() async {
    if (!await _audioRecorder.hasPermission()) {
      Fluttertoast.showToast(msg: 'Sin permiso de micrófono');
      return;
    }
    final dir = await getTemporaryDirectory();
    _recordingPath = '${dir.path}/audio_${DateTime.now().millisecondsSinceEpoch}.m4a';
    await _audioRecorder.start(
      const RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 64000, sampleRate: 22050),
      path: _recordingPath!,
    );
    _recordSeconds = 0;
    _recordTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _recordSeconds++);
    });
    setState(() => _isRecording = true);
  }

  Future<void> _stopAndSendRecording() async {
    _recordTimer?.cancel();
    final path = await _audioRecorder.stop();
    setState(() => _isRecording = false);
    if (path == null) return;
    final file = File(path);
    if (!file.existsSync()) return;
    setState(() => _isLoading = true);
    try {
      final fileName = 'chat_audio/${_currentUserId}_${DateTime.now().millisecondsSinceEpoch}.m4a';
      final ref = _chatProvider.firebaseStorage.ref().child(fileName);
      final snapshot = await ref.putFile(file);
      final url = await snapshot.ref.getDownloadURL();
      setState(() => _isLoading = false);
      _onSendMessage(url, TypeMessage.audio);
    } catch (e) {
      setState(() => _isLoading = false);
      Fluttertoast.showToast(msg: 'Error al subir audio: $e');
    }
  }

  void _cancelRecording() async {
    _recordTimer?.cancel();
    await _audioRecorder.stop();
    setState(() {
      _isRecording = false;
      _recordSeconds = 0;
    });
    Fluttertoast.showToast(msg: 'Grabación cancelada');
  }

  Future<void> _startJitsiCall({bool videoMuted = true}) async {
    // Pedir permisos antes de unirse
    await Permission.microphone.request();
    if (!videoMuted) await Permission.camera.request();

    final myNickname = _authProvider.prefs.getString(FirestoreConstants.nickname) ?? 'Usuario';
    final myAvatar = _authProvider.prefs.getString(FirestoreConstants.photoUrl) ?? '';
    final ids = [_currentUserId, widget.arguments.peerId]..sort();
    final roomName = 'lamano_${ids.join('_')}';

    // Enviar mensaje de llamada al chat para notificar al receptor
    final callType = videoMuted ? TypeMessage.audioCall : TypeMessage.videoCall;
    _onSendMessage(roomName, callType);

    // ── FCM push al receptor (funciona aunque tenga la app cerrada) ─────────
    _sendCallPushToPeer(
      roomName: roomName,
      callerName: myNickname,
      callerUid: _currentUserId,
      isVideo: !videoMuted,
    );

    final jitsi = JitsiMeet();
    final options = JitsiMeetConferenceOptions(
      serverURL: 'https://jitsi.38.247.147.220.nip.io',
      room: roomName,
      configOverrides: {
        'startWithAudioMuted': false,
        'startWithVideoMuted': videoMuted,
        'subject': widget.arguments.peerNickname,
      },
      featureFlags: {
        'unsafeRoomWarning.enabled': false,
        'welcomePage.enabled': false,
        'calendar.enabled': false,
        'recording.enabled': false,
        'liveStreaming.enabled': false,
        'invite.enabled': false,
      },
      userInfo: JitsiMeetUserInfo(
        displayName: myNickname,
        avatar: myAvatar.isNotEmpty ? myAvatar : null,
      ),
    );
    try {
      await jitsi.join(options, JitsiMeetEventListener(
        conferenceJoined: (url) => debugPrint('JITSI joined: $url'),
        conferenceTerminated: (url, error) => debugPrint('JITSI terminated: $url err=$error'),
        conferenceWillJoin: (url) => debugPrint('JITSI willJoin: $url'),
      ));
    } catch (e) {
      debugPrint('JITSI ERROR: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error llamada: $e'), duration: const Duration(seconds: 6)),
        );
      }
    }
  }

  /// Sends FCM push to peer so they see an incoming-call screen even if the
  /// app is in background / terminated.
  Future<void> _sendCallPushToPeer({
    required String roomName,
    required String callerName,
    required String callerUid,
    required bool isVideo,
  }) async {
    try {
      // Fetch peer's FCM push token from Firestore
      final peerDoc = await FirebaseFirestore.instance
          .collection(FirestoreConstants.pathUserCollection)
          .doc(widget.arguments.peerId)
          .get();
      final pushToken = peerDoc.data()?['pushToken'] as String?;
      if (pushToken == null || pushToken.isEmpty) return;

      await http.post(
        Uri.parse('http://38.247.147.220/lamano/api_send_call_push.php'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'push_token':  pushToken,
          'caller_name': callerName,
          'caller_uid':  callerUid,
          'room_name':   roomName,
          'is_video':    isVideo,
        }),
      ).timeout(const Duration(seconds: 10));
    } catch (_) {
      // FCM push is best-effort; Firestore message is the fallback
    }
  }

  Widget _buildCallBubble(String roomName, {required bool isVideo, required bool isMe}) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 220),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: isMe ? ColorConstants.greyColor2 : ColorConstants.primaryColor,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isVideo ? Icons.videocam : Icons.call,
                color: isMe ? Colors.black87 : Colors.white,
                size: 20,
              ),
              const SizedBox(width: 8),
              Text(
                isVideo ? 'Videollamada' : 'Llamada de voz',
                style: TextStyle(
                  color: isMe ? Colors.black87 : Colors.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          if (!isMe) ...[
            const SizedBox(height: 8),
            ElevatedButton.icon(
              onPressed: () {
                final myNickname = _authProvider.prefs.getString(FirestoreConstants.nickname) ?? 'Usuario';
                final myAvatar = _authProvider.prefs.getString(FirestoreConstants.photoUrl) ?? '';
                final jitsi = JitsiMeet();
                jitsi.join(JitsiMeetConferenceOptions(
                  serverURL: 'https://jitsi.38.247.147.220.nip.io',
                  room: roomName,
                  configOverrides: {
                    'startWithAudioMuted': false,
                    'startWithVideoMuted': !isVideo,
                    'subject': widget.arguments.peerNickname,
                  },
                  featureFlags: {
                    'unsafeRoomWarning.enabled': false,
                    'welcomePage.enabled': false,
                    'calendar.enabled': false,
                    'recording.enabled': false,
                    'liveStreaming.enabled': false,
                    'invite.enabled': false,
                  },
                  userInfo: JitsiMeetUserInfo(
                    displayName: myNickname,
                    avatar: myAvatar.isNotEmpty ? myAvatar : null,
                  ),
                ));
              },
              icon: Icon(isVideo ? Icons.videocam : Icons.call, size: 16),
              label: const Text('Unirse'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                minimumSize: const Size(0, 32),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildAudioBubble(String url, {required bool isMe}) {
    final isPlaying = _playingUrl == url;
    return Container(
      constraints: const BoxConstraints(maxWidth: 220),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: isMe ? ColorConstants.greyColor2 : ColorConstants.primaryColor,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          GestureDetector(
            onTap: () async {
              if (isPlaying) {
                await _audioPlayer.stop();
                setState(() => _playingUrl = null);
              } else {
                setState(() => _playingUrl = url);
                await _audioPlayer.setUrl(url);
                _audioPlayer.play();
                _audioPlayer.playerStateStream.listen((state) {
                  if (state.processingState == ProcessingState.completed && mounted) {
                    setState(() => _playingUrl = null);
                  }
                });
              }
            },
            child: Icon(
              isPlaying ? Icons.stop_circle : Icons.play_circle_fill,
              size: 36,
              color: isMe ? ColorConstants.primaryColor : Colors.white,
            ),
          ),
          const SizedBox(width: 8),
          Icon(Icons.graphic_eq, color: isMe ? ColorConstants.greyColor : Colors.white70, size: 20),
          const SizedBox(width: 4),
          Text(
            '🎤 Audio',
            style: TextStyle(
              color: isMe ? ColorConstants.primaryColor : Colors.white,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
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
                        color: active
                            ? Colors.green
                            : (isMe ? Colors.grey : Colors.white70),
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
                    style: TextStyle(
                      color: isMe ? ColorConstants.primaryColor : Colors.white,
                      fontSize: 11,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Toca para abrir en Maps',
                    style: TextStyle(
                      color: isMe ? Colors.blue : Colors.white70,
                      decoration: TextDecoration.underline,
                      fontSize: 12,
                    ),
                  ),
                ],
                if (!active)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      'El usuario dejó de compartir',
                      style: TextStyle(
                        color: isMe ? Colors.grey : Colors.white60,
                        fontSize: 11,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
  // ────────────────────────────────────────────────────────────

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

      setState(() {
        _isLoading = true;
      });

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
      );

      final payload = jsonEncode({
        'lat': position.latitude,
        'lng': position.longitude,
      });

      setState(() {
        _isLoading = false;
      });

      _onSendMessage(payload, TypeMessage.location);
    } catch (e) {
      setState(() {
        _isLoading = false;
      });
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

  Widget _buildLocationBubble(String content, {required bool isMe}) {
    final location = _parseLocationContent(content);
    if (location == null) {
      return Container(
        padding: const EdgeInsets.fromLTRB(15, 10, 15, 10),
        width: 220,
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
      width: 220,
      padding: const EdgeInsets.fromLTRB(15, 12, 15, 12),
      decoration: BoxDecoration(
        color: isMe ? ColorConstants.greyColor2 : ColorConstants.primaryColor,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
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

  Future<void> _uploadFile() async {
    if (_imageFile == null) {
      Fluttertoast.showToast(msg: 'No hay imagen seleccionada');
      return;
    }
    setState(() => _isLoading = true);
    final fileName = 'chat_images/${_currentUserId}_${DateTime.now().millisecondsSinceEpoch}.jpg';
    final uploadTask = _chatProvider.uploadFile(_imageFile!, fileName);
    try {
      final snapshot = await uploadTask;
      if (snapshot.state != TaskState.success) {
        setState(() => _isLoading = false);
        Fluttertoast.showToast(msg: 'Error al subir la imagen (estado: ${snapshot.state})');
        return;
      }
      _imageUrl = await snapshot.ref.getDownloadURL();
      setState(() {
        _isLoading = false;
        _onSendMessage(_imageUrl, TypeMessage.image);
      });
    } on FirebaseException catch (e) {
      setState(() => _isLoading = false);
      Fluttertoast.showToast(msg: 'Firebase: ${e.code} - ${e.message}');
    } catch (e) {
      setState(() => _isLoading = false);
      Fluttertoast.showToast(msg: 'Error al subir la imagen');
    }
  }

  void _onSendMessage(String content, int type) {
    if (content.trim().isNotEmpty) {
      _chatInputController.clear();
      final extras = <String, dynamic>{};
      final myRolId = _authProvider.prefs.getString(FirestoreConstants.rolId) ?? '';
      extras['senderRolId'] = myRolId;
      if (_replyTo != null) {
        extras['replyTo'] = _replyTo;
        setState(() => _replyTo = null);
      }
      _chatProvider.setTyping(_groupChatId, _currentUserId, false);
      _typingTimer?.cancel();
      _chatProvider.sendMessage(content, type, _groupChatId, _currentUserId, widget.arguments.peerId,
          extras: extras.isNotEmpty ? extras : null);
      if (_listScrollController.hasClients) {
        _listScrollController.animateTo(0, duration: Duration(milliseconds: 300), curve: Curves.easeOut);
      }
    } else {
      Fluttertoast.showToast(msg: 'Nothing to send', backgroundColor: ColorConstants.greyColor);
    }
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
        style: TextStyle(color: Colors.blue, decoration: TextDecoration.underline),
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
    if (spans.isEmpty) {
      return Text(text, style: TextStyle(color: textColor));
    }
    return RichText(text: TextSpan(children: spans));
  }

  Widget _buildItemMessage(int index, DocumentSnapshot? document) {
    if (document == null) return SizedBox.shrink();
    final messageChat = MessageChat.fromDocument(document);
    final docData = document.data() as Map<String, dynamic>;
    final reactions = Map<String, dynamic>.from(docData['reactions'] as Map? ?? {});
    final replyTo = docData['replyTo'] as Map<String, dynamic>?;
    final deletedByName = docData['deletedByName'] as String? ?? '';
    final isDeleted = (docData['deletedBy'] as String? ?? '').isNotEmpty;
    final msgStatus = docData['status'] as String?;
    final isMe = messageChat.idFrom == _currentUserId;
    // Detect if peer is admin from their messages
    if (!isMe && (docData['senderRolId'] as String? ?? '') == '1' && !_peerIsAdmin) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _peerIsAdmin = true);
      });
    }
    final senderName = _authProvider.prefs.getString(FirestoreConstants.nickname) ?? 'Yo';
    final msgKey = _messageKeys.putIfAbsent(document.id, () => GlobalKey());

    Widget _bubbleContent() {
      if (isDeleted) {
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
              Flexible(child: Text('Eliminado por $deletedByName', style: const TextStyle(fontSize: 12, color: Colors.grey, fontStyle: FontStyle.italic))),
            ],
          ),
        );
      }
      if (messageChat.type == TypeMessage.text) {
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
              if (replyTo != null) _buildReplyBubble(replyTo, onTap: () => _scrollToMessage(replyTo['msgId'] ?? '')),
              _buildRichText(messageChat.content, isMe ? ColorConstants.primaryColor : Colors.white),
            ],
          ),
        );
      } else if (messageChat.type == TypeMessage.image) {
        return Container(
          clipBehavior: Clip.hardEdge,
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(8)),
          child: GestureDetector(
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => FullPhotoPage(url: messageChat.content))),
            child: Image.network(messageChat.content,
              loadingBuilder: (_, child, prog) {
                if (prog == null) return child;
                return Container(width: 200, height: 200, color: ColorConstants.greyColor2,
                  child: Center(child: CircularProgressIndicator(color: ColorConstants.themeColor,
                    value: prog.expectedTotalBytes != null ? prog.cumulativeBytesLoaded / prog.expectedTotalBytes! : null)));
              },
              errorBuilder: (_, __, ___) => Image.asset('images/img_not_available.jpeg', width: 200, height: 200, fit: BoxFit.cover),
              width: 200, height: 200, fit: BoxFit.cover),
          ),
        );
      } else if (messageChat.type == TypeMessage.video) {
        return _buildVideoBubble(messageChat.content);
      } else if (messageChat.type == TypeMessage.location) {
        return LocationMapBubble(payload: messageChat.content, isMe: isMe, live: false);
      } else if (messageChat.type == TypeMessage.liveLocation) {
        return LocationMapBubble(payload: messageChat.content, isMe: isMe, live: true);
      } else if (messageChat.type == TypeMessage.audio) {
        return _buildAudioBubble(messageChat.content, isMe: isMe);
      } else if (messageChat.type == TypeMessage.videoCall || messageChat.type == TypeMessage.audioCall) {
        return _buildCallBubble(messageChat.content, isVideo: messageChat.type == TypeMessage.videoCall, isMe: isMe);
      } else {
        return _buildStickerImage(messageChat.content);
      }
    }

    Widget bubble = GestureDetector(
      onLongPress: () => _showReactionPicker(document.id),
      onHorizontalDragEnd: (details) {
        if (details.primaryVelocity != null && details.primaryVelocity! > 200) {
          setState(() => _replyTo = {
            'content': messageChat.content,
            'senderName': isMe ? senderName : widget.arguments.peerNickname,
            'msgId': document.id,
            'type': messageChat.type,
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
        key: msgKey,
        margin: EdgeInsets.only(bottom: _isLastMessageRight(index) ? 20 : 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                bubble,
                const SizedBox(width: 10),
              ],
            ),
            if (_isLastMessageRight(index))
              Padding(
                padding: const EdgeInsets.only(right: 10, top: 3),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      DateFormat('HH:mm').format(DateTime.fromMillisecondsSinceEpoch(int.tryParse(messageChat.timestamp) ?? 0)),
                      style: const TextStyle(color: ColorConstants.greyColor, fontSize: 11),
                    ),
                    const SizedBox(width: 3),
                    _buildTicks(msgStatus),
                  ],
                ),
              ),
          ],
        ),
      );
    } else {
      return Container(
        key: msgKey,
        margin: EdgeInsets.only(bottom: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                _isLastMessageLeft(index)
                    ? ClipOval(child: Image.network(widget.arguments.peerAvatar,
                        width: 35, height: 35, fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => const Icon(Icons.account_circle, size: 35, color: ColorConstants.greyColor)))
                    : Container(width: 35),
                const SizedBox(width: 6),
                bubble,
              ],
            ),
            if (_isLastMessageLeft(index))
              Padding(
                padding: const EdgeInsets.only(left: 47, top: 4),
                child: Text(
                  DateFormat('dd MMM kk:mm').format(DateTime.fromMillisecondsSinceEpoch(int.tryParse(messageChat.timestamp) ?? 0)),
                  style: const TextStyle(color: ColorConstants.greyColor, fontSize: 12, fontStyle: FontStyle.italic),
                ),
              ),
          ],
        ),
      );
    }
  }

  bool _isLastMessageLeft(int index) {
    if ((index > 0 && _listMessage[index - 1].get(FirestoreConstants.idFrom) == _currentUserId) || index == 0) {
      return true;
    } else {
      return false;
    }
  }

  bool _isLastMessageRight(int index) {
    if ((index > 0 && _listMessage[index - 1].get(FirestoreConstants.idFrom) != _currentUserId) || index == 0) {
      return true;
    } else {
      return false;
    }
  }

  void _onBackPress() {
    _chatProvider.updateDataFirestore(
      FirestoreConstants.pathUserCollection,
      _currentUserId,
      {FirestoreConstants.chattingWith: null},
    );
    Navigator.pop(context);
  }

  bool get _isMuted => _mutedUntil > DateTime.now().millisecondsSinceEpoch;

  void _handleAppBarMenu(String val) async {
    if (val == 'mute') {
      if (_isMuted) {
        setState(() => _mutedUntil = 0);
        await _authProvider.prefs.remove('muted_until_$_groupChatId');
        Fluttertoast.showToast(msg: 'Notificaciones activadas');
      } else {
        _showMuteDialog();
      }
    } else if (val == 'block') {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: Text(_isBlocked ? 'Desbloquear usuario' : 'Bloquear usuario'),
          content: Text(_isBlocked
              ? '¿Deseas desbloquear a ${widget.arguments.peerNickname}?'
              : '¿Bloquear a ${widget.arguments.peerNickname}? No podrás enviar ni recibir mensajes.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancelar')),
            TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Confirmar')),
          ],
        ),
      );
      if (confirm == true) _toggleBlock();
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
                  await _authProvider.prefs.setInt('muted_until_$_groupChatId', until);
                  Navigator.pop(context);
                  Fluttertoast.showToast(msg: 'Silenciado por ${opt['label']}');
                },
              ),
          ],
        ),
      ),
    );
  }

  void _showReactionPicker(String messageId) {
    const emojis = ['❤️', '👍', '😂', '😮', '😢', '👏'];
    String _deletedBy = '';
    String _msgContent = '';
    try {
      final doc = _listMessage.firstWhere((d) => d.id == messageId);
      final data = doc.data() as Map<String, dynamic>;
      _deletedBy = data['deletedBy'] as String? ?? '';
      _msgContent = data[FirestoreConstants.content] as String? ?? '';
    } catch (_) {}
    final isPinned = _pinnedMessage != null && _pinnedMessage!['msgId'] == messageId;

    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: emojis.map((e) => GestureDetector(
                  onTap: () {
                    Navigator.pop(context);
                    _chatProvider.toggleReaction(_groupChatId, messageId, e, _currentUserId);
                  },
                  child: Text(e, style: const TextStyle(fontSize: 32)),
                )).toList(),
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: Icon(isPinned ? Icons.push_pin : Icons.push_pin_outlined,
                  color: ColorConstants.primaryColor),
              title: Text(isPinned ? 'Desfijar mensaje' : 'Fijar mensaje', style: const TextStyle(fontSize: 14)),
              onTap: () {
                Navigator.pop(context);
                _togglePin(messageId, _msgContent);
              },
            ),
            if (_deletedBy.isEmpty)
              ListTile(
                leading: const Icon(Icons.delete_outline, color: Colors.orange),
                title: const Text('Eliminar mensaje', style: TextStyle(fontSize: 14)),
                subtitle: const Text('Queda visible como eliminado', style: TextStyle(fontSize: 11, color: Colors.grey)),
                onTap: () {
                  Navigator.pop(context);
                  _softDeleteMessage(messageId);
                },
              ),
            ListTile(
              leading: const Icon(Icons.delete_forever, color: Colors.red),
              title: const Text('Eliminar permanente', style: TextStyle(fontSize: 14, color: Colors.red)),
              subtitle: const Text('Se borra para siempre sin dejar rastro', style: TextStyle(fontSize: 11, color: Colors.grey)),
              onTap: () {
                Navigator.pop(context);
                _hardDeleteMessage(messageId);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _softDeleteMessage(String messageId) async {
    final myNickname = _authProvider.prefs.getString(FirestoreConstants.nickname) ?? 'Usuario';
    await FirebaseFirestore.instance
        .collection(FirestoreConstants.pathMessageCollection)
        .doc(_groupChatId)
        .collection(_groupChatId)
        .doc(messageId)
        .update({
      'deletedBy': _currentUserId,
      'deletedByName': myNickname,
      'deletedAt': DateTime.now().millisecondsSinceEpoch,
    });
  }

  Future<void> _hardDeleteMessage(String messageId) async {
    await FirebaseFirestore.instance
        .collection(FirestoreConstants.pathMessageCollection)
        .doc(_groupChatId)
        .collection(_groupChatId)
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: StreamBuilder<DocumentSnapshot>(
          stream: FirebaseFirestore.instance
              .collection(FirestoreConstants.pathUserCollection)
              .doc(widget.arguments.peerId)
              .snapshots(),
          builder: (_, snap) {
            final data = snap.data?.data() as Map<String, dynamic>?;
            final isOnline = data?[FirestoreConstants.isOnline] as bool? ?? false;
            final lastSeen = data?[FirestoreConstants.lastSeen] as int? ?? 0;
            String subtitle = '';
            if (isOnline) {
              subtitle = 'en línea';
            } else if (lastSeen > 0) {
              final dt = DateTime.fromMillisecondsSinceEpoch(lastSeen);
              final diff = DateTime.now().difference(dt);
              if (diff.inMinutes < 1) subtitle = 'visto hace un momento';
              else if (diff.inMinutes < 60) subtitle = 'visto hace ${diff.inMinutes}m';
              else if (diff.inHours < 24) subtitle = 'visto hoy a las ${dt.hour.toString().padLeft(2,'0')}:${dt.minute.toString().padLeft(2,'0')}';
              else if (diff.inDays == 1) subtitle = 'visto ayer';
              else subtitle = 'visto el ${dt.day}/${dt.month}';
            }
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!_peerIsAdmin)
                  Text(widget.arguments.peerNickname, style: const TextStyle(color: ColorConstants.primaryColor))
                else
                  RainbowText(widget.arguments.peerNickname, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
                if (_peerTyping)
                  const Text('escribiendo...', style: TextStyle(fontSize: 11, color: Colors.green, fontStyle: FontStyle.italic))
                else if (subtitle.isNotEmpty)
                  Text(subtitle, style: TextStyle(fontSize: 11, color: isOnline ? Colors.green : Colors.grey)),
                if (_isMuted)
                  const Text('🔇 silenciado', style: TextStyle(fontSize: 10, color: Colors.grey)),
              ],
            );
          },
        ),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.videocam, color: ColorConstants.primaryColor),
            tooltip: 'Videollamada',
            onPressed: () => _startJitsiCall(videoMuted: false),
          ),
          IconButton(
            icon: const Icon(Icons.call, color: Colors.green),
            tooltip: 'Llamada de voz',
            onPressed: () => _startJitsiCall(videoMuted: true),
          ),
          IconButton(
            icon: const Icon(Icons.phone_forwarded, color: Colors.orange),
            tooltip: 'Llamada anónima (Twilio)',
            onPressed: _twilioCall,
          ),
          PopupMenuButton<String>(
            onSelected: (val) => _handleAppBarMenu(val),
            itemBuilder: (_) => [
              PopupMenuItem(value: 'mute', child: Row(children: [
                Icon(_isMuted ? Icons.notifications_active : Icons.notifications_off, size: 18, color: Colors.grey),
                const SizedBox(width: 8),
                Text(_isMuted ? 'Activar notificaciones' : 'Silenciar'),
              ])),
              PopupMenuItem(value: 'block', child: Row(children: [
                Icon(_isBlocked ? Icons.lock_open : Icons.block, size: 18, color: _isBlocked ? Colors.green : Colors.red),
                const SizedBox(width: 8),
                Text(_isBlocked ? 'Desbloquear usuario' : 'Bloquear usuario'),
              ])),
            ],
          ),
        ],
      ),
      body: SafeArea(
        child: PopScope(
          child: Stack(
            children: [
              Column(
                children: [
                  if (_groupChatId.startsWith('order-') && _viewerIsAgente) _buildGpsBanner(),
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
                              onTap: () => _togglePin(_pinnedMessage!['msgId'] ?? '', ''),
                              child: const Icon(Icons.close, size: 16, color: Colors.grey),
                            ),
                          ],
                        ),
                      ),
                    ),
                  _buildListMessage(),
                  _isShowSticker ? _buildStickers() : SizedBox.shrink(),
                  if (_isBlocked || _blockedByPeer)
                    Container(
                      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                      color: Colors.grey.shade200,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.block, color: Colors.grey, size: 18),
                          const SizedBox(width: 8),
                          Text(
                            _isBlocked ? 'Has bloqueado a este usuario' : 'No puedes enviar mensajes',
                            style: const TextStyle(color: Colors.grey, fontSize: 13),
                          ),
                          if (_isBlocked) ...[
                            const SizedBox(width: 8),
                            GestureDetector(
                              onTap: _toggleBlock,
                              child: const Text('Desbloquear',
                                  style: TextStyle(color: ColorConstants.primaryColor, fontSize: 13, fontWeight: FontWeight.bold)),
                            ),
                          ],
                        ],
                      ),
                    )
                  else
                    _buildInput(),
                ],
              ),
              Positioned(
                child: _isLoading ? LoadingView() : SizedBox.shrink(),
              ),
            ],
          ),
          canPop: false,
          onPopInvokedWithResult: (didPop, result) {
            if (didPop) return;
            _onBackPress();
          },
        ),
      ),
    );
  }

  Widget _buildGpsBanner() {
    if (_motoGps == null) {
      // No GPS data yet — show waiting state
      return Container(
        color: const Color(0xFFf0fdf4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            const Icon(Icons.location_searching, size: 18, color: Colors.grey),
            const SizedBox(width: 8),
            const Text('Esperando ubicación del motoboy...', style: TextStyle(color: Colors.grey, fontSize: 12)),
          ],
        ),
      );
    }
    final gps = _motoGps!;
    final lat = (gps['lat'] as num?)?.toDouble();
    final lng = (gps['lng'] as num?)?.toDouble();
    final updatedAt = gps['updatedAt'] as int?;
    final online = gps['online'] as bool? ?? false;

    if (lat == null || lng == null) return const SizedBox.shrink();

    String agoText = '';
    if (updatedAt != null) {
      final mins = ((DateTime.now().millisecondsSinceEpoch - updatedAt) / 60000).round();
      agoText = mins < 1 ? 'ahora mismo' : 'hace ${mins} min';
    }

    return GestureDetector(
      onTap: () async {
        final url = Uri.parse('https://maps.google.com/?q=$lat,$lng');
        if (await canLaunchUrl(url)) launchUrl(url, mode: LaunchMode.externalApplication);
      },
      child: Container(
        color: const Color(0xFFf0fdf4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header con toggle ocultar
            GestureDetector(
              onTap: () => setState(() => _gpsBannerExpanded = !_gpsBannerExpanded),
              child: Container(
                color: const Color(0xFF128C7E),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                child: Row(
                  children: [
                    Container(
                      width: 8, height: 8,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: online ? Colors.greenAccent : Colors.grey,
                      ),
                    ),
                    const SizedBox(width: 6),
                    const Icon(Icons.directions_bike, size: 13, color: Colors.white),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        'Ubicación del motoboy${agoText.isNotEmpty ? '  ·  $agoText' : ''}',
                        style: const TextStyle(fontSize: 11, color: Colors.white, fontWeight: FontWeight.w600),
                      ),
                    ),
                    Icon(
                      _gpsBannerExpanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                      size: 16, color: Colors.white,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      _gpsBannerExpanded ? 'Ocultar' : 'Ver mapa',
                      style: const TextStyle(color: Colors.white, fontSize: 10),
                    ),
                  ],
                ),
              ),
            ),
            // Mapa colapsable
            AnimatedCrossFade(
              firstChild: SizedBox(
                height: 220,
                child: Stack(
                  children: [
                    _LiveMiniMap(lat: lat, lng: lng, nickname: widget.arguments.peerNickname),
                    Positioned(
                      top: 6, right: 6,
                      child: GestureDetector(
                        onTap: () async {
                          final url = Uri.parse('https://maps.google.com/?q=$lat,$lng');
                          if (await canLaunchUrl(url)) launchUrl(url, mode: LaunchMode.externalApplication);
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.black54,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.open_in_new, size: 11, color: Colors.white),
                              SizedBox(width: 4),
                              Text('Google Maps', style: TextStyle(color: Colors.white, fontSize: 10)),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              secondChild: const SizedBox(height: 0),
              crossFadeState: _gpsBannerExpanded ? CrossFadeState.showFirst : CrossFadeState.showSecond,
              duration: const Duration(milliseconds: 220),
            ),
          ],
        ),
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

  Widget _buildStickerImage(String content) {
    if (content.startsWith('http')) {
      return Image.network(
        content,
        width: 120,
        height: 120,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => const Icon(Icons.broken_image),
      );
    }
    return Image.asset(
      'images/$content.gif',
      width: 120,
      height: 120,
      fit: BoxFit.cover,
    );
  }

  Widget _buildInput() {
    return Container(
      decoration: BoxDecoration(
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
                  tooltip: 'Enviar foto de galería',
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
                  onPressed: () {
                    _pickImage(source: ImageSource.camera).then((isSuccess) {
                      if (isSuccess) _uploadFile();
                    });
                  },
                  color: ColorConstants.primaryColor,
                ),
              ),
              Material(
                color: Colors.white,
                child: IconButton(
                  icon: Icon(_isSharingLiveLocation ? Icons.location_off : Icons.my_location),
                  tooltip: _isSharingLiveLocation ? 'Detener ubicación en vivo' : 'Activar mi ubicación',
                  onPressed: _toggleLiveLocation,
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
              const Spacer(),
              if (_isRecording)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.cancel, color: Colors.grey),
                      onPressed: _cancelRecording,
                    ),
                    IconButton(
                      icon: const Icon(Icons.send, color: Colors.green),
                      onPressed: _stopAndSendRecording,
                    ),
                  ],
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
                    onSubmitted: (_) {
                      _onSendMessage(_chatInputController.text, TypeMessage.text);
                    },
                    style: const TextStyle(color: ColorConstants.primaryColor, fontSize: 15),
                    controller: _chatInputController,
                    decoration: InputDecoration.collapsed(
                      hintText: _isRecording ? '🔴 Grabando... $_recordSeconds s' : 'Escribe un mensaje...',
                      hintStyle: TextStyle(color: _isRecording ? Colors.red : ColorConstants.greyColor),
                    ),
                    focusNode: _focusNode,
                    enabled: !_isRecording,
                  ),
                ),
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: _chatInputController,
                  builder: (_, value, __) {
                    final hasText = value.text.trim().isNotEmpty;
                    if (_isRecording) return const SizedBox.shrink();
                    return hasText
                        ? IconButton(
                            icon: const Icon(Icons.send),
                            color: ColorConstants.primaryColor,
                            onPressed: () => _onSendMessage(_chatInputController.text, TypeMessage.text),
                          )
                        : IconButton(
                            icon: const Icon(Icons.mic),
                            color: ColorConstants.primaryColor,
                            onPressed: _startRecording,
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

  void _checkIncomingCall() {
    if (!mounted || _listMessage.isEmpty || _callDialogVisible) return;
    // Most recent message is first in the reversed list
    final doc = _listMessage.first;
    final type = doc.get(FirestoreConstants.type) as int? ?? -1;
    if (type != TypeMessage.videoCall && type != TypeMessage.audioCall) return;
    final idFrom = doc.get(FirestoreConstants.idFrom) as String? ?? '';
    if (idFrom == _currentUserId) return; // I sent it, no dialog needed
    final docId = doc.id;
    if (docId == _lastShownCallId) return; // Already shown
    // Only show for recent calls (< 2 min)
    final ts = int.tryParse(doc.get(FirestoreConstants.timestamp)?.toString() ?? '0') ?? 0;
    final age = DateTime.now().millisecondsSinceEpoch - ts;
    if (age > 120000) return;

    _lastShownCallId = docId;
    final isVideo = type == TypeMessage.videoCall;
    final roomName = doc.get(FirestoreConstants.content) as String? ?? '';

    _callDialogVisible = true;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(isVideo ? Icons.videocam : Icons.call, color: Colors.green, size: 28),
            const SizedBox(width: 10),
            Text(isVideo ? 'Videollamada entrante' : 'Llamada entrante'),
          ],
        ),
        content: Text('${widget.arguments.peerNickname} te está llamando'),
        actions: [
          TextButton(
            onPressed: () {
              _callDialogVisible = false;
              Navigator.of(context, rootNavigator: true).pop();
            },
            child: const Text('Rechazar', style: TextStyle(color: Colors.red)),
          ),
          ElevatedButton.icon(
            onPressed: () {
              _callDialogVisible = false;
              Navigator.of(context, rootNavigator: true).pop();
              final myNickname = _authProvider.prefs.getString(FirestoreConstants.nickname) ?? 'Usuario';
              final myAvatar = _authProvider.prefs.getString(FirestoreConstants.photoUrl) ?? '';
              JitsiMeet().join(JitsiMeetConferenceOptions(
                serverURL: 'https://jitsi.38.247.147.220.nip.io',
                room: roomName,
                configOverrides: {
                  'startWithAudioMuted': false,
                  'startWithVideoMuted': !isVideo,
                  'subject': widget.arguments.peerNickname,
                },
                featureFlags: {
                  'unsafeRoomWarning.enabled': false,
                  'welcomePage.enabled': false,
                  'calendar.enabled': false,
                  'recording.enabled': false,
                  'liveStreaming.enabled': false,
                  'invite.enabled': false,
                },
                userInfo: JitsiMeetUserInfo(
                  displayName: myNickname,
                  avatar: myAvatar.isNotEmpty ? myAvatar : null,
                ),
              ));
            },
            icon: Icon(isVideo ? Icons.videocam : Icons.call, size: 16),
            label: const Text('Contestar'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.green,
              foregroundColor: Colors.white,
            ),
          ),
        ],
      ),
    ).then((_) => _callDialogVisible = false);
  }

  Widget _buildListMessage() {
    return Flexible(
      child: _groupChatId.isNotEmpty
          ? StreamBuilder<QuerySnapshot>(
              stream: _chatProvider.getChatStream(_groupChatId, _limit),
              builder: (_, snapshot) {
                if (snapshot.hasData) {
                  _listMessage = snapshot.data!.docs;
                  // Check for incoming call
                  WidgetsBinding.instance.addPostFrameCallback((_) => _checkIncomingCall());
                  if (_listMessage.length > 0) {
                    return ListView.builder(
                      padding: EdgeInsets.all(10),
                      itemBuilder: (_, index) => _buildItemMessage(index, snapshot.data?.docs[index]),
                      itemCount: snapshot.data?.docs.length,
                      reverse: true,
                      controller: _listScrollController,
                    );
                  } else {
                    return Center(child: Text("No message here yet..."));
                  }
                } else {
                  return Center(
                    child: CircularProgressIndicator(
                      color: ColorConstants.themeColor,
                    ),
                  );
                }
              },
            )
          : Center(
              child: CircularProgressIndicator(
                color: ColorConstants.themeColor,
              ),
            ),
    );
  }
}

/// Mini mapa Leaflet/OSM que sigue la posici\u00f3n en vivo del motoboy.
class _LiveMiniMap extends StatefulWidget {
  const _LiveMiniMap({required this.lat, required this.lng, required this.nickname});
  final double lat;
  final double lng;
  final String nickname;

  @override
  State<_LiveMiniMap> createState() => _LiveMiniMapState();
}

class _LiveMiniMapState extends State<_LiveMiniMap> {
  late final MapController _ctrl = MapController();

  @override
  void didUpdateWidget(covariant _LiveMiniMap old) {
    super.didUpdateWidget(old);
    if (old.lat != widget.lat || old.lng != widget.lng) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        try { _ctrl.move(LatLng(widget.lat, widget.lng), _ctrl.camera.zoom); } catch (_) {}
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final point = LatLng(widget.lat, widget.lng);
    final initial = (widget.nickname.isNotEmpty ? widget.nickname[0] : '?').toUpperCase();
    return FlutterMap(
      mapController: _ctrl,
      options: MapOptions(
        initialCenter: point,
        initialZoom: 15,
      ),
      children: [
        TileLayer(
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          userAgentPackageName: 'com.lamano.clonewhatsapp',
        ),
        MarkerLayer(markers: [
          Marker(
            point: point,
            width: 40,
            height: 40,
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
                border: Border.all(color: const Color(0xFF128C7E), width: 2.5),
                boxShadow: const [
                  BoxShadow(color: Color(0x44128C7E), blurRadius: 8, spreadRadius: 2),
                ],
              ),
              alignment: Alignment.center,
              child: Text(
                initial,
                style: const TextStyle(
                  color: Color(0xFF128C7E),
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
            ),
          ),
        ]),
      ],
    );
  }
}

class ChatPageArguments {
  final String peerId;
  final String peerAvatar;
  final String peerNickname;
  final String? customGroupChatId;
  final String? peerLamanoId;

  ChatPageArguments({
    required this.peerId,
    required this.peerAvatar,
    required this.peerNickname,
    this.customGroupChatId,
    this.peerLamanoId,
  });
}
