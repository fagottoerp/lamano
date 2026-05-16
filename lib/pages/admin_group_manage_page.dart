import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_chat_demo/constants/constants.dart';
import 'package:flutter_chat_demo/providers/providers.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

class AdminGroupManagePage extends StatefulWidget {
  const AdminGroupManagePage({super.key});

  @override
  State<AdminGroupManagePage> createState() => _AdminGroupManagePageState();
}

class _AdminGroupManagePageState extends State<AdminGroupManagePage> {
  final _nameController = TextEditingController();
  final _descController = TextEditingController();
  final _searchController = TextEditingController();

  final Set<String> _selectedUserIds = <String>{};
  bool _isCreating = false;
  String _userSearch = '';

  late final _authProvider = context.read<AuthProvider>();
  late final String _currentUserId;

  @override
  void initState() {
    super.initState();
    _currentUserId = _authProvider.userFirebaseId ?? '';
    _selectedUserIds.add(_currentUserId);
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _createGroup() async {
    final name = _nameController.text.trim();
    final description = _descController.text.trim();
    final members = _selectedUserIds.where((e) => e.isNotEmpty).toList();

    if (name.isEmpty) {
      Fluttertoast.showToast(msg: 'Ingresa un nombre para el grupo');
      return;
    }
    if (members.isEmpty) {
      Fluttertoast.showToast(msg: 'Selecciona al menos 1 usuario');
      return;
    }

    setState(() => _isCreating = true);
    try {
      await FirebaseFirestore.instance.collection('groups').add({
        'name': name,
        'description': description,
        'members': members,
        'createdBy': _currentUserId,
        'createdAt': DateTime.now().millisecondsSinceEpoch,
      });

      if (!mounted) return;
      _nameController.clear();
      _descController.clear();
      _searchController.clear();
      setState(() {
        _userSearch = '';
        _selectedUserIds
          ..clear()
          ..add(_currentUserId);
      });
      Fluttertoast.showToast(msg: 'Grupo creado correctamente');
    } catch (e) {
      Fluttertoast.showToast(msg: 'Error creando grupo: $e');
    } finally {
      if (mounted) setState(() => _isCreating = false);
    }
  }

  Future<void> _changeGroupImage(String groupId) async {
    try {
      final picker = ImagePicker();
      final xfile = await picker.pickImage(source: ImageSource.gallery, imageQuality: 75);
      if (xfile == null) return;
      Fluttertoast.showToast(msg: 'Subiendo imagen...');
      final chatProvider = context.read<ChatProvider>();
      final fileName = 'group_${groupId}_${DateTime.now().millisecondsSinceEpoch}';
      final snap = await chatProvider.uploadFile(File(xfile.path), fileName);
      final url = await snap.ref.getDownloadURL();
      await FirebaseFirestore.instance
          .collection('groups')
          .doc(groupId)
          .update({'groupImage': url});
      Fluttertoast.showToast(msg: '✅ Imagen actualizada', backgroundColor: Colors.green);
    } catch (e) {
      Fluttertoast.showToast(msg: 'Error: $e', backgroundColor: Colors.red);
    }
  }

  Future<void> _removeGroup(String groupId) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Eliminar grupo'),
        content: const Text('¿Seguro que deseas eliminar este grupo?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancelar')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Eliminar', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await FirebaseFirestore.instance.collection('groups').doc(groupId).delete();
      Fluttertoast.showToast(msg: 'Grupo eliminado');
    } catch (e) {
      Fluttertoast.showToast(msg: 'No se pudo eliminar: $e');
    }
  }

  /// Abre un bottom sheet para editar los miembros de un grupo existente
  void _editGroupMembers(String groupId, String groupName, List<String> currentMembers) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => _EditMembersSheet(
        groupId: groupId,
        groupName: groupName,
        currentMembers: currentMembers,
        currentUserId: _currentUserId,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Administrar Grupos', style: TextStyle(color: ColorConstants.primaryColor)),
        centerTitle: true,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(12),
          children: [
            _buildCreateCard(),
            const SizedBox(height: 14),
            _buildUsersSelectorCard(),
            const SizedBox(height: 14),
            _buildGroupsCard(),
          ],
        ),
      ),
    );
  }

  Widget _buildCreateCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Crear grupo',
                style: TextStyle(fontWeight: FontWeight.bold, color: ColorConstants.primaryColor)),
            const SizedBox(height: 10),
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(labelText: 'Nombre del grupo', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _descController,
              decoration: const InputDecoration(labelText: 'Descripción (opcional)', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 10),
            Text('Seleccionados: ${_selectedUserIds.length}', style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _isCreating ? null : _createGroup,
                icon: _isCreating
                    ? const SizedBox(
                        width: 14, height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.group_add),
                label: Text(_isCreating ? 'Creando...' : 'Crear grupo'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildUsersSelectorCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Seleccionar usuarios para el nuevo grupo',
                style: TextStyle(fontWeight: FontWeight.bold, color: ColorConstants.primaryColor)),
            const SizedBox(height: 10),
            TextField(
              controller: _searchController,
              decoration: const InputDecoration(
                labelText: 'Buscar por nombre o rol',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
              ),
              onChanged: (value) => setState(() => _userSearch = value.trim().toLowerCase()),
            ),
            const SizedBox(height: 10),
            SizedBox(
              height: 280,
              child: StreamBuilder<QuerySnapshot>(
                stream: FirebaseFirestore.instance
                    .collection(FirestoreConstants.pathUserCollection)
                    .snapshots(),
                builder: (_, snapshot) {
                  if (!snapshot.hasData) {
                    return const Center(child: CircularProgressIndicator(color: ColorConstants.themeColor));
                  }
                  final docs = snapshot.data!.docs;
                  docs.sort((a, b) {
                    final na = ((a.data() as Map)[FirestoreConstants.nickname] ?? '').toString().toLowerCase();
                    final nb = ((b.data() as Map)[FirestoreConstants.nickname] ?? '').toString().toLowerCase();
                    return na.compareTo(nb);
                  });
                  final filtered = docs.where((doc) {
                    final data = doc.data() as Map<String, dynamic>;
                    final nickname = (data[FirestoreConstants.nickname] ?? '').toString().toLowerCase();
                    final role = (data[FirestoreConstants.aboutMe] ?? '').toString().toLowerCase();
                    if (_userSearch.isEmpty) return true;
                    return nickname.contains(_userSearch) || role.contains(_userSearch);
                  }).toList();

                  if (filtered.isEmpty) {
                    return const Center(child: Text('No se encontraron usuarios'));
                  }
                  return ListView.builder(
                    itemCount: filtered.length,
                    itemBuilder: (_, index) {
                      final doc = filtered[index];
                      final data = doc.data() as Map<String, dynamic>;
                      final uid = doc.id;
                      final nickname = (data[FirestoreConstants.nickname] ?? 'Usuario').toString();
                      final role = (data[FirestoreConstants.aboutMe] ?? '').toString();
                      final selected = _selectedUserIds.contains(uid);
                      return CheckboxListTile(
                        dense: true,
                        value: selected,
                        onChanged: (v) {
                          setState(() {
                            if (v == true) {
                              _selectedUserIds.add(uid);
                            } else {
                              if (uid == _currentUserId) return;
                              _selectedUserIds.remove(uid);
                            }
                          });
                        },
                        title: Text(nickname),
                        subtitle: Text(role.isNotEmpty ? role : uid,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        secondary: CircleAvatar(
                          backgroundColor: ColorConstants.primaryColor,
                          child: Text(nickname.isNotEmpty ? nickname[0].toUpperCase() : 'U'),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGroupsCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Grupos creados',
                style: TextStyle(fontWeight: FontWeight.bold, color: ColorConstants.primaryColor)),
            const SizedBox(height: 10),
            StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('groups')
                  .orderBy('createdAt', descending: true)
                  .limit(40)
                  .snapshots(),
              builder: (_, snapshot) {
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator(color: ColorConstants.themeColor));
                }
                final docs = snapshot.data!.docs;
                if (docs.isEmpty) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Text('No hay grupos todavía.'),
                  );
                }
                return Column(
                  children: docs.map((doc) {
                    final data = doc.data() as Map<String, dynamic>;
                    final name = (data['name'] ?? 'Grupo').toString();
                    final description = (data['description'] ?? '').toString();
                    final memberList = List<String>.from((data['members'] as List?) ?? []);
                    final memberCount = memberList.length;
                    final groupImage = (data['groupImage'] as String?) ?? '';
                    final createdBy = (data['createdBy'] as String?) ?? '';
                    final isCreator = createdBy == _currentUserId;

                    return Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      elevation: 2,
                      child: ListTile(
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                        leading: GestureDetector(
                          onTap: isCreator ? () => _changeGroupImage(doc.id) : null,
                          child: CircleAvatar(
                            backgroundColor: ColorConstants.primaryColor,
                            backgroundImage: groupImage.isNotEmpty ? NetworkImage(groupImage) : null,
                            child: groupImage.isEmpty
                                ? Text(name.isNotEmpty ? name[0].toUpperCase() : 'G',
                                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold))
                                : null,
                          ),
                        ),
                        title: Text(name, style: const TextStyle(fontWeight: FontWeight.bold)),
                        subtitle: Text(
                          description.isNotEmpty
                              ? '$description · $memberCount miembros'
                              : '$memberCount miembro${memberCount == 1 ? '' : 's'}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // ── Cambiar imagen (solo creador) ──
                            if (isCreator)
                              IconButton(
                                icon: const Icon(Icons.image_outlined, color: ColorConstants.primaryColor),
                                tooltip: 'Cambiar imagen del grupo',
                                onPressed: () => _changeGroupImage(doc.id),
                              ),
                            // ── Editar miembros ──
                            IconButton(
                              icon: const Icon(Icons.group_outlined, color: ColorConstants.primaryColor),
                              tooltip: 'Editar miembros',
                              onPressed: () => _editGroupMembers(doc.id, name, memberList),
                            ),
                            // ── Eliminar ──
                            IconButton(
                              icon: const Icon(Icons.delete_outline, color: Colors.red),
                              tooltip: 'Eliminar grupo',
                              onPressed: () => _removeGroup(doc.id),
                            ),
                          ],
                        ),
                      ),
                    );
                  }).toList(),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Bottom sheet para editar miembros de un grupo ya existente
// ─────────────────────────────────────────────────────────────────────────────
class _EditMembersSheet extends StatefulWidget {
  final String groupId;
  final String groupName;
  final List<String> currentMembers;
  final String currentUserId;

  const _EditMembersSheet({
    required this.groupId,
    required this.groupName,
    required this.currentMembers,
    required this.currentUserId,
  });

  @override
  State<_EditMembersSheet> createState() => _EditMembersSheetState();
}

class _EditMembersSheetState extends State<_EditMembersSheet> {
  late Set<String> _selected;
  String _search = '';
  bool _saving = false;
  final _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _selected = Set<String>.from(widget.currentMembers);
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_selected.isEmpty) {
      Fluttertoast.showToast(msg: 'El grupo debe tener al menos 1 miembro');
      return;
    }
    setState(() => _saving = true);
    try {
      await FirebaseFirestore.instance
          .collection('groups')
          .doc(widget.groupId)
          .update({'members': _selected.toList()});
      if (mounted) {
        Fluttertoast.showToast(
          msg: 'Miembros actualizados (${_selected.length})',
          backgroundColor: Colors.green,
        );
        Navigator.pop(context);
      }
    } catch (e) {
      Fluttertoast.showToast(msg: 'Error: $e', backgroundColor: Colors.red);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      maxChildSize: 0.95,
      minChildSize: 0.5,
      builder: (_, scrollController) {
        return Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
          child: Column(
            children: [
              // Handle
              Container(
                margin: const EdgeInsets.symmetric(vertical: 10),
                width: 40, height: 4,
                decoration: BoxDecoration(
                    color: Colors.grey[300], borderRadius: BorderRadius.circular(2)),
              ),
              // Header
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Miembros: ${widget.groupName}',
                        style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: ColorConstants.primaryColor),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    TextButton.icon(
                      onPressed: _saving ? null : _save,
                      icon: _saving
                          ? const SizedBox(
                              width: 16, height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.save),
                      label: Text(_saving ? 'Guardando...' : 'Guardar (${_selected.length})'),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              // Search
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
                child: TextField(
                  controller: _searchCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Buscar usuario',
                    prefixIcon: Icon(Icons.search),
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  onChanged: (v) => setState(() => _search = v.trim().toLowerCase()),
                ),
              ),
              // User list
              Expanded(
                child: StreamBuilder<QuerySnapshot>(
                  stream: FirebaseFirestore.instance
                      .collection(FirestoreConstants.pathUserCollection)
                      .snapshots(),
                  builder: (_, snapshot) {
                    if (!snapshot.hasData) {
                      return const Center(
                          child: CircularProgressIndicator(color: ColorConstants.themeColor));
                    }
                    final docs = snapshot.data!.docs;
                    docs.sort((a, b) {
                      final na = ((a.data() as Map)[FirestoreConstants.nickname] ?? '').toString().toLowerCase();
                      final nb = ((b.data() as Map)[FirestoreConstants.nickname] ?? '').toString().toLowerCase();
                      return na.compareTo(nb);
                    });
                    final filtered = docs.where((doc) {
                      final data = doc.data() as Map<String, dynamic>;
                      final nick = (data[FirestoreConstants.nickname] ?? '').toString().toLowerCase();
                      final role = (data[FirestoreConstants.aboutMe] ?? '').toString().toLowerCase();
                      if (_search.isEmpty) return true;
                      return nick.contains(_search) || role.contains(_search);
                    }).toList();

                    if (filtered.isEmpty) {
                      return const Center(child: Text('No se encontraron usuarios'));
                    }
                    return ListView.builder(
                      controller: scrollController,
                      itemCount: filtered.length,
                      itemBuilder: (_, i) {
                        final doc = filtered[i];
                        final data = doc.data() as Map<String, dynamic>;
                        final uid = doc.id;
                        final nick = (data[FirestoreConstants.nickname] ?? 'Usuario').toString();
                        final role = (data[FirestoreConstants.aboutMe] ?? '').toString();
                        final isMe = uid == widget.currentUserId;
                        final inGroup = _selected.contains(uid);

                        return CheckboxListTile(
                          dense: true,
                          value: inGroup,
                          onChanged: (v) {
                            if (isMe) return; // admin siempre queda
                            setState(() {
                              if (v == true) {
                                _selected.add(uid);
                              } else {
                                _selected.remove(uid);
                              }
                            });
                          },
                          title: Text(nick,
                              style: TextStyle(
                                  fontWeight: isMe ? FontWeight.bold : FontWeight.normal)),
                          subtitle: Text(
                            role.isNotEmpty
                                ? (isMe ? '$role · (tú)' : role)
                                : (isMe ? 'tú' : uid),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          secondary: CircleAvatar(
                            backgroundColor: inGroup
                                ? ColorConstants.primaryColor
                                : ColorConstants.greyColor2,
                            child: Text(
                              nick.isNotEmpty ? nick[0].toUpperCase() : 'U',
                              style: TextStyle(
                                  color: inGroup ? Colors.white : ColorConstants.greyColor),
                            ),
                          ),
                          activeColor: ColorConstants.primaryColor,
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
