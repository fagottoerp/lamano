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

  @override
  void initState() {
    super.initState();
    _currentUserId = _authProvider.userFirebaseId ?? '';
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
        return ListView.separated(
          itemCount: docs.length,
          separatorBuilder: (_, __) => const Divider(height: 1, indent: 72),
          itemBuilder: (_, i) {
            final data = docs[i].data() as Map<String, dynamic>;
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
                            customGroupChatId: groupChatId,
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
            );
          },
        );
      },
    );
  }
}
