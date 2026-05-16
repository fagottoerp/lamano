import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_chat_demo/constants/constants.dart';
import 'package:flutter_chat_demo/models/models.dart';
import 'package:flutter_chat_demo/providers/providers.dart';
import 'package:flutter_chat_demo/widgets/loading_view.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State createState() => SettingsPageState();
}

class SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _controllerNickname;
  late final TextEditingController _controllerAboutMe;

  String _userId = '';
  String _nickname = '';
  String _aboutMe = '';
  String _avatarUrl = '';
  String _phone = '';
  bool _isMotoboy = false;

  bool _isLoading = false;
  bool _savingPhone = false;
  File? _avatarFile;
  late final _settingProvider = context.read<SettingProvider>();
  late final TextEditingController _controllerPhone;

  final _focusNodeNickname = FocusNode();
  final _focusNodeAboutMe = FocusNode();

  Color _myBubbleColor = const Color(0xFFE8E8E8);

  Future<void> _loadBubbleColor() async {
    final prefs = await SharedPreferences.getInstance();
    final val = prefs.getInt('myBubbleColor');
    if (val != null) setState(() => _myBubbleColor = Color(val));
  }

  Future<void> _saveBubbleColor(Color color) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('myBubbleColor', color.value);
    setState(() => _myBubbleColor = color);
  }

  void _showColorPicker() {
    Color picked = _myBubbleColor;
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Color de mis burbujas'),
        content: SingleChildScrollView(
          child: ColorPicker(
            pickerColor: picked,
            onColorChanged: (c) => picked = c,
            enableAlpha: false,
            pickerAreaHeightPercent: 0.8,
          ),
        ),
        actions: [
          TextButton(child: const Text('Cancelar'), onPressed: () => Navigator.pop(context)),
          ElevatedButton(child: const Text('Guardar'), onPressed: () {
            _saveBubbleColor(picked);
            Navigator.pop(context);
          }),
        ],
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _readLocal();
    _loadBubbleColor();
  }

  void _readLocal() {
    setState(() {
      _userId = _settingProvider.getPref(FirestoreConstants.id) ?? "";
      _nickname = _settingProvider.getPref(FirestoreConstants.nickname) ?? "";
      _aboutMe = _settingProvider.getPref(FirestoreConstants.aboutMe) ?? "";
      _avatarUrl = _settingProvider.getPref(FirestoreConstants.photoUrl) ?? "";
      _phone = _settingProvider.getPref(FirestoreConstants.motoboyPhone) ?? "";
      _isMotoboy = (_settingProvider.getPref(FirestoreConstants.aboutMe) ?? '')
          .toLowerCase()
          .contains('motoboy');
    });
    _controllerPhone = TextEditingController(text: _phone);

    _controllerNickname = TextEditingController(text: _nickname);
    _controllerAboutMe = TextEditingController(text: _aboutMe);
  }

  Future<bool> _pickAvatar() async {
    final imagePicker = ImagePicker();
    final pickedXFile = await imagePicker.pickImage(source: ImageSource.gallery).catchError((err) {
      Fluttertoast.showToast(msg: err.toString());
      return null;
    });
    if (pickedXFile != null) {
      final imageFile = File(pickedXFile.path);
      setState(() {
        _avatarFile = imageFile;
        _isLoading = true;
      });
      return true;
    } else {
      return false;
    }
  }

  Future<void> _uploadFile() async {
    final fileName = _userId;
    final uploadTask = _settingProvider.uploadFile(_avatarFile!, fileName);
    try {
      final snapshot = await uploadTask;
      _avatarUrl = await snapshot.ref.getDownloadURL();
      final updateInfo = UserChat(
        id: _userId,
        photoUrl: _avatarUrl,
        nickname: _nickname,
        aboutMe: _aboutMe,
      );
      _settingProvider
          .updateDataFirestore(FirestoreConstants.pathUserCollection, _userId, updateInfo.toJson())
          .then((_) async {
        await _settingProvider.setPref(FirestoreConstants.photoUrl, _avatarUrl);
        setState(() {
          _isLoading = false;
        });
        Fluttertoast.showToast(msg: "Upload success");
      }).catchError((err) {
        setState(() {
          _isLoading = false;
        });
        Fluttertoast.showToast(msg: err.toString());
      });
    } on FirebaseException catch (e) {
      setState(() {
        _isLoading = false;
      });
      Fluttertoast.showToast(msg: e.message ?? e.toString());
    }
  }

  void _handleUpdateData() {
    _focusNodeNickname.unfocus();
    _focusNodeAboutMe.unfocus();

    setState(() {
      _isLoading = true;
    });
    UserChat updateInfo = UserChat(
      id: _userId,
      photoUrl: _avatarUrl,
      nickname: _nickname,
      aboutMe: _aboutMe,
    );
    _settingProvider
        .updateDataFirestore(FirestoreConstants.pathUserCollection, _userId, updateInfo.toJson())
        .then((_) async {
      await _settingProvider.setPref(FirestoreConstants.nickname, _nickname);
      await _settingProvider.setPref(FirestoreConstants.aboutMe, _aboutMe);
      await _settingProvider.setPref(FirestoreConstants.photoUrl, _avatarUrl);

      setState(() {
        _isLoading = false;
      });

      Fluttertoast.showToast(msg: "Update success");
    }).catchError((err) {
      setState(() {
        _isLoading = false;
      });

      Fluttertoast.showToast(msg: err.toString());
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          AppConstants.settingsTitle,
          style: TextStyle(color: ColorConstants.primaryColor),
        ),
        centerTitle: true,
      ),
      body: Stack(
        children: [
          SingleChildScrollView(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Avatar
                CupertinoButton(
                  onPressed: () {
                    _pickAvatar().then((isSuccess) {
                      if (isSuccess) _uploadFile();
                    });
                  },
                  child: Container(
                    margin: EdgeInsets.all(20),
                    child: _avatarFile == null
                        ? _avatarUrl.isNotEmpty
                            ? ClipRRect(
                                borderRadius: BorderRadius.circular(45),
                                child: Image.network(
                                  _avatarUrl,
                                  fit: BoxFit.cover,
                                  width: 90,
                                  height: 90,
                                  errorBuilder: (_, __, ___) {
                                    return Icon(
                                      Icons.account_circle,
                                      size: 90,
                                      color: ColorConstants.greyColor,
                                    );
                                  },
                                  loadingBuilder: (_, child, loadingProgress) {
                                    if (loadingProgress == null) return child;
                                    return Container(
                                      width: 90,
                                      height: 90,
                                      child: Center(
                                        child: CircularProgressIndicator(
                                          color: ColorConstants.themeColor,
                                          value: loadingProgress.expectedTotalBytes != null
                                              ? loadingProgress.cumulativeBytesLoaded /
                                                  loadingProgress.expectedTotalBytes!
                                              : null,
                                        ),
                                      ),
                                    );
                                  },
                                ),
                              )
                            : Icon(
                                Icons.account_circle,
                                size: 90,
                                color: ColorConstants.greyColor,
                              )
                        : ClipOval(
                            child: Image.file(
                              _avatarFile!,
                              width: 90,
                              height: 90,
                              fit: BoxFit.cover,
                            ),
                          ),
                  ),
                ),

                // Input
                Column(
                  children: [
                    // Usuario
                    Container(
                      child: Text(
                        'Usuario',
                        style: TextStyle(
                          fontStyle: FontStyle.italic,
                          fontWeight: FontWeight.bold,
                          color: ColorConstants.primaryColor,
                        ),
                      ),
                      margin: EdgeInsets.only(left: 10, bottom: 5, top: 10),
                    ),
                    Container(
                      child: Theme(
                        data: Theme.of(context).copyWith(primaryColor: ColorConstants.primaryColor),
                        child: TextField(
                          decoration: InputDecoration(
                            hintText: 'Usuario',
                            contentPadding: EdgeInsets.all(5),
                            hintStyle: TextStyle(color: ColorConstants.greyColor),
                          ),
                          controller: _controllerNickname,
                          onChanged: (value) {
                            _nickname = value;
                          },
                          focusNode: _focusNodeNickname,
                        ),
                      ),
                      margin: EdgeInsets.only(left: 30, right: 30),
                    ),

                    // Rol (read-only)
                    Container(
                      child: Text(
                        'Rol',
                        style: TextStyle(
                          fontStyle: FontStyle.italic,
                          fontWeight: FontWeight.bold,
                          color: ColorConstants.primaryColor,
                        ),
                      ),
                      margin: EdgeInsets.only(left: 10, top: 30, bottom: 5),
                    ),
                    Container(
                      padding: EdgeInsets.symmetric(horizontal: 5, vertical: 10),
                      margin: EdgeInsets.only(left: 30, right: 30),
                      decoration: BoxDecoration(
                        border: Border(bottom: BorderSide(color: ColorConstants.greyColor)),
                      ),
                      child: Text(
                        _aboutMe.isNotEmpty ? _aboutMe : 'Sin rol asignado',
                        style: TextStyle(color: ColorConstants.primaryColor, fontSize: 15),
                      ),
                    ),
                  ],
                  crossAxisAlignment: CrossAxisAlignment.start,
                ),

                // Teléfono (todos los usuarios — para llamadas anónimas Twilio)
                ...[
                  Container(
                    margin: EdgeInsets.only(left: 10, top: 30, bottom: 5),
                    child: Row(
                      children: [
                        Icon(Icons.phone, size: 16, color: ColorConstants.primaryColor),
                        SizedBox(width: 6),
                        Text(
                          'Teléfono para llamadas anónimas',
                          style: TextStyle(
                            fontStyle: FontStyle.italic,
                            fontWeight: FontWeight.bold,
                            color: ColorConstants.primaryColor,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    margin: EdgeInsets.only(left: 30, right: 30),
                    child: Theme(
                      data: Theme.of(context).copyWith(primaryColor: ColorConstants.primaryColor),
                      child: TextField(
                        controller: _controllerPhone,
                        keyboardType: TextInputType.phone,
                        decoration: InputDecoration(
                          hintText: '+56912345678',
                          hintStyle: TextStyle(color: ColorConstants.greyColor),
                          contentPadding: EdgeInsets.all(5),
                        ),
                        onChanged: (v) => _phone = v,
                      ),
                    ),
                  ),
                  Container(
                    margin: EdgeInsets.only(left: 30, right: 30, top: 8),
                    child: Text(
                      'Twilio te llamará a este número y te conecta con el otro usuario. Nadie verá el número real del otro.',
                      style: TextStyle(fontSize: 11, color: ColorConstants.greyColor),
                    ),
                  ),
                  Container(
                    margin: EdgeInsets.only(top: 12, bottom: 4),
                    child: _savingPhone
                        ? CircularProgressIndicator()
                        : ElevatedButton.icon(
                            icon: Icon(Icons.save, size: 16),
                            label: Text('Guardar teléfono'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.green,
                              foregroundColor: Colors.white,
                              padding: EdgeInsets.symmetric(horizontal: 24, vertical: 10),
                            ),
                            onPressed: _savePhone,
                          ),
                  ),
                ],

                // Bubble color picker
                Container(
                  margin: const EdgeInsets.symmetric(vertical: 8),
                  child: ListTile(
                    leading: CircleAvatar(backgroundColor: _myBubbleColor, radius: 18),
                    title: const Text('Color de mis burbujas'),
                    subtitle: const Text('Toca para cambiar el color'),
                    onTap: _showColorPicker,
                  ),
                ),

                // Button
                Container(
                  child: TextButton(
                    onPressed: _handleUpdateData,
                    child: Text(
                      'Update',
                      style: TextStyle(fontSize: 16, color: Colors.white),
                    ),
                    style: ButtonStyle(
                      backgroundColor: WidgetStateProperty.all<Color>(ColorConstants.primaryColor),
                      padding: WidgetStateProperty.all<EdgeInsets>(
                        EdgeInsets.fromLTRB(30, 10, 30, 10),
                      ),
                    ),
                  ),
                  margin: EdgeInsets.only(top: 30, bottom: 50),
                ),
              ],
            ),
            padding: EdgeInsets.only(left: 15, right: 15),
          ),

          // Loading
          Positioned(child: _isLoading ? LoadingView() : SizedBox.shrink()),
        ],
      ),
    );
  }

  Future<void> _savePhone() async {
    final phone = _controllerPhone.text.trim();
    if (phone.isEmpty) return;
    setState(() => _savingPhone = true);
    try {
      await _settingProvider.setPref(FirestoreConstants.motoboyPhone, phone);
      final lamanoUserId = _settingProvider.getPref(FirestoreConstants.lamanoUserId) ?? '';
      if (lamanoUserId.isNotEmpty) {
        await http.post(
          Uri.parse('http://38.247.147.220/lamano/api_save_phone.php'),
          headers: {'Content-Type': 'application/json'},
          body: json.encode({'user_id': lamanoUserId, 'phone': phone}),
        );
      }
      setState(() { _phone = phone; _savingPhone = false; });
      Fluttertoast.showToast(msg: 'Teléfono guardado ✓', backgroundColor: Colors.green);
    } catch (_) {
      setState(() => _savingPhone = false);
      Fluttertoast.showToast(msg: 'Error al guardar', backgroundColor: Colors.red);
    }
  }

  @override
  void dispose() {
    _controllerNickname.dispose();
    _controllerAboutMe.dispose();
    _controllerPhone.dispose();
    _focusNodeNickname.dispose();
    _focusNodeAboutMe.dispose();
    super.dispose();
  }
}
