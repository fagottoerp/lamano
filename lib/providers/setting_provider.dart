import 'dart:io';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;

class SettingProvider {
  final SharedPreferences prefs;
  final FirebaseFirestore firebaseFirestore;

  SettingProvider({
    required this.prefs,
    required this.firebaseFirestore,
  });

  String? getPref(String key) {
    return prefs.getString(key);
  }

  Future<bool> setPref(String key, String value) async {
    return await prefs.setString(key, value);
  }

  Future<String> uploadFile(File image, String type) async {
    final userId = prefs.getString('id') ?? 'unknown';
    
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('http://93.127.135.73/lamano/api_upload_chat_file.php'),
    );
    
    request.fields['userId'] = userId;
    request.fields['type'] = type;
    request.files.add(await http.MultipartFile.fromPath('file', image.path));
    
    final response = await request.send();
    final responseBody = await response.stream.bytesToString();
    
    if (response.statusCode != 200) {
      throw Exception('Upload failed: $responseBody');
    }
    
    final json = jsonDecode(responseBody);
    return json['url'] as String;
  }

  Future<void> updateDataFirestore(String collectionPath, String path, Map<String, String> dataNeedUpdate) {
    return firebaseFirestore.collection(collectionPath).doc(path).update(dataNeedUpdate);
  }
}
