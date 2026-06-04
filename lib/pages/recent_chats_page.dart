import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_chat_demo/constants/constants.dart';
import 'package:flutter_chat_demo/pages/pages.dart';
import 'package:flutter_chat_demo/providers/providers.dart';
import 'package:provider/provider.dart';

class RecentChatsPage extends StatefulWidget {
  const RecentChatsPage({super.key});

  @override
  State<RecentChatsPage> createState() => _RecentChatsPageState();
}

class _RecentChatsPageState extends State<RecentChatsPage> {
  late final _authProvider = context.read<AuthProvider>();
  late final _chatProvider = context.read<ChatProvider>();
  late final String _currentUserId;
  bool _showArchived = false;

  @override
  void initState() {
    super.initState();
    _currentUserId = _authProvider.userFirebaseId ?? '';
  }

  Future<void> _toggleArchive(String peerId, bool currentlyArchived) async {
    await FirebaseFirestore.instance
        .collection('user_conversations')
        .doc(_currentUserId)
        .collection('chats')
        .doc(peerId)
        .set({'archived': !currentlyArchived}, SetOptions(merge: true));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(currentlyArchived ? 'Chat desarchivado' : 'Chat archivado'),
        action: SnackBarAction(
          label: 'Deshacer',
          onPressed: () => _toggleArchive(peerId, !currentlyArchived),
        ),
      ));
    }
  }

  void _showChatOptions(BuildContext ctx, String peerId, String name, bool archived) {
    showModalBottomSheet(
      context: ctx,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(archived ? Icons.unarchive : Icons.archive_outlined,
                  color: ColorConstants.primaryColor),
              title: Text(archived ? 'Desarchivar chat' : 'Archivar chat'),
              onTap: () {
                Navigator.pop(ctx);
                _toggleArchive(peerId, archived);
              },
            ),
          ],
        ),
      ),
    );
  }

  String _formatTime(int ts) {
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

  @override
  Widget build(BuildContext context) {
    if (_currentUserId.isEmpty) {
      return const Center(child: Text('Sin sesión'));
    }
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFFE9F7F2), ColorConstants.bgApp],
        ),
      ),
      child: StreamBuilder<QuerySnapshot>(
        stream: _chatProvider.getRecentChats(_currentUserId),
        builder: (_, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator(color: ColorConstants.themeColor));
        }
        if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: const [
                Icon(Icons.chat_bubble_outline, size: 64, color: ColorConstants.greyColor),
                SizedBox(height: 12),
                Text('No hay chats recientes.\nBusca un contacto para chatear.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: ColorConstants.greyColor)),
              ],
            ),
          );
        }

        final docs = snapshot.data!.docs;
        final filtered = docs.where((d) {
          final data = d.data() as Map<String, dynamic>;
          final archived = data['archived'] as bool? ?? false;
          return _showArchived ? archived : !archived;
        }).toList();
        final archivedCount = docs.where((d) {
          final data = d.data() as Map<String, dynamic>;
          return data['archived'] as bool? ?? false;
        }).length;

        return Column(
          children: [
            if (!_showArchived && archivedCount > 0)
              InkWell(
                onTap: () => setState(() => _showArchived = true),
                child: Container(
                  color: ColorConstants.greyColor2,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  child: Row(
                    children: [
                      const Icon(Icons.archive_outlined, color: ColorConstants.primaryColor),
                      const SizedBox(width: 12),
                      Text('Archivados ($archivedCount)',
                          style: const TextStyle(color: ColorConstants.primaryColor, fontWeight: FontWeight.w500)),
                    ],
                  ),
                ),
              ),
            if (_showArchived)
              InkWell(
                onTap: () => setState(() => _showArchived = false),
                child: Container(
                  color: ColorConstants.greyColor2,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  child: const Row(
                    children: [
                      Icon(Icons.arrow_back, color: ColorConstants.primaryColor),
                      SizedBox(width: 12),
                      Text('Volver a chats', style: TextStyle(color: ColorConstants.primaryColor, fontWeight: FontWeight.w500)),
                    ],
                  ),
                ),
              ),
            Expanded(
              child: ListView.separated(
                padding: const EdgeInsets.fromLTRB(10, 10, 10, 18),
                itemCount: filtered.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (_, i) {
                  final data = filtered[i].data() as Map<String, dynamic>;
                  final peerId = data['peerId'] as String? ?? '';
                  final groupChatId = data['groupChatId'] as String? ?? '';
                  final lastMessage = data['lastMessage'] as String? ?? '';
                  final lastTs = data['lastTimestamp'] as int? ?? 0;
                  final unread = (data['unreadCount'] as int? ?? 0);

                  return FutureBuilder<DocumentSnapshot>(
                    future: FirebaseFirestore.instance
                        .collection(FirestoreConstants.pathUserCollection)
                        .doc(peerId)
                        .get(),
                    builder: (_, userSnap) {
                      String name = peerId;
                      String avatar = '';
                      if (userSnap.hasData && userSnap.data!.exists) {
                        final u = userSnap.data!.data() as Map<String, dynamic>;
                        name = u[FirestoreConstants.nickname] as String? ?? peerId;
                        avatar = u[FirestoreConstants.photoUrl] as String? ?? '';
                      }

                      return Material(
                        color: unread > 0 ? const Color(0xFFF3FFF8) : Colors.white,
                        borderRadius: BorderRadius.circular(16),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(16),
                          onLongPress: () {
                            final archived = data['archived'] as bool? ?? false;
                            _showChatOptions(context, peerId, name, archived);
                          },
                          onTap: () {
                            FirebaseFirestore.instance
                                .collection('user_conversations')
                                .doc(_currentUserId)
                                .collection('chats')
                                .doc(peerId)
                                .update({'unreadCount': 0}).catchError((_) {});
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => ChatPage(
                                  arguments: ChatPageArguments(
                                    peerId: peerId,
                                    peerAvatar: avatar,
                                    peerNickname: name,
                                    customGroupChatId: groupChatId.contains('-') ? groupChatId : null,
                                  ),
                                ),
                              ),
                            );
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: unread > 0 ? const Color(0xFFB8EFD0) : const Color(0xFFE3ECE8),
                                width: unread > 0 ? 1.2 : 1,
                              ),
                            ),
                            child: Row(
                              children: [
                                CircleAvatar(
                                  radius: 26,
                                  backgroundImage: avatar.isNotEmpty ? NetworkImage(avatar) : null,
                                  backgroundColor: const Color(0xFFDDF2EA),
                                  child: avatar.isEmpty
                                      ? Text(
                                          name.isNotEmpty ? name[0].toUpperCase() : '?',
                                          style: const TextStyle(
                                            color: ColorConstants.primaryColor,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        )
                                      : null,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        name,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontWeight: unread > 0 ? FontWeight.w700 : FontWeight.w600,
                                          color: ColorConstants.textPrimary,
                                        ),
                                      ),
                                      const SizedBox(height: 3),
                                      Text(
                                        lastMessage,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: unread > 0 ? const Color(0xFF2E5E4D) : ColorConstants.textSecondary,
                                          fontSize: 13,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    Text(
                                      _formatTime(lastTs),
                                      style: TextStyle(
                                        color: unread > 0 ? const Color(0xFF1F7A5F) : ColorConstants.greyColor,
                                        fontSize: 12,
                                        fontWeight: unread > 0 ? FontWeight.w600 : FontWeight.w500,
                                      ),
                                    ),
                                    if (unread > 0) ...[
                                      const SizedBox(height: 4),
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                                        decoration: BoxDecoration(
                                          color: ColorConstants.themeColor,
                                          borderRadius: BorderRadius.circular(14),
                                          boxShadow: const [
                                            BoxShadow(color: Color(0x3325D366), blurRadius: 6, offset: Offset(0, 2)),
                                          ],
                                        ),
                                        child: Text(
                                          unread > 99 ? '99+' : '$unread',
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 11,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        );
      },
    ),
  );
  }
}
