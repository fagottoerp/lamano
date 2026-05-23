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
    return StreamBuilder<QuerySnapshot>(
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
                itemCount: filtered.length,
                separatorBuilder: (_, __) => const Divider(height: 1, indent: 72),
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

                return ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  leading: CircleAvatar(
                    radius: 26,
                    backgroundImage: avatar.isNotEmpty ? NetworkImage(avatar) : null,
                    backgroundColor: ColorConstants.greyColor2,
                    child: avatar.isEmpty
                        ? Text(name.isNotEmpty ? name[0].toUpperCase() : '?',
                            style: const TextStyle(
                                color: ColorConstants.primaryColor, fontWeight: FontWeight.bold))
                        : null,
                  ),
                  title: Text(name,
                      style: const TextStyle(
                          fontWeight: FontWeight.w600, color: ColorConstants.primaryColor)),
                  subtitle: Text(lastMessage,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: ColorConstants.greyColor, fontSize: 13)),
                  trailing: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(_formatTime(lastTs),
                          style: const TextStyle(color: ColorConstants.greyColor, fontSize: 12)),
                      if (unread > 0) ...[
                        const SizedBox(height: 4),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: ColorConstants.themeColor,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            unread > 99 ? '99+' : '$unread',
                            style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                    ],
                  ),
                  onLongPress: () {
                    final archived = data['archived'] as bool? ?? false;
                    _showChatOptions(context, peerId, name, archived);
                  },
                  onTap: () {
                    // Reset unread count
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
                            // Only pass customGroupChatId for 1-on-1 / order chats (contain '-').
                            // Group IDs are Firestore auto-IDs with no '-'; skip them to avoid
                            // loading group messages inside a 1-on-1 chat view.
                            customGroupChatId: groupChatId.contains('-') ? groupChatId : null,
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
            );
          },
        ),
            ),
          ],
        );
      },
    );
  }
}
