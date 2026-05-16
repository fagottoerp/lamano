import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_chat_demo/constants/constants.dart';
import 'package:flutter_chat_demo/models/models.dart';
import 'package:flutter_chat_demo/pages/pages.dart';
import 'package:flutter_chat_demo/providers/providers.dart';
import 'package:flutter_chat_demo/utils/utils.dart';
import 'package:provider/provider.dart';

class ContactsPage extends StatefulWidget {
  const ContactsPage({super.key});

  @override
  State<ContactsPage> createState() => _ContactsPageState();
}

class _ContactsPageState extends State<ContactsPage> {
  int _limit = 20;
  final _limitIncrement = 20;
  String _textSearch = '';
  final _searchBarController = TextEditingController();
  final _btnClearController = StreamController<bool>();
  final _listScrollController = ScrollController();
  final _searchDebouncer = Debouncer(milliseconds: 300);

  late final _homeProvider = context.read<HomeProvider>();
  late final _authProvider = context.read<AuthProvider>();
  late final String _currentUserId;

  @override
  void initState() {
    super.initState();
    _currentUserId = _authProvider.userFirebaseId ?? '';
    _listScrollController.addListener(_scrollListener);
  }

  void _scrollListener() {
    if (_listScrollController.offset >= _listScrollController.position.maxScrollExtent &&
        !_listScrollController.position.outOfRange) {
      setState(() => _limit += _limitIncrement);
    }
  }

  @override
  void dispose() {
    _searchBarController.dispose();
    _btnClearController.close();
    _listScrollController.removeListener(_scrollListener);
    _listScrollController.dispose();
    super.dispose();
  }

  String _formatLastSeen(int timestamp) {
    if (timestamp <= 0) return 'Sin actividad';
    final diff = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(timestamp));
    if (diff.inMinutes < 1) return 'Visto hace segundos';
    if (diff.inMinutes < 60) return 'Visto hace ${diff.inMinutes} min';
    if (diff.inHours < 24) return 'Visto hace ${diff.inHours} h';
    return 'Visto hace ${diff.inDays} d';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Contactos', style: TextStyle(color: ColorConstants.primaryColor)),
        centerTitle: true,
      ),
      body: SafeArea(
        child: Column(
          children: [
            _buildSearchBar(),
            Expanded(
              child: StreamBuilder<QuerySnapshot>(
                stream: _homeProvider.getStreamFireStore(
                  FirestoreConstants.pathUserCollection,
                  _limit,
                  _textSearch,
                ),
                builder: (_, snapshot) {
                  if (!snapshot.hasData) {
                    return const Center(child: CircularProgressIndicator(color: ColorConstants.themeColor));
                  }
                  final allDocs = snapshot.data?.docs ?? [];
                  final q = _textSearch.trim().toLowerCase();
                  final docs = q.isEmpty
                      ? allDocs
                      : allDocs.where((d) {
                          final user = UserChat.fromDocument(d);
                          return user.nickname.toLowerCase().contains(q) ||
                              user.aboutMe.toLowerCase().contains(q);
                        }).toList();
                  if (docs.isEmpty) {
                    return const Center(child: Text('No se encontraron contactos'));
                  }
                  return ListView.builder(
                    padding: const EdgeInsets.all(10),
                    itemCount: docs.length,
                    controller: _listScrollController,
                    itemBuilder: (_, index) => _buildItem(docs[index]),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchBar() {
    return Container(
      height: 40,
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: ColorConstants.greyColor2,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const Icon(Icons.search, color: ColorConstants.greyColor, size: 20),
          const SizedBox(width: 5),
          Expanded(
            child: TextFormField(
              textInputAction: TextInputAction.search,
              controller: _searchBarController,
              onTapOutside: (_) => Utilities.closeKeyboard(),
              onChanged: (value) {
                _searchDebouncer.run(() {
                  if (value.isNotEmpty) {
                    _btnClearController.add(true);
                    setState(() => _textSearch = value);
                  } else {
                    _btnClearController.add(false);
                    setState(() => _textSearch = '');
                  }
                });
              },
              decoration: const InputDecoration.collapsed(
                hintText: 'Buscar por nombre o rol',
                hintStyle: TextStyle(fontSize: 13, color: ColorConstants.greyColor),
              ),
              style: const TextStyle(fontSize: 13),
            ),
          ),
          StreamBuilder<bool>(
            stream: _btnClearController.stream,
            builder: (_, snapshot) => snapshot.data == true
                ? GestureDetector(
                    onTap: () {
                      _searchBarController.clear();
                      _btnClearController.add(false);
                      setState(() => _textSearch = '');
                    },
                    child: const Icon(Icons.clear_rounded, color: ColorConstants.greyColor, size: 20),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }

  Widget _buildItem(DocumentSnapshot? document) {
    if (document == null) return const SizedBox.shrink();
    final userChat = UserChat.fromDocument(document);
    if (userChat.id == _currentUserId) return const SizedBox.shrink();

    // Try to read lamanoUserId from the document for call support
    String lamanoId = '';
    try {
      lamanoId = document.get(FirestoreConstants.lamanoUserId)?.toString() ?? '';
    } catch (_) {}

    return Container(
      margin: const EdgeInsets.only(bottom: 10, left: 5, right: 5),
      child: TextButton(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.all<Color>(ColorConstants.greyColor2),
          shape: WidgetStateProperty.all<OutlinedBorder>(
            const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(10))),
          ),
        ),
        onPressed: () {
          if (Utilities.isKeyboardShowing(context)) Utilities.closeKeyboard();
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => ChatPage(
                arguments: ChatPageArguments(
                  peerId: userChat.id,
                  peerAvatar: userChat.photoUrl,
                  peerNickname: userChat.nickname,
                  peerLamanoId: lamanoId.isNotEmpty ? lamanoId : null,
                ),
              ),
            ),
          );
        },
        child: Row(
          children: [
            ClipOval(
              child: Stack(
                children: [
                  userChat.photoUrl.isNotEmpty
                      ? Image.network(
                          userChat.photoUrl,
                          fit: BoxFit.cover,
                          width: 50,
                          height: 50,
                          errorBuilder: (_, __, ___) =>
                              const Icon(Icons.account_circle, size: 50, color: ColorConstants.greyColor),
                        )
                      : const Icon(Icons.account_circle, size: 50, color: ColorConstants.greyColor),
                  Positioned(
                    right: 1,
                    bottom: 1,
                    child: Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        color: userChat.isOnline ? Colors.green : ColorConstants.greyColor,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 2),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Flexible(
              child: Container(
                margin: const EdgeInsets.only(left: 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      userChat.nickname,
                      maxLines: 1,
                      style: const TextStyle(color: ColorConstants.primaryColor, fontWeight: FontWeight.bold),
                    ),
                    if (userChat.aboutMe.isNotEmpty)
                      Text(
                        userChat.aboutMe,
                        maxLines: 1,
                        style: const TextStyle(color: ColorConstants.greyColor, fontSize: 12),
                      ),
                    Text(
                      userChat.isOnline ? 'En línea' : _formatLastSeen(userChat.lastSeen),
                      maxLines: 1,
                      style: TextStyle(
                        color: userChat.isOnline ? Colors.green : ColorConstants.greyColor,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
